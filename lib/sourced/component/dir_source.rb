# frozen_string_literal: true

module Sourced
  class Component
    # Components declared by the Ruby files matching a glob, through a Zeitwerk loader. See Component#from_dir.
    # Each file's key is its path relative to +root+, prefixed with +namespace+:
    #   lib/queries/users/search.rb => 'lib.queries.users.search'
    # The file's constant (as Zeitwerk expects it) declares its components with
    # .install_sourced_component(declarer), where the declarer is scoped to that key. Constants that
    # don't respond to it are skipped.
    class DirSource
      INSTALL = :install_sourced_component
      GLOB_CHARS = /[*?\[{]/
      DEFAULT_ON_ERROR = lambda do |error|
        Kernel.warn("[Sourced::Component] reloading components failed: #{error.class}: #{error.message}")
      end

      # branch: the key every file is declared under, relative to the owner. Reconfigured on reload
      # error:  the last reload's error, nil once a reload succeeds
      attr_reader :branch, :error

      def initialize(owner, glob, loader:, root:, namespace:, on_error:)
        @owner = owner
        @loader = loader
        @root = File.expand_path(root.to_s)
        @namespace = namespace&.to_s
        @on_error = on_error
        @glob, static_dir = expand(glob.to_s)
        @branch = key_for(static_dir)
        @installed = false
        @error = nil

        if @branch.empty?
          raise ArgumentError, "from_dir #{glob}: files must be declared under a key, pass namespace: or a root: above #{static_dir}"
        end
      end

      def installed? = @installed

      # Whether both would declare in the same branch: one reconfiguring would drop the other's components
      def overlaps?(other)
        mine = "#{branch}."
        theirs = "#{other.branch}."
        mine.start_with?(theirs) || theirs.start_with?(mine)
      end

      # The first time, on the root's #prepare!: plain declarations into the open tree
      def install!
        declare_all
        @installed = true
        self
      end

      # After Zeitwerk sets up again (a reload): re-declare the branch from the new constants.
      # Every file re-implements its components, so they're recycled, and the ones whose file or
      # method is gone are removed. Runs inside Zeitwerk's on_setup, where raising would leave the
      # loader half set up, so errors go to +on_error+ instead. The tree is left as it was (see
      # Component#reconfigure), and the error is also published as root.failed.
      def reload!
        return self unless @installed
        return self if @owner.root.boot_status == :torn_down

        @owner.reconfigure(branch) { declare_all }
        @error = nil
        self
      rescue StandardError, ScriptError => e
        @error = e
        @on_error.call(e)
        self
      end

      def inspect = "#<#{self.class} #{@glob} => #{branch}>"

      private def declare_all
        files.each do |path|
          cpath = @loader.cpath_expected_at(path)
          next unless cpath

          mod = Object.const_get(cpath)
          next unless mod.respond_to?(INSTALL)

          mod.public_send(INSTALL, Declarer.new(@owner, key_for(path.delete_suffix('.rb'))))
        end
      end

      private def files
        Dir.glob(@glob).select { |path| path.end_with?('.rb') && File.file?(path) }.sort
      end

      # [absolute glob, the directory above its first wildcard]. A plain directory means its own .rb files
      private def expand(glob)
        abs = File.expand_path(glob)
        segments = abs.split('/')
        static = segments.take_while { |s| !GLOB_CHARS.match?(s) }
        return [abs, static.join('/')] if static.size < segments.size
        raise ArgumentError, "from_dir: #{abs} is not a directory" unless File.directory?(abs)

        [File.join(abs, '*.rb'), abs]
      end

      private def key_for(path)
        relative = if path == @root
                     ''
                   elsif path.start_with?("#{@root}/")
                     path.delete_prefix("#{@root}/")
                   else
                     raise ArgumentError, "from_dir: #{path} is not under root #{@root}"
                   end
        [@namespace, *relative.split('/')].compact.reject(&:empty?).join('.')
      end

      # What .install_sourced_component gets: the component's DSL, scoped to the file's key.
      # Deps are relative to the component #from_dir was called on, like the keys of #inject.
      #   def self.install_sourced_component(c) = c.declare(self).factory(self)
      #   def self.install_sourced_component(c)       # several, under the file's key
      #     c['logger'].declare(Logger) { Logger.new($stdout) }
      #     c['store'].declare(Store).config!([c['logger'].key]) { |logger| Store.new(logger) }
      #   end
      class Declarer
        # The key, relative to the component #from_dir was called on, ex. 'lib.queries.users.search'
        attr_reader :key

        def initialize(owner, key)
          @owner = owner
          @key = key
        end

        # A declarer for a key under this one
        def [](ckey) = Declarer.new(@owner, "#{key}.#{ckey}")

        def declare(type = T::Any, &default) = tap { @owner.declare(key, type, &default) }
        def component!(...) = tap { @owner.component!(key, ...) }
        def component(...) = tap { @owner.component(key, ...) }
        def config!(...) = tap { @owner.config!(key, ...) }
        def config(...) = tap { @owner.config(key, ...) }
        def alias(target) = tap { @owner.alias(key, target) }
        def factory(constructor) = tap { @owner.factory(key, constructor) }
        def defer = tap { @owner.defer(key) }

        def inspect = "#<#{self.class} #{key}>"
      end
    end
  end
end
