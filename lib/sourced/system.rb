# frozen_string_literal: true

require 'monitor'
require 'tsort'
require 'plumb'
require_relative 'system/version'

module Sourced
  # A tree of systems. Every node is a System: it can declare a type, be implemented with
  # dependencies and lifecycle hooks, have its own lifecycle status, and have sub-systems.
  #   app.declare('sourced.db', DB)                 # builds the 'sourced' > 'db' branch
  #   app.component('sourced.db', ['logger']) { build { |logger| DB.new(logger:) } }
  #   app.mount('payments', Payments)               # attach an existing system as a branch
  # Systems own their declarations and the sub-trees under them: an ancestor can implement
  # (or re-implement) any node below it, but can only declare under nodes it declared itself.
  # The root system drives the lifecycle of the whole tree.
  class System
    SystemError = Class.new(StandardError)
    DeclarationOverrideError = Class.new(SystemError)
    OwnershipError = Class.new(SystemError)
    LockedSystemError = Class.new(SystemError)
    SubsystemError = Class.new(SystemError)
    UndeclaredComponentError = Class.new(SystemError)
    UnimplementedComponentError = Class.new(SystemError)
    MissingDependencyError = Class.new(SystemError)
    CircularDependencyError = Class.new(SystemError)
    NotBuiltError = Class.new(SystemError)

    module T
      include Plumb::Types
    end

    CallableInterface = Plumb::Types::Interface[:call]

    # Lifecycle statuses, in order. Shared by the root (boot status) and every node.
    STATUSES = %i[open prepared built started toredown].freeze
    HOOKS = %i[prepare build start teardown].freeze
    MODES = %i[singleton dynamic].freeze

    # Records lifecycle hooks from a component block
    class DSL
      attr_reader :hooks

      def initialize
        @hooks = HOOKS.to_h { |name| [name, []] }
      end

      HOOKS.each do |name|
        define_method(name) do |callable = nil, &block|
          @hooks[name] << CallableInterface.parse(callable || block)
          self
        end
      end
    end

    # How a node is built. Deps are keys relative to the implementer: the system that called #component.
    #   prepare:  hooks run with no arguments
    #   build:    hooks run with dep values. The last result is the node's value
    #   start:    hooks run with (value, context)
    #   teardown: hooks run with (value)
    class Implementation
      attr_reader :deps, :implementer, :mode

      def self.from_block(deps, implementer:, mode:, &block)
        dsl = DSL.new
        if block
          block.arity > 0 ? block.call(dsl) : dsl.instance_eval(&block)
        end
        new(deps, implementer:, mode:, hooks: dsl.hooks)
      end

      def initialize(deps, implementer:, mode:, hooks:)
        raise ArgumentError, "unknown mode #{mode.inspect}, expected one of #{MODES.join(', ')}" unless MODES.include?(mode)

        @deps = deps.map { |d| d.to_s.freeze }.freeze
        @implementer = implementer
        @mode = mode
        @hooks = hooks.transform_values(&:freeze).freeze
      end

      def singleton? = mode == :singleton
      def dynamic? = mode == :dynamic

      def prepare = @hooks[:prepare].each(&:call)
      def build(*deps) = @hooks[:build].reduce(nil) { |_, b| b.call(*deps) }
      def start(value, context) = @hooks[:start].each { |b| b.call(value, context) }
      def teardown(value) = @hooks[:teardown].each { |b| b.call(value) }
    end

    # key:   local segment, ex. 'db'. nil for a root that isn't mounted anywhere
    # owner: the system that declared this node. Standalone systems own themselves
    # type:  the declared type. Any for implicit nodes created as intermediate segments (namespaces)
    # index: every descendant, by relative key, ex. { 'sourced' => <System>, 'sourced.db' => <System> }
    attr_reader :key, :parent, :owner, :type, :implementation, :status, :value, :children, :index, :boot_status

    def initialize(owner: nil, type: Plumb::Undefined)
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

        node.implement!(Implementation.from_block([], implementer: self, mode: :singleton) { build(&default) }) if default
        self
      end
    end

    # Implement (or re-implement) a node anywhere under this system. The last implementation wins.
    # Deps are keys relative to this system.
    #   sys.component('sourced.db', ['logger']) do
    #     prepare { require 'sequel' }
    #     build { |logger| Sequel.sqlite(logger:) }
    #     start { |db, context| }
    #     teardown { |db| db.disconnect }
    #   end
    def component(ckey, deps = [], mode: :singleton, &block)
      synchronize do
        raise LockedSystemError, "can't implement #{ckey} in a locked system" if locked?

        node(ckey).implement!(Implementation.from_block(deps, implementer: self, mode:, &block))
        self
      end
    end

    # Attach an existing standalone system as a branch. It keeps owning its declarations,
    # and this system can implement its nodes.
    #   app.mount('sourced', Sourced.system)
    def mount(ckey, sub)
      raise ArgumentError, "can't mount #{sub.inspect}, it's not a System" unless sub.is_a?(System)

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

    def prepare!
      raise_mounted!
      synchronize do
        return self if past?(:prepared)

        @order = resolve_order
        @order.each { |n| n.prepare_node! }
        @boot_status = :prepared
        self
      end
    end

    def build!
      raise_mounted!
      synchronize do
        prepare!
        return self if past?(:built)

        @order.each { |n| n.build_node! }
        @boot_status = :built
        @readable = true
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

        begin
          @order.each { |n| n.start_node!(context) }
          @boot_status = :started
        rescue Exception # rubocop:disable Lint/RescueException
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

        errors = teardown_nodes
        @boot_status = :toredown
        raise errors.first if errors.any?

        self
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

    private def build_value
      type.parse(implementation.build(*@dep_nodes.map { |n| n.current_value }))
    end

    # Whether moving to new_status would run hooks. Only started nodes can be torn down.
    private def pending?(new_status)
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
        n.teardown_node!
      rescue StandardError => e
        errors << e
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

    private def type_name = type.inspect.gsub('Plumb::Types::', '')
  end
end
