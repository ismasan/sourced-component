# frozen_string_literal: true

require 'spec_helper'
require 'date'

RSpec.describe Sourced::System do
  def new_system = described_class.new

  it 'has a version number' do
    expect(Sourced::System::VERSION).not_to be_nil
  end

  describe '#declare' do
    it 'builds a tree of nodes from dot-separated keys, with intermediate namespaces' do
      sys = new_system
      sys.declare('sourced.db.logger', String)

      sourced = sys.children.fetch('sourced')
      db = sourced.children.fetch('db')
      logger = db.children.fetch('logger')

      expect(sourced).to be_a(described_class)
      expect(sourced.namespace?).to be(true)
      expect(db.namespace?).to be(true)
      expect(logger.namespace?).to be(false)
      expect(logger.type).to eq(Plumb::Composable.wrap(String))
      expect([sourced.key, db.key, logger.key]).to eq(%w[sourced db logger])
      expect(logger.path).to eq('sourced.db.logger')
      expect(logger.parent).to be(db)
      expect(logger.root).to be(sys)
    end

    it 'indexes every descendant by relative key, in every ancestor' do
      sys = new_system
      sys.declare('sourced.db.logger', String)

      expect(sys.index.keys).to eq(%w[sourced sourced.db sourced.db.logger])
      expect(sys.node('sourced').index.keys).to eq(%w[db db.logger])
      expect(sys.node('sourced.db').index.keys).to eq(%w[logger])
      expect(sys.node('sourced.db.logger')).to be(sys.node('sourced').node('db.logger'))
      expect(sys.declared?('sourced.db')).to be(true)
      expect(sys.declared?('nope')).to be(false)
    end

    it 'makes the declaring system the owner of the nodes it creates' do
      sys = new_system
      sys.declare('a.b', String)

      expect(sys.owner).to be(sys)
      expect(sys.node('a').owner).to be(sys)
      expect(sys.node('a.b').owner).to be(sys)
    end

    it 'defaults the type to Any' do
      sys = new_system
      sys.declare('anything') { 1 }

      expect(sys.node('anything').type).to eq(Plumb::Types::Any)
      expect(sys.node('anything').implicit?).to be(false)
    end

    it 'treats nil as a valid type' do
      sys = new_system
      sys.declare('nothing', nil) { nil }
      sys.build!

      expect(sys.node('nothing').implicit?).to be(false)
      expect(sys['nothing']).to be_nil
    end

    it 'gives implicit nodes the Any type' do
      sys = new_system
      sys.declare('ns.x', String)

      expect(sys.node('ns').implicit?).to be(true)
      expect(sys.node('ns').type).to eq(Plumb::Types::Any)
    end

    it 'registers a default block as a singleton implementation' do
      sys = new_system
      sys.declare('name', String) { 'Joe' }
      sys.build!

      expect(sys.node('name').implementation.mode).to eq(:singleton)
      expect(sys['name']).to eq('Joe')
    end

    it 'can add children to namespaces it owns' do
      sys = new_system
      sys.declare('cache.redis', String) { 'redis://' }
      sys.declare('cache.redis.pool', Integer) { 5 }
      sys.build!

      expect(sys['cache.redis']).to eq('redis://')
      expect(sys['cache.redis.pool']).to eq(5)
    end

    it 'gives a type to an implicit namespace it created' do
      sys = new_system
      sys.declare('db.url', String) { 'sqlite://' }
      sys.declare('db', String)
      sys.component!('db', ['db.url']) { build { |url| "DB(#{url})" } }
      sys.build!

      expect(sys.node('db').implicit?).to be(false)
      expect(sys['db']).to eq('DB(sqlite://)')
    end

    it 'raises when re-declaring a key' do
      sys = new_system
      sys.declare('a', String)

      expect { sys.declare('a', Integer) }.to raise_error(described_class::DeclarationOverrideError, /a is already declared/)
    end

    it 'raises on invalid keys' do
      sys = new_system

      expect { sys.declare('a..b') }.to raise_error(ArgumentError)
      expect { sys.declare('') }.to raise_error(ArgumentError)
      expect { sys.declare('.a') }.to raise_error(ArgumentError)
    end
  end

  describe 'ownership' do
    let(:lib) do
      new_system.tap do |s|
        s.declare('db', String) { 'lib db' }
      end
    end

    let(:app) do
      new_system.tap { |s| s.mount('sourced', lib) }
    end

    it "can't declare under a mounted system's nodes" do
      expect { app.declare('sourced.extra', String) }.to raise_error(described_class::OwnershipError, /sourced is owned by/)
      expect { app.declare('sourced.db.extra', String) }.to raise_error(described_class::OwnershipError)
    end

    it "can't declare under namespaces created by another system" do
      lib.declare('settings.retries', Integer) { 3 }

      expect { app.declare('sourced.settings.timeout', Integer) }.to raise_error(described_class::OwnershipError, /sourced is owned by/)
    end

    it 'lets the mounted system keep declaring under itself' do
      app
      lib.declare('settings.retries', Integer) { 3 }

      expect(app.index.keys).to include('sourced.settings', 'sourced.settings.retries')
      expect(lib.node('settings.retries')).to be(app.node('sourced.settings.retries'))
    end

    it "lets an ancestor implement a mounted system's nodes" do
      app.component!('sourced.db') { build { 'app db' } }
      app.build!

      expect(app['sourced.db']).to eq('app db')
    end
  end

  describe '#component' do
    it 'implements a declared node with deps and lifecycle hooks' do
      sys = new_system
      sys.declare('url', String) { 'sqlite://' }
      sys.declare('db', String)
      sys.component!('db', ['url']) do
        build { |url| "DB(#{url})" }
      end
      sys.build!

      impl = sys.node('db').implementation
      expect(impl.deps).to eq(['url'])
      expect(impl.implementer).to be(sys)
      expect(sys['db']).to eq('DB(sqlite://)')
    end

    it 'accepts a block with the DSL as an argument' do
      sys = new_system
      sys.declare('a', Integer)
      sys.component!('a') { |c| c.build { 1 } }
      sys.build!

      expect(sys['a']).to eq(1)
    end

    it 'accepts callables as hooks' do
      sys = new_system
      sys.declare('a', Integer)
      sys.component!('a') { build(-> { 2 }) }
      sys.build!

      expect(sys['a']).to eq(2)
    end

    it 'resolves deps relative to the implementing system' do
      lib = new_system
      lib.declare('logger', String) { 'lib logger' }
      lib.declare('db', String)
      lib.component!('db', ['logger']) { build { |logger| "db with #{logger}" } }

      app = new_system
      app.declare('logger', String) { 'app logger' }
      app.mount('sourced', lib)
      app.build!

      expect(app['sourced.db']).to eq('db with lib logger')
    end

    it 'lets an ancestor re-implement a node, with deps relative to the ancestor' do
      lib = new_system
      lib.declare('logger', String) { 'lib logger' }
      lib.declare('db', String)
      lib.component!('db', ['logger']) { build { |logger| "db with #{logger}" } }

      app = new_system
      app.declare('logger', String) { 'app logger' }
      app.mount('sourced', lib)
      app.component!('sourced.db', ['logger']) { build { |logger| "app db with #{logger}" } }
      app.build!

      expect(app['sourced.db']).to eq('app db with app logger')
      expect(lib['db']).to eq('app db with app logger')
      expect(lib['db']).to be(app['sourced.db'])
    end

    it 'can depend on nodes in mounted systems' do
      lib = new_system
      lib.declare('logger', String) { 'lib logger' }

      app = new_system
      app.mount('sourced', lib)
      app.declare('db', String)
      app.component!('db', ['sourced.logger']) { build { |logger| "db with #{logger}" } }
      app.build!

      expect(app['db']).to eq('db with lib logger')
    end

    it 'replaces previous implementations' do
      sys = new_system
      sys.declare('a', Integer) { 1 }
      sys.component!('a') { build { 2 } }
      sys.build!

      expect(sys['a']).to eq(2)
    end

    it 'can implement a namespace node' do
      sys = new_system
      sys.declare('ns.x', Integer) { 1 }
      sys.component!('ns', ['ns.x']) { build { |x| x + 1 } }
      sys.build!

      expect(sys['ns']).to eq(2)
      expect(sys.node('ns').namespace?).to be(false)
    end

    it 'raises for undeclared keys' do
      sys = new_system

      expect { sys.component!('nope') { build { 1 } } }.to raise_error(described_class::UndeclaredComponentError, /nope is not declared/)
    end

    it 'implements singletons with #component! and dynamic components with #component' do
      sys = new_system
      sys.declare('a')
      sys.declare('b')
      sys.component!('a') { build { 1 } }
      sys.component('b', ['a']) { build { |a| a + 1 } }

      expect(sys.node('a').implementation.mode).to eq(:singleton)
      expect(sys.node('b').implementation.mode).to eq(:dynamic)
      expect(sys.node('b').implementation.deps).to eq(['a'])
    end

    describe 'providers' do
      it 'builds components with callables, called with the deps values' do
        factory = Class.new { def self.call(url) = "DB(#{url})" }
        sys = new_system
        sys.declare('db.url', String) { 'sqlite://' }
        sys.declare('db', String)
        sys.declare('clock')
        sys.component!('db', ['db.url'], factory)
        sys.component!('clock', -> { Time }) # no deps
        sys.build!

        expect(sys['db']).to eq('DB(sqlite://)')
        expect(sys['clock']).to be(Time)
        expect(sys.node('db').implementation).to have_attributes(mode: :singleton, deps: ['db.url'], implementer: sys)
      end

      it 'builds dynamic components with callables' do
        counter = 0
        sys = new_system
        sys.declare('id', Integer)
        sys.component('id', -> { counter += 1 })
        sys.build!

        expect(sys.node('id').implementation.mode).to eq(:dynamic)
        expect([sys['id'], sys['id']]).to eq([1, 2])
      end

      it 'sets up providers with #builder_for(node)' do
        provider = Class.new do
          def self.builder_for(node) = ->(prefix) { "#{prefix} #{node.path} #{node.type.inspect}" }
        end
        sys = new_system
        sys.declare('prefix', String) { 'built' }
        sys.declare('a.b', String)
        sys.component!('a.b', ['prefix'], provider)
        sys.build!

        expect(sys['a.b']).to eq('built a.b String')
      end

      it "runs the builder's optional prepare, start and teardown hooks" do
        calls = []
        pool_provider = Class.new do
          define_singleton_method(:builder_for) { |node| new(node, calls) }
          define_method(:initialize) { |node, calls| @node = node; @calls = calls }
          define_method(:prepare) { @calls << [:prepare, @node.path] }
          define_method(:call) { |url| @calls << [:build, url]; "pool(#{url})" }
          define_method(:start) { |pool, context| @calls << [:start, pool, context] }
          define_method(:teardown) { |pool| @calls << [:teardown, pool] }
        end
        sys = new_system
        sys.declare('db.url', String) { 'sqlite://' }
        sys.declare('db.pool', String)
        sys.component!('db.pool', ['db.url'], pool_provider)
        sys.start!(:ctx)
        sys.teardown!

        expect(calls).to eq([
          [:prepare, 'db.pool'],
          [:build, 'sqlite://'],
          [:start, 'pool(sqlite://)', :ctx],
          [:teardown, 'pool(sqlite://)']
        ])
      end

      it 'runs hooks implemented by callable providers, and skips the ones they leave out' do
        calls = []
        provider = Object.new
        provider.define_singleton_method(:call) { 'value' }
        provider.define_singleton_method(:teardown) { |value| calls << [:teardown, value] }
        sys = new_system.declare('a', String)
        sys.component!('a', provider)
        sys.start!
        sys.teardown!

        expect(calls).to eq([[:teardown, 'value']])
      end

      it 'runs hooks for dynamic components, with a nil value' do
        calls = []
        provider = Object.new
        provider.define_singleton_method(:call) { 'fresh' }
        provider.define_singleton_method(:start) { |value, _context| calls << [:start, value] }
        sys = new_system.declare('a', String)
        sys.component('a', provider)
        sys.start!

        expect(calls).to eq([[:start, nil]])
        expect(sys['a']).to eq('fresh')
      end

      it 'raises if #builder_for returns something that is not callable' do
        provider = Class.new { def self.builder_for(_node) = Object.new }
        sys = new_system.declare('a')

        expect { sys.component!('a', provider) }.to raise_error(ArgumentError, /a: .+\.builder_for must return a callable/)
      end

      it 'accepts ENV providers' do
        previous = ENV['SYS_TEST_NAME']
        ENV['SYS_TEST_NAME'] = 'Joe'
        sys = new_system
        sys.declare('name', String)
        sys.declare('all', Plumb::Types::Hash[SYS_TEST_NAME: String])
        sys.component!('name', described_class::ENVProvider.new('SYS_TEST_NAME'))
        sys.component!('all', described_class::ENVProvider) # all variables
        sys.build!

        expect(sys['name']).to eq('Joe')
        expect(sys['all']).to eq(SYS_TEST_NAME: 'Joe')
      ensure
        previous.nil? ? ENV.delete('SYS_TEST_NAME') : ENV['SYS_TEST_NAME'] = previous
      end

      it 'checks ENV providers against the node type' do
        sys = new_system.declare('name', String)

        expect { sys.component!('name', described_class::ENVProvider.new(/^USER_/)) }.to raise_error(ArgumentError, /doesn't take one/)
        expect(sys.node('name').implementation).to be_nil
      end

      it 'parses provided values through the declared type' do
        sys = new_system.declare('n', Integer)
        sys.component!('n', -> { 'nope' })

        expect { sys.build! }.to raise_error(Plumb::ParseError, 'n: Must be a Integer')
      end

      it 'raises for providers that are not callable' do
        sys = new_system.declare('a')

        expect { sys.component!('a', Object.new) }.to raise_error(ArgumentError, /a: a provider must respond to #call or #builder_for/)
        expect { sys.component!('a', 'b') }.to raise_error(ArgumentError, /a provider must respond/)
      end

      it 'raises when given both a provider and a block, or deps that are not an array' do
        sys = new_system.declare('a')

        expect { sys.component!('a', -> { 1 }) { build { 2 } } }.to raise_error(ArgumentError, /either a provider or a block/)
        expect { sys.component!('a', ['b'], -> { 1 }) { build { 2 } } }.to raise_error(ArgumentError, /either a provider or a block/)
        expect { sys.component!('a', 'b', -> { 1 }) }.to raise_error(ArgumentError, /deps must be an Array/)
      end
    end

    it 'raises for unknown implementation modes' do
      expect {
        described_class::Implementation.new([], implementer: new_system, mode: :lazy, hooks: {})
      }.to raise_error(ArgumentError, /unknown mode/)
    end
  end

  describe '#config! and #config' do
    it 'implements singletons with only a build step' do
      builds = 0
      sys = new_system
      sys.declare('foo.bar', Integer)
      sys.config!('foo.bar') { builds += 1; 10 }
      sys.build!

      expect(sys.node('foo.bar').implementation.mode).to eq(:singleton)
      expect(sys['foo.bar']).to eq(10)
      expect(sys['foo.bar']).to eq(10)
      expect(builds).to eq(1)
    end

    it 'implements dynamic components with only a build step' do
      counter = 0
      sys = new_system
      sys.declare('counter', Integer)
      sys.config('counter') { counter += 1 }
      sys.build!

      expect(sys.node('counter').implementation.mode).to eq(:dynamic)
      expect(sys['counter']).to eq(1)
      expect(sys['counter']).to eq(2)
    end

    it 'passes dependency values to the block, relative to the implementing system' do
      lib = new_system
      lib.declare('db', String) { 'lib db' }
      app = new_system
      app.mount('sourced', lib)
      app.declare('with.deps', String)
      app.declare('dynamic', String)
      app.config!('with.deps', ['sourced.db']) { |db| "with #{db}" }
      app.config('dynamic', ['sourced.db', 'with.deps']) { |db, with| "#{db} / #{with}" }
      app.build!

      expect(app['with.deps']).to eq('with lib db')
      expect(app['dynamic']).to eq('lib db / with lib db')
    end

    it 'runs no other hooks' do
      sys = new_system
      sys.declare('a', Integer)
      sys.config!('a') { 1 }
      sys.start!
      sys.teardown!

      expect(sys.node('a').status).to eq(:toredown)
      expect(sys['a']).to eq(1)
    end

    it 'parses values through the declared type' do
      sys = new_system
      sys.declare('a', Integer)
      sys.config!('a') { 'nope' }

      expect { sys.build! }.to raise_error(Plumb::ParseError, 'a: Must be a Integer')
    end

    it 'replaces previous implementations' do
      sys = new_system
      sys.declare('a', Integer) { 1 }
      sys.config!('a') { 2 }
      sys.build!

      expect(sys['a']).to eq(2)
    end

    it 'requires a block' do
      sys = new_system
      sys.declare('a')

      expect { sys.config!('a') }.to raise_error(ArgumentError, /needs a block/)
      expect { sys.config('a') }.to raise_error(ArgumentError, /needs a block/)
    end

    it 'raises for undeclared keys and locked systems' do
      sys = new_system

      expect { sys.config!('nope') { 1 } }.to raise_error(described_class::UndeclaredComponentError)
      sys.declare('a') { 1 }
      sys.prepare!
      expect { sys.config('a') { 2 } }.to raise_error(described_class::LockedSystemError)
    end
  end

  describe '#env' do
    let(:user) { Plumb::Types::Data[name: String, dob: Date] }

    # Set ENV variables for the block, restoring previous values afterwards
    def with_env(vars)
      previous = vars.keys.to_h { |k| [k, ENV[k]] }
      vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    def build(sys)
      sys.build!
      sys
    end

    def env_error = described_class::ENVProvider::Error

    describe 'single variables' do
      it 'decodes a variable into the declared type' do
        with_env('USER_EMAIL' => 'me@example.com', 'APP_PORT' => '3000') do
          sys = new_system.declare('user.email', Plumb::Types::Email).declare('app.port', Integer)
          expect(sys.env('USER_EMAIL' => 'user.email', 'APP_PORT' => 'app.port')).to be(sys)

          expect(build(sys)['user.email']).to eq('me@example.com')
          expect(sys['app.port']).to eq(3000)
        end
      end

      it 'names the variable when it is missing or invalid, without its value' do
        with_env('USER_EMAIL' => nil) do
          sys = new_system.declare('user.email', Plumb::Types::Email).env('USER_EMAIL' => 'user.email')
          expect { sys.build! }.to raise_error(env_error, 'invalid ENV for user.email: USER_EMAIL is missing')
        end

        with_env('USER_EMAIL' => 'secret-nope') do
          sys = new_system.declare('user.email', Plumb::Types::Email).env('USER_EMAIL' => 'user.email')
          expect { sys.build! }.to raise_error(Plumb::ParseError) { |e|
            expect(e).to be_a(env_error)
            expect(e.message).to start_with('invalid ENV for user.email: USER_EMAIL is invalid: Must match')
            expect(e.message).not_to include('secret-nope')
          }
        end
      end

      it 'allows missing variables for nullable types' do
        with_env('USER_EMAIL' => nil) do
          sys = new_system.declare('user.email', Plumb::Types::Email.nullable).env('USER_EMAIL' => 'user.email')
          expect(build(sys)['user.email']).to be_nil
        end
      end

      it "doesn't allow modifiers" do
        sys = new_system.declare('user.email')
        expect { sys.env(:downcase, 'USER_EMAIL' => 'user.email') }.to raise_error(ArgumentError, /only be used when collecting variables with a regex/)
        expect(sys.node('user.email').implementation).to be_nil
      end
    end

    describe 'collecting variables with a regex' do
      it 'collects matching variables into a hash, removing the match, and decodes it' do
        with_env('NAME' => 'root', 'USER_NAME' => 'Ismael', 'USER_DOB' => '1977-11-29') do
          sys = new_system.declare('user.info', Plumb::Types::Hash[NAME: String, DOB: Date])
          sys.env(/^USER_/ => 'user.info')

          expect(build(sys)['user.info']).to eq(NAME: 'Ismael', DOB: Date.new(1977, 11, 29))
        end
      end

      it 'decodes names into the keys the type expects: symbols for schemas and symbol maps, strings for string maps' do
        with_env('APP_HOST' => 'localhost', 'APP_PORT' => '3000') do
          sys = new_system
          sys.declare('strings', Plumb::Types::Hash[String, String])
          sys.declare('symbols', Plumb::Types::Hash[Symbol, String])
          sys.declare('schema', Plumb::Types::Hash['HOST' => String, 'PORT' => Integer])
          # separate calls: the same regex twice in one hash literal would be one key
          %w[strings symbols schema].each { |key| sys.env(/^APP_/ => key) }
          sys.build!

          expect(sys['strings']).to include('HOST' => 'localhost', 'PORT' => '3000')
          expect(sys['symbols']).to include(HOST: 'localhost', PORT: '3000')
          expect(sys['schema']).to eq('HOST' => 'localhost', 'PORT' => 3000)
        end
      end

      it 'applies modifiers to collected names' do
        with_env('USER_NAME' => 'Ismael', 'USER_DOB' => '1977-11-29') do
          sys = new_system.declare('user.info', user).env(:downcase, /^USER_/ => 'user.info')

          expect(build(sys)['user.info']).to be_a(user).and have_attributes(name: 'Ismael', dob: Date.new(1977, 11, 29))
        end
      end

      it 'names invalid variables, and missing attributes, hinting at modifiers' do
        with_env('USER_NAME' => 'Ismael', 'USER_DOB' => 'not-a-date', 'USER_EMAIL' => nil) do
          type = Plumb::Types::Data[name: String, dob: Date, email: String]
          sys = new_system.declare('user.info', type).env(:downcase, /^USER_/ => 'user.info')

          expect { sys.build! }.to raise_error(env_error, <<~MSG.chomp)
            invalid ENV for user.info:
              USER_DOB is invalid: Must match /\\A\\d{4}-\\d{2}-\\d{2}\\z/
              email is missing from ENV variables matching /^USER_/
          MSG
        end

        with_env('USER_NAME' => 'Ismael', 'USER_DOB' => '1977-11-29') do
          sys = new_system.declare('user.info', user).env(/^USER_/ => 'user.info')

          expect { sys.build! }.to raise_error(
            env_error, /name is missing from ENV variables matching \/\^USER_\/ \(found USER_NAME, try :downcase\)/
          )
        end
      end

      it 'checks that the declared type takes a hash' do
        person = Class.new(Plumb::Types::Data) { attribute :name, String }
        takes_hash = [
          Plumb::Types::Any,
          Plumb::Types::Hash,
          Plumb::Types::Hash[name: String],
          Plumb::Types::Hash[String, String],
          user,
          person,
          user.nullable,
          Plumb::Types::Hash[name: String].default({}.freeze),
          Plumb::Types::String | Plumb::Types::Hash
        ]
        takes_hash.each do |type|
          sys = new_system.declare('user.info', type)
          expect { sys.env(/^USER_/ => 'user.info') }.not_to raise_error, "expected #{type.inspect} to be accepted"
        end

        [Plumb::Types::String, Plumb::Types::Email, Integer, Plumb::Types::Array[String], Plumb::Types::String.nullable].each do |type|
          sys = new_system.declare('user.info', type)
          expect { sys.env(/^USER_/ => 'user.info') }.to raise_error(
            ArgumentError, /user.info: ENV variables matching \/\^USER_\/ are collected into a hash, but .+ doesn't take one/
          ), "expected #{type.inspect} to be rejected"
          expect(sys.node('user.info').implementation).to be_nil
        end
      end

      it 'checks types when collecting all variables, and with a provider directly' do
        sys = new_system.declare('user.email', String)

        expect { sys.env('user.email') }.to raise_error(ArgumentError, /doesn't take one/)
        expect { described_class::ENVProvider.new(/^USER_/).check!(sys.node('user.email')) }.to raise_error(ArgumentError, /doesn't take one/)
        expect { sys.env('USER_EMAIL' => 'user.email') }.not_to raise_error # single variables take any type
      end

      it 'supports optional attributes and defaults' do
        with_env('USER_NAME' => 'Ismael', 'USER_DOB' => nil) do
          optional = new_system.declare('user.info', Plumb::Types::Data[name: String, dob?: Date])
          optional.env(:downcase, /^USER_/ => 'user.info')
          defaulted = new_system.declare('user.info', Plumb::Types::Data[name: String, dob: Plumb::Types::Date.default(Date.new(2000, 1, 1).freeze)])
          defaulted.env(:downcase, /^USER_/ => 'user.info')

          expect(build(optional)['user.info']).to have_attributes(name: 'Ismael', dob: nil)
          expect(build(defaulted)['user.info'].dob).to eq(Date.new(2000, 1, 1))
        end
      end

      it 'rejects unknown modifiers' do
        expect { new_system.declare('a').env(:upcase, /^A_/ => 'a') }.to raise_error(ArgumentError, /unknown ENV modifiers: upcase/)
      end
    end

    describe 'collecting all variables' do
      it 'collects every variable when given only a component key' do
        with_env('NAME' => 'Ismael', 'DOB' => '1977-11-29') do
          sys = new_system.declare('user.info', Plumb::Types::Hash[NAME: String, DOB: Date]).env('user.info')

          expect(build(sys)['user.info']).to eq(NAME: 'Ismael', DOB: Date.new(1977, 11, 29))
        end
      end

      it 'applies modifiers' do
        with_env('NAME' => 'Ismael', 'DOB' => '1977-11-29') do
          sys = new_system.declare('user.info', user).env(:downcase, 'user.info')

          expect(build(sys)['user.info']).to have_attributes(name: 'Ismael', dob: Date.new(1977, 11, 29))
        end
      end

      it 'is what a provider with no source does' do
        expect(described_class::ENVProvider.new.source).to eq(described_class::ENVProvider::ALL)
      end
    end

    it 'reads raw strings into untyped (Any) components' do
      with_env('USER_EMAIL' => 'me@example.com', 'USER_NAME' => 'Ismael') do
        sys = new_system.declare('user.email').declare('user.info')
        sys.env('USER_EMAIL' => 'user.email', /^USER_/ => 'user.info')
        sys.build!

        expect(sys['user.email']).to eq('me@example.com')
        expect(sys['user.info']).to include('NAME' => 'Ismael', 'EMAIL' => 'me@example.com')
      end
    end

    it 'reads ENV when components are built, not when they are implemented' do
      sys = new_system.declare('user.email', String).env('USER_EMAIL' => 'user.email')

      with_env('USER_EMAIL' => 'later@example.com') do
        expect(build(sys)['user.email']).to eq('later@example.com')
      end
    end

    it 'implements singleton components, replacing previous implementations' do
      with_env('USER_EMAIL' => 'me@example.com') do
        sys = new_system.declare('user.email', String) { 'default' }
        sys.env('USER_EMAIL' => 'user.email')

        expect(sys.node('user.email').implementation).to have_attributes(mode: :singleton, implementer: sys, deps: [])
        expect(build(sys)['user.email']).to eq('me@example.com')
      end
    end

    it 'validates every source, key and type before implementing any' do
      sys = new_system.declare('a').declare('b', String)

      expect { sys.env('A' => 'a', 42 => 'b') }.to raise_error(ArgumentError, /must be a variable name or a regex/)
      expect { sys.env('A' => 'a', /^B_/ => 'b') }.to raise_error(ArgumentError, /doesn't take one/)
      expect { sys.env('A' => 'a', 'B' => 'nope') }.to raise_error(described_class::UndeclaredComponentError)
      expect { sys.env }.to raise_error(ArgumentError, /needs a component key/)
      expect(sys.node('a').implementation).to be_nil
    end

    it "can't implement components in a locked system" do
      sys = new_system.declare('a') { 1 }
      sys.prepare!

      expect { sys.env('A' => 'a') }.to raise_error(described_class::LockedSystemError)
    end

    it 'takes keys relative to the system' do
      with_env('DB_URL' => 'sqlite://') do
        sys = new_system.declare('sourced.db.url', String)
        sys.node('sourced').env('DB_URL' => 'db.url')

        expect(sys.node('sourced.db.url').implementation.implementer).to be(sys.node('sourced'))
        expect(build(sys)['sourced.db.url']).to eq('sqlite://')
      end
    end

    it 'names the full path of components in mounted systems, even if implemented before mounting' do
      with_env('DB_PORT' => 'nope') do
        lib = new_system.declare('db.port', Integer).env('DB_PORT' => 'db.port')
        app = new_system
        app.mount('sourced', lib)

        expect { app.build! }.to raise_error(env_error, /\Ainvalid ENV for sourced\.db\.port: DB_PORT is invalid/)
      end
    end

    it 'lets an app implement components of a mounted system from ENV' do
      with_env('DB_PORT' => '5432') do
        lib = new_system.declare('db.port', Integer) { 3306 }
        app = new_system
        app.mount('sourced', lib)
        app.env('DB_PORT' => 'sourced.db.port')

        expect(build(app)['sourced.db.port']).to eq(5432)
        expect(lib['db.port']).to eq(5432)
      end
    end

    it 'shows sources and modifiers when inspecting' do
      expect(described_class::ENVProvider.new('USER_EMAIL').inspect).to eq('#<Sourced::System::ENVProvider "USER_EMAIL">')
      expect(described_class::ENVProvider.new(/^USER_/, :downcase).inspect).to eq('#<Sourced::System::ENVProvider /^USER_/ downcase>')
    end
  end

  describe '#inject' do
    def injectable_system
      new_system.tap do |s|
        s.declare('logger') { 'the logger' }
        s.declare('sourced.store') { 'the store' }
        counter = 0
        s.declare('counter', Integer)
        s.config('counter') { counter += 1 }
      end
    end

    it 'injects components as kwargs with readers, defaulting to system values' do
      sys = injectable_system
      sys.build!
      klass = Class.new { include sys.inject('logger') }

      expect(klass.new.logger).to eq('the logger')
      expect(klass.new(logger: 'custom').logger).to eq('custom')
      expect(klass.new(logger: nil).logger).to be_nil
    end

    it 'names kwargs after the last segment of dotted keys, and takes multiple keys' do
      sys = injectable_system
      sys.build!
      klass = Class.new { include sys.inject('logger', 'sourced.store') }
      obj = klass.new(store: 'custom store')

      expect(obj.logger).to eq('the logger')
      expect(obj.store).to eq('custom store')
    end

    it 'aliases keys to custom kwargs with a hash' do
      sys = injectable_system
      sys.build!
      klass = Class.new { include sys.inject('logger', 'sourced.store' => 'st') }

      expect(klass.new.st).to eq('the store')
      expect(klass.new(st: 'custom').st).to eq('custom')
      expect(klass.new).not_to respond_to(:store)
    end

    it "composes multiple injections with the class' own #initialize" do
      sys = injectable_system
      sys.build!
      klass = Class.new do
        include sys.inject('logger')
        include sys.inject('sourced.store')
        attr_reader :args

        def initialize(name, age: 1)
          @args = [name, age]
        end
      end
      obj = klass.new('joe', age: 40, store: 'custom')

      expect(obj.args).to eq(['joe', 40])
      expect(obj.logger).to eq('the logger')
      expect(obj.store).to eq('custom')
    end

    it 'is inherited by subclasses' do
      sys = injectable_system
      sys.build!
      parent = Class.new { include sys.inject('logger') }
      child = Class.new(parent) { include sys.inject('sourced.store') }
      obj = child.new(logger: 'custom')

      expect(obj.logger).to eq('custom')
      expect(obj.store).to eq('the store')
    end

    it 'reads values on instantiation, so classes can be defined before the system is built' do
      sys = injectable_system
      klass = Class.new { include sys.inject('counter') }
      expect { klass.new }.to raise_error(described_class::NotBuiltError)

      sys.build!
      expect(klass.new.counter).to eq(1)
      expect(klass.new.counter).to eq(2)
    end

    it 'injects by keys relative to the system' do
      sys = injectable_system
      sys.build!
      klass = Class.new { include sys.node('sourced').inject('store') }

      expect(klass.new.store).to eq('the store')
    end

    it "gives classes injecting from a library's system the overrides of the app that mounts it" do
      lib = new_system
      lib.declare('store', String) { 'lib store' }
      klass = Class.new { include lib.inject('store') } # defined before the library is mounted

      app = new_system
      app.mount('sourced', lib)
      app.config!('sourced.store') { 'app store' }

      expect { klass.new }.to raise_error(described_class::NotBuiltError)
      app.build!
      expect(klass.new.store).to eq('app store')
    end

    it 'describes the injection' do
      sys = injectable_system

      expect(sys.inject('logger', 'sourced.store' => 'st').inspect)
        .to eq('#<Sourced::System::Injector logger => logger, sourced.store => st>')
    end

    it 'raises on undeclared components' do
      sys = injectable_system

      expect { sys.inject('nope') }.to raise_error(described_class::UndeclaredComponentError, /nope is not declared/)
    end

    it 'raises on duplicate names' do
      sys = injectable_system
      sys.declare('other.logger')
      expect { sys.inject('logger', 'other.logger') }.to raise_error(ArgumentError, /duplicate injected names: logger/)

      klass = Class.new { include sys.inject('logger') }
      expect { klass.include(sys.inject('other.logger')) }.to raise_error(ArgumentError, /already injects logger/)
    end
  end

  describe '#mount' do
    it 'attaches a standalone system as a branch, indexing its nodes' do
      lib = new_system
      lib.declare('db', String) { 'db' }
      app = new_system
      app.mount('sourced', lib)

      expect(lib.parent).to be(app)
      expect(lib.key).to eq('sourced')
      expect(lib.path).to eq('sourced')
      expect(lib.owner).to be(lib)
      expect(lib.root).to be(app)
      expect(app.children['sourced']).to be(lib)
      expect(app.index.keys).to eq(%w[sourced sourced.db])
    end

    it 'mounts under dotted keys, creating namespaces' do
      lib = new_system
      lib.declare('db', String) { 'db' }
      app = new_system
      app.mount('libs.sourced', lib)
      app.build!

      expect(app.node('libs').namespace?).to be(true)
      expect(app.node('libs').owner).to be(app)
      expect(app['libs.sourced.db']).to eq('db')
    end

    it 'mounts nested trees' do
      inner = new_system
      inner.declare('x', Integer) { 1 }
      middle = new_system
      middle.mount('inner', inner)
      app = new_system
      app.mount('middle', middle)
      app.build!

      expect(app.index.keys).to eq(%w[middle middle.inner middle.inner.x])
      expect(app['middle.inner.x']).to eq(1)
      expect(inner['x']).to eq(1)
      expect(inner.path).to eq('middle.inner')
    end

    it 'indexes nodes declared in mounted systems after mounting, in every ancestor' do
      inner = new_system
      middle = new_system
      middle.mount('inner', inner)
      app = new_system
      app.mount('middle', middle)
      inner.declare('late', Integer) { 1 }

      expect(app.node('middle.inner.late')).to be(inner.node('late'))
      expect(middle.node('inner.late')).to be(inner.node('late'))
    end

    it 'raises if not given a System' do
      expect { new_system.mount('x', Object.new) }.to raise_error(ArgumentError, /not a System/)
    end

    it 'raises if the system is already mounted' do
      lib = new_system
      new_system.mount('a', lib)

      expect { new_system.mount('b', lib) }.to raise_error(described_class::SubsystemError, /already mounted/)
    end

    it 'raises when mounting a system into its own tree' do
      app = new_system
      lib = new_system
      app.mount('lib', lib)

      expect { app.mount('self', app) }.to raise_error(described_class::SubsystemError, /own tree/)
      expect { lib.mount('up', app) }.to raise_error(described_class::SubsystemError, /own tree/)
    end

    it 'raises if the key is taken' do
      app = new_system
      app.declare('a', String)

      expect { app.mount('a', new_system) }.to raise_error(described_class::DeclarationOverrideError, /a is already declared/)
    end

    it "raises if the key is under another system's nodes" do
      lib = new_system
      app = new_system
      app.mount('sourced', lib)

      expect { app.mount('sourced.other', new_system) }.to raise_error(described_class::OwnershipError)
    end

    it 'raises if the mounted system is locked' do
      lib = new_system
      lib.build!

      expect { new_system.mount('lib', lib) }.to raise_error(described_class::LockedSystemError, /must be open/)
    end
  end

  describe 'lifecycle' do
    it 'runs prepare, build, start and teardown hooks across the tree, in dependency order' do
      calls = []
      lib = new_system
      lib.declare('logger', String)
      lib.component!('logger') do
        prepare { calls << [:prepare, 'logger'] }
        build { calls << [:build, 'logger']; 'logger' }
        start { |value, context| calls << [:start, 'logger', value, context] }
        teardown { |value| calls << [:teardown, 'logger', value] }
      end

      app = new_system
      app.declare('db', String)
      app.component!('db', ['sourced.logger']) do
        prepare { calls << [:prepare, 'db'] }
        build { |logger| calls << [:build, 'db', logger]; 'db' }
        start { |value, context| calls << [:start, 'db', value, context] }
        teardown { |value| calls << [:teardown, 'db', value] }
      end
      app.mount('sourced', lib)

      app.start!(:ctx)
      app.teardown!

      expect(calls).to eq([
        [:prepare, 'logger'],
        [:prepare, 'db'],
        [:build, 'logger'],
        [:build, 'db', 'logger'],
        [:start, 'logger', 'logger', :ctx],
        [:start, 'db', 'db', :ctx],
        [:teardown, 'db', 'db'],
        [:teardown, 'logger', 'logger']
      ])
    end

    it 'moves the root and every node through statuses' do
      sys = new_system
      sys.declare('a.b', Integer) { 1 }
      node = sys.node('a.b')

      expect([sys.boot_status, node.status]).to eq(%i[open open])
      sys.prepare!
      expect([sys.boot_status, node.status]).to eq(%i[prepared prepared])
      sys.build!
      expect([sys.boot_status, node.status]).to eq(%i[built built])
      sys.start!
      expect([sys.boot_status, node.status]).to eq(%i[started started])
      sys.teardown!
      expect([sys.boot_status, node.status]).to eq(%i[toredown toredown])
      expect(sys.node('a').status).to eq(:open) # namespaces are skipped
    end

    it 'defaults the start context to the current thread' do
      context = nil
      sys = new_system
      sys.declare('a')
      sys.component!('a') { start { |_, ctx| context = ctx } }
      sys.start!

      expect(context).to be(Thread.current)
    end

    it 'is idempotent' do
      builds = 0
      sys = new_system
      sys.declare('a', Integer)
      sys.component!('a') { build { builds += 1 } }

      sys.start!
      sys.start!
      sys.build!
      sys.prepare!

      expect(builds).to eq(1)
    end

    it 'only tears down a started system' do
      torn = false
      sys = new_system
      sys.declare('a')
      sys.component!('a') { teardown { torn = true } }
      sys.build!
      sys.teardown!

      expect(torn).to be(false)
      expect(sys.boot_status).to eq(:built)
    end

    it 'exposes nodes in dependency order once prepared' do
      sys = new_system
      sys.declare('b', Integer)
      sys.declare('a', Integer) { 1 }
      sys.component!('b', ['a']) { build { |a| a + 1 } }

      expect { sys.ordered_nodes }.to raise_error(described_class::NotBuiltError)
      sys.prepare!
      expect(sys.ordered_nodes.map(&:path)).to eq(%w[a b])
    end

    it 'includes the root when it is implemented' do
      lib = new_system
      lib.declare('x', Integer) { 1 }
      app = new_system
      app.mount('lib', lib)
      app.component!('lib', ['lib.x']) { build { |x| x * 10 } }
      app.build!

      expect(app['lib']).to eq(10)
    end

    it 'parses built values through the declared type' do
      sys = new_system
      sys.declare('n', Integer) { 'nope' }

      expect { sys.build! }.to raise_error(Plumb::ParseError, 'n: Must be a Integer')
    end

    it 'names the full path of the component in type errors' do
      lib = new_system
      lib.declare('db.port', Integer) { 'nope' }
      app = new_system
      app.mount('libs.sourced', lib)

      expect { app.build! }.to raise_error(Plumb::ParseError, 'libs.sourced.db.port: Must be a Integer')
      expect(app.boot_status).to eq(:prepared)
    end

    it 'includes structured errors, without the value' do
      sys = new_system
      sys.declare('user', Plumb::Types::Hash[name: String, age: Integer]) { { name: 'Joe', age: 'secret' } }

      expect { sys.build! }.to raise_error(Plumb::ParseError) { |e|
        expect(e.message).to start_with('user: {')
        expect(e.message).to include('age')
        expect(e.message).not_to include('secret')
      }
    end

    it 'stores the parsed value' do
      sys = new_system
      sys.declare('port', Plumb::Types::Lax::Integer) { '3000' }
      sys.build!

      expect(sys['port']).to eq(3000)
    end

    it 'locks the tree once prepared' do
      lib = new_system
      app = new_system
      app.mount('lib', lib)
      app.prepare!

      expect { app.declare('a') }.to raise_error(described_class::LockedSystemError)
      expect { lib.declare('a') }.to raise_error(described_class::LockedSystemError)
      expect { app.component!('lib') { build { 1 } } }.to raise_error(described_class::LockedSystemError)
      expect { app.mount('other', new_system) }.to raise_error(described_class::LockedSystemError)
      expect(lib.locked?).to be(true)
    end

    it 'raises when booting a mounted system' do
      lib = new_system
      new_system.mount('lib', lib)

      %i[prepare! build! start! teardown! ordered_nodes].each do |method|
        expect { lib.public_send(method) }.to raise_error(described_class::SubsystemError, /boot the root/)
      end
    end

    describe 'prepare! errors' do
      it 'raises for declared nodes without an implementation' do
        sys = new_system
        sys.declare('deep.thing', Integer)
        sys.declare('other', Integer)

        expect { sys.prepare! }.to raise_error(described_class::UnimplementedComponentError, /deep\.thing, other/)
      end

      it 'raises for missing deps, with full keys' do
        lib = new_system
        lib.declare('x', Integer)
        lib.component!('x', ['nope']) { build { 1 } }
        app = new_system
        app.mount('libs.lib', lib)

        expect { app.prepare! }.to raise_error(
          described_class::MissingDependencyError,
          'libs.lib.x depends on libs.lib.nope, which is not declared'
        )
      end

      it 'raises for deps on unimplemented namespaces' do
        sys = new_system
        sys.declare('ns.x', Integer) { 1 }
        sys.declare('a', Integer)
        sys.component!('a', ['ns']) { build { 1 } }

        expect { sys.prepare! }.to raise_error(described_class::MissingDependencyError, /a depends on ns, which is not implemented/)
      end

      it "can't reach outside the implementer's tree" do
        lib = new_system
        lib.declare('x', Integer)
        lib.component!('x', ['logger']) { build { 1 } }
        app = new_system
        app.declare('logger') { 'app logger' }
        app.mount('lib', lib)

        expect { app.prepare! }.to raise_error(described_class::MissingDependencyError, /lib\.x depends on lib\.logger/)
      end

      it 'raises for circular dependencies' do
        sys = new_system
        sys.declare('a', Integer)
        sys.declare('b', Integer)
        sys.component!('a', ['b']) { build { |b| b } }
        sys.component!('b', ['a']) { build { |a| a } }

        expect { sys.prepare! }.to raise_error(described_class::CircularDependencyError, /between a, b/)
      end

      it 'raises for self dependencies' do
        sys = new_system
        sys.declare('a', Integer)
        sys.component!('a', ['a']) { build { |a| a } }

        expect { sys.prepare! }.to raise_error(described_class::CircularDependencyError, /between a/)
      end

      it 'resolves deps declared after the component' do
        sys = new_system
        sys.declare('b', Integer)
        sys.component!('b', ['a']) { build { |a| a + 1 } }
        sys.declare('a', Integer) { 1 }
        sys.build!

        expect(sys['b']).to eq(2)
      end
    end

    describe 'start! failures' do
      it 'tears down started nodes, in reverse order, and re-raises' do
        calls = []
        sys = new_system
        sys.declare('a') { 1 }
        sys.declare('b') { 2 }
        sys.declare('c')
        sys.component!('a') { start { calls << :start_a }; teardown { calls << :teardown_a } }
        sys.component!('b', ['a']) { start { calls << :start_b }; teardown { calls << :teardown_b } }
        sys.component!('c', ['b']) { start { raise 'boom' }; teardown { calls << :teardown_c } }

        expect { sys.start! }.to raise_error(RuntimeError, 'boom')
        expect(calls).to eq(%i[start_a start_b teardown_b teardown_a])
        expect(sys.boot_status).to eq(:toredown)
        expect(sys.node('c').status).to eq(:built)
      end
    end

    describe 'teardown! failures' do
      it 'tears down every node, then re-raises the first error' do
        calls = []
        sys = new_system
        sys.declare('a') { 1 }
        sys.declare('b')
        sys.declare('c')
        sys.component!('a') { teardown { calls << :a } }
        sys.component!('b', ['a']) { teardown { calls << :b; raise 'b failed' } }
        sys.component!('c', ['b']) { teardown { calls << :c; raise 'c failed' } }
        sys.start!

        expect { sys.teardown! }.to raise_error(RuntimeError, 'c failed')
        expect(calls).to eq(%i[c b a])
        expect(sys.boot_status).to eq(:toredown)
      end
    end
  end

  describe 'reading values' do
    it 'raises until the system is built' do
      sys = new_system
      sys.declare('a') { 1 }

      expect { sys['a'] }.to raise_error(described_class::NotBuiltError)
      sys.prepare!
      expect { sys['a'] }.to raise_error(described_class::NotBuiltError)
      sys.build!
      expect(sys['a']).to eq(1)
    end

    it 'keeps values readable after teardown' do
      sys = new_system
      sys.declare('a') { 1 }
      sys.start!
      sys.teardown!

      expect(sys['a']).to eq(1)
    end

    it 'memoizes singletons' do
      sys = new_system
      sys.declare('a', String) { +'a' }
      sys.build!

      expect(sys['a']).to be(sys['a'])
    end

    it 'builds dynamic components on each read, with their deps' do
      counter = 0
      sys = new_system
      sys.declare('prefix', String) { 'req' }
      sys.declare('request_id', String)
      sys.component('request_id', ['prefix']) { build { |prefix| "#{prefix}-#{counter += 1}" } }
      sys.build!

      expect(sys['request_id']).to eq('req-1')
      expect(sys['request_id']).to eq('req-2')
    end

    it 'gives singletons that depend on dynamic components a value built once' do
      counter = 0
      sys = new_system
      sys.declare('id', Integer)
      sys.component('id') { build { counter += 1 } }
      sys.declare('first', Integer)
      sys.component!('first', ['id']) { build { |id| id } }
      sys.build!

      expect(sys['first']).to eq(1)
      expect(sys['first']).to eq(1)
      expect(sys['id']).to eq(2)
    end

    it 'parses dynamic values through the declared type' do
      sys = new_system
      sys.declare('n', Integer)
      sys.component('n') { build { 'nope' } }
      sys.build!

      expect { sys['n'] }.to raise_error(Plumb::ParseError, 'n: Must be a Integer')
    end

    it 'raises for undeclared keys and namespaces' do
      sys = new_system
      sys.declare('ns.x') { 1 }
      sys.build!

      expect { sys['nope'] }.to raise_error(described_class::UndeclaredComponentError, /nope is not declared/)
      expect { sys['ns'] }.to raise_error(described_class::UndeclaredComponentError, /ns is a namespace/)
    end

    it 'reads from mounted systems through their own keys' do
      lib = new_system
      lib.declare('db', String) { 'lib db' }
      app = new_system
      app.mount('sourced', lib)
      app.build!

      expect(lib['db']).to eq('lib db')
      expect(lib.node('db')).to be(app.node('sourced.db'))
    end
  end

  describe '#graph' do
    it 'describes all declared components, their statuses, dependencies and types' do
      logger_type = Plumb::Types::Interface[:info]
      sys = new_system
      sys.declare('app')
      sys.declare('logger', logger_type)
      sys.declare('logger.output') { STDOUT }
      sys.declare('db', Plumb::Types::Interface[:append].nullable)
      sys.component!('app', %w[logger logger.output]) { start { |_v, _c| } }
      sys.config('logger', ['logger.output']) { |o| o }

      graph = sys.graph
      expect(graph).to be_a(described_class::Graph)
      expect(graph.status).to eq(:open)
      expect(graph.to_h).to eq(status: :open, components: graph.components)
      expect(graph.components.map { |c| c[:key] }).to eq(%w[app logger logger.output db])

      expect(graph.components[1]).to match(
        key: 'logger',
        type: logger_type,
        type_name: 'Interface[info]',
        implemented: true,
        mode: :dynamic,
        status: :open,
        deps: ['logger.output'],
        missing: [],
        dependents: ['app'],
        provider: be_a(Proc)
      )
      expect(graph.components[0]).to include(provider: nil) # a block of hooks
      expect(graph.components[2]).to include(deps: [], dependents: %w[app logger])
      expect(graph.components[3]).to include(
        key: 'db',
        type_name: '(Nil | Interface[append])',
        implemented: false,
        mode: nil,
        status: :open,
        deps: [],
        missing: [],
        dependents: [],
        provider: nil
      )
    end

    it 'lists components in dependency order, with their statuses, once prepared' do
      sys = new_system
      sys.declare('app')
      sys.declare('logger') { 'logger' }
      sys.config!('app', ['logger']) { |l| l }
      sys.start!

      graph = sys.graph
      expect(graph.status).to eq(:started)
      expect(graph.components.map { |c| [c[:key], c[:status]] }).to eq([['logger', :started], ['app', :started]])
    end

    it 'lists deps that are not declared, or are namespaces without an implementation, as missing' do
      sys = new_system
      sys.declare('ns.x') { 1 }
      sys.declare('app')
      sys.config!('app', %w[ns.x nope ns]) { 1 }

      expect(sys.graph.components.last).to include(key: 'app', deps: %w[ns.x nope ns], missing: %w[nope ns])
    end

    it 'leaves out namespaces, and includes namespaces with an implementation' do
      sys = new_system
      sys.declare('a.b.c') { 1 }
      sys.declare('x.y') { 1 }
      sys.config!('x') { 2 }

      expect(sys.graph.components.map { |c| c[:key] }).to eq(%w[a.b.c x x.y])
    end

    it 'includes providers' do
      provider = described_class::ENVProvider.new('A')
      sys = new_system
      sys.declare('a')
      sys.declare('b')
      sys.component!('a', provider)
      sys.env('B' => 'b')

      expect(sys.graph.components.map { |c| c[:provider] }).to match([provider, be_a(described_class::ENVProvider)])
    end

    it 'describes mounted systems by full path, with deps relative to their implementers' do
      lib = new_system
      lib.declare('logger') { 'lib logger' }
      lib.declare('db')
      lib.config!('db', ['logger']) { |l| l }
      app = new_system
      app.declare('logger') { 'app logger' }
      app.mount('sourced', lib)
      app.declare('app')
      app.config!('app', ['sourced.db']) { |db| db }

      expect(app.graph.components.map { |c| c.slice(:key, :deps, :dependents) }).to eq([
        { key: 'logger', deps: [], dependents: [] },
        { key: 'sourced.logger', deps: [], dependents: ['sourced.db'] },
        { key: 'sourced.db', deps: ['sourced.logger'], dependents: ['app'] },
        { key: 'app', deps: ['sourced.db'], dependents: [] }
      ])

      # The app re-implements the library's db, with its own logger
      app.config!('sourced.db', ['logger']) { |l| l }
      expect(app.graph.components.find { |c| c[:key] == 'logger' }[:dependents]).to eq(['sourced.db'])
    end

    it 'describes the components under a mounted system, with dependents only from its graph' do
      lib = new_system
      lib.declare('logger') { 'lib logger' }
      lib.declare('db')
      app = new_system
      app.declare('logger') { 'app logger' }
      app.declare('app')
      app.mount('sourced', lib)
      app.config!('sourced.db', ['logger']) { |l| l }
      app.config!('app', ['sourced.db']) { |db| db }
      app.start!

      graph = lib.graph
      expect(graph.status).to eq(:started)
      expect(graph.components.map { |c| c.slice(:key, :deps, :missing, :dependents) }).to contain_exactly(
        { key: 'sourced.logger', deps: [], missing: [], dependents: [] },
        { key: 'sourced.db', deps: ['logger'], missing: [], dependents: [] }
      )
    end

    it 'names types without module prefixes' do
      sys = new_system
      sys.declare('email', described_class::T::Email)

      expect(sys.graph.components.first[:type_name]).to eq('Email')
    end
  end

  describe 'Graph#to_mermaid' do
    def classdefs = described_class::Graph::MERMAID_CLASSES.map { |name, style| "  classDef #{name} #{style}" }.join("\n")

    it 'draws components, dependency edges, modes and implementations' do
      sys = new_system
      sys.declare('output') { STDOUT }
      sys.declare('logger', Plumb::Types::Interface[:info])
      sys.declare('db', Plumb::Types::Interface[:exec].nullable)
      sys.declare('request_id', String)
      sys.declare('app')
      sys.config('logger', ['output']) { |o| o }
      sys.config('request_id') { 'x' }
      sys.config!('app', %w[logger db request_id nope]) { 1 }

      expect(sys.graph.to_mermaid).to eq(<<~MERMAID.chomp)
        flowchart LR
          c0["output<br/>Any<br/><i>singleton, open</i>"]:::open
          c1(["logger<br/>Interface[info]<br/><i>dynamic, open</i>"]):::open
          c2["db<br/>(Nil | Interface[exec])<br/><i>not implemented</i>"]:::unimplemented
          c3(["request_id<br/>String<br/><i>dynamic, open</i>"]):::open
          c4["app<br/>Any<br/><i>singleton, open</i>"]:::open
          c5["nope<br/><i>not declared</i>"]:::missing
          c0 --> c1
          c1 --> c4
          c2 --> c4
          c3 --> c4
          c5 --> c4
        #{classdefs}
      MERMAID
    end

    it 'styles nodes by status, in dependency order' do
      sys = new_system
      sys.declare('app')
      sys.declare('logger') { 1 }
      sys.config!('app', ['logger']) { |l| l }
      sys.start!

      nodes = sys.graph.to_mermaid.lines.grep(/:::/).map(&:strip)
      expect(nodes).to eq([
        'c0["logger<br/>Any<br/><i>singleton, started</i>"]:::started',
        'c1["app<br/>Any<br/><i>singleton, started</i>"]:::started'
      ])
    end

    it 'draws deps outside the graph, ex. an app override in a library graph' do
      lib = new_system
      lib.declare('db')
      app = new_system
      app.declare('logger') { 1 }
      app.mount('sourced', lib)
      app.config!('sourced.db', ['logger']) { |l| l }

      expect(lib.graph.to_mermaid).to eq(<<~MERMAID.chomp)
        flowchart LR
          c0["sourced.db<br/>Any<br/><i>singleton, open</i>"]:::open
          c1["logger<br/><i>outside this system</i>"]:::external
          c1 --> c0
        #{classdefs}
      MERMAID
    end

    it 'escapes labels' do
      graph = described_class::Graph.new(status: :open, components: [
        { key: 'a"b', type_name: 'Hash<String> & more', implemented: false, mode: nil, status: :open, deps: [] }
      ])

      expect(graph.to_mermaid.lines[1].strip).to eq(
        'c0["a#quot;b<br/>Hash#lt;String#gt; #amp; more<br/><i>not implemented</i>"]:::unimplemented'
      )
    end
  end

  describe '#inspect' do
    it 'describes the node' do
      sys = new_system
      sys.declare('ns.a', Integer) { 1 }
      sys.declare('ns.b', String)
      sys.component('ns.b') { build { 'b' } }
      sys.declare('ns.c', String)

      expect(sys.inspect).to eq('#<Sourced::System (root) (namespace)>')
      expect(sys.node('ns').inspect).to eq('#<Sourced::System ns (namespace)>')
      expect(sys.node('ns.a').inspect).to eq('#<Sourced::System ns.a Integer (singleton, open)>')
      expect(sys.node('ns.b').inspect).to eq('#<Sourced::System ns.b String (dynamic, open)>')
      expect(sys.node('ns.c').inspect).to eq('#<Sourced::System ns.c String (not implemented, open)>')
    end
  end

  describe 'concurrency' do
    it 'boots once when started from multiple threads' do
      builds = 0
      sys = new_system
      sys.declare('a', Integer)
      sys.component!('a') do
        build do
          sleep 0.01
          builds += 1
        end
      end

      10.times.map { Thread.new { sys.start! } }.each(&:join)

      expect(builds).to eq(1)
      expect(sys.boot_status).to eq(:started)
    end
  end
end
