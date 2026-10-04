# frozen_string_literal: true

module Sourced
  class System
    # Lifecycle hooks a component can implement, in the order they run
    HOOKS = %i[prepare build start teardown].freeze

    CallableInterface = Plumb::Types::Interface[:call]

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
  end
end
