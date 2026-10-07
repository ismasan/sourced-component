# frozen_string_literal: true

require 'monitor'
require 'tsort'
require 'plumb'
require_relative 'component/version'
require_relative 'component/errors'
require_relative 'component/dsl'
require_relative 'component/implementation'
require_relative 'component/injector'
require_relative 'component/env_provider'
require_relative 'component/mermaid'
require_relative 'component/graph'
require_relative 'component/events'
require_relative 'component/notifier'
require_relative 'component/tree'
require_relative 'component/reconfiguration'

module Sourced
  # A tree of components. Every node is a Component: it can declare a type, be implemented with
  # dependencies and lifecycle hooks, have its own lifecycle status, and have subcomponents.
  #   app.declare('sourced.db', DB)                 # builds the 'sourced' > 'db' branch
  #   app.component!('sourced.db', ['logger']) { build { |logger| DB.new(logger:) } }
  #   app.mount('payments', Payments)               # attach an existing component as a branch
  # Components own their declarations and the sub-trees under them: an ancestor can implement
  # (or re-implement) any node below it, but can only declare under nodes it declared itself.
  # The root component drives the lifecycle of the whole tree.
  class Component
    module T
      include Plumb::Types
    end

    # Lifecycle statuses, in order. Shared by the root (boot status) and every node.
    # Only nodes are ever :stopped: a started node stopped by key (see #stop_component!),
    # which can be started again. Only nodes are ever :removed either: a component a
    # reconfiguration dropped from the tree (see #reconfigure), which is terminal.
    STATUSES = %i[open prepared built started stopped torn_down removed].freeze

    # What #mount takes: anything that returns a Component from #to_component
    MountableInterface = Plumb::Types::Interface[:to_component]

    # key:   local segment, ex. 'db'. nil for a root that isn't mounted anywhere
    # owner: the component that declared this node. Standalone components own themselves
    # type:  the declared type. Any for implicit nodes created as intermediate segments (namespaces)
    # index: every descendant, by relative key, ex. { 'sourced' => <Component>, 'sourced.db' => <Component> }
    attr_reader :key, :parent, :owner, :type, :implementation, :status, :value, :children, :index, :boot_status

    # notifier: receives lifecycle events. See Component::Notifier and Component::Events.
    # The root's notifier receives the events of the whole tree, so a mounted component uses its root's.
    def initialize(owner: nil, type: Plumb::Undefined, notifier: Notifier.new)
      @notifier = NotifierInterface.parse(notifier)
      @key = nil
      @parent = nil
      @owner = owner || self
      @implicit = Plumb::Undefined == type # not declared with a type: a namespace, unless implemented
      @type = @implicit ? Plumb::Types::Any : Plumb::Composable.wrap(type)
      @implementation = nil
      @status = :open
      @value = nil
      @deferred = false # skipped by the root's #start!, see #defer
      @held = false     # not started with the tree or its dependencies: deferred, or stopped by key
      @recycle_to = nil # the status to come back to while recycling, see #recycle_component!
      @reconfiguration = nil # the reconfiguration in progress, on the root only. See #reconfigure
      @deps = [].freeze      # resolved deps: a node, or { segment => node } for a wildcard
      @dep_nodes = [].freeze # every node in @deps, for sorting
      @children = {}
      @index = {}
      # Only used on the root
      @boot_status = :open
      @readable = false
      @starting = false
      @order = nil
      @lock = Monitor.new
    end

    def root = parent ? parent.root : self
    def root? = parent.nil?

    # The notifier lifecycle events are published to: the root's, for every component in the tree
    def notifier = root? ? @notifier : root.notifier

    # Full key from the root, ex. 'sourced.db'. nil for the root
    def path
      return nil unless parent

      [parent.path, key].compact.join('.')
    end

    def implicit? = @implicit
    def namespace? = implicit? && implementation.nil?

    # Whether the root's #start! skips it (see #defer)
    def deferred? = @deferred
    # Whether the tree refuses declarations. A #reconfigure block opens it again
    def locked? = root.boot_status != :open && !root.reconfiguring?

    # Whether a reconfiguration's block is running. Only ever true on the root
    def reconfiguring? = !@reconfiguration.nil?

    # The Reconfiguration in progress, which records what its block declares
    protected def reconfiguration = @reconfiguration

    def inspect
      details = namespace? ? '(namespace)' : "#{type_name} (#{[implementation&.mode || 'not implemented', status, ('deferred' if deferred?)].compact.join(', ')})"
      "#<#{self.class} #{path || '(root)'} #{details}>"
    end

    # Declare a typed node. Dot-separated keys build the tree, creating intermediate (namespace) nodes as needed.
    # An optional block provides a default singleton implementation.
    #   comp.declare('sourced.db.logger', Logger) { Logger.new(STDOUT) }
    def declare(ckey, type = T::Any, &default)
      synchronize do
        raise LockedComponentError, "can't declare #{ckey} in a locked component" if locked?

        branch, leaf = walk(ckey)
        node = branch.children[leaf]
        if node.nil?
          node = branch.attach(leaf, Component.new(owner: self, type:))
        elsif !node.owner.equal?(self)
          raise OwnershipError, ownership_message(node)
        elsif !node.implicit? && !root.reconfiguring?
          raise DeclarationOverrideError, "#{node.path} is already declared"
        else
          # Idempotent while reconfiguring: an unchanged component keeps its value and status,
          # and a changed type marks it to be recycled
          was = node.implicit? ? nil : node.type_name
          node.declare_type!(type) # an implicit namespace this component created, now with a type
          root.reconfiguration&.retyped!(node) if was && was != node.type_name
        end
        root.reconfiguration&.declared!(node)
        # While reconfiguring, only new components are announced: re-declaring the rest is noise
        unless root.reconfiguring? && !root.reconfiguration.created.include?(node)
          emit(Events::ComponentDeclared, key: node.path, type_name: node.type_name)
        end

        implement_node(node, Implementation.from_block([], implementer: self, mode: :singleton) { build(&default) }) if default
        self
      end
    end

    # Implement (or re-implement) a node anywhere under this component as a singleton,
    # built once on #build! and memoized. The last implementation wins.
    # Deps are keys relative to this component.
    #   comp.component!('sourced.db', ['logger']) do
    #     prepare { require 'sequel' }
    #     build { |logger| Sequel.sqlite(logger:) }
    #     start { |db, context| }
    #     teardown { |db| db.disconnect }
    #   end
    # Instead of a block, a provider can implement the component:
    # - a callable, called with the deps' values, as the build step
    # - or an object with #builder_for(node), which returns that callable for the node (ex. ENVProvider)
    # The callable can also implement any of #prepare, #start(value, context) and #teardown(value),
    # which become the component's other hooks.
    #   comp.component!('db', ['db.url'], DBFactory)    # DBFactory.call(url)
    #   comp.component!('clock', -> { Time })           # no deps
    #   comp.component!('user.email', Component::ENVProvider.new('USER_EMAIL'))
    # Given a component (anything with #to_component), it mounts it instead. See #mount
    #   comp.component!('sourced', Sourced)
    def component!(ckey, deps_or_provider = [], provider = nil, &block)
      return mount_from(ckey, deps_or_provider, provider, &block) if MountableInterface === deps_or_provider

      implement(ckey, deps_or_provider, provider, :singleton, &block)
    end

    # Same as #component!, but built on every read, ex. a per-request value.
    #   comp.component('request_id') { build { SecureRandom.uuid } }
    #   comp.component('request_id', -> { SecureRandom.uuid })
    # Given a component (anything with #to_component), it mounts it instead, same as #component!
    #   comp.component('sourced', Sourced)
    def component(ckey, deps_or_provider = [], provider = nil, &block)
      return mount_from(ckey, deps_or_provider, provider, &block) if MountableInterface === deps_or_provider

      implement(ckey, deps_or_provider, provider, :dynamic, &block)
    end

    # A singleton component with only a build step. The block gets the deps' values.
    #   comp.config!('db.url') { 'sqlite://app.db' }
    #   comp.config!('db', ['db.url']) { |url| DB.new(url) }
    def config!(ckey, deps = [], &build_block)
      raise ArgumentError, "config! #{ckey} needs a block to build its value" unless build_block

      implement(ckey, deps, build_block, :singleton)
    end

    # Same as #config!, but built on every read
    #   comp.config('now') { Time.now }
    def config(ckey, deps = [], &build_block)
      raise ArgumentError, "config #{ckey} needs a block to build its value" unless build_block

      implement(ckey, deps, build_block, :dynamic)
    end

    # Implement a node as an alias of another component: reading it reads the target, through the
    # node's declared type. Deps are keys relative to this component, and so is the target.
    #   comp.alias('sidereal.store', 'sourced.store')
    # Same as comp.config!('sidereal.store', ['sourced.store']) { |store| store }, except that an alias of a
    # dynamic component is dynamic too. An alias has no hooks: the target runs its own lifecycle,
    # and the alias follows it like any other dependent.
    def alias(ckey, target)
      synchronize do
        raise LockedComponentError, "can't implement #{ckey} in a locked component" if locked?

        implement_node(node(ckey), Implementation.alias(target, implementer: self))
        self
      end
    end

    # Implement singleton components built from ENV variables (see Component::ENVProvider),
    # decoding values into each declared type with Plumb::Codec::Forms. ENV is read when components are built.
    #   comp.env('USER_EMAIL' => 'user.email')        # a single variable
    #   comp.env(/^USER_/ => 'user.info')             # matching variables into a hash, match removed: USER_NAME => NAME
    #   comp.env(:downcase, /^USER_/ => 'user.info')  # ... with modifiers: USER_NAME => name
    #   comp.env('user.info')                         # all variables into a hash
    #   comp.env(:downcase, 'user.info')              # all variables, with modifiers
    # A hash can map several sources at once. Modifiers are only allowed when collecting variables with a regex.
    # Keys are relative to this component. Every source, key and type is checked before anything is implemented.
    def env(*args)
      mapping = args.last.is_a?(::Hash) ? args.pop : { ENVProvider::ALL => args.pop }
      if mapping.empty? || mapping.value?(nil)
        raise ArgumentError, 'env needs a component key, or a hash of ENV variables (or regexes) => component keys'
      end

      synchronize do
        raise LockedComponentError, "can't implement ENV components in a locked component" if locked?

        builders = mapping.map do |source, ckey|
          target = node(ckey)
          provider = ENVProvider.new(source, *args)
          [target, provider, provider.builder_for(target)]
        end
        builders.each do |target, provider, builder|
          implement_node(target, Implementation.from_builder(builder, [], implementer: self, mode: :singleton, provider:))
        end
        self
      end
    end

    # Defer a node under this component: the root's #start! skips it, and every component that
    # depends on it, directly or not, since they can't start before it. Start it by key instead,
    # ex. when its process is elected to run it (see #start_component!).
    #   app.defer('sourced.dispatcher')
    #   app.start!(task)                                # everything else
    #   app.start_component!('sourced.dispatcher', task) # later, and again after each #stop_component!
    # Deferring is a property of the node, not of its implementation, so it's kept when the node is
    # implemented again. Any component can defer a node below it, like implementing one.
    def defer(ckey)
      synchronize do
        raise LockedComponentError, "can't defer #{ckey} in a locked component" if locked?

        target = node(ckey)
        target.defer!
        emit(Events::ComponentDeferred, key: target.path, deferrer: path)
        self
      end
    end

    # Build an Injector for components under this component, by relative key.
    # Keys map to kwargs named after their last segment ('sourced.store' => :store),
    # and a Hash maps keys to custom kwarg names ('sourced.store' => 'st').
    #   class Dispatcher
    #     include App.inject('logger', 'sourced.store' => 'st')
    #   end
    # Values are read when objects are instantiated, so classes can be defined before the component is built.
    def inject(*keys)
      names = keys.each_with_object({}) do |arg, map|
        pairs = arg.is_a?(::Hash) ? arg : { arg => arg.to_s.split('.').last }
        pairs.each do |key, name|
          map[key.to_s] = name.to_sym
        end
      end

      duplicates = names.values.tally.select { |_, count| count > 1 }.keys
      raise ArgumentError, "duplicate injected names: #{duplicates.join(', ')}" if duplicates.any?

      Injector.new(names.to_h { |key, _| [key, node(key)] }, names)
    end

    # Attach an existing standalone component as a branch. It keeps owning its declarations,
    # and this component can implement its nodes.
    # Takes anything with #to_component, which must return a Component, ex. a library module:
    #   app.mount('sourced', Sourced.component)
    #   app.mount('sourced', Sourced) # Sourced.to_component => its Component
    def mount(ckey, mountable)
      unless MountableInterface === mountable
        raise ArgumentError, "can't mount #{mountable.inspect}: it must respond to #to_component"
      end

      sub = mountable.to_component
      raise ArgumentError, "#{mountable.inspect}.to_component must return a Component, got #{sub.inspect}" unless sub.is_a?(Component)

      synchronize do
        raise LockedComponentError, "can't mount #{ckey} in a locked component" if locked?
        raise SubcomponentError, "#{sub.inspect} is already mounted in another component" unless sub.root?
        raise SubcomponentError, "can't mount a component into its own tree" if sub.equal?(root)
        raise LockedComponentError, "can't mount a #{sub.boot_status} component: it must be open" if sub.locked?

        branch, leaf = walk(ckey)
        if (existing = branch.children[leaf])
          raise DeclarationOverrideError, "#{existing.path} is already declared: can't mount a component there"
        end

        branch.attach(leaf, sub)
        self
      end
    end

    # The mountable interface (see #mount)
    def to_component = self

    # A node under this component, by relative key
    def node(ckey)
      index.fetch(ckey.to_s) { raise UndeclaredComponentError, "#{ckey} is not declared in #{path || 'this component'}" }
    end

    def declared?(ckey) = index.key?(ckey.to_s)

    # Read a node's value. Singletons are memoized on #build!, dynamic nodes are built on each read.
    def [](ckey) = node(ckey).read

    def read
      raise RemovedComponentError, "#{path} was removed from the tree" if removed?
      raise NotBuiltError, 'component is not built yet' unless root.readable?
      raise UndeclaredComponentError, "#{path} is a namespace, not a component" unless implementation

      current_value
    end

    # ---- Lifecycle. Only the root drives it ----------------------------------------

    # Each step publishes root.<stage>ing and root.<stage>ed events (or root.failed),
    # and component events for every component whose hooks run. See Component::Events
    def prepare!
      raise_mounted!
      synchronize do
        return self if past?(:prepared)

        instrument_root(:prepare) do
          @order = resolve_order
          @order.each { |n| instrument_component(n, :prepare) { n.prepare_node! } }
          @boot_status = :prepared
        end
        self
      end
    end

    def build!
      raise_mounted!
      synchronize do
        prepare!
        return self if past?(:built)

        instrument_root(:build) do
          @order.each { |n| instrument_component(n, :build) { n.build_node! } }
          @boot_status = :built
          @readable = true
        end
        self
      end
    end

    # If a start hook raises, nodes already started are torn down (in reverse order),
    # the component is left :torn_down, and the error is re-raised.
    # :torn_down is terminal: starting a torn down component raises TornDownError.
    def start!(context = Thread.current)
      raise_mounted!
      synchronize do
        raise TornDownError, "can't start a torn down component" if boot_status == :torn_down

        build!
        return self if past?(:started)

        instrument_root(:start) do
          @starting = true
          @order.each do |n|
            # Deferred nodes, and the ones depending on them, wait to be started by key.
            # A start hook may already have started some of them by key (see #start_component!)
            next if n.held? || !n.dep_nodes.all? { |dep| dep.started? }

            instrument_component(n, :start) { n.start_node!(context) }
          end
          @boot_status = :started
        rescue Exception # rubocop:disable Lint/RescueException -- any error (incl. Interrupt) must tear down what was started. Always re-raised
          teardown_nodes(include_built: false)
          @boot_status = :torn_down
          raise
        ensure
          @starting = false
        end
        self
      end
    end

    # Tears down every node, in reverse dependency order, even if some raise. The first error is re-raised.
    # Started nodes run their stop hooks, then their teardown hooks. Nodes that never started (deferred)
    # or were stopped run their teardown hooks.
    def teardown!
      raise_mounted!
      synchronize do
        return self unless boot_status == :started

        instrument_root(:teardown) do
          errors = teardown_nodes(include_built: true)
          @boot_status = :torn_down
          raise errors.first if errors.any?
        end
        self
      end
    end

    # ---- Starting and stopping components by key ------------------------------------

    # Start a component that isn't running, by key relative to this component: a deferred one
    # (see #defer), or one stopped with #stop_component!. Follows the dependency graph:
    # - first, any of its dependencies that aren't running, in dependency order
    # - then the component itself
    # - then the components depending on it that aren't running, once all their dependencies are,
    #   ex. the ones its #stop_component! stopped. Not the ones stopped by key themselves
    # Each one runs its start hooks with +context+. A no-op for components already running.
    # If a start hook raises, the components this call started are stopped again, in reverse order,
    # and the error is re-raised: the rest of the tree is left as it was.
    # The root must be started, or starting (a start hook can start a deferred component).
    #   app.start_component!('sourced.dispatcher', task)
    def start_component!(ckey, context = Thread.current)
      synchronize do
        target = running_node(ckey)
        dependencies = target.transitive_dependencies
        dependents = target.transitive_dependents
        holds = [target, *dependencies].to_h { |n| [n, n.held?] }
        started = []

        begin
          root.order.each do |n|
            if n.equal?(target) || dependencies.include?(n)
              next if n.started?

              n.release!
            elsif dependents.include?(n)
              next if n.started? || n.held? || !n.dep_nodes.all? { |dep| dep.started? }
            else
              next
            end

            instrument_component(n, :start) { n.start_node!(context) }
            started << n
          end
        rescue Exception # rubocop:disable Lint/RescueException -- any error (incl. Interrupt) must stop what this call started. Always re-raised
          stop_nodes(started.reverse)
          holds.each { |n, held| n.hold! if held }
          raise
        end
        self
      end
    end

    # Stop a running component, by key relative to this component, and every running component
    # that depends on it, directly or not: dependents first, in reverse dependency order. Each one
    # runs its stop hooks, and keeps its value, so it can be started again (see #start_component!).
    # The component's own dependencies keep running.
    # The component stays stopped until it's started by key: the root's lifecycle, and starting
    # its dependencies, don't start it again. Its dependents start again with it.
    # Every one is stopped even if stop hooks raise, and the first error is re-raised.
    #   app.stop_component!('sourced.dispatcher')
    def stop_component!(ckey)
      synchronize do
        target = running_node(ckey)
        target.hold!
        stopping = [target, *target.transitive_dependents]
        errors = stop_nodes(root.order.reverse.select { |n| stopping.include?(n) && n.started? })
        raise errors.first if errors.any?

        self
      end
    end

    # #stop_component! then #start_component!: stops the component and its dependents, and starts
    # them again, in dependency order.
    #   app.restart_component!('sourced.dispatcher', task)
    def restart_component!(ckey, context = Thread.current)
      synchronize do
        stop_component!(ckey)
        start_component!(ckey, context)
      end
    end

    # ---- Recycling components -------------------------------------------------------

    # Run a component's whole lifecycle again, by key relative to this component: stop it if it's
    # running, tear it down, drop its value, then prepare and build it from scratch.
    # Every component depending on it, directly or not, is recycled too: their values were built
    # from its old one. Its own dependencies are left alone.
    # Each one is left in the status it had before, so a started component is started again with
    # +context+, and one that was only built stops at built. A component that was stopped by key
    # (or deferred) comes back built and still held: the fresh value has never run, so it waits to
    # be started by key, as it was.
    # If a stop or teardown hook raises, every component is still torn down and its value dropped,
    # and the first error is re-raised before anything is prepared again. A prepare, build or start
    # hook leaves the component where it got to. Either way, recycling again recovers: each one
    # remembers the status to restore until a recycle completes, so a retry puts it back even when
    # its own status no longer says it was running.
    # The root must be built, or started, and not booting.
    #   app.recycle_component!('sourced.store')
    def recycle_component!(ckey, context = Thread.current)
      recycle_components!(ckey, context:)
    end

    # #recycle_component! for several keys at once: a component depending on more than one of them
    # is recycled once, not once per key.
    #   app.recycle_components!('sourced.store', 'repos.users')
    def recycle_components!(*ckeys, context: Thread.current)
      synchronize do
        nodes = ckeys.flatten.map { |ckey| recyclable_node(ckey) }
        # Recycling nothing resolves no nodes, so it checks the tree itself, and does nothing
        if nodes.empty?
          check_recyclable!('components')
          return self
        end

        recycle_nodes!(nodes, context)
      end
    end

    # #recycle_component! for every component in the tree, in dependency order. Only the root
    # can recycle the whole tree.
    #   app.recycle!
    def recycle!(context = Thread.current)
      raise_mounted!
      synchronize do
        check_recyclable!('the tree')
        recycle_nodes!(order, context)
      end
    end

    # ---- Re-configuring a booted tree ----------------------------------------------

    # Re-declare one branch of a booted tree, by key relative to this component. The block declares
    # the branch's new contents, and whatever it doesn't declare is removed.
    # Re-declaring a key is idempotent, so a component that didn't change keeps its value and status.
    # Re-implementing it, re-typing it, or declaring a new key recycles it (see #recycle_component!),
    # along with its dependents and anything whose resolved deps changed, ex. a wildcard over the branch.
    # Nothing runs any hooks until the new set is validated, so a block that raises, or a set with a
    # missing dep or a cycle, leaves the tree as it was. Holds survive: stopped stays stopped.
    #   app.reconfigure('reactors') do |reactors|
    #     files.each { |f| reactors.declare(f.key) }
    #     changed.each { |f| reactors.component!(f.key, f.deps, &f.implementation) }
    #   end
    def reconfigure(ckey, context = Thread.current, &block)
      raise ArgumentError, "reconfigure #{ckey}: a block must declare the branch's contents" unless block

      synchronize do
        branch = reconfigurable_branch(ckey)
        reconf = Reconfiguration.new(branch, self)
        root.reconfiguring!(reconf)

        begin
          instrument_root(:reconfigure) do
            reconf.snapshot!(root)
            plan = begin
              block.call(reconf.branch_handle)
              validate_reconfiguration!(reconf)
            rescue Exception # rubocop:disable Lint/RescueException -- nothing has run yet: put the tree back, whatever it was. Always re-raised
              reconf.rollback!
              raise
            end
            commit_reconfiguration!(reconf, plan, context)
          end
        ensure
          root.reconfiguring!(nil)
        end
        self
      end
    end

    # A Component::Graph describing the components under this component, by full path from the root.
    # Components are listed in dependency order once the tree is prepared, and in declaration order before that.
    # Namespaces without an implementation are left out.
    #   graph = comp.graph
    #   graph.status         # => :built, the root's status
    #   graph.components     # => [{ key: 'logger', type:, type_name:, implemented:, mode:, status:, deps:, missing:, dependents:, provider: }, ...]
    #   graph.to_mermaid     # => a Mermaid flowchart
    # See Component::Graph
    def graph
      synchronize do
        nodes = index.values.reject(&:namespace?)
        nodes = (root.order & nodes) | nodes if root.order

        described = nodes.map { |n| [n, *graph_deps(n)] }
        dependents = Hash.new { |h, k| h[k] = [] }
        described.each { |n, deps, _| deps.each { |dep| dependents[dep] << n.path } }

        components = described.map do |n, deps, missing|
          impl = n.implementation
          {
            key: n.path,
            type: n.type,
            type_name: n.type_name,
            implemented: !impl.nil?,
            mode: impl&.mode,
            status: n.status,
            deferred: n.deferred?,
            deps:,
            missing:,
            dependents: dependents[n.path],
            provider: impl&.provider
          }
        end

        Graph.new(status: root.boot_status, components:)
      end
    end

    # A Component::Tree of the components under this one, as nested nodes: how components are nested,
    # which components are mounted, and who declared and implemented each one. See #graph for dependencies.
    #   puts App.tree
    #   (root)
    #   ├── logger Interface[info] (singleton, built)
    #   └── sourced [mounted]
    #       └── db DB (singleton, built) implemented by (root)
    def tree
      synchronize { Tree.new(status: root.boot_status, root: tree_node) }
    end

    protected def tree_node
      Tree::Node.new(
        key:,
        path:,
        type:,
        type_name:,
        namespace: namespace?,
        mounted: !root? && owner.equal?(self),
        implemented: !implementation.nil?,
        mode: implementation&.mode,
        status:,
        deferred: deferred?,
        owner: owner.equal?(self) ? path : owner.path,
        implementer: implementation&.implementer&.path,
        children: children.values.map { |child| child.tree_node }
      )
    end

    # Nodes in dependency order. Available after #prepare!
    def ordered_nodes
      raise_mounted!
      raise NotBuiltError, 'component is not prepared yet' unless @order

      @order.dup
    end

    # ---- Node internals -------------------------------------------------------------

    # The nodes this one depends on, resolved on #prepare!, wildcards included. See #graph for keys
    def dep_nodes = @dep_nodes

    # Every node in dependency order, or nil before #prepare!. #ordered_nodes is the checked version
    def order = @order

    # Whether a #reconfigure dropped this node. Terminal: reading it raises RemovedComponentError
    def removed? = status == :removed

    protected def readable? = @readable
    protected def starting? = @starting
    protected def lock = @lock

    private def synchronize(&) = root.lock.synchronize(&)

    protected def declare_type!(type)
      @implicit = false
      @type = Plumb::Composable.wrap(type)
    end

    # Back to an implicit namespace: a dropped component that still has children (see #reconfigure).
    # Returns the implementation it had, to tear it down with, and keeps its value until then.
    # Clearing it before the order is resolved leaves it out, and fails validation for its dependents
    protected def undeclare_type!
      @implicit = true
      @type = Plumb::Types::Any
      @deps = [].freeze
      @dep_nodes = [].freeze
      @implementation.tap { @implementation = nil }
    end

    # Run a reverted component's hooks with the implementation it had, then leave it a bare namespace
    protected def teardown_reverted!(implementation)
      return self unless %i[built started stopped].include?(status)

      begin
        implementation.stop(value) if started?
      ensure
        implementation.teardown(value)
      end
      @status = :open
      @value = nil
      self
    end

    protected def implement!(implementation)
      @implementation = implementation
    end

    protected def defer! = @deferred = true
    protected def held? = @held
    protected def hold! = @held = true
    protected def release! = @held = false
    protected def started? = status == :started

    # ---- Reconfiguration internals (see #reconfigure) -------------------------------

    # Public because Component::Reconfiguration is a collaborator, not another Component

    def reconfiguring!(reconf) = @reconfiguration = reconf
    def restore_order!(order) = @order = order

    # Re-resolve every node's deps and the order, leaving holds alone. Raises if the new set is invalid
    def reresolve! = resolve_order(reset_holds: false)

    # Everything a reconfiguration can change about a node, to snapshot and roll back
    def reconfigurable_state
      {
        implementation: @implementation, type: @type, implicit: @implicit, deps: @deps,
        dep_nodes: @dep_nodes, deferred: @deferred, held: @held, status: @status, value: @value,
        recycle_to: @recycle_to
      }
    end

    def reconfigurable_state=(state)
      @implementation = state[:implementation]
      @type = state[:type]
      @implicit = state[:implicit]
      @deps = state[:deps]
      @dep_nodes = state[:dep_nodes]
      @deferred = state[:deferred]
      @held = state[:held]
      @status = state[:status]
      @value = state[:value]
      @recycle_to = state[:recycle_to]
    end

    def restore_children!(children) = @children = children
    def restore_index!(index) = @index = index

    # The status a recycle is bringing this node back to, remembered before anything is torn down.
    # A recycle that raises leaves it set, so a retry restores what the first one meant to: the
    # node's own status is no use by then, ex. :built for one a failed start never reached
    protected def recycle_to = @recycle_to
    protected def recycle_to!(status) = @recycle_to = status
    protected def recycled! = @recycle_to = nil

    # Every node this one depends on, directly or not
    protected def transitive_dependencies
      dep_nodes.each_with_object([]) do |dep, all|
        next if all.include?(dep)

        all << dep
        dep.transitive_dependencies.each { |n| all << n unless all.include?(n) }
      end
    end

    # Every node that depends on this one, directly or not. Nodes come after their
    # dependencies in the root's order, so one pass over the order finds them all.
    protected def transitive_dependents
      reached = [self]
      root.order.each do |n|
        reached << n if !reached.include?(n) && n.dep_nodes.any? { |dep| reached.include?(dep) }
      end
      reached.drop(1)
    end

    protected def adopt!(parent, key)
      @parent = parent
      @key = key.freeze
    end

    # Add a child node and index it (and its own descendants) here and in every ancestor
    protected def attach(segment, child)
      @children[segment] = child
      child.adopt!(self, segment)
      index!(segment, child)
      child.index.each { |sub_key, n| index!("#{segment}.#{sub_key}", n) }
      child
    end

    protected def index!(ckey, node)
      @index[ckey] = node
      parent&.index!("#{key}.#{ckey}", node)
    end

    # The inverse of #index!: drop a descendant here and in every ancestor
    protected def unindex!(ckey)
      @index.delete(ckey)
      parent&.unindex!("#{key}.#{ckey}")
    end

    # Drop a child and its descendants from this node's children, and from every index
    protected def detach!(segment)
      child = @children.delete(segment)
      return nil unless child

      child.index.each_key { |sub_key| unindex!("#{segment}.#{sub_key}") }
      unindex!(segment)
      child
    end

    # Resolve deps through the implementer's index. Called on #prepare!, so declaration order doesn't matter.
    # A wildcard dep ('reactors.*') resolves to a hash of the components directly under its key, by segment,
    # and to an empty hash if there are none.
    protected def resolve_deps!
      @deps = implementation.deps.map do |dep|
        next wildcard_nodes(dep) if dep.end_with?('.*')

        dep_node = implementation.implementer.index[dep]
        unless dep_node && !dep_node.namespace?
          where = implementation.implementer.path
          full = [where, dep].compact.join('.')
          raise MissingDependencyError, "#{path} depends on #{full}, which is not #{dep_node ? 'implemented' : 'declared'}"
        end

        dep_node
      end.freeze
      @dep_nodes = @deps.flat_map { |d| d.is_a?(::Hash) ? d.values : [d] }.freeze
    end

    # { 'segment' => <Component> } for the components directly under a wildcard dep's key
    protected def wildcard_nodes(dep)
      branch = implementation.implementer.index[dep.delete_suffix('.*')]
      return {}.freeze unless branch

      branch.children.reject { |_, child| child.namespace? }.freeze
    end

    protected def prepare_node!
      return self unless pending?(:prepare)

      implementation.prepare
      @status = :prepared
      self
    end

    protected def build_node!
      return self unless pending?(:build)

      @value = build_value if memoized?
      @status = :built
      self
    end

    # From :built, or again from :stopped
    protected def start_node!(context)
      return self unless pending?(:start)

      implementation.start(value, context)
      @status = :started
      recycled! # whatever a recycle meant to restore, this is the node's status now
      self
    end

    # Stopped even if a stop hook raises: it's no longer running either way
    protected def stop_node!
      return self unless pending?(:stop)

      begin
        implementation.stop(value)
      ensure
        @status = :stopped
        recycled! # ... and the same when a component is stopped by key
      end
      self
    end

    # A started node runs its stop hooks first. Teardown hooks run even if those raise, and the node
    # is torn down whatever they raise (incl. Interrupt): its hooks have had their turn either way,
    # and running them again would tear the same value down twice
    protected def teardown_node!
      return self unless pending?(:teardown)

      was_started = started?
      @status = :torn_down
      begin
        implementation.stop(value) if was_started
      ensure
        implementation.teardown(value)
      end
      self
    end

    # Back to :open, so every hook runs again from the top (see #recycle_component!).
    # Keeps the node's hold, its deps and its place in the root's order: the tree is locked,
    # so nothing about the graph can have changed
    protected def recycle_node!
      @status = :open
      @value = nil
      self
    end

    # Whether the node has been built. A torn down node keeps its value, which stays readable;
    # recycling drops it, back to :open, and removing it drops it for good
    protected def built? = !%i[open prepared removed].include?(status)

    # Drop the value and mark the node removed, once torn down: anything still holding it (an
    # Injector, say) then fails loudly instead of reading a dead value. Terminal
    protected def remove_node!
      @value = nil
      @status = :removed
      self
    end

    # Without the readable check: deps are read while the component is building, in dependency order
    protected def current_value
      raise RemovedComponentError, "#{path} was removed from the tree" if removed?
      raise NotBuiltError, "#{path} is not built: it was torn down or recycled" if memoized? && !built?

      memoized? ? value : build_value
    end

    # Whether the value is built once, on #build!: singletons, and aliases of memoized components.
    # Only known once deps are resolved, on #prepare!
    protected def memoized?
      implementation.alias? ? dep_nodes.first.memoized? : implementation.singleton?
    end

    # Parse the built value through the declared type. Type errors name the component, ex.
    #   Plumb::ParseError: db.port: Must be a Integer
    # The value is left out, as it can hold secrets.
    private def build_value
      values = @deps.map { |d| d.is_a?(::Hash) ? d.transform_values { |n| n.current_value } : d.current_value }
      result = type.resolve(implementation.build(*values))
      return result.value if result.valid?

      errors = result.errors.is_a?(::String) ? result.errors : result.errors.inspect
      raise Plumb::ParseError, "#{path || '(root)'}: #{errors}"
    end

    # Whether a lifecycle stage would run this node's hooks
    protected def pending?(stage)
      case stage
      when :prepare then status == :open
      when :build then status == :prepared
      when :start then status == :built || status == :stopped
      when :stop then started?
      when :teardown then %i[built started stopped].include?(status)
      end
    end

    # ---- Root internals -------------------------------------------------------------

    private def raise_mounted!
      raise SubcomponentError, "#{path} is mounted in another component: boot the root" unless root?
    end

    private def past?(new_status)
      STATUSES.index(boot_status) >= STATUSES.index(new_status)
    end

    # Every node that is declared or implemented, in dependency order
    # reset_holds: release every node and hold only the deferred ones, as a first boot does.
    # A reconfiguration passes false: a component stopped by #stop_component! must stay held,
    # or it would start again on the next re-declaration
    private def resolve_order(reset_holds: true)
      nodes = [self, *index.values].reject(&:namespace?)

      unimplemented = nodes.reject(&:implementation)
      if unimplemented.any?
        raise UnimplementedComponentError, "components are declared but not implemented: #{unimplemented.map(&:path).join(', ')}"
      end

      deferred_namespaces = index.values.select { |n| n.deferred? && n.namespace? }
      if deferred_namespaces.any?
        raise UnimplementedComponentError, "components are deferred but not implemented: #{deferred_namespaces.map(&:path).join(', ')}"
      end

      nodes.each do |n|
        n.resolve_deps!
        next unless reset_holds

        n.release!
        n.hold! if n.deferred?
      end

      each_node = ->(&b) { nodes.each(&b) }
      each_child = ->(n, &b) { n.dep_nodes.each(&b) }
      cycle = TSort.each_strongly_connected_component(each_node, each_child).find do |c|
        c.size > 1 || c.first.dep_nodes.include?(c.first)
      end
      raise CircularDependencyError, "circular dependency between #{cycle.map(&:path).join(', ')}" if cycle

      TSort.tsort(each_node, each_child)
    end

    # include_built: also tear down nodes that are built but never started (deferred, or depending
    # on a deferred node). A failed #start! leaves the ones it didn't reach alone.
    private def teardown_nodes(include_built:)
      @order.reverse.each_with_object([]) do |n, errors|
        next if !include_built && n.status == :built

        instrument_component(n, :teardown) { n.teardown_node! }
      rescue Exception => e # rubocop:disable Lint/RescueException -- any error (incl. Interrupt) must still tear the rest down. The first is re-raised
        errors << e
      end
    end

    # Stop the given nodes, in the given order, even if some raise. Returns the errors
    private def stop_nodes(nodes)
      nodes.each_with_object([]) do |n, errors|
        instrument_component(n, :stop) { n.stop_node! }
      rescue StandardError => e
        errors << e
      end
    end

    # A node to start or stop by key: implemented, under a root that's started, or starting
    private def running_node(ckey)
      target = node(ckey)
      raise UndeclaredComponentError, "#{target.path} is a namespace, not a component" if target.namespace?
      raise TornDownError, "can't start or stop #{target.path}: the component is torn down" if root.boot_status == :torn_down
      unless root.boot_status == :started || root.starting?
        raise NotStartedError, "can't start or stop #{target.path} before the root is started: start! it first"
      end

      target
    end

    # A node to recycle by key: implemented, under a root that can be recycled
    private def recyclable_node(ckey)
      target = node(ckey)
      raise UndeclaredComponentError, "#{target.path} is a namespace, not a component" if target.namespace?

      check_recyclable!(target.path)
      target
    end

    # A branch to reconfigure: a namespace, under a tree that isn't booting or torn down
    private def reconfigurable_branch(ckey)
      branch = node(ckey)
      raise LockedComponentError, "can't reconfigure #{branch.path}: a reconfiguration is already running" if root.reconfiguring?
      raise TornDownError, "can't reconfigure #{branch.path}: the component is torn down" if root.boot_status == :torn_down
      if root.starting?
        raise LockedComponentError, "can't reconfigure #{branch.path} while the root is booting"
      end
      unless branch.namespace?
        raise UndeclaredComponentError, "#{branch.path} is a component, not a namespace: reconfigure the branch above it"
      end

      mounted = [branch, *branch.index.values].find { |n| n.owner.equal?(n) && !n.root? }
      raise SubcomponentError, "can't reconfigure #{branch.path}: #{mounted.path} is a mounted component" if mounted

      branch
    end

    # Apply the new set structurally and re-resolve, before any hooks run: raises what a first boot
    # would if it's invalid, with nothing torn down yet
    private def validate_reconfiguration!(reconf)
      reverting = reconf.reverting
      removing = reconf.emptied_namespaces(reconf.removable)

      # Each reverted component hands its implementation back, to tear down once validation passes
      reverted = reverting.to_h { |n| [n, n.undeclare_type!] }
      removing.each { |n| n.parent.detach!(n.key) }

      # An open tree has nothing resolved or built: #prepare! validates the set when it boots
      { reverting:, reverted:, removing:, order: root.boot_status == :open ? nil : root.reresolve! }
    end

    # Past validation, so nothing here rolls back: tear down what's going, recycle what changed
    private def commit_reconfiguration!(reconf, plan, context)
      booted = !plan[:order].nil?
      old_order = reconf.order_before
      root.restore_order!(plan[:order]) if booted

      # Dependents first. On an open tree every hook is pending?-skipped, so this only unindexes
      going = plan[:removing] + plan[:reverting]
      going.sort_by { |n| -(old_order.index(n) || -1) }.each do |n|
        if (implementation = plan[:reverted][n])
          instrument_component(n, :teardown) { n.teardown_reverted!(implementation) }
          next
        end

        instrument_component(n, :teardown) { n.teardown_node! }
        n.remove_node!
        emit(Events::ComponentRemoved, key: n.path, remover: path)
      end
      return unless booted

      # Nothing new has a status to go back to, so it comes up to wherever the root is
      coming_up = root.boot_status == :started ? :started : :built
      reconf.newly_components.each do |n|
        n.hold! if n.deferred?
        n.recycle_to!(n.deferred? ? :built : coming_up)
      end
      affected = reconf.affected
      recycle_nodes!(affected, context) if affected.any?
    end

    # Whether the tree can be recycled: built or started, and not booting. +what+ names what
    # the caller is recycling, for the error messages
    private def check_recyclable!(what)
      raise TornDownError, "can't recycle #{what}: the component is torn down" if root.boot_status == :torn_down
      if root.starting?
        raise LockedComponentError, "can't recycle #{what} while the root is booting: it has no status to go back to"
      end
      return if %i[built started].include?(root.boot_status)

      raise NotBuiltError, "can't recycle #{what} before the root is built: build! it first"
    end

    # Tear the targets and their dependents down, drop their values, and prepare and build them
    # again, leaving each one in the status it had before. See #recycle_component!
    private def recycle_nodes!(targets, context)
      affected = targets.flat_map { |t| [t, *t.transitive_dependents] }.uniq
      ordered = root.order.select { |n| affected.include?(n) }
      # What each node comes back to, remembered before anything is torn down. A node a previous
      # recycle left part way through keeps the status that recycle meant to restore
      ordered.each { |n| n.recycle_to!(n.recycle_to || n.status) }

      instrument_root(:recycle) do
        # Down, dependents first. Started nodes run their stop hooks, then their teardown hooks.
        # Their values are dropped whatever a hook raises (incl. Interrupt): they've been torn down
        errors = []
        begin
          ordered.reverse.each do |n|
            instrument_component(n, :teardown) { n.teardown_node! }
          rescue Exception => e # rubocop:disable Lint/RescueException -- as #teardown_nodes: the rest are still torn down
            errors << e
          end
        ensure
          ordered.each { |n| n.recycle_node! }
        end
        raise errors.first if errors.any?

        # And up again, in dependency order, one stage at a time, as the root boots
        ordered.each { |n| instrument_component(n, :prepare) { n.prepare_node! } }
        ordered.each { |n| instrument_component(n, :build) { n.build_node! } }
        ordered.each do |n|
          next unless n.recycle_to == :started && n.dep_nodes.all? { |dep| dep.started? }

          instrument_component(n, :start) { n.start_node!(context) }
        end
        # Only once every node is back: a recycle that raises keeps the statuses for the retry
        ordered.each { |n| n.recycled! }
      end
      self
    end

    # ---- Telemetry ------------------------------------------------------------------

    # Publish root.<stage>ing, run the block, and publish root.<stage>ed with its duration,
    # or root.failed if it raises.
    private def instrument_root(stage)
      before, after = ROOT_EVENTS.fetch(stage)
      emit(before)
      started_at = now
      begin
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised
        emit(Events::RootFailed, stage:, **error_attributes(e))
        raise
      end
      emit(after, duration: now - started_at)
    end

    # Same as #instrument_root for a component, but only if the stage would run its hooks.
    # Components that aren't memoized aren't built on #build!, so they don't publish build events.
    private def instrument_component(node, stage)
      return yield unless node.pending?(stage)
      return yield if stage == :build && !node.memoized?

      before, after = COMPONENT_EVENTS.fetch(stage)
      emit(before, key: node.path)
      started_at = now
      begin
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised
        emit(Events::ComponentFailed, key: node.path, stage:, **error_attributes(e))
        raise
      end
      emit(after, key: node.path, duration: now - started_at)
    end

    # Errors as JSON-friendly values. See Component::Event
    private def error_attributes(error)
      {
        error_class: error.class.name || error.class.inspect,
        error_message: error.message.to_s,
        backtrace: error.backtrace || []
      }
    end

    # Publish an event to the root's notifier, with the process, thread and fiber it was published from
    private def emit(event_class, **attrs)
      event = event_class.new(
        payload: {
          pid: Process.pid,
          thread_id: Thread.current.object_id,
          fiber_id: Fiber.current.object_id,
          **attrs
        }
      )
      raise ArgumentError, "invalid #{event_class.type} event: #{event.errors}" unless event.valid?

      notifier.publish(event)
    end

    private def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # #component! and #component given a component: an alias to #mount, which takes nothing else
    private def mount_from(ckey, mountable, provider, &block)
      raise ArgumentError, "#{ckey}: can't pass a provider or a block when mounting a component" if provider || block

      mount(ckey, mountable)
    end

    # deps_or_provider: deps, or a provider when there are no deps (#component!('clock', -> { Time }))
    private def implement(ckey, deps_or_provider, provider, mode, &block)
      deps = deps_or_provider
      unless deps.is_a?(::Array)
        raise ArgumentError, "#{ckey}: deps must be an Array, got #{deps.inspect}" if provider

        deps = []
        provider = deps_or_provider
      end
      raise ArgumentError, "#{ckey}: pass either a provider or a block, not both" if provider && block

      synchronize do
        raise LockedComponentError, "can't implement #{ckey} in a locked component" if locked?

        target = node(ckey)
        implementation = if provider
                           Implementation.from_builder(builder_from(target, provider), deps, implementer: self, mode:, provider:)
                         else
                           Implementation.from_block(deps, implementer: self, mode:, &block)
                         end
        implement_node(target, implementation)
        self
      end
    end

    private def implement_node(target, implementation)
      override = !target.implementation.nil?
      target.implement!(implementation)
      root.reconfiguration&.implemented!(target)
      emit(
        Events::ComponentImplemented,
        key: target.path,
        mode: implementation.mode,
        deps: implementation.deps,
        implementer: implementation.implementer.path,
        override:
      )
    end

    # The builder for a node, from a provider: the provider itself if it's callable,
    # or what its #builder_for(node) returns, which must be callable.
    private def builder_from(target, provider)
      if provider.respond_to?(:builder_for)
        builder = provider.builder_for(target)
        return builder if builder.respond_to?(:call)

        raise ArgumentError, "#{target.path}: #{provider.inspect}.builder_for must return a callable, got #{builder.inspect}"
      end
      return provider if provider.respond_to?(:call)

      raise ArgumentError, "#{target.path}: a provider must respond to #call or #builder_for(node), got #{provider.inspect}"
    end

    # A node's deps, as full paths, and the ones that don't resolve to a component
    private def graph_deps(node)
      impl = node.implementation
      return [[], []] unless impl

      impl.deps.each_with_object([[], []]) do |dep, (deps, missing)|
        if dep.end_with?('.*')
          deps.concat(node.wildcard_nodes(dep).values.map(&:path))
          next
        end

        target = impl.implementer.index[dep]
        if target && !target.namespace?
          deps << target.path
        else
          full = [impl.implementer.path, dep].compact.join('.')
          deps << full
          missing << full
        end
      end
    end

    # Walk a key's intermediate segments from this component, creating namespace nodes owned by it.
    # Returns the branch node and the last segment.
    private def walk(ckey)
      ckey = ckey.to_s
      raise ArgumentError, "invalid key #{ckey.inspect}" unless ckey.match?(/\A[^.]+(\.[^.]+)*\z/)

      *segments, leaf = ckey.split('.')
      branch = segments.reduce(self) do |current, segment|
        child = current.children[segment] || current.attach(segment, Component.new(owner: self))
        raise OwnershipError, ownership_message(child) unless child.owner.equal?(self)

        child
      end
      [branch, leaf.freeze]
    end

    private def ownership_message(node)
      owner = node.owner.path || 'another component'
      "#{node.path} is owned by #{owner}: declare it there. This component can only implement it"
    end

    protected def type_name = type.inspect.gsub(/(Plumb::Types|Sourced::Component::T)::/, '')
  end
end
