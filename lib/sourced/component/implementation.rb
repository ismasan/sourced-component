# frozen_string_literal: true

module Sourced
  class Component
    # singleton: built once, on #build!, and memoized
    # dynamic:   built on every read
    # alias:     reads another component (its only dep). Memoized if that component is, see Component#alias
    MODES = %i[singleton dynamic alias].freeze

    # How a node is built. Deps are keys relative to the implementer: the component that called #component! or #component.
    #   prepare:  hooks run with no arguments
    #   build:    hooks run with dep values. The last result is the node's value
    #   start:    hooks run with (value, context). Again after each stop, for a component started by key
    #   stop:     hooks run with (value), when a started component is stopped, or torn down
    #   teardown: hooks run with (value), once, when the root is torn down
    # A dep ending in '.*' depends on every component directly under that key, and its value is
    # a hash of their values by key segment, ex. 'reactors.*' => { 'foo' => <Foo>, 'bar' => <Bar> }
    class Implementation
      WILDCARD = /\A[^.*]+(\.[^.*]+)*\.\*\z/

      # provider: the provider the component was implemented with (see Component#component!), the block of
      # Component#config! and #config, or nil for blocks of hooks
      attr_reader :deps, :implementer, :mode, :provider

      def self.from_block(deps, implementer:, mode:, &block)
        dsl = DSL.new
        if block
          block.arity > 0 ? block.call(dsl) : dsl.instance_eval(&block)
        end
        new(deps, implementer:, mode:, hooks: dsl.hooks)
      end

      # An alias of the component at +target+, relative to the implementer: its value is the target's,
      # and it has no other hooks
      def self.alias(target, implementer:)
        target = target.to_s
        raise ArgumentError, "can't alias #{target.inspect}: an alias takes a single component, not a wildcard" if target.include?('*')

        new([target], implementer:, mode: :alias, hooks: DSL.new.build { |value| value }.hooks)
      end

      # Hooks that a provider's builder can implement, besides #call (the build step)
      OPTIONAL_HOOKS = %i[prepare start stop teardown].freeze

      # From a provider's builder: #call(*deps) is the build step, and it can also implement
      # #prepare, #start(value, context), #stop(value) and #teardown(value).
      def self.from_builder(builder, deps, implementer:, mode:, provider: nil)
        dsl = DSL.new
        dsl.build(builder)
        OPTIONAL_HOOKS.each do |name|
          dsl.public_send(name, builder.method(name)) if builder.respond_to?(name)
        end
        new(deps, implementer:, mode:, hooks: dsl.hooks, provider:)
      end

      def initialize(deps, implementer:, mode:, hooks:, provider: nil)
        raise ArgumentError, "unknown mode #{mode.inspect}, expected one of #{MODES.join(', ')}" unless MODES.include?(mode)

        @deps = deps.map { |d| d.to_s.freeze }.freeze
        @deps.each do |dep|
          next unless dep.include?('*')
          next if dep.match?(WILDCARD)

          raise ArgumentError, "invalid dependency #{dep.inspect}: a wildcard must be the last segment, ex. 'reactors.*'"
        end
        @implementer = implementer
        @mode = mode
        @provider = provider
        @hooks = hooks.transform_values(&:freeze).freeze
      end

      def singleton? = mode == :singleton
      def dynamic? = mode == :dynamic
      def alias? = mode == :alias

      def prepare = @hooks[:prepare].each(&:call)
      def build(*deps) = @hooks[:build].reduce(nil) { |_, b| b.call(*deps) }
      def start(value, context) = @hooks[:start].each { |b| b.call(value, context) }
      def stop(value) = @hooks[:stop].each { |b| b.call(value) }
      def teardown(value) = @hooks[:teardown].each { |b| b.call(value) }
    end
  end
end
