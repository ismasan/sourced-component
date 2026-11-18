# frozen_string_literal: true

module Sourced
  class Component
    # Components declared by the Ruby files matching a glob, through a Zeitwerk loader. See Component#from_dir.
    # Each file's key is its path relative to +root+, prefixed with +namespace+:
    #   lib/queries/users/search.rb => 'lib.queries.users.search'
    # The file's constant (as Zeitwerk expects it) declares its components with
    # .__install_component(declarer), where the declarer is scoped to that key. Constants that
    # don't respond to it are skipped.
    # Reloads re-declare the branch above the glob's first wildcard. With no such branch (root: is
    # the directory scanned, and no namespace:), each top-level directory is a branch of its own:
    #   system/users/create.rb, system/queries/search.rb, root: 'system' => 'users.create', 'queries.search'
    class DirSource
      INSTALL = :__install_component
      GLOB_CHARS = /[*?\[{]/
      DEFAULT_ON_ERROR = lambda do |error|
        Kernel.warn("[Sourced::Component] reloading a from_dir directory failed: #{error.class}: #{error.message}")
      end

      # branch: the key every file is declared under, relative to the owner. Reconfigured on reload.
      #         Empty when each top-level directory is a branch
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
        @claimed = [] # with an empty branch: the top-level keys the last install declared under
      end

      def installed? = @installed

      # Raise if two sources would declare in the same branch: one reloading would drop the other's components
      def self.check_overlaps!(sources)
        sources.combination(2) do |a, b|
          raise ArgumentError, "#{a.inspect} overlaps #{b.inspect}: each reconfigures its whole branch" if a.overlaps?(b)
        end
      end

      # The branch's full path from the root
      def full_branch = [@owner.path, branch].compact.join('.')

      def overlaps?(other)
        return true if full_branch.empty? || other.full_branch.empty? # claims every top-level directory

        mine = "#{full_branch}."
        theirs = "#{other.full_branch}."
        mine.start_with?(theirs) || theirs.start_with?(mine)
      end

      # The first time, on the root's #prepare!. Through #reconfigure, which on an open tree is plain
      # declaration, but rolls back if a file raises: a retried #prepare! starts from a clean branch
      def install!
        reconfigure!
        @installed = true
        self
      end

      # After Zeitwerk sets up again (a reload): re-declare the branch from the new constants.
      # Every file re-implements its components, so they're recycled, and the ones whose file or
      # method is gone are removed. Runs inside Zeitwerk's on_setup, where raising would leave the
      # loader half set up, so errors go to +on_error+ instead, which mustn't raise either. The tree is
      # left as it was (see Component#reconfigure), and the error is also published as root.failed.
      def reload!
        return self unless @installed
        return self if @owner.root.boot_status == :torn_down

        reconfigure!
        @error = nil
        self
      rescue StandardError, ScriptError => e
        @error = e
        @on_error.call(e)
        self
      end

      def inspect = "#<#{self.class} #{@glob} => #{full_branch}>"

      # Load every file first, so a file that doesn't load raises before anything is reconfigured, and
      # the branches are known. With an empty branch, they're the top-level keys of the files that
      # install, and those of the last install, so a directory that's gone is emptied. New ones are
      # created by declaring into them.
      # Files can inject components that other files declare, whichever loads first: those are
      # resolved once every file is installed, and a missing one rolls the reconfiguration back.
      # Once the tree is reconfigured, the root's #on_dir_load listeners get every file's constant.
      private def reconfigure!
        loaded = nil
        installs = nil
        deferred = @owner.root.deferring_injections do
          loaded = constants
          installs = installables(loaded)
        end
        keys = if branch.empty?
                 claimed = installs.map { |key, _| key.split('.').first }.uniq
                 (@claimed | claimed).select { |k| @owner.declared?(k) }
               else
                 [branch]
               end

        @owner.reconfigure(keys) do
          installs.each { |key, mod| mod.public_send(INSTALL, Declarer.new(@owner, key)) }
          deferred.each(&:resolve!)
        end
        @claimed = claimed if branch.empty?
        @owner.root.dir_loaded!(self, loaded.map(&:last))
      end

      # [[path, constant]] for each file the loader expects a constant in, loading it
      private def constants
        files.filter_map do |path|
          cpath = @loader.cpath_expected_at(path)
          [path, Object.const_get(cpath)] if cpath
        end
      end

      # [[key, constant]] for each of +loaded+ that responds to .__install_component
      private def installables(loaded)
        loaded.filter_map do |path, mod|
          next unless mod.respond_to?(INSTALL)

          key = key_for(path.delete_suffix('.rb'))
          if branch.empty? && !key.include?('.')
            raise ArgumentError, "#{path} can't install components at the top level, where reloading can't " \
                                 "re-declare them: move it into a directory, or pass namespace: to #from_dir"
          end

          [key, mod]
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

      # What .__install_component gets: the component's DSL, scoped to the file's key.
      # Deps are relative to the component #from_dir was called on, like the keys of #inject.
      #   def self.__install_component(c) = c.declare(self).factory(self)
      #   def self.__install_component(c)       # several, under the file's key
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
