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
      # Extended into whatever includes an Injector, see #included
      module ComponentDeps
        # Every component injected into this class, including inherited ones, by key.
        # See Injector.deps_for
        def __component_deps = Injector.deps_for(self)
      end

      # Every component injected into mod, as the key it's registered under (a path from the root of
      # its tree) mapped to the name it's injected as, in injection order, with the ones injected
      # into mod's ancestors first. Injecting a key again under another name replaces the name, so
      # the one closest to mod wins.
      #   { 'logger' => :logger, 'repos.users' => :customers }
      def self.deps_for(mod)
        mod.ancestors.grep(Injector).reverse.reduce({}) { |deps, injector| deps.merge(injector.mapping) }
      end

      attr_reader :names, :nodes

      # nodes: { 'component.key' => <Component node> }
      # names: { 'component.key' => :kwarg_name }
      def initialize(nodes, names)
        super()
        @names = names.freeze
        @nodes = names.keys.map { |key| nodes.fetch(key) }.freeze

        # Instance variable names are computed once, not on every #new
        entries = @nodes.zip(names.values).map { |node, name| [node, name, :"@#{name}"] }.freeze

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
          base.extend(ComponentDeps)
        end
      end

      # The keys as passed to Component#inject, relative to the component they were injected from
      def keys = names.keys

      # The keys the injected components are registered under, as paths from the root of their tree.
      # Computed on each call: a node's path changes when its root is mounted into another component.
      def paths = nodes.map(&:path)

      # Those keys, mapped to the names the components are injected as
      def mapping = paths.zip(names.values).to_h

      def inspect = "#<#{self.class} #{names.map { |key, name| "#{key} => #{name}" }.join(', ')}>"
    end
  end
end
