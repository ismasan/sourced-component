# frozen_string_literal: true

module Sourced
  class System
    MODES = %i[singleton dynamic].freeze

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
  end
end
