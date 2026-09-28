# frozen_string_literal: true

require 'monitor'
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

  # Lifecycle events published to the system's notifier. Each event class has a #type string
  # which can be used to subscribe to it, ex. notifier.subscribe('components.built') { |event| ... }
  module Events
    REGISTRY = {}

    class Event < Plumb::Types::Data
      attribute :timestamp, Time

      class << self
        attr_reader :type

        # Define and register an event subclass with a type string
        def define(type, &block)
          raise ArgumentError, "event type #{type} is already defined" if REGISTRY.key?(type)

          REGISTRY[type] = Class.new(self) do
            @type = type
            class_eval(&block) if block
          end
        end
      end

      def type = self.class.type
    end

    class SystemEvent < Event; end

    class ComponentEvent < Event
      attribute :key, String
    end

    Completed = proc { attribute :duration, Float }
    Failed = proc do
      attribute :stage, Symbol
      attribute :error, Exception
    end

    SystemPreparing = SystemEvent.define('system.preparing')
    SystemPrepared = SystemEvent.define('system.prepared', &Completed)
    SystemBuilding = SystemEvent.define('system.building')
    SystemBuilt = SystemEvent.define('system.built', &Completed)
    SystemStarting = SystemEvent.define('system.starting')
    SystemStarted = SystemEvent.define('system.started', &Completed)
    SystemTearingDown = SystemEvent.define('system.tearing_down')
    SystemToredown = SystemEvent.define('system.toredown', &Completed)
    SystemFailed = SystemEvent.define('system.failed', &Failed)

    ComponentDeclared = ComponentEvent.define('components.declared') do
      attribute :type_name, String
    end
    ComponentRegistered = ComponentEvent.define('components.registered') do
      attribute :mode, Symbol
      attribute :deps, Plumb::Types::Array[String]
      attribute :override, Plumb::Types::Boolean
    end
    ComponentPreparing = ComponentEvent.define('components.preparing')
    ComponentPrepared = ComponentEvent.define('components.prepared', &Completed)
    ComponentBuilding = ComponentEvent.define('components.building')
    ComponentBuilt = ComponentEvent.define('components.built', &Completed)
    ComponentStarting = ComponentEvent.define('components.starting')
    ComponentStarted = ComponentEvent.define('components.started', &Completed)
    ComponentTearingDown = ComponentEvent.define('components.tearing_down')
    ComponentToredown = ComponentEvent.define('components.toredown', &Completed)
    ComponentFailed = ComponentEvent.define('components.failed', &Failed)
  end

  # The default notifier. Custom notifiers must implement the same #publish and #subscribe interface.
  # Handlers are called synchronously, in the order they subscribed, by the thread or fiber running the lifecycle step.
  # Errors raised by handlers propagate to the caller.
  class Notifier
    def initialize
      @subscriptions = [].freeze
      @lock = Mutex.new
    end

    # Subscribe to an event type string (ex. 'components.built'),
    # or an event class, which also matches its subclasses (ex. Events::ComponentEvent for all component events)
    def subscribe(event_class_or_type, &handler)
      raise ArgumentError, 'a handler block is required' unless handler

      matcher = case event_class_or_type
                when Class
                  ->(event) { event.is_a?(event_class_or_type) }
                when String, Symbol
                  type = event_class_or_type.to_s
                  raise ArgumentError, "unknown event type #{type}" unless Events::REGISTRY.key?(type)

                  ->(event) { event.type == type }
                else
                  raise ArgumentError, "can't subscribe to #{event_class_or_type.inspect}"
                end

      # copy-on-write, so publishing never needs the lock
      @lock.synchronize { @subscriptions = [*@subscriptions, [matcher, handler]].freeze }
      self
    end

    def publish(event)
      @subscriptions.each { |matcher, handler| handler.call(event) if matcher.call(event) }
      self
    end
  end

  NotifierInterface = Plumb::Types::Interface[:publish, :subscribe]

  # Lifecycle stages, and the status each one moves to
  STAGES = { prepare: :prepared, build: :built, start: :started, teardown: :toredown }.freeze

  SYSTEM_EVENTS = {
    prepare: [Events::SystemPreparing, Events::SystemPrepared],
    build: [Events::SystemBuilding, Events::SystemBuilt],
    start: [Events::SystemStarting, Events::SystemStarted],
    teardown: [Events::SystemTearingDown, Events::SystemToredown]
  }.freeze

  COMPONENT_EVENTS = {
    prepare: [Events::ComponentPreparing, Events::ComponentPrepared],
    build: [Events::ComponentBuilding, Events::ComponentBuilt],
    start: [Events::ComponentStarting, Events::ComponentStarted],
    teardown: [Events::ComponentTearingDown, Events::ComponentToredown]
  }.freeze

  class Component
    attr_reader :key, :deps, :mode, :status, :value

    # Hooks are called with:
    #   prepare: no arguments
    #   build:   the resolved values of #deps, in order. The last build hook's return value is the component's value
    #   start:   the built value, and the context passed to System#start!
    #   teardown: the built value
    # Dynamic components don't memoize a value, so their start and teardown hooks get nil.
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
      transition(:started) { @start_blocks.each { |b| b.call(value, context) } }
    end

    def teardown!
      transition(:toredown) { @teardown_blocks.each { |b| b.call(value) } }
    end

    # Run build hooks and return the last result (nil if there are no build hooks)
    def call(dep_values)
      @build_blocks.reduce(nil) { |_, b| b.call(*dep_values) }
    end

    # Whether moving to new_status would run hooks. Only started components can be torn down.
    def pending?(new_status)
      return status == :started if new_status == :toredown

      STATUSES.index(status) < STATUSES.index(new_status)
    end

    # Run the block and move to the new status, unless already there or past it.
    private def transition(new_status)
      return self unless pending?(new_status)

      yield
      @status = new_status
      self
    end
  end

  # A module that injects system components into a class as keyword arguments to #initialize,
  # defaulting to the component's value when the object is instantiated.
  #   include Sys.inject('logger', 'sourced.store' => 'st')
  # Each include prepends its own #initialize, which takes its kwargs and passes the rest on to super,
  # so multiple injections (and the class' own #initialize) compose.
  class Injector < Module
    attr_reader :names

    # names: { 'component.key' => :kwarg_name }
    def initialize(system, names)
      super()
      @names = names

      initializer = Module.new do
        define_method(:initialize) do |*args, **kwargs, &block|
          names.each do |key, name|
            instance_variable_set(:"@#{name}", kwargs.key?(name) ? kwargs.delete(name) : system[key])
          end
          super(*args, **kwargs, &block)
        end
      end

      define_singleton_method(:included) do |base|
        taken = (base.ancestors.grep(Injector) - [self]).flat_map { |i| i.names.values } & names.values
        raise ArgumentError, "#{base} already injects #{taken.join(', ')}" if taken.any?

        base.prepend(initializer)
        base.send(:attr_reader, *names.values)
      end
    end

    def inspect = "#<#{self.class} #{names.map { |key, name| "#{key} => #{name}" }.join(', ')}>"
  end

  attr_reader :declarations, :components, :status, :notifier

  # Registration and lifecycle methods are synchronized with a Monitor, so a single system
  # can be booted from multiple threads or fibers: concurrent callers wait for the first one to finish,
  # and then no-op. The Monitor is reentrant (#start! calls #build!, hooks may call the system)
  # and owned per fiber, so it works with fiber schedulers (ex. Async).
  # Reading values with #[] (and injected defaults) needs no lock, as they're immutable once built.
  # notifier: receives lifecycle events. See System::Notifier and System::Events
  def initialize(notifier: Notifier.new)
    @declarations = {}
    @components = {}
    @status = :open
    @order = nil
    @lock = Monitor.new
    @notifier = NotifierInterface.parse(notifier)
  end

  # Declare a component that MUST be registered before #prepare!
  # Optional components are expressed by the type, ex. Types::Interface[:info].nullable
  # An optional block provides a lazy default, registered as a singleton config (built and validated on #build!),
  # which can then be overridden with a different component (ex. with its own deps and lifecycle hooks).
  #   sys.declare('logger', Logger) { Logger.new(STDOUT) }
  def declare(key, type = Plumb::Types::Any, &default)
    @lock.synchronize do
      raise LockedSystemError, "can't declare components in a locked system" if locked?

      key = build_key(key)
      type = Plumb::Composable.wrap(type)
      raise DeclarationOverrideError, "#{key} is already declared" if declared?(key)

      @declarations[key] = Declaration.new(key, type)
      emit(Events::ComponentDeclared, key:, type_name: type_name(type))
      config!(key, &default) if default
      self
    end
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

  # Build an Injector for the given component keys.
  # Keys map to kwargs named after their last segment ('sourced.store' => :store),
  # and a Hash maps keys to custom kwarg names ('sourced.store' => 'st').
  #   include Sys.inject('logger', 'sourced.store' => 'st')
  def inject(*keys)
    names = keys.each_with_object({}) do |arg, map|
      pairs = arg.is_a?(Hash) ? arg : { arg => build_key(arg).split('.').last }
      pairs.each do |key, name|
        key = build_key(key)
        raise UndeclaredComponentError, "#{key} component is not declared in this system" unless declared?(key)

        map[key] = name.to_sym
      end
    end

    duplicates = names.values.tally.select { |_, count| count > 1 }.keys
    raise ArgumentError, "duplicate injected names: #{duplicates.join(', ')}" if duplicates.any?

    Injector.new(self, names)
  end

  # #<System status=built components=2/3
  #   logger.output : Any (singleton, built) hooks=[build]
  #   logger : Interface[info, debug] (singleton, built) deps=[logger.output] hooks=[prepare, build]
  #   db : (Nil | Interface[append]) (not registered)
  # >
  # Declarations are listed in dependency order once the system is prepared.
  def inspect
    header = "#<#{self.class} status=#{status} components=#{@components.size}/#{@declarations.size}"
    return "#{header}>" if @declarations.empty?

    lines = tree[:components].map do |node|
      details = @components[node[:key]]&.details || '(not registered)'
      "  #{node[:key]} : #{node[:type_name]} #{details}"
    end

    [header, *lines, '>'].join("\n")
  end

  # A data structure describing the system and all declared components,
  # in dependency order once the system is prepared (declaration order before that).
  #   {
  #     status: :built,
  #     components: [
  #       {
  #         key: 'logger',
  #         type: <Plumb type>,
  #         type_name: 'Interface[info, debug]',
  #         registered: true,
  #         mode: :singleton,          # nil if not registered
  #         status: :built,            # nil if not registered
  #         deps: ['logger.output'],   # components this one depends on
  #         dependents: ['app'],       # components that depend on this one
  #         hooks: [:prepare, :build]
  #       },
  #       ...
  #     ]
  #   }
  def tree
    @lock.synchronize { build_tree }
  end

  private def build_tree
    keys = @order ? @order | @declarations.keys : @declarations.keys
    dependents = Hash.new { |h, k| h[k] = [] }
    keys.each do |key|
      @components[key]&.deps&.each { |dep| dependents[dep] << key }
    end

    components = keys.map do |key|
      type = @declarations[key].type
      component = @components[key]

      {
        key:,
        type:,
        type_name: type_name(type),
        registered: !component.nil?,
        mode: component&.mode,
        status: component&.status,
        deps: component ? component.deps : [],
        dependents: dependents[key],
        hooks: component ? component.hooks : []
      }
    end

    { status:, components: }
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
    @lock.synchronize do
      return self if past?(:prepared)

      instrument_system(:prepare) do
        check_registered_components!
        @order = resolve_order
        ordered_components.each do |component|
          instrument_component(component, :prepare) { component.prepare! }
        end
        @status = :prepared
      end
      self
    end
  end

  # prepare system if not already prepared (idempotent)
  # call #build hooks on all (singleton) components, which should memoize the values
  # pass the value through the matching declaration's type (type.parse(value))
  # build! is also idempotent
  def build!
    @lock.synchronize do
      prepare! # idempotent call
      return self if past?(:built)

      instrument_system(:build) do
        ordered_components.each do |component|
          instrument_component(component, :build) do
            component.build!(dep_values(component), @declarations[component.key].type)
          end
        end
        @status = :built
      end
      self
    end
  end

  # call #start hooks on all components. Idempotent.
  # each component's #start hooks are called with (value, context)
  # useful for components that want to start threads or fibers in a context (ex. parent fiber)
  # Start hooks run while holding the system lock, so they should spawn long-running work and return, not block.
  # If a start hook raises, components already started are torn down (in reverse order),
  # the system is left :toredown, and the original exception is re-raised.
  def start!(context = Thread.current)
    @lock.synchronize do
      build! # idempotent
      return self if past?(:started)

      instrument_system(:start) do
        ordered_components.each do |component|
          instrument_component(component, :start) { component.start!(context) }
        end
        @status = :started
      rescue Exception # any error (incl. Interrupt) must tear down what was started. Always re-raised.
        teardown_components
        @status = :toredown
        raise
      end
      self
    end
  end

  # call #teardown hooks on all components, in reverse dependency order
  # no-op if system is not started
  # All components are torn down even if some teardown hooks raise. The first error is then re-raised.
  def teardown!
    @lock.synchronize do
      return self unless status == :started

      instrument_system(:teardown) do
        errors = teardown_components
        @status = :toredown
        raise errors.first if errors.any?
      end
      self
    end
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

  # Tear down started components in reverse dependency order, carrying on past errors.
  # Returns the errors raised by teardown hooks.
  private def teardown_components
    ordered_components.reverse.each_with_object([]) do |component, errors|
      instrument_component(component, :teardown) { component.teardown! }
    rescue StandardError => e
      errors << e
    end
  end

  # Publish system.<stage>ing, run the block, and publish system.<stage>ed with its duration,
  # or system.failed if it raises.
  private def instrument_system(stage)
    before, after = SYSTEM_EVENTS.fetch(stage)
    emit(before)
    started_at = now
    begin
      yield
    rescue Exception => e # re-raised
      emit(Events::SystemFailed, stage:, error: e)
      raise
    end
    emit(after, duration: now - started_at)
  end

  # Same as #instrument_system for a component, but only if the stage would run hooks.
  # Dynamic components aren't built by the system, so they don't publish build events.
  private def instrument_component(component, stage)
    return yield unless component.pending?(STAGES.fetch(stage))
    return yield if stage == :build && component.dynamic?

    key = component.key
    before, after = COMPONENT_EVENTS.fetch(stage)
    emit(before, key:)
    started_at = now
    begin
      yield
    rescue Exception => e # re-raised
      emit(Events::ComponentFailed, key:, stage:, error: e)
      raise
    end
    emit(after, key:, duration: now - started_at)
  end

  private def emit(event_class, **attrs)
    event = event_class.new(timestamp: Time.now, **attrs)
    raise ArgumentError, "invalid #{event_class.type} event: #{event.errors}" unless event.valid?

    @notifier.publish(event)
  end

  private def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  private def type_name(type) = type.inspect.gsub('Plumb::Types::', '')

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
    @lock.synchronize do
      raise LockedSystemError, "can't add components to a locked system" if locked?

      key = build_key(key)
      raise UndeclaredComponentError, "#{key} component is not declared in this system" unless declared?(key)

      override = @components.key?(key)
      component = @components[key] = yield(key, deps.map { |d| build_key(d) })
      emit(Events::ComponentRegistered, key:, mode: component.mode, deps: component.deps, override:)
      self
    end
  end
end
