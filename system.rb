# frozen_string_literal: true

require 'tsort'
require 'plumb'

class System

  SystemError = Class.new(StandardError)
  DeclarationOverrideError = Class.new(SystemError)
  LockedSystemError = Class.new(SystemError)
  UndeclaredComponentError = Class.new(SystemError)
  MissingDependencyError = Class.new(SystemError)
  UnregisteredComponentError = Class.new(SystemError)
  CircularDependencyError = Class.new(SystemError)
  NotBuiltError = Class.new(SystemError)
  CallableInterface = Plumb::Types::Interface[:call]

  # Lifecycle statuses, in order. Shared by the system and its components.
  STATUSES = %i[open prepared built started toredown].freeze

  Declaration = Data.define(:key, :type)

  class Component
    attr_reader :key, :deps, :mode, :status, :value

    # Hooks are called with:
    #   prepare: no arguments
    #   build:   the resolved values of #deps, in order. The last build hook's return value is the component's value
    #   start:   the context passed to System#start!
    #   teardown: no arguments
    # Hooks defined in an instance_eval block have the component as self, so they can use #value.
    def initialize(key, deps, mode: :singleton, &block)
      @key = key
      @deps = deps
      @mode = mode
      @status = :open
      @value = nil
      @prepare_blocks = []
      @build_blocks = []
      @start_blocks = []
      @teardown_blocks = []

      if block_given?
        if block.arity > 0
          block.call(self)
        else
          self.instance_eval(&block)
        end
        # Freeze hook registration, but not lifecycle state
        [@prepare_blocks, @build_blocks, @start_blocks, @teardown_blocks].each(&:freeze)
      end
    end

    def singleton? = mode == :singleton
    def dynamic? = mode == :dynamic

    # Names of the lifecycle hooks this component defines
    def hooks
      {
        prepare: @prepare_blocks,
        build: @build_blocks,
        start: @start_blocks,
        teardown: @teardown_blocks
      }.reject { |_, blocks| blocks.empty? }.keys
    end

    # ex. (singleton, built) deps=[logger.output] hooks=[prepare, build]
    def details
      parts = ["(#{mode}, #{status})"]
      parts << "deps=[#{deps.join(', ')}]" if deps.any?
      parts << "hooks=[#{hooks.join(', ')}]" if hooks.any?
      parts.join(' ')
    end

    def inspect = "#<#{self.class} #{key} #{details}>"

    def prepare(callable = nil, &block)
      @prepare_blocks << CallableInterface.parse(callable || block)
      self
    end

    def build(callable = nil, &block)
      @build_blocks << CallableInterface.parse(callable || block)
      self
    end

    def start(callable = nil, &block)
      @start_blocks << CallableInterface.parse(callable || block)
      self
    end

    def teardown(callable = nil, &block)
      @teardown_blocks << CallableInterface.parse(callable || block)
      self
    end

    def prepare!
      transition(:prepared) { @prepare_blocks.each(&:call) }
    end

    # Singletons memoize their value, parsed through the declared type.
    # Dynamic components only move to :built, and produce a fresh value on each #call.
    def build!(dep_values, type)
      transition(:built) do
        @value = type.parse(call(dep_values)) if singleton?
      end
    end

    def start!(context)
      transition(:started) { @start_blocks.each { |b| b.call(context) } }
    end

    def teardown!
      return self unless status == :started

      transition(:toredown) { @teardown_blocks.each(&:call) }
    end

    # Run build hooks and return the last result (nil if there are no build hooks)
    def call(dep_values)
      @build_blocks.reduce(nil) { |_, b| b.call(*dep_values) }
    end

    # Run the block and move to the new status, unless already there or past it.
    private def transition(new_status)
      return self if STATUSES.index(status) >= STATUSES.index(new_status)

      yield
      @status = new_status
      self
    end
  end

  attr_reader :declarations, :components, :status

  def initialize
    @declarations = {}
    @components = {}
    @status = :open
    @order = nil
  end

  # Declare a component that MUST be registered before #prepare!
  # Optional components are expressed by the type, ex. Types::Interface[:info].nullable
  # An optional block provides a lazy default, registered as a singleton config (built and validated on #build!),
  # which can then be overridden with a different component (ex. with its own deps and lifecycle hooks).
  #   sys.declare('logger', Logger) { Logger.new(STDOUT) }
  def declare(key, type = Plumb::Types::Any, &default)
    key = build_key(key)
    type = Plumb::Composable.wrap(type)
    raise DeclarationOverrideError, "#{key} is already declared" if declared?(key)

    @declarations[key] = Declaration.new(key, type)
    config!(key, &default) if default
    self
  end

  def declared?(key)
    @declarations.key?(build_key(key))
  end

  # A singleton config that is built and memoized on System.build!
  # A 'config' is just a component with a custom build hook, and all other hooks as no-ops
  def config!(key, deps = [], &block)
    add_component(key, deps) do |key, deps|
      Component.new(key, deps, mode: :singleton) do |c|
        c.build(&block)
      end
    end
  end

  # A config that is built on each call
  def config(key, deps = [], &block)
    add_component(key, deps) do |key, deps|
      Component.new(key, deps, mode: :dynamic) do |c|
        c.build(&block)
      end
    end
  end

  # A full singleton component with lifecycle hooks
  def component!(key, deps = [], &block)
    add_component(key, deps) do |key, deps|
      Component.new(key, deps, mode: :singleton, &block)
    end
  end

  # A full dynamic component with lifecycle hooks
  def component(key, deps = [], &block)
    add_component(key, deps) do |key, deps|
      Component.new(key, deps, mode: :dynamic, &block)
    end
  end

  def locked? = status != :open

  # #<System status=built components=2/3
  #   logger.output : Any (singleton, built) hooks=[build]
  #   logger : Interface[info, debug] (singleton, built) deps=[logger.output] hooks=[prepare, build]
  #   db : (Nil | Interface[append]) (not registered)
  # >
  # Declarations are listed in dependency order once the system is prepared.
  def inspect
    header = "#<#{self.class} status=#{status} components=#{@components.size}/#{@declarations.size}"
    return "#{header}>" if @declarations.empty?

    keys = @order ? @order | @declarations.keys : @declarations.keys
    lines = keys.map do |key|
      type = @declarations[key].type.inspect.gsub('Plumb::Types::', '')
      "  #{key} : #{type} #{@components[key]&.details || '(not registered)'}"
    end

    [header, *lines, '>'].join("\n")
  end

  # Components in dependency order (dependencies first). Available after #prepare!
  def ordered_components
    raise NotBuiltError, 'system is not prepared yet' unless @order

    @order.map { |key| @components[key] }
  end

  # Use TSORT to ensure that all dependencies of registered components are satisfied
  # and there's no circular dependencies. Raise a clear error otherwise
  # call #prepare hooks on all components, in dependency order
  # update status to :prepared
  # prepare! should be idempotent
  def prepare!
    return self if past?(:prepared)

    check_registered_components!
    @order = resolve_order
    ordered_components.each(&:prepare!)
    @status = :prepared
    self
  end

  # prepare system if not already prepared (idempotent)
  # call #build hooks on all (singleton) components, which should memoize the values
  # pass the value through the matching declaration's type (type.parse(value))
  # build! is also idempotent
  def build!
    prepare! # idempotent call
    return self if past?(:built)

    ordered_components.each do |component|
      component.build!(dep_values(component), @declarations[component.key].type)
    end
    @status = :built
    self
  end

  # call #start hooks on all components. Idempotent.
  # context is passed to each component's #start(context)
  # useful for components that want to start threads or fibers in a context (ex. parent fiber)
  def start!(context = Thread.current)
    build! # idempotent
    return self if past?(:started)

    ordered_components.each { |c| c.start!(context) }
    @status = :started
    self
  end

  # call #teardown hooks on all components, in reverse dependency order
  # no-op if system is not started
  def teardown!
    return self unless status == :started

    ordered_components.reverse_each(&:teardown!)
    @status = :toredown
    self
  end

  # Fetch a component's value. Singletons return their memoized value,
  # dynamic components are built on each call.
  def [](key)
    raise NotBuiltError, 'system is not built yet' unless past?(:built)

    resolve(build_key(key))
  end

  private def resolve(key)
    component = @components.fetch(key) do
      raise UndeclaredComponentError, "#{key} is not a registered component"
    end

    if component.singleton?
      component.value
    else
      @declarations[key].type.parse(component.call(dep_values(component)))
    end
  end

  private def past?(new_status)
    STATUSES.index(status) >= STATUSES.index(new_status)
  end

  private def dep_values(component)
    component.deps.map { |dep| resolve(dep) }
  end

  private def check_registered_components!
    missing = @declarations.each_key.reject { |key| @components.key?(key) }
    return if missing.empty?

    raise UnregisteredComponentError, "components are declared but not registered: #{missing.join(', ')}"
  end

  # Topologically sort components so that dependencies come first.
  private def resolve_order
    @components.each_value do |component|
      missing = component.deps.reject { |dep| @components.key?(dep) }
      next if missing.empty?

      raise MissingDependencyError, "#{component.key} depends on unregistered components: #{missing.join(', ')}"
    end

    each_node = ->(&b) { @components.each_key(&b) }
    each_child = ->(key, &b) { @components[key].deps.each(&b) }
    TSort.tsort(each_node, each_child)
  rescue TSort::Cyclic => e
    raise CircularDependencyError, e.message
  end

  private def build_key(key)
    key.to_s.freeze
  end

  # Registering a key that already has a component overrides it (ex. an extension replacing an app default).
  # The declaration is left untouched, so the new component must still satisfy the declared type.
  private def add_component(key, deps, &)
    raise LockedSystemError, "can't add components to a locked system" if locked?

    key = build_key(key)
    raise UndeclaredComponentError, "#{key} component is not declared in this system" unless declared?(key)

    @components[key] = yield(key, deps.map { |d| build_key(d) })
    self
  end
end
