# frozen_string_literal: true

require 'monitor'
require 'tsort'
require 'plumb'
require_relative 'system/version'
require_relative 'system/errors'
require_relative 'system/dsl'
require_relative 'system/implementation'
require_relative 'system/injector'
require_relative 'system/env_provider'
require_relative 'system/graph'
require_relative 'system/events'
require_relative 'system/notifier'

module Sourced
  # A tree of systems. Every node is a System: it can declare a type, be implemented with
  # dependencies and lifecycle hooks, have its own lifecycle status, and have sub-systems.
  #   app.declare('sourced.db', DB)                 # builds the 'sourced' > 'db' branch
  #   app.component!('sourced.db', ['logger']) { build { |logger| DB.new(logger:) } }
  #   app.mount('payments', Payments)               # attach an existing system as a branch
  # Systems own their declarations and the sub-trees under them: an ancestor can implement
  # (or re-implement) any node below it, but can only declare under nodes it declared itself.
  # The root system drives the lifecycle of the whole tree.
  class System
    module T
      include Plumb::Types
    end

    # Lifecycle statuses, in order. Shared by the root (boot status) and every node.
    STATUSES = %i[open prepared built started toredown].freeze

    # What #mount takes: anything that returns a System from #to_system
    MountableInterface = Plumb::Types::Interface[:to_system]

    # key:   local segment, ex. 'db'. nil for a root that isn't mounted anywhere
    # owner: the system that declared this node. Standalone systems own themselves
    # type:  the declared type. Any for implicit nodes created as intermediate segments (namespaces)
    # index: every descendant, by relative key, ex. { 'sourced' => <System>, 'sourced.db' => <System> }
    attr_reader :key, :parent, :owner, :type, :implementation, :status, :value, :children, :index, :boot_status

    # notifier: receives lifecycle events. See System::Notifier and System::Events.
    # The root's notifier receives the events of the whole tree, so a mounted system uses its root's.
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
      @dep_nodes = [].freeze
      @children = {}
      @index = {}
      # Only used on the root
      @boot_status = :open
      @readable = false
      @order = nil
      @lock = Monitor.new
    end

    def root = parent ? parent.root : self
    def root? = parent.nil?

    # The notifier lifecycle events are published to: the root's, for every system in the tree
    def notifier = root? ? @notifier : root.notifier

    # Full key from the root, ex. 'sourced.db'. nil for the root
    def path
      return nil unless parent

      [parent.path, key].compact.join('.')
    end

    def implicit? = @implicit
    def namespace? = implicit? && implementation.nil?
    def locked? = root.boot_status != :open

    def inspect
      details = namespace? ? '(namespace)' : "#{type_name} (#{implementation&.mode || 'not implemented'}, #{status})"
      "#<#{self.class} #{path || '(root)'} #{details}>"
    end

    # Declare a typed node. Dot-separated keys build the tree, creating intermediate (namespace) nodes as needed.
    # An optional block provides a default singleton implementation.
    #   sys.declare('sourced.db.logger', Logger) { Logger.new(STDOUT) }
    def declare(ckey, type = T::Any, &default)
      synchronize do
        raise LockedSystemError, "can't declare #{ckey} in a locked system" if locked?

        branch, leaf = walk(ckey)
        node = branch.children[leaf]
        if node.nil?
          node = branch.attach(leaf, System.new(owner: self, type:))
        elsif !node.owner.equal?(self)
          raise OwnershipError, ownership_message(node)
        elsif !node.implicit?
          raise DeclarationOverrideError, "#{node.path} is already declared"
        else
          node.declare_type!(type) # an implicit namespace this system created, now with a type
        end
        emit(Events::ComponentDeclared, key: node.path, type_name: node.type_name)

        implement_node(node, Implementation.from_block([], implementer: self, mode: :singleton) { build(&default) }) if default
        self
      end
    end

    # Implement (or re-implement) a node anywhere under this system as a singleton,
    # built once on #build! and memoized. The last implementation wins.
    # Deps are keys relative to this system.
    #   sys.component!('sourced.db', ['logger']) do
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
    #   sys.component!('db', ['db.url'], DBFactory)    # DBFactory.call(url)
    #   sys.component!('clock', -> { Time })           # no deps
    #   sys.component!('user.email', System::ENVProvider.new('USER_EMAIL'))
    def component!(ckey, deps_or_provider = [], provider = nil, &block)
      implement(ckey, deps_or_provider, provider, :singleton, &block)
    end

    # Same as #component!, but built on every read, ex. a per-request value.
    #   sys.component('request_id') { build { SecureRandom.uuid } }
    #   sys.component('request_id', -> { SecureRandom.uuid })
    def component(ckey, deps_or_provider = [], provider = nil, &block)
      implement(ckey, deps_or_provider, provider, :dynamic, &block)
    end

    # A singleton component with only a build step. The block gets the deps' values.
    #   sys.config!('db.url') { 'sqlite://app.db' }
    #   sys.config!('db', ['db.url']) { |url| DB.new(url) }
    def config!(ckey, deps = [], &build_block)
      raise ArgumentError, "config! #{ckey} needs a block to build its value" unless build_block

      implement(ckey, deps, build_block, :singleton)
    end

    # Same as #config!, but built on every read
    #   sys.config('now') { Time.now }
    def config(ckey, deps = [], &build_block)
      raise ArgumentError, "config #{ckey} needs a block to build its value" unless build_block

      implement(ckey, deps, build_block, :dynamic)
    end

    # Implement singleton components built from ENV variables (see System::ENVProvider),
    # decoding values into each declared type with Plumb::Codec::Forms. ENV is read when components are built.
    #   sys.env('USER_EMAIL' => 'user.email')        # a single variable
    #   sys.env(/^USER_/ => 'user.info')             # matching variables into a hash, match removed: USER_NAME => NAME
    #   sys.env(:downcase, /^USER_/ => 'user.info')  # ... with modifiers: USER_NAME => name
    #   sys.env('user.info')                         # all variables into a hash
    #   sys.env(:downcase, 'user.info')              # all variables, with modifiers
    # A hash can map several sources at once. Modifiers are only allowed when collecting variables with a regex.
    # Keys are relative to this system. Every source, key and type is checked before anything is implemented.
    def env(*args)
      mapping = args.last.is_a?(::Hash) ? args.pop : { ENVProvider::ALL => args.pop }
      if mapping.empty? || mapping.value?(nil)
        raise ArgumentError, 'env needs a component key, or a hash of ENV variables (or regexes) => component keys'
      end

      synchronize do
        raise LockedSystemError, "can't implement ENV components in a locked system" if locked?

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

    # Build an Injector for components under this system, by relative key.
    # Keys map to kwargs named after their last segment ('sourced.store' => :store),
    # and a Hash maps keys to custom kwarg names ('sourced.store' => 'st').
    #   class Dispatcher
    #     include Sys.inject('logger', 'sourced.store' => 'st')
    #   end
    # Values are read when objects are instantiated, so classes can be defined before the system is built.
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

    # Attach an existing standalone system as a branch. It keeps owning its declarations,
    # and this system can implement its nodes.
    # Takes anything with #to_system, which must return a System, ex. a library module:
    #   app.mount('sourced', Sourced.system)
    #   app.mount('sourced', Sourced) # Sourced.to_system => its System
    def mount(ckey, mountable)
      unless MountableInterface === mountable
        raise ArgumentError, "can't mount #{mountable.inspect}: it must respond to #to_system"
      end

      sub = mountable.to_system
      raise ArgumentError, "#{mountable.inspect}.to_system must return a System, got #{sub.inspect}" unless sub.is_a?(System)

      synchronize do
        raise LockedSystemError, "can't mount #{ckey} in a locked system" if locked?
        raise SubsystemError, "#{sub.inspect} is already mounted in another system" unless sub.root?
        raise SubsystemError, "can't mount a system into its own tree" if sub.equal?(root)
        raise LockedSystemError, "can't mount a #{sub.boot_status} system: it must be open" if sub.locked?

        branch, leaf = walk(ckey)
        if (existing = branch.children[leaf])
          raise DeclarationOverrideError, "#{existing.path} is already declared: can't mount a system there"
        end

        branch.attach(leaf, sub)
        self
      end
    end

    # The mountable interface (see #mount)
    def to_system = self

    # A node under this system, by relative key
    def node(ckey)
      index.fetch(ckey.to_s) { raise UndeclaredComponentError, "#{ckey} is not declared in #{path || 'this system'}" }
    end

    def declared?(ckey) = index.key?(ckey.to_s)

    # Read a node's value. Singletons are memoized on #build!, dynamic nodes are built on each read.
    def [](ckey) = node(ckey).read

    def read
      raise NotBuiltError, 'system is not built yet' unless root.readable?
      raise UndeclaredComponentError, "#{path} is a namespace, not a component" unless implementation

      current_value
    end

    # ---- Lifecycle. Only the root drives it ----------------------------------------

    # Each step publishes system.<stage>ing and system.<stage>ed events (or system.failed),
    # and component events for every component whose hooks run. See System::Events
    def prepare!
      raise_mounted!
      synchronize do
        return self if past?(:prepared)

        instrument_system(:prepare) do
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

        instrument_system(:build) do
          @order.each { |n| instrument_component(n, :build) { n.build_node! } }
          @boot_status = :built
          @readable = true
        end
        self
      end
    end

    # If a start hook raises, nodes already started are torn down (in reverse order),
    # the system is left :toredown, and the error is re-raised.
    def start!(context = Thread.current)
      raise_mounted!
      synchronize do
        build!
        return self if past?(:started)

        instrument_system(:start) do
          @order.each { |n| instrument_component(n, :start) { n.start_node!(context) } }
          @boot_status = :started
        rescue Exception # rubocop:disable Lint/RescueException -- any error (incl. Interrupt) must tear down what was started. Always re-raised
          teardown_nodes
          @boot_status = :toredown
          raise
        end
        self
      end
    end

    # Tears down all started nodes, in reverse dependency order, even if some raise. The first error is re-raised.
    def teardown!
      raise_mounted!
      synchronize do
        return self unless boot_status == :started

        instrument_system(:teardown) do
          errors = teardown_nodes
          @boot_status = :toredown
          raise errors.first if errors.any?
        end
        self
      end
    end

    # A System::Graph describing the components under this system, by full path from the root.
    # Components are listed in dependency order once the tree is prepared, and in declaration order before that.
    # Namespaces without an implementation are left out.
    #   graph = sys.graph
    #   graph.status         # => :built, the root's status
    #   graph.components     # => [{ key: 'logger', type:, type_name:, implemented:, mode:, status:, deps:, missing:, dependents:, provider: }, ...]
    #   graph.to_mermaid     # => a Mermaid flowchart
    # See System::Graph
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
            deps:,
            missing:,
            dependents: dependents[n.path],
            provider: impl&.provider
          }
        end

        Graph.new(status: root.boot_status, components:)
      end
    end

    # Nodes in dependency order. Available after #prepare!
    def ordered_nodes
      raise_mounted!
      raise NotBuiltError, 'system is not prepared yet' unless @order

      @order.dup
    end

    # ---- Node internals -------------------------------------------------------------

    protected def readable? = @readable
    protected def lock = @lock
    protected def dep_nodes = @dep_nodes
    protected def order = @order

    private def synchronize(&) = root.lock.synchronize(&)

    protected def declare_type!(type)
      @implicit = false
      @type = Plumb::Composable.wrap(type)
    end

    protected def implement!(implementation)
      @implementation = implementation
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

    # Resolve deps through the implementer's index. Called on #prepare!, so declaration order doesn't matter
    protected def resolve_deps!
      @dep_nodes = implementation.deps.map do |dep|
        dep_node = implementation.implementer.index[dep]
        unless dep_node && !dep_node.namespace?
          where = implementation.implementer.path
          full = [where, dep].compact.join('.')
          raise MissingDependencyError, "#{path} depends on #{full}, which is not #{dep_node ? 'implemented' : 'declared'}"
        end

        dep_node
      end.freeze
    end

    protected def prepare_node!
      transition(:prepared) { implementation.prepare }
    end

    protected def build_node!
      transition(:built) do
        @value = build_value if implementation.singleton?
      end
    end

    protected def start_node!(context)
      transition(:started) { implementation.start(value, context) }
    end

    protected def teardown_node!
      transition(:toredown) { implementation.teardown(value) }
    end

    # Without the readable check: deps are read while the system is building, in dependency order
    protected def current_value = implementation.singleton? ? value : build_value

    # Parse the built value through the declared type. Type errors name the component, ex.
    #   Plumb::ParseError: db.port: Must be a Integer
    # The value is left out, as it can hold secrets.
    private def build_value
      result = type.resolve(implementation.build(*@dep_nodes.map { |n| n.current_value }))
      return result.value if result.valid?

      errors = result.errors.is_a?(::String) ? result.errors : result.errors.inspect
      raise Plumb::ParseError, "#{path || '(root)'}: #{errors}"
    end

    # Whether moving to new_status would run hooks. Only started nodes can be torn down.
    protected def pending?(new_status)
      return status == :started if new_status == :toredown

      STATUSES.index(status) < STATUSES.index(new_status)
    end

    private def transition(new_status)
      return self unless pending?(new_status)

      yield
      @status = new_status
      self
    end

    # ---- Root internals -------------------------------------------------------------

    private def raise_mounted!
      raise SubsystemError, "#{path} is mounted in another system: boot the root" unless root?
    end

    private def past?(new_status)
      STATUSES.index(boot_status) >= STATUSES.index(new_status)
    end

    # Every node that is declared or implemented, in dependency order
    private def resolve_order
      nodes = [self, *index.values].reject(&:namespace?)

      unimplemented = nodes.reject(&:implementation)
      if unimplemented.any?
        raise UnimplementedComponentError, "components are declared but not implemented: #{unimplemented.map(&:path).join(', ')}"
      end

      nodes.each { |n| n.resolve_deps! }

      each_node = ->(&b) { nodes.each(&b) }
      each_child = ->(n, &b) { n.dep_nodes.each(&b) }
      cycle = TSort.each_strongly_connected_component(each_node, each_child).find do |c|
        c.size > 1 || c.first.dep_nodes.include?(c.first)
      end
      raise CircularDependencyError, "circular dependency between #{cycle.map(&:path).join(', ')}" if cycle

      TSort.tsort(each_node, each_child)
    end

    private def teardown_nodes
      @order.reverse.each_with_object([]) do |n, errors|
        instrument_component(n, :teardown) { n.teardown_node! }
      rescue StandardError => e
        errors << e
      end
    end

    # ---- Telemetry ------------------------------------------------------------------

    # Publish system.<stage>ing, run the block, and publish system.<stage>ed with its duration,
    # or system.failed if it raises.
    private def instrument_system(stage)
      before, after = SYSTEM_EVENTS.fetch(stage)
      emit(before)
      started_at = now
      begin
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised
        emit(Events::SystemFailed, stage:, **error_attributes(e))
        raise
      end
      emit(after, duration: now - started_at)
    end

    # Same as #instrument_system for a component, but only if the stage would run its hooks.
    # Dynamic components aren't built by the system, so they don't publish build events.
    private def instrument_component(node, stage)
      return yield unless node.pending?(STAGES.fetch(stage))
      return yield if stage == :build && node.implementation.dynamic?

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

    # Errors as JSON-friendly values. See System::Event
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
        raise LockedSystemError, "can't implement #{ckey} in a locked system" if locked?

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

    # Walk a key's intermediate segments from this system, creating namespace nodes owned by it.
    # Returns the branch node and the last segment.
    private def walk(ckey)
      ckey = ckey.to_s
      raise ArgumentError, "invalid key #{ckey.inspect}" unless ckey.match?(/\A[^.]+(\.[^.]+)*\z/)

      *segments, leaf = ckey.split('.')
      branch = segments.reduce(self) do |current, segment|
        child = current.children[segment] || current.attach(segment, System.new(owner: self))
        raise OwnershipError, ownership_message(child) unless child.owner.equal?(self)

        child
      end
      [branch, leaf.freeze]
    end

    private def ownership_message(node)
      owner = node.owner.path || 'another system'
      "#{node.path} is owned by #{owner}: declare it there. This system can only implement it"
    end

    protected def type_name = type.inspect.gsub(/(Plumb::Types|Sourced::System::T)::/, '')
  end
end
