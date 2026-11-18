# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'securerandom'
require 'zeitwerk'

RSpec.describe Sourced::Component, '#from_dir' do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = File.realpath(dir)
      FileUtils.mkdir_p(File.join(@dir, 'lib'))
      example.run
    end
  end

  let(:ns) { "FromDirSpec#{SecureRandom.hex(4)}" }
  let(:app) { Sourced::Component.new(loader:) }
  let(:loader) do
    Zeitwerk::Loader.new.tap do |l|
      l.push_dir(File.join(@dir, 'lib'), namespace: Object.const_get(ns))
      l.enable_reloading
    end
  end

  before do
    Object.const_set(ns, Module.new).const_set(:App, app)
    app.declare('db', String) { 'the-db' }
  end

  after do
    loader.setup # unload needs it, ex. for examples that never boot
    loader.unload
    loader.unregister
    Object.send(:remove_const, ns)
  end

  def write(path, source)
    path = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
  end

  def delete(path) = File.delete(File.join(@dir, path))

  def search_class(version: 1)
    write('lib/queries/users/search.rb', <<~RUBY)
      class #{ns}::Queries::Users::Search
        include #{ns}::App.inject('db')
        def self.__install_component(c) = c.declare(self).factory(self)
        def version = #{version}
      end
    RUBY
  end

  def from_dir(glob = 'lib/**/*.rb', **opts)
    app.from_dir(File.join(@dir, glob), root: @dir, **opts)
  end

  it 'declares a component per file, under its path' do
    search_class
    write('lib/plain.rb', "class #{ns}::Plain; end")
    from_dir
    loader.setup
    app.start!

    search = app['lib.queries.users.search']
    expect(search).to be_a(Object.const_get("#{ns}::Queries::Users::Search"))
    expect(search.db).to eq('the-db')
    expect(app.declared?('lib.plain')).to be(false)
    expect(app.node('lib.queries.users.search').dep_nodes.map(&:path)).to eq(['db'])
  end

  it 'installs Installable classes with #factory, unless they define their own' do
    write('lib/queries/users/search.rb', <<~RUBY)
      class #{ns}::Queries::Users::Search
        include Sourced::Component::Installable
        include #{ns}::App.inject('db')
      end
    RUBY
    write('lib/queries/users/admin_search.rb', <<~RUBY)
      class #{ns}::Queries::Users::AdminSearch < #{ns}::Queries::Users::Search; end
    RUBY
    write('lib/queries/users/custom.rb', <<~RUBY)
      class #{ns}::Queries::Users::Custom
        include Sourced::Component::Installable
        def self.__install_component(c) = c.declare(String).config { 'custom' }
      end
    RUBY
    from_dir
    loader.setup
    app.start!

    expect(app['lib.queries.users.search'].db).to eq('the-db')
    expect(app['lib.queries.users.admin_search']).to be_a(Object.const_get("#{ns}::Queries::Users::AdminSearch"))
    expect(app.node('lib.queries.users.search').dep_nodes.map(&:path)).to eq(['db'])
    expect(app['lib.queries.users.custom']).to eq('custom')
  end

  it "doesn't install abstract components, but installs their subclasses" do
    write('lib/queries/base.rb', <<~RUBY)
      class #{ns}::Queries::Base
        include Sourced::Component::Installable
        include #{ns}::App.inject('db')
        __abstract_component!
      end
    RUBY
    write('lib/queries/search.rb', "class #{ns}::Queries::Search < #{ns}::Queries::Base; end")
    from_dir
    loader.setup
    app.start!

    expect(app.declared?('lib.queries.base')).to be(false)
    expect(app['lib.queries.search'].db).to eq('the-db')
  end

  it 'leaves nothing behind when a file fails on boot, so booting again works' do
    write('lib/a.rb', <<~RUBY)
      class #{ns}::A
        include Sourced::Component::Installable
      end
    RUBY
    write('lib/b.rb', "class #{ns}::B\n  def self.__install_component(c) = raise('boom')\nend")
    from_dir
    loader.setup

    expect { app.prepare! }.to raise_error(RuntimeError, 'boom')
    expect(app.declared?('lib.a')).to be(false)

    write('lib/b.rb', "class #{ns}::B; end")
    loader.reload
    app.start!

    expect(app.declared?('lib.a')).to be(true)
  end

  it 'declares several components under a file' do
    write('lib/integrations/sourced.rb', <<~RUBY)
      module #{ns}::Integrations::Sourced
        def self.__install_component(c)
          c['logger'].declare(String) { 'logger' }
          c['store'].declare(String).config!([c['logger'].key, 'db']) { |l, db| [l, db].join('+') }
        end
      end
    RUBY
    from_dir
    loader.setup
    app.start!

    expect(app['lib.integrations.sourced.logger']).to eq('logger')
    expect(app['lib.integrations.sourced.store']).to eq('logger+the-db')
  end

  it 'keys files relative to root:, under namespace:' do
    search_class
    app.from_dir(File.join(@dir, 'lib/queries/**/*.rb'), root: File.join(@dir, 'lib/queries'), namespace: 'q')
    loader.setup
    app.start!

    expect(app.declared?('q.users.search')).to be(true)
  end

  it 'takes a plain directory as its own Ruby files' do
    write('lib/queries/top.rb', <<~RUBY)
      class #{ns}::Queries::Top
        def self.__install_component(c) = c.declare.config { 1 }
      end
    RUBY
    search_class
    from_dir('lib/queries')
    loader.setup
    app.start!

    expect(app['lib.queries.top']).to eq(1)
    expect(app.declared?('lib.queries.users.search')).to be(false)
  end

  describe 'on reload' do
    before do
      app.declare('searches', Sourced::Component::T::Hash)
      app.config!('searches', ['lib.queries.users.*']) { |all| all.transform_values(&:version) }
    end

    it 're-declares the branch from the reloaded constants' do
      search_class
      from_dir
      loader.setup
      app.start!
      expect(app['lib.queries.users.search'].version).to eq(1)

      search_class(version: 2)
      write('lib/queries/users/find.rb', <<~RUBY)
        class #{ns}::Queries::Users::Find
          def self.__install_component(c) = c.declare(self).factory(self)
          def version = :find
        end
      RUBY
      loader.reload

      expect(app['lib.queries.users.search'].version).to eq(2)
      expect(app['searches']).to eq('search' => 2, 'find' => :find)

      delete('lib/queries/users/search.rb')
      loader.reload

      expect(app.declared?('lib.queries.users.search')).to be(false)
      expect(app['searches']).to eq('find' => :find)
    end

    it 'leaves the tree as it was when a file is broken, and recovers on the next reload' do
      errors = []
      search_class
      from_dir(on_error: ->(e) { errors << e })
      loader.setup
      app.start!

      write('lib/queries/users/search.rb', "class #{ns}::Queries::Users::Search\n def oops(\nend")
      loader.reload

      expect(errors.map(&:class)).to eq([SyntaxError])
      expect(app.node('lib.queries.users.search').status).to eq(:started)
      expect(app['searches']).to eq('search' => 1)

      search_class(version: 3)
      loader.reload

      expect(errors.size).to eq(1)
      expect(app['searches']).to eq('search' => 3)
    end

    it 'reconfigures a branch whose files declared nothing at first' do
      from_dir('lib/queries/users/*.rb')
      loader.setup
      app.start!
      expect(app['searches']).to eq({})

      search_class
      loader.reload

      expect(app['searches']).to eq('search' => 1)
    end

    it 'does nothing before the tree is prepared, or once it is torn down' do
      search_class
      from_dir(on_error: ->(e) { raise e })
      loader.setup
      loader.reload
      expect(app.declared?('lib.queries.users.search')).to be(false)

      app.start!
      app.teardown!
      loader.reload
      expect(app.boot_status).to eq(:torn_down)
    end
  end

  it 'raises for overlapping branches' do
    from_dir('lib/queries/**/*.rb')
    expect { from_dir('lib/**/*.rb') }.to raise_error(ArgumentError, /overlaps/)
    expect { from_dir('lib/queries/users/*.rb') }.to raise_error(ArgumentError, /overlaps/)
    expect { from_dir('lib/other/*.rb') }.not_to raise_error
  end

  it 'raises for overlapping branches registered through other components in the tree' do
    app.declare('lib.other', String) { 'other' } # so the 'lib' node exists to call #from_dir on
    from_dir('lib/**/*.rb')
    expect { app.node('lib').from_dir(File.join(@dir, 'lib/q/**/*.rb'), root: File.join(@dir, 'lib')) }
      .to raise_error(ArgumentError, /overlaps/)
  end

  it "registers with the loader outside the tree's lock" do
    owned = nil
    allow(loader).to receive(:on_setup).and_wrap_original do |original, &block|
      owned = app.instance_variable_get(:@lock).mon_owned?
      original.call(&block)
    end
    from_dir

    expect(owned).to be(false)
  end

  it "can't be called while reconfiguring" do
    app.declare('other.x', String) { 'x' }
    app.start!
    expect { app.reconfigure('other') { |b| b.declare('x'); from_dir } }
      .to raise_error(Sourced::Component::LockedComponentError)
  end

  describe 'rooted at the directory it scans' do
    let(:lib) { File.join(@dir, 'lib') }

    def installable(path, name, deps = [])
      write("lib/#{path}.rb", <<~RUBY)
        class #{ns}::#{name}
          include Sourced::Component::Installable
          #{"include #{ns}::App.inject(#{deps.map(&:inspect).join(', ')})" if deps.any?}
        end
      RUBY
    end

    before { app.from_dir(File.join(lib, '**/*.rb'), root: lib) }

    it 'declares each top-level directory as a branch of its own' do
      installable('users/create', 'Users::Create', ['db'])
      installable('queries/search', 'Queries::Search', ['users.create'])
      loader.setup
      app.start!

      expect(app['queries.search'].create.db).to eq('the-db')
      expect(app['db']).to eq('the-db')
    end

    it 're-declares every branch at once on reload, adding and removing directories' do
      installable('users/create', 'Users::Create')
      installable('queries/search', 'Queries::Search', ['users.create'])
      write('lib/support/helper.rb', "module #{ns}::Support::Helper; end")
      app.declare('support.manual', String) { 'manual' }
      loader.setup
      app.start!

      # Renamed in one branch, and its dependent in another follows
      delete('lib/users/create.rb')
      installable('users/register', 'Users::Register')
      installable('queries/search', 'Queries::Search', ['users.register'])
      installable('billing/charge', 'Billing::Charge')
      loader.reload

      expect(app['queries.search'].register).to be_a(Object.const_get("#{ns}::Users::Register"))
      expect(app.declared?('users.create')).to be(false)
      expect(app.declared?('billing.charge')).to be(true)
      expect(app['support.manual']).to eq('manual') # no file installs under support: not claimed

      delete('lib/billing/charge.rb')
      loader.reload

      expect(app.declared?('billing.charge')).to be(false)
    end

    it 'raises for an injected component no file declares, and rolls back on reload' do
      errors = []
      app.instance_variable_get(:@dir_sources).first.instance_variable_set(:@on_error, ->(e) { errors << e })
      installable('users/create', 'Users::Create')
      installable('queries/search', 'Queries::Search', ['users.missing'])
      loader.setup

      expect { app.prepare! }.to raise_error(Sourced::Component::UndeclaredComponentError, /users.missing/)
      expect(app.declared?('users.create')).to be(false)

      installable('queries/search', 'Queries::Search', ['users.create'])
      loader.reload
      app.start!
      installable('queries/search', 'Queries::Search', ['users.missing'])
      loader.reload

      expect(errors.map(&:class)).to eq([Sourced::Component::UndeclaredComponentError])
      # Rolled back: the previous classes, not the ones the failed reload loaded
      expect(app['queries.search'].create.class.name).to eq("#{ns}::Users::Create")
    end

    it 'raises for a top-level file that installs components' do
      installable('top', 'Top')
      write('lib/plain.rb', "class #{ns}::Plain; end")
      loader.setup

      expect { app.prepare! }.to raise_error(ArgumentError, /top level/)
    end

    it 'overlaps any other source' do
      expect { from_dir('lib/other/*.rb') }.to raise_error(ArgumentError, /overlaps/)
    end
  end

  describe '#install_dirs!' do
    it 'declares the components on an open tree, so classes loaded before #prepare! can inject them' do
      search_class
      # Outside the glob, so only eager_load loads it
      write('web/page.rb', <<~RUBY)
        class #{ns}::Page
          include #{ns}::App.inject('lib.queries.users.search')
        end
      RUBY
      loader.push_dir(File.join(@dir, 'web'), namespace: Object.const_get(ns))
      from_dir
      loader.setup

      expect(app.install_dirs!).to be(app)
      expect(app.declared?('lib.queries.users.search')).to be(true)
      expect(app.locked?).to be(false)

      loader.eager_load # loads Page, which injects it
      app.declare('extra', String) { 'extra' } # still open
      app.start!

      expect(Object.const_get("#{ns}::Page").new.search.db).to eq('the-db')
      expect(app['extra']).to eq('extra')
    end

    it 'installs each source once, and the ones added later on #prepare!' do
      search_class
      write('other/thing.rb', <<~RUBY)
        class #{ns}::Thing
          include Sourced::Component::Installable
        end
      RUBY
      loader.push_dir(File.join(@dir, 'other'), namespace: Object.const_get(ns))
      from_dir
      loader.setup
      app.install_dirs!
      app.install_dirs!
      from_dir('other/*.rb')
      app.start!

      expect(app.declared?('lib.queries.users.search')).to be(true)
      expect(app.declared?('other.thing')).to be(true)
    end

    it 'reconfigures the branch on reload, before the tree is prepared' do
      search_class
      from_dir
      loader.setup
      app.install_dirs!

      search_class(version: 2)
      loader.reload
      app.start!

      expect(app['lib.queries.users.search'].version).to eq(2)
    end

    it 'leaves nothing behind when a file fails, so calling it again works' do
      write('lib/a.rb', <<~RUBY)
        class #{ns}::A
          include Sourced::Component::Installable
        end
      RUBY
      write('lib/b.rb', "class #{ns}::B\n  def self.__install_component(c) = raise('boom')\nend")
      from_dir
      loader.setup

      expect { app.install_dirs! }.to raise_error(RuntimeError, 'boom')
      expect(app.declared?('lib.a')).to be(false)

      write('lib/b.rb', "class #{ns}::B; end")
      loader.reload
      app.install_dirs!

      expect(app.declared?('lib.a')).to be(true)
    end

    it 'is for open trees, on the root' do
      lib = Sourced::Component.new
      app.mount('lib_mount', lib)
      expect { lib.install_dirs! }.to raise_error(Sourced::Component::SubcomponentError)

      loader.setup
      app.prepare!
      expect { app.install_dirs! }.to raise_error(Sourced::Component::LockedComponentError)
    end
  end

  describe 'the loader' do
    it 'is required' do
      expect { Sourced::Component.new.from_dir(File.join(@dir, 'lib/**/*.rb')) }
        .to raise_error(Sourced::Component::MissingLoaderError, /no code loader/)
    end

    it 'can be set on the root, and is used by mounted components' do
      lib = Sourced::Component.new
      bare = Sourced::Component.new
      bare.mount('lib', lib)
      expect { lib.loader = loader }.to raise_error(Sourced::Component::SubcomponentError)

      bare.loader = loader
      expect(lib.loader).to be(loader)
      expect { lib.from_dir(File.join(@dir, 'lib/**/*.rb'), root: @dir) }.not_to raise_error
    end

    it "can't be mounted with a loader of its own" do
      lib = Sourced::Component.new(loader:)
      expect { app.mount('lib', lib) }.to raise_error(Sourced::Component::SubcomponentError, /own loader/)
    end

    it 'must be a loader' do
      expect { Sourced::Component.new(loader: Object.new) }.to raise_error(Plumb::ParseError)
    end

    it "can't be replaced once from_dir registered with it, or once the tree is locked" do
      from_dir
      expect { app.loader = loader }.to raise_error(ArgumentError, /replace the loader/)

      other = Sourced::Component.new
      other.prepare!
      expect { other.loader = loader }.to raise_error(Sourced::Component::LockedComponentError)
    end
  end

  it 'raises once the tree is locked' do
    app.prepare!
    expect { from_dir }.to raise_error(Sourced::Component::LockedComponentError)
  end
end
