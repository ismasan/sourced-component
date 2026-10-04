# frozen_string_literal: true

module Sourced
  class System
    # Builds a component from ENV, decoding values into the node's type with Plumb::Codec::Forms,
    # the codec for string input (ex. '30' => 30, '1977-11-29' => Date).
    #   ENVProvider.new('USER_EMAIL')         # a single variable
    #   ENVProvider.new(/^USER_/)             # matching variables into a hash, with the match removed: USER_NAME => NAME
    #   ENVProvider.new(/^USER_/, :downcase)  # ... and modified: USER_NAME => name
    #   ENVProvider.new                       # all variables into a hash, same as ENVProvider.new(ENVProvider::ALL)
    # A component provider (see System#component!), and what System#env uses:
    #   sys.component!('user.email', ENVProvider.new('USER_EMAIL'))
    #   sys.component!('everything', ENVProvider) # all variables
    class ENVProvider
      T = Plumb::Types

      # Raised when ENV variables are missing or invalid, naming each variable.
      # A Plumb::ParseError, like any other type mismatch.
      Error = Class.new(Plumb::ParseError)

      # Matches every variable, without removing anything from their names
      ALL = /\A/

      # Applied to collected variable names, in order, after the match is removed
      MODIFIERS = { downcase: :downcase.to_proc }.freeze

      # The provider interface, collecting all variables
      def self.builder_for(node) = new.builder_for(node)

      def self.error_text(error) = error.is_a?(::String) ? error : error.inspect

      # Whether a type accepts a hash, from what it consumes: Any, Hash types and Data structs,
      # or a union or wrapper (ex. nullable, default) with a branch that does.
      def self.takes_hash?(type)
        type = type.input_type if type.respond_to?(:input_type)
        return true if type.is_a?(Plumb::AnyClass) || type.subtype_of?(T::Hash)

        case type
        when Plumb::Disjunction, Plumb::Policy then type.children.any? { |child| takes_hash?(child) }
        when Plumb::And then takes_hash?(type.children.first)
        else false
        end
      end

      attr_reader :source, :modifiers

      # source: a variable name, or a regex to collect variables with
      # modifiers: ex. :downcase. Only when collecting with a regex
      def initialize(source = ALL, *modifiers)
        case source
        when ::String
          if modifiers.any?
            raise ArgumentError, "ENV modifiers (#{modifiers.join(', ')}) can only be used when collecting variables with a regex"
          end
        when ::Regexp
          unknown = modifiers - MODIFIERS.keys
          if unknown.any?
            raise ArgumentError, "unknown ENV modifiers: #{unknown.join(', ')}. Supported: #{MODIFIERS.keys.join(', ')}"
          end
        else
          raise ArgumentError, "an ENV source must be a variable name or a regex, got #{source.inspect}"
        end

        @source = source.dup.freeze
        @modifiers = modifiers.uniq.freeze
      end

      # Regex sources collect variables into a hash, so the node's type must take one
      def check!(node)
        return self if source.is_a?(::String) || ENVProvider.takes_hash?(node.type)

        raise ArgumentError, "#{node.path}: ENV variables matching #{source.inspect} are collected into a hash, " \
                             "but #{node.type.inspect} doesn't take one. Declare a Hash or Data struct type, " \
                             "or map a single variable, ex. env('VAR_NAME' => '#{node.path}')"
      end

      # The provider interface: a callable that reads and decodes ENV for a node, to use as its build step.
      # Checks the node's type first.
      def builder_for(node)
        check!(node)
        # Any (no declared type) takes raw strings. Codec::Forms can't decode into it
        type = node.type
        decoder = type.is_a?(Plumb::AnyClass) ? type : Plumb::Codec::Forms >> type
        if source.is_a?(::String)
          VariableBuilder.new(node, source, decoder)
        else
          # Collected names are strings. Codec::Forms decodes them into the type's keys (ex. 'name' => :name)
          CollectionBuilder.new(node, source, modifiers, decoder)
        end
      end

      def inspect = "#<#{self.class} #{[source.inspect, *modifiers].join(' ')}>"

      # Builds from a single variable. Reads ENV on each call.
      class VariableBuilder
        def initialize(node, name, decoder)
          @node = node
          @name = name
          @decoder = decoder
        end

        # ex. invalid ENV for user.email: USER_EMAIL is invalid: Must match /.../
        # Values are left out, as ENV often holds secrets.
        def call(*_)
          result = @decoder.resolve(ENV[@name])
          return result.value if result.valid?

          detail = ENV.key?(@name) ? "is invalid: #{ENVProvider.error_text(result.errors)}" : 'is missing'
          raise Error, "invalid ENV for #{@node.path}: #{@name} #{detail}"
        end
      end

      # Builds from the variables matching a regex, collected into a hash. Reads ENV on each call.
      class CollectionBuilder
        def initialize(node, regex, modifiers, decoder)
          @node = node
          @regex = regex
          @modifiers = modifiers.map { |name| MODIFIERS.fetch(name) }
          @decoder = decoder
        end

        def call(*_)
          vars, names = collect
          result = @decoder.resolve(vars)
          raise Error, error_message(result.errors, vars, names) unless result.valid?

          result.value
        end

        # Matching variables, as { collected name => value }, and { collected name => ENV name }.
        # The match is removed from names, then modifiers are applied. Names left empty are skipped.
        private def collect
          ENV.each_with_object([{}, {}]) do |(name, value), (vars, names)|
            next unless @regex.match?(name)

            collected = @modifiers.reduce(name.sub(@regex, '')) { |n, modifier| modifier.call(n) }
            next if collected.empty?

            vars[collected] = value
            names[collected] = name
          end
        end

        # ex.
        #   invalid ENV for user.info:
        #     USER_DOB is invalid: Must match /\A\d{4}-\d{2}-\d{2}\z/
        #     email is missing from ENV variables matching /^USER_/
        # Values are left out, as ENV often holds secrets.
        private def error_message(errors, vars, names)
          return "invalid ENV for #{@node.path}: #{ENVProvider.error_text(errors)}" unless errors.is_a?(::Hash)

          lines = errors.map do |attribute, error|
            attribute = attribute.to_s
            if names.key?(attribute)
              "  #{names[attribute]} is invalid: #{ENVProvider.error_text(error)}"
            else
              line = "  #{attribute} is missing from ENV variables matching #{@regex.inspect}"
              near = vars.keys.find { |collected| collected.casecmp?(attribute) }
              near ? "#{line} (found #{names[near]}, try :downcase)" : line
            end
          end
          ["invalid ENV for #{@node.path}:", *lines].join("\n")
        end
      end
    end
  end
end
