# frozen_string_literal: true

module Sourced
  class Component
    # A module that injects components into a class as keyword arguments to #initialize,
    # defaulting to the component's value when the object is instantiated.
    #   include App.inject('logger', 'sourced.store' => 'st')
    # Each include prepends its own #initialize, which takes its kwargs and passes the rest on to super,
    # so multiple injections (and the class' own #initialize) compose.
    # Including it raises InjectionError if the class already has a method named like an injected reader.
    # Values are read from the nodes themselves, so a class injecting from a library's component
    # gets the overrides of the application that mounts it.
    class Injector < Module
      attr_reader :names

      # nodes: { 'component.key' => <Component node> }
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

        # Checked before the module is added to the class, so a refused include leaves the class untouched
        define_singleton_method(:append_features) do |base|
          taken = (base.ancestors.grep(Injector) - [self]).flat_map { |i| i.names.values } & names.values
          raise InjectionError, "#{base} already injects #{taken.join(', ')}" if taken.any?

          # Readers would silently replace these, including private ones (ex. Kernel#format)
          defined = names.values.select { |name| base.method_defined?(name) || base.private_method_defined?(name) }
          if defined.any?
            methods = defined.map { |name| "##{name} (from #{base.instance_method(name).owner})" }
            raise InjectionError, "#{base} already defines #{methods.join(', ')}: " \
                                  "inject under another name instead, ex. inject('key' => 'other_name')"
          end

          super(base)
        end

        define_singleton_method(:included) do |base|
          base.prepend(initializer)
          base.attr_reader(*names.values)
        end
      end

      def inspect = "#<#{self.class} #{names.map { |key, name| "#{key} => #{name}" }.join(', ')}>"
    end
  end
end
