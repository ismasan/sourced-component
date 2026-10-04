# frozen_string_literal: true

module Sourced
  class Component
    MODES = %i[singleton dynamic].freeze

    # How a node is built. Deps are keys relative to the implementer: the component that called #component! or #component.
    #   prepare:  hooks run with no arguments
    #   build:    hooks run with dep values. The last result is the node's value
    #   start:    hooks run with (value, context)
    #   teardown: hooks run with (value)
    class Implementation
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

      # Hooks that a provider's builder can implement, besides #call (the build step)
      OPTIONAL_HOOKS = %i[prepare start teardown].freeze

      # From a provider's builder: #call(*deps) is the build step, and it can also implement
      # #prepare, #start(value, context) and #teardown(value).
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
        @implementer = implementer
        @mode = mode
        @provider = provider
        @hooks = hooks.transform_values(&:freeze).freeze
      end

      def singleton? = mode == :singleton
      def dynamic? = mode == :dynamic

      def prepare = @hooks[:prepare].each(&:call)
      def build(*deps) = @hooks[:build].reduce(nil) { |_, b| b.call(*deps) }
      def start(value, context) = @hooks[:start].each { |b| b.call(value, context) }
      def teardown(value) = @hooks[:teardown].each { |b| b.call(value) }
    end
  end
end
