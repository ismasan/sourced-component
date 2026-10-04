# frozen_string_literal: true

module Sourced
  class System
    # A module that injects system components into a class as keyword arguments to #initialize,
    # defaulting to the component's value when the object is instantiated.
    #   include Sys.inject('logger', 'sourced.store' => 'st')
    # Each include prepends its own #initialize, which takes its kwargs and passes the rest on to super,
    # so multiple injections (and the class' own #initialize) compose.
    # Values are read from the nodes themselves, so a class injecting from a library's system
    # gets the overrides of the application that mounts it.
    class Injector < Module
      attr_reader :names

      # nodes: { 'component.key' => <System node> }
      # names: { 'component.key' => :kwarg_name }
      def initialize(nodes, names)
        super()
        @names = names.freeze

        # Instance variable names are computed once, not on every #new
        entries = names.map { |key, name| [nodes.fetch(key), name, :"@#{name}"] }.freeze

        initializer = Module.new do
          define_method(:initialize) do |*args, **kwargs, &block|
            entries.each do |node, name, ivar|
              instance_variable_set(ivar, kwargs.key?(name) ? kwargs.delete(name) : node.read)
            end
            super(*args, **kwargs, &block)
          end
        end

        define_singleton_method(:included) do |base|
          taken = (base.ancestors.grep(Injector) - [self]).flat_map { |i| i.names.values } & names.values
          raise ArgumentError, "#{base} already injects #{taken.join(', ')}" if taken.any?

          base.prepend(initializer)
          base.attr_reader(*names.values)
        end
      end

      def inspect = "#<#{self.class} #{names.map { |key, name| "#{key} => #{name}" }.join(', ')}>"
    end
  end
end
