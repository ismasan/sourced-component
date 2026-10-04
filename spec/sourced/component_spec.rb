# frozen_string_literal: true

require 'spec_helper'
require 'date'

RSpec.describe Sourced::Component do
  def new_component = described_class.new

  it 'has a version number' do
    expect(Sourced::Component::VERSION).not_to be_nil
  end

  describe '#declare' do
    it 'builds a tree of nodes from dot-separated keys, with intermediate namespaces' do
      comp = new_component
      comp.declare('sourced.db.logger', String)

      sourced = comp.children.fetch('sourced')
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
      expect(logger.root).to be(comp)
    end

    it 'indexes every descendant by relative key, in every ancestor' do
      comp = new_component
      comp.declare('sourced.db.logger', String)

      expect(comp.index.keys).to eq(%w[sourced sourced.db sourced.db.logger])
      expect(comp.node('sourced').index.keys).to eq(%w[db db.logger])
      expect(comp.node('sourced.db').index.keys).to eq(%w[logger])
      expect(comp.node('sourced.db.logger')).to be(comp.node('sourced').node('db.logger'))
      expect(comp.declared?('sourced.db')).to be(true)
      expect(comp.declared?('nope')).to be(false)
    end

    it 'makes the declaring component the owner of the nodes it creates' do
      comp = new_component
      comp.declare('a.b', String)

      expect(comp.owner).to be(comp)
      expect(comp.node('a').owner).to be(comp)
      expect(comp.node('a.b').owner).to be(comp)
    end

    it 'defaults the type to Any' do
      comp = new_component
      comp.declare('anything') { 1 }

      expect(comp.node('anything').type).to eq(Plumb::Types::Any)
      expect(comp.node('anything').implicit?).to be(false)
    end

    it 'treats nil as a valid type' do
      comp = new_component
      comp.declare('nothing', nil) { nil }
      comp.build!

      expect(comp.node('nothing').implicit?).to be(false)
      expect(comp['nothing']).to be_nil
    end

    it 'gives implicit nodes the Any type' do
      comp = new_component
      comp.declare('ns.x', String)

      expect(comp.node('ns').implicit?).to be(true)
      expect(comp.node('ns').type).to eq(Plumb::Types::Any)
    end

    it 'registers a default block as a singleton implementation' do
      comp = new_component
      comp.declare('name', String) { 'Joe' }
      comp.build!

      expect(comp.node('name').implementation.mode).to eq(:singleton)
      expect(comp['name']).to eq('Joe')
    end

    it 'can add children to namespaces it owns' do
      comp = new_component
      comp.declare('cache.redis', String) { 'redis://' }
      comp.declare('cache.redis.pool', Integer) { 5 }
      comp.build!

      expect(comp['cache.redis']).to eq('redis://')
      expect(comp['cache.redis.pool']).to eq(5)
    end

    it 'gives a type to an implicit namespace it created' do
      comp = new_component
      comp.declare('db.url', String) { 'sqlite://' }
      comp.declare('db', String)
      comp.component!('db', ['db.url']) { build { |url| "DB(#{url})" } }
      comp.build!

      expect(comp.node('db').implicit?).to be(false)
      expect(comp['db']).to eq('DB(sqlite://)')
    end

    it 'raises when re-declaring a key' do
      comp = new_component
      comp.declare('a', String)

      expect { comp.declare('a', Integer) }.to raise_error(described_class::DeclarationOverrideError, /a is already declared/)
    end

    it 'raises on invalid keys' do
      comp = new_component

      expect { comp.declare('a..b') }.to raise_error(ArgumentError)
      expect { comp.declare('') }.to raise_error(ArgumentError)
      expect { comp.declare('.a') }.to raise_error(ArgumentError)
    end
  end

  describe 'ownership' do
    let(:lib) do
      new_component.tap do |s|
        s.declare('db', String) { 'lib db' }
      end
    end

    let(:app) do
      new_component.tap { |s| s.mount('sourced', lib) }
    end

    it "can't declare under a mounted component's nodes" do
      expect { app.declare('sourced.extra', String) }.to raise_error(described_class::OwnershipError, /sourced is owned by/)
      expect { app.declare('sourced.db.extra', String) }.to raise_error(described_class::OwnershipError)
    end

    it "can't declare under namespaces created by another component" do
      lib.declare('settings.retries', Integer) { 3 }

      expect { app.declare('sourced.settings.timeout', Integer) }.to raise_error(described_class::OwnershipError, /sourced is owned by/)
    end

    it 'lets the mounted component keep declaring under itself' do
      app
      lib.declare('settings.retries', Integer) { 3 }

      expect(app.index.keys).to include('sourced.settings', 'sourced.settings.retries')
      expect(lib.node('settings.retries')).to be(app.node('sourced.settings.retries'))
    end

    it "lets an ancestor implement a mounted component's nodes" do
      app.component!('sourced.db') { build { 'app db' } }
      app.build!

      expect(app['sourced.db']).to eq('app db')
    end
  end

  describe '#component' do
    it 'implements a declared node with deps and lifecycle hooks' do
      comp = new_component
      comp.declare('url', String) { 'sqlite://' }
      comp.declare('db', String)
      comp.component!('db', ['url']) do
        build { |url| "DB(#{url})" }
      end
      comp.build!

      impl = comp.node('db').implementation
      expect(impl.deps).to eq(['url'])
      expect(impl.implementer).to be(comp)
      expect(comp['db']).to eq('DB(sqlite://)')
    end

    it 'accepts a block with the DSL as an argument' do
      comp = new_component
      comp.declare('a', Integer)
      comp.component!('a') { |c| c.build { 1 } }
      comp.build!

      expect(comp['a']).to eq(1)
    end

    it 'accepts callables as hooks' do
      comp = new_component
      comp.declare('a', Integer)
      comp.component!('a') { build(-> { 2 }) }
      comp.build!

      expect(comp['a']).to eq(2)
    end

    it 'resolves deps relative to the implementing component' do
      lib = new_component
      lib.declare('logger', String) { 'lib logger' }
      lib.declare('db', String)
      lib.component!('db', ['logger']) { build { |logger| "db with #{logger}" } }

      app = new_component
      app.declare('logger', String) { 'app logger' }
      app.mount('sourced', lib)
      app.build!

      expect(app['sourced.db']).to eq('db with lib logger')
    end

    it 'lets an ancestor re-implement a node, with deps relative to the ancestor' do
      lib = new_component
      lib.declare('logger', String) { 'lib logger' }
      lib.declare('db', String)
      lib.component!('db', ['logger']) { build { |logger| "db with #{logger}" } }

      app = new_component
      app.declare('logger', String) { 'app logger' }
      app.mount('sourced', lib)
      app.component!('sourced.db', ['logger']) { build { |logger| "app db with #{logger}" } }
      app.build!

      expect(app['sourced.db']).to eq('app db with app logger')
      expect(lib['db']).to eq('app db with app logger')
      expect(lib['db']).to be(app['sourced.db'])
    end

    it 'can depend on nodes in mounted components' do
      lib = new_component
      lib.declare('logger', String) { 'lib logger' }

      app = new_component
      app.mount('sourced', lib)
      app.declare('db', String)
      app.component!('db', ['sourced.logger']) { build { |logger| "db with #{logger}" } }
      app.build!

      expect(app['db']).to eq('db with lib logger')
    end

    it 'replaces previous implementations' do
      comp = new_component
      comp.declare('a', Integer) { 1 }
      comp.component!('a') { build { 2 } }
      comp.build!

      expect(comp['a']).to eq(2)
    end

    it 'can implement a namespace node' do
      comp = new_component
      comp.declare('ns.x', Integer) { 1 }
      comp.component!('ns', ['ns.x']) { build { |x| x + 1 } }
      comp.build!

      expect(comp['ns']).to eq(2)
      expect(comp.node('ns').namespace?).to be(false)
    end

    it 'raises for undeclared keys' do
      comp = new_component

      expect { comp.component!('nope') { build { 1 } } }.to raise_error(described_class::UndeclaredComponentError, /nope is not declared/)
    end

    it 'implements singletons with #component! and dynamic components with #component' do
      comp = new_component
      comp.declare('a')
      comp.declare('b')
      comp.component!('a') { build { 1 } }
      comp.component('b', ['a']) { build { |a| a + 1 } }

      expect(comp.node('a').implementation.mode).to eq(:singleton)
      expect(comp.node('b').implementation.mode).to eq(:dynamic)
      expect(comp.node('b').implementation.deps).to eq(['a'])
    end

    describe 'providers' do
      it 'builds components with callables, called with the deps values' do
        factory = Class.new { def self.call(url) = "DB(#{url})" }
        comp = new_component
        comp.declare('db.url', String) { 'sqlite://' }
        comp.declare('db', String)
        comp.declare('clock')
        comp.component!('db', ['db.url'], factory)
        comp.component!('clock', -> { Time }) # no deps
        comp.build!

        expect(comp['db']).to eq('DB(sqlite://)')
        expect(comp['clock']).to be(Time)
        expect(comp.node('db').implementation).to have_attributes(mode: :singleton, deps: ['db.url'], implementer: comp)
      end

      it 'builds dynamic components with callables' do
        counter = 0
        comp = new_component
        comp.declare('id', Integer)
        comp.component('id', -> { counter += 1 })
        comp.build!

        expect(comp.node('id').implementation.mode).to eq(:dynamic)
        expect([comp['id'], comp['id']]).to eq([1, 2])
      end

      it 'sets up providers with #builder_for(node)' do
        provider = Class.new do
          def self.builder_for(node) = ->(prefix) { "#{prefix} #{node.path} #{node.type.inspect}" }
        end
        comp = new_component
        comp.declare('prefix', String) { 'built' }
        comp.declare('a.b', String)
        comp.component!('a.b', ['prefix'], provider)
        comp.build!

        expect(comp['a.b']).to eq('built a.b String')
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
        comp = new_component
        comp.declare('db.url', String) { 'sqlite://' }
        comp.declare('db.pool', String)
        comp.component!('db.pool', ['db.url'], pool_provider)
        comp.start!(:ctx)
        comp.teardown!

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
        comp = new_component.declare('a', String)
        comp.component!('a', provider)
        comp.start!
        comp.teardown!

        expect(calls).to eq([[:teardown, 'value']])
      end

      it 'runs hooks for dynamic components, with a nil value' do
        calls = []
        provider = Object.new
        provider.define_singleton_method(:call) { 'fresh' }
        provider.define_singleton_method(:start) { |value, _context| calls << [:start, value] }
        comp = new_component.declare('a', String)
        comp.component('a', provider)
        comp.start!

        expect(calls).to eq([[:start, nil]])
        expect(comp['a']).to eq('fresh')
      end

      it 'raises if #builder_for returns something that is not callable' do
        provider = Class.new { def self.builder_for(_node) = Object.new }
        comp = new_component.declare('a')

        expect { comp.component!('a', provider) }.to raise_error(ArgumentError, /a: .+\.builder_for must return a callable/)
      end

      it 'accepts ENV providers' do
        previous = ENV['SYS_TEST_NAME']
        ENV['SYS_TEST_NAME'] = 'Joe'
        comp = new_component
        comp.declare('name', String)
        comp.declare('all', Plumb::Types::Hash[SYS_TEST_NAME: String])
        comp.component!('name', described_class::ENVProvider.new('SYS_TEST_NAME'))
        comp.component!('all', described_class::ENVProvider) # all variables
        comp.build!

        expect(comp['name']).to eq('Joe')
        expect(comp['all']).to eq(SYS_TEST_NAME: 'Joe')
      ensure
        previous.nil? ? ENV.delete('SYS_TEST_NAME') : ENV['SYS_TEST_NAME'] = previous
      end

      it 'checks ENV providers against the node type' do
        comp = new_component.declare('name', String)

        expect { comp.component!('name', described_class::ENVProvider.new(/^USER_/)) }.to raise_error(ArgumentError, /doesn't take one/)
        expect(comp.node('name').implementation).to be_nil
      end

      it 'parses provided values through the declared type' do
        comp = new_component.declare('n', Integer)
        comp.component!('n', -> { 'nope' })

        expect { comp.build! }.to raise_error(Plumb::ParseError, 'n: Must be a Integer')
      end

      it 'raises for providers that are not callable' do
        comp = new_component.declare('a')

        expect { comp.component!('a', Object.new) }.to raise_error(ArgumentError, /a: a provider must respond to #call or #builder_for/)
        expect { comp.component!('a', 'b') }.to raise_error(ArgumentError, /a provider must respond/)
      end

      it 'raises when given both a provider and a block, or deps that are not an array' do
        comp = new_component.declare('a')

        expect { comp.component!('a', -> { 1 }) { build { 2 } } }.to raise_error(ArgumentError, /either a provider or a block/)
        expect { comp.component!('a', ['b'], -> { 1 }) { build { 2 } } }.to raise_error(ArgumentError, /either a provider or a block/)
        expect { comp.component!('a', 'b', -> { 1 }) }.to raise_error(ArgumentError, /deps must be an Array/)
      end
    end

    it 'raises for unknown implementation modes' do
      expect {
        described_class::Implementation.new([], implementer: new_component, mode: :lazy, hooks: {})
      }.to raise_error(ArgumentError, /unknown mode/)
    end
  end

  describe '#config! and #config' do
    it 'implements singletons with only a build step' do
      builds = 0
      comp = new_component
      comp.declare('foo.bar', Integer)
      comp.config!('foo.bar') { builds += 1; 10 }
      comp.build!

      expect(comp.node('foo.bar').implementation.mode).to eq(:singleton)
      expect(comp['foo.bar']).to eq(10)
      expect(comp['foo.bar']).to eq(10)
      expect(builds).to eq(1)
    end

    it 'implements dynamic components with only a build step' do
      counter = 0
      comp = new_component
      comp.declare('counter', Integer)
      comp.config('counter') { counter += 1 }
      comp.build!

      expect(comp.node('counter').implementation.mode).to eq(:dynamic)
      expect(comp['counter']).to eq(1)
      expect(comp['counter']).to eq(2)
    end

    it 'passes dependency values to the block, relative to the implementing component' do
      lib = new_component
      lib.declare('db', String) { 'lib db' }
      app = new_component
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
      comp = new_component
      comp.declare('a', Integer)
      comp.config!('a') { 1 }
      comp.start!
      comp.teardown!

      expect(comp.node('a').status).to eq(:toredown)
      expect(comp['a']).to eq(1)
    end

    it 'parses values through the declared type' do
      comp = new_component
      comp.declare('a', Integer)
      comp.config!('a') { 'nope' }

      expect { comp.build! }.to raise_error(Plumb::ParseError, 'a: Must be a Integer')
    end

    it 'replaces previous implementations' do
      comp = new_component
      comp.declare('a', Integer) { 1 }
      comp.config!('a') { 2 }
      comp.build!

      expect(comp['a']).to eq(2)
    end

    it 'requires a block' do
      comp = new_component
      comp.declare('a')

      expect { comp.config!('a') }.to raise_error(ArgumentError, /needs a block/)
      expect { comp.config('a') }.to raise_error(ArgumentError, /needs a block/)
    end

    it 'raises for undeclared keys and locked components' do
      comp = new_component

      expect { comp.config!('nope') { 1 } }.to raise_error(described_class::UndeclaredComponentError)
      comp.declare('a') { 1 }
      comp.prepare!
      expect { comp.config('a') { 2 } }.to raise_error(described_class::LockedComponentError)
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

    def build(comp)
      comp.build!
      comp
    end

    def env_error = described_class::ENVProvider::Error

    describe 'single variables' do
      it 'decodes a variable into the declared type' do
        with_env('USER_EMAIL' => 'me@example.com', 'APP_PORT' => '3000') do
          comp = new_component.declare('user.email', Plumb::Types::Email).declare('app.port', Integer)
          expect(comp.env('USER_EMAIL' => 'user.email', 'APP_PORT' => 'app.port')).to be(comp)

          expect(build(comp)['user.email']).to eq('me@example.com')
          expect(comp['app.port']).to eq(3000)
        end
      end

      it 'names the variable when it is missing or invalid, without its value' do
        with_env('USER_EMAIL' => nil) do
          comp = new_component.declare('user.email', Plumb::Types::Email).env('USER_EMAIL' => 'user.email')
          expect { comp.build! }.to raise_error(env_error, 'invalid ENV for user.email: USER_EMAIL is missing')
        end

        with_env('USER_EMAIL' => 'secret-nope') do
          comp = new_component.declare('user.email', Plumb::Types::Email).env('USER_EMAIL' => 'user.email')
          expect { comp.build! }.to raise_error(Plumb::ParseError) { |e|
            expect(e).to be_a(env_error)
            expect(e.message).to start_with('invalid ENV for user.email: USER_EMAIL is invalid: Must match')
            expect(e.message).not_to include('secret-nope')
          }
        end
      end

      it 'allows missing variables for nullable types' do
        with_env('USER_EMAIL' => nil) do
          comp = new_component.declare('user.email', Plumb::Types::Email.nullable).env('USER_EMAIL' => 'user.email')
          expect(build(comp)['user.email']).to be_nil
        end
      end

      it "doesn't allow modifiers" do
        comp = new_component.declare('user.email')
        expect { comp.env(:downcase, 'USER_EMAIL' => 'user.email') }.to raise_error(ArgumentError, /only be used when collecting variables with a regex/)
        expect(comp.node('user.email').implementation).to be_nil
      end
    end

    describe 'collecting variables with a regex' do
      it 'collects matching variables into a hash, removing the match, and decodes it' do
        with_env('NAME' => 'root', 'USER_NAME' => 'Ismael', 'USER_DOB' => '1977-11-29') do
          comp = new_component.declare('user.info', Plumb::Types::Hash[NAME: String, DOB: Date])
          comp.env(/^USER_/ => 'user.info')

          expect(build(comp)['user.info']).to eq(NAME: 'Ismael', DOB: Date.new(1977, 11, 29))
        end
      end

      it 'decodes names into the keys the type expects: symbols for schemas and symbol maps, strings for string maps' do
        with_env('APP_HOST' => 'localhost', 'APP_PORT' => '3000') do
          comp = new_component
          comp.declare('strings', Plumb::Types::Hash[String, String])
          comp.declare('symbols', Plumb::Types::Hash[Symbol, String])
          comp.declare('schema', Plumb::Types::Hash['HOST' => String, 'PORT' => Integer])
          # separate calls: the same regex twice in one hash literal would be one key
          %w[strings symbols schema].each { |key| comp.env(/^APP_/ => key) }
          comp.build!

          expect(comp['strings']).to include('HOST' => 'localhost', 'PORT' => '3000')
          expect(comp['symbols']).to include(HOST: 'localhost', PORT: '3000')
          expect(comp['schema']).to eq('HOST' => 'localhost', 'PORT' => 3000)
        end
      end

      it 'applies modifiers to collected names' do
        with_env('USER_NAME' => 'Ismael', 'USER_DOB' => '1977-11-29') do
          comp = new_component.declare('user.info', user).env(:downcase, /^USER_/ => 'user.info')

          expect(build(comp)['user.info']).to be_a(user).and have_attributes(name: 'Ismael', dob: Date.new(1977, 11, 29))
        end
      end

      it 'names invalid variables, and missing attributes, hinting at modifiers' do
        with_env('USER_NAME' => 'Ismael', 'USER_DOB' => 'not-a-date', 'USER_EMAIL' => nil) do
          type = Plumb::Types::Data[name: String, dob: Date, email: String]
          comp = new_component.declare('user.info', type).env(:downcase, /^USER_/ => 'user.info')

          expect { comp.build! }.to raise_error(env_error, <<~MSG.chomp)
            invalid ENV for user.info:
              USER_DOB is invalid: Must match /\\A\\d{4}-\\d{2}-\\d{2}\\z/
              email is missing from ENV variables matching /^USER_/
          MSG
        end

        with_env('USER_NAME' => 'Ismael', 'USER_DOB' => '1977-11-29') do
          comp = new_component.declare('user.info', user).env(/^USER_/ => 'user.info')

          expect { comp.build! }.to raise_error(
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
          comp = new_component.declare('user.info', type)
          expect { comp.env(/^USER_/ => 'user.info') }.not_to raise_error, "expected #{type.inspect} to be accepted"
        end

        [Plumb::Types::String, Plumb::Types::Email, Integer, Plumb::Types::Array[String], Plumb::Types::String.nullable].each do |type|
          comp = new_component.declare('user.info', type)
          expect { comp.env(/^USER_/ => 'user.info') }.to raise_error(
            ArgumentError, /user.info: ENV variables matching \/\^USER_\/ are collected into a hash, but .+ doesn't take one/
          ), "expected #{type.inspect} to be rejected"
          expect(comp.node('user.info').implementation).to be_nil
        end
      end

      it 'checks types when collecting all variables, and with a provider directly' do
        comp = new_component.declare('user.email', String)

        expect { comp.env('user.email') }.to raise_error(ArgumentError, /doesn't take one/)
        expect { described_class::ENVProvider.new(/^USER_/).check!(comp.node('user.email')) }.to raise_error(ArgumentError, /doesn't take one/)
        expect { comp.env('USER_EMAIL' => 'user.email') }.not_to raise_error # single variables take any type
      end

      it 'supports optional attributes and defaults' do
        with_env('USER_NAME' => 'Ismael', 'USER_DOB' => nil) do
          optional = new_component.declare('user.info', Plumb::Types::Data[name: String, dob?: Date])
          optional.env(:downcase, /^USER_/ => 'user.info')
          defaulted = new_component.declare('user.info', Plumb::Types::Data[name: String, dob: Plumb::Types::Date.default(Date.new(2000, 1, 1).freeze)])
          defaulted.env(:downcase, /^USER_/ => 'user.info')

          expect(build(optional)['user.info']).to have_attributes(name: 'Ismael', dob: nil)
          expect(build(defaulted)['user.info'].dob).to eq(Date.new(2000, 1, 1))
        end
      end

      it 'rejects unknown modifiers' do
        expect { new_component.declare('a').env(:upcase, /^A_/ => 'a') }.to raise_error(ArgumentError, /unknown ENV modifiers: upcase/)
      end
    end

    describe 'collecting all variables' do
      it 'collects every variable when given only a component key' do
        with_env('NAME' => 'Ismael', 'DOB' => '1977-11-29') do
          comp = new_component.declare('user.info', Plumb::Types::Hash[NAME: String, DOB: Date]).env('user.info')

          expect(build(comp)['user.info']).to eq(NAME: 'Ismael', DOB: Date.new(1977, 11, 29))
        end
      end

      it 'applies modifiers' do
        with_env('NAME' => 'Ismael', 'DOB' => '1977-11-29') do
          comp = new_component.declare('user.info', user).env(:downcase, 'user.info')

          expect(build(comp)['user.info']).to have_attributes(name: 'Ismael', dob: Date.new(1977, 11, 29))
        end
      end

      it 'is what a provider with no source does' do
        expect(described_class::ENVProvider.new.source).to eq(described_class::ENVProvider::ALL)
      end
    end

    it 'reads raw strings into untyped (Any) components' do
      with_env('USER_EMAIL' => 'me@example.com', 'USER_NAME' => 'Ismael') do
        comp = new_component.declare('user.email').declare('user.info')
        comp.env('USER_EMAIL' => 'user.email', /^USER_/ => 'user.info')
        comp.build!

        expect(comp['user.email']).to eq('me@example.com')
        expect(comp['user.info']).to include('NAME' => 'Ismael', 'EMAIL' => 'me@example.com')
      end
    end

    it 'reads ENV when components are built, not when they are implemented' do
      comp = new_component.declare('user.email', String).env('USER_EMAIL' => 'user.email')

      with_env('USER_EMAIL' => 'later@example.com') do
        expect(build(comp)['user.email']).to eq('later@example.com')
      end
    end

    it 'implements singleton components, replacing previous implementations' do
      with_env('USER_EMAIL' => 'me@example.com') do
        comp = new_component.declare('user.email', String) { 'default' }
        comp.env('USER_EMAIL' => 'user.email')

        expect(comp.node('user.email').implementation).to have_attributes(mode: :singleton, implementer: comp, deps: [])
        expect(build(comp)['user.email']).to eq('me@example.com')
      end
    end

    it 'validates every source, key and type before implementing any' do
      comp = new_component.declare('a').declare('b', String)

      expect { comp.env('A' => 'a', 42 => 'b') }.to raise_error(ArgumentError, /must be a variable name or a regex/)
      expect { comp.env('A' => 'a', /^B_/ => 'b') }.to raise_error(ArgumentError, /doesn't take one/)
      expect { comp.env('A' => 'a', 'B' => 'nope') }.to raise_error(described_class::UndeclaredComponentError)
      expect { comp.env }.to raise_error(ArgumentError, /needs a component key/)
      expect(comp.node('a').implementation).to be_nil
    end

    it "can't implement components in a locked component" do
      comp = new_component.declare('a') { 1 }
      comp.prepare!

      expect { comp.env('A' => 'a') }.to raise_error(described_class::LockedComponentError)
    end

    it 'takes keys relative to the component' do
      with_env('DB_URL' => 'sqlite://') do
        comp = new_component.declare('sourced.db.url', String)
        comp.node('sourced').env('DB_URL' => 'db.url')

        expect(comp.node('sourced.db.url').implementation.implementer).to be(comp.node('sourced'))
        expect(build(comp)['sourced.db.url']).to eq('sqlite://')
      end
    end

    it 'names the full path of components in mounted components, even if implemented before mounting' do
      with_env('DB_PORT' => 'nope') do
        lib = new_component.declare('db.port', Integer).env('DB_PORT' => 'db.port')
        app = new_component
        app.mount('sourced', lib)

        expect { app.build! }.to raise_error(env_error, /\Ainvalid ENV for sourced\.db\.port: DB_PORT is invalid/)
      end
    end

    it 'lets an app implement components of a mounted component from ENV' do
      with_env('DB_PORT' => '5432') do
        lib = new_component.declare('db.port', Integer) { 3306 }
        app = new_component
        app.mount('sourced', lib)
        app.env('DB_PORT' => 'sourced.db.port')

        expect(build(app)['sourced.db.port']).to eq(5432)
        expect(lib['db.port']).to eq(5432)
      end
    end

    it 'shows sources and modifiers when inspecting' do
      expect(described_class::ENVProvider.new('USER_EMAIL').inspect).to eq('#<Sourced::Component::ENVProvider "USER_EMAIL">')
      expect(described_class::ENVProvider.new(/^USER_/, :downcase).inspect).to eq('#<Sourced::Component::ENVProvider /^USER_/ downcase>')
    end
  end

  describe '#inject' do
    def injectable_component
      new_component.tap do |s|
        s.declare('logger') { 'the logger' }
        s.declare('sourced.store') { 'the store' }
        counter = 0
        s.declare('counter', Integer)
        s.config('counter') { counter += 1 }
      end
    end

    it 'injects components as kwargs with readers, defaulting to component values' do
      comp = injectable_component
      comp.build!
      klass = Class.new { include comp.inject('logger') }

      expect(klass.new.logger).to eq('the logger')
      expect(klass.new(logger: 'custom').logger).to eq('custom')
      expect(klass.new(logger: nil).logger).to be_nil
    end

    it 'names kwargs after the last segment of dotted keys, and takes multiple keys' do
      comp = injectable_component
      comp.build!
      klass = Class.new { include comp.inject('logger', 'sourced.store') }
      obj = klass.new(store: 'custom store')

      expect(obj.logger).to eq('the logger')
      expect(obj.store).to eq('custom store')
    end

    it 'aliases keys to custom kwargs with a hash' do
      comp = injectable_component
      comp.build!
      klass = Class.new { include comp.inject('logger', 'sourced.store' => 'st') }

      expect(klass.new.st).to eq('the store')
      expect(klass.new(st: 'custom').st).to eq('custom')
      expect(klass.new).not_to respond_to(:store)
    end

    it "composes multiple injections with the class' own #initialize" do
      comp = injectable_component
      comp.build!
      klass = Class.new do
        include comp.inject('logger')
        include comp.inject('sourced.store')
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
      comp = injectable_component
      comp.build!
      parent = Class.new { include comp.inject('logger') }
      child = Class.new(parent) { include comp.inject('sourced.store') }
      obj = child.new(logger: 'custom')

      expect(obj.logger).to eq('custom')
      expect(obj.store).to eq('the store')
    end

    it 'reads values on instantiation, so classes can be defined before the component is built' do
      comp = injectable_component
      klass = Class.new { include comp.inject('counter') }
      expect { klass.new }.to raise_error(described_class::NotBuiltError)

      comp.build!
      expect(klass.new.counter).to eq(1)
      expect(klass.new.counter).to eq(2)
    end

    it 'injects by keys relative to the component' do
      comp = injectable_component
      comp.build!
      klass = Class.new { include comp.node('sourced').inject('store') }

      expect(klass.new.store).to eq('the store')
    end

    it "gives classes injecting from a library's component the overrides of the app that mounts it" do
      lib = new_component
      lib.declare('store', String) { 'lib store' }
      klass = Class.new { include lib.inject('store') } # defined before the library is mounted

      app = new_component
      app.mount('sourced', lib)
      app.config!('sourced.store') { 'app store' }

      expect { klass.new }.to raise_error(described_class::NotBuiltError)
      app.build!
      expect(klass.new.store).to eq('app store')
    end

    it 'describes the injection' do
      comp = injectable_component

      expect(comp.inject('logger', 'sourced.store' => 'st').inspect)
        .to eq('#<Sourced::Component::Injector logger => logger, sourced.store => st>')
    end

    it 'raises on undeclared components' do
      comp = injectable_component

      expect { comp.inject('nope') }.to raise_error(described_class::UndeclaredComponentError, /nope is not declared/)
    end

    it 'raises on duplicate names' do
      comp = injectable_component
      comp.declare('other.logger')
      expect { comp.inject('logger', 'other.logger') }.to raise_error(ArgumentError, /duplicate injected names: logger/)

      klass = Class.new { include comp.inject('logger') }
      expect { klass.include(comp.inject('other.logger')) }.to raise_error(ArgumentError, /already injects logger/)
    end
  end

  describe '#mount' do
    it 'attaches a standalone component as a branch, indexing its nodes' do
      lib = new_component
      lib.declare('db', String) { 'db' }
      app = new_component
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
      lib = new_component
      lib.declare('db', String) { 'db' }
      app = new_component
      app.mount('libs.sourced', lib)
      app.build!

      expect(app.node('libs').namespace?).to be(true)
      expect(app.node('libs').owner).to be(app)
      expect(app['libs.sourced.db']).to eq('db')
    end

    it 'mounts nested trees' do
      inner = new_component
      inner.declare('x', Integer) { 1 }
      middle = new_component
      middle.mount('inner', inner)
      app = new_component
      app.mount('middle', middle)
      app.build!

      expect(app.index.keys).to eq(%w[middle middle.inner middle.inner.x])
      expect(app['middle.inner.x']).to eq(1)
      expect(inner['x']).to eq(1)
      expect(inner.path).to eq('middle.inner')
    end

    it 'indexes nodes declared in mounted components after mounting, in every ancestor' do
      inner = new_component
      middle = new_component
      middle.mount('inner', inner)
      app = new_component
      app.mount('middle', middle)
      inner.declare('late', Integer) { 1 }

      expect(app.node('middle.inner.late')).to be(inner.node('late'))
      expect(middle.node('inner.late')).to be(inner.node('late'))
    end

    it 'mounts anything that implements #to_component' do
      lib_component = new_component.declare('db', String) { 'lib db' }
      lib = Module.new
      lib.define_singleton_method(:to_component) { lib_component }

      app = new_component
      expect(app.mount('sourced', lib)).to be(app)
      app.build!

      expect(app.node('sourced')).to be(lib_component)
      expect(app['sourced.db']).to eq('lib db')
    end

    it 'is implemented by components, returning themselves' do
      comp = new_component

      expect(comp.to_component).to be(comp)
    end

    it 'raises if not given something that implements #to_component' do
      expect { new_component.mount('x', Object.new) }.to raise_error(ArgumentError, /must respond to #to_component/)
    end

    it 'raises if #to_component does not return a Component' do
      fake = Object.new
      fake.define_singleton_method(:to_component) { Object.new }

      expect { new_component.mount('x', fake) }.to raise_error(ArgumentError, /to_component must return a Component/)
    end

    it 'applies the same checks to the returned component' do
      lib_component = new_component
      new_component.mount('a', lib_component)
      lib = Module.new
      lib.define_singleton_method(:to_component) { lib_component }

      expect { new_component.mount('b', lib) }.to raise_error(described_class::SubcomponentError, /already mounted/)
    end

    it 'raises if the component is already mounted' do
      lib = new_component
      new_component.mount('a', lib)

      expect { new_component.mount('b', lib) }.to raise_error(described_class::SubcomponentError, /already mounted/)
    end

    it 'raises when mounting a component into its own tree' do
      app = new_component
      lib = new_component
      app.mount('lib', lib)

      expect { app.mount('self', app) }.to raise_error(described_class::SubcomponentError, /own tree/)
      expect { lib.mount('up', app) }.to raise_error(described_class::SubcomponentError, /own tree/)
    end

    it 'raises if the key is taken' do
      app = new_component
      app.declare('a', String)

      expect { app.mount('a', new_component) }.to raise_error(described_class::DeclarationOverrideError, /a is already declared/)
    end

    it "raises if the key is under another component's nodes" do
      lib = new_component
      app = new_component
      app.mount('sourced', lib)

      expect { app.mount('sourced.other', new_component) }.to raise_error(described_class::OwnershipError)
    end

    it 'raises if the mounted component is locked' do
      lib = new_component
      lib.build!

      expect { new_component.mount('lib', lib) }.to raise_error(described_class::LockedComponentError, /must be open/)
    end
  end

  describe 'lifecycle' do
    it 'runs prepare, build, start and teardown hooks across the tree, in dependency order' do
      calls = []
      lib = new_component
      lib.declare('logger', String)
      lib.component!('logger') do
        prepare { calls << [:prepare, 'logger'] }
        build { calls << [:build, 'logger']; 'logger' }
        start { |value, context| calls << [:start, 'logger', value, context] }
        teardown { |value| calls << [:teardown, 'logger', value] }
      end

      app = new_component
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
      comp = new_component
      comp.declare('a.b', Integer) { 1 }
      node = comp.node('a.b')

      expect([comp.boot_status, node.status]).to eq(%i[open open])
      comp.prepare!
      expect([comp.boot_status, node.status]).to eq(%i[prepared prepared])
      comp.build!
      expect([comp.boot_status, node.status]).to eq(%i[built built])
      comp.start!
      expect([comp.boot_status, node.status]).to eq(%i[started started])
      comp.teardown!
      expect([comp.boot_status, node.status]).to eq(%i[toredown toredown])
      expect(comp.node('a').status).to eq(:open) # namespaces are skipped
    end

    it 'defaults the start context to the current thread' do
      context = nil
      comp = new_component
      comp.declare('a')
      comp.component!('a') { start { |_, ctx| context = ctx } }
      comp.start!

      expect(context).to be(Thread.current)
    end

    it 'is idempotent' do
      builds = 0
      comp = new_component
      comp.declare('a', Integer)
      comp.component!('a') { build { builds += 1 } }

      comp.start!
      comp.start!
      comp.build!
      comp.prepare!

      expect(builds).to eq(1)
    end

    it 'only tears down a started component' do
      torn = false
      comp = new_component
      comp.declare('a')
      comp.component!('a') { teardown { torn = true } }
      comp.build!
      comp.teardown!

      expect(torn).to be(false)
      expect(comp.boot_status).to eq(:built)
    end

    it 'exposes nodes in dependency order once prepared' do
      comp = new_component
      comp.declare('b', Integer)
      comp.declare('a', Integer) { 1 }
      comp.component!('b', ['a']) { build { |a| a + 1 } }

      expect { comp.ordered_nodes }.to raise_error(described_class::NotBuiltError)
      comp.prepare!
      expect(comp.ordered_nodes.map(&:path)).to eq(%w[a b])
    end

    it 'includes the root when it is implemented' do
      lib = new_component
      lib.declare('x', Integer) { 1 }
      app = new_component
      app.mount('lib', lib)
      app.component!('lib', ['lib.x']) { build { |x| x * 10 } }
      app.build!

      expect(app['lib']).to eq(10)
    end

    it 'parses built values through the declared type' do
      comp = new_component
      comp.declare('n', Integer) { 'nope' }

      expect { comp.build! }.to raise_error(Plumb::ParseError, 'n: Must be a Integer')
    end

    it 'names the full path of the component in type errors' do
      lib = new_component
      lib.declare('db.port', Integer) { 'nope' }
      app = new_component
      app.mount('libs.sourced', lib)

      expect { app.build! }.to raise_error(Plumb::ParseError, 'libs.sourced.db.port: Must be a Integer')
      expect(app.boot_status).to eq(:prepared)
    end

    it 'includes structured errors, without the value' do
      comp = new_component
      comp.declare('user', Plumb::Types::Hash[name: String, age: Integer]) { { name: 'Joe', age: 'secret' } }

      expect { comp.build! }.to raise_error(Plumb::ParseError) { |e|
        expect(e.message).to start_with('user: {')
        expect(e.message).to include('age')
        expect(e.message).not_to include('secret')
      }
    end

    it 'stores the parsed value' do
      comp = new_component
      comp.declare('port', Plumb::Types::Lax::Integer) { '3000' }
      comp.build!

      expect(comp['port']).to eq(3000)
    end

    it 'locks the tree once prepared' do
      lib = new_component
      app = new_component
      app.mount('lib', lib)
      app.prepare!

      expect { app.declare('a') }.to raise_error(described_class::LockedComponentError)
      expect { lib.declare('a') }.to raise_error(described_class::LockedComponentError)
      expect { app.component!('lib') { build { 1 } } }.to raise_error(described_class::LockedComponentError)
      expect { app.mount('other', new_component) }.to raise_error(described_class::LockedComponentError)
      expect(lib.locked?).to be(true)
    end

    it 'raises when booting a mounted component' do
      lib = new_component
      new_component.mount('lib', lib)

      %i[prepare! build! start! teardown! ordered_nodes].each do |method|
        expect { lib.public_send(method) }.to raise_error(described_class::SubcomponentError, /boot the root/)
      end
    end

    describe 'prepare! errors' do
      it 'raises for declared nodes without an implementation' do
        comp = new_component
        comp.declare('deep.thing', Integer)
        comp.declare('other', Integer)

        expect { comp.prepare! }.to raise_error(described_class::UnimplementedComponentError, /deep\.thing, other/)
      end

      it 'raises for missing deps, with full keys' do
        lib = new_component
        lib.declare('x', Integer)
        lib.component!('x', ['nope']) { build { 1 } }
        app = new_component
        app.mount('libs.lib', lib)

        expect { app.prepare! }.to raise_error(
          described_class::MissingDependencyError,
          'libs.lib.x depends on libs.lib.nope, which is not declared'
        )
      end

      it 'raises for deps on unimplemented namespaces' do
        comp = new_component
        comp.declare('ns.x', Integer) { 1 }
        comp.declare('a', Integer)
        comp.component!('a', ['ns']) { build { 1 } }

        expect { comp.prepare! }.to raise_error(described_class::MissingDependencyError, /a depends on ns, which is not implemented/)
      end

      it "can't reach outside the implementer's tree" do
        lib = new_component
        lib.declare('x', Integer)
        lib.component!('x', ['logger']) { build { 1 } }
        app = new_component
        app.declare('logger') { 'app logger' }
        app.mount('lib', lib)

        expect { app.prepare! }.to raise_error(described_class::MissingDependencyError, /lib\.x depends on lib\.logger/)
      end

      it 'raises for circular dependencies' do
        comp = new_component
        comp.declare('a', Integer)
        comp.declare('b', Integer)
        comp.component!('a', ['b']) { build { |b| b } }
        comp.component!('b', ['a']) { build { |a| a } }

        expect { comp.prepare! }.to raise_error(described_class::CircularDependencyError, /between a, b/)
      end

      it 'raises for self dependencies' do
        comp = new_component
        comp.declare('a', Integer)
        comp.component!('a', ['a']) { build { |a| a } }

        expect { comp.prepare! }.to raise_error(described_class::CircularDependencyError, /between a/)
      end

      it 'resolves deps declared after the component' do
        comp = new_component
        comp.declare('b', Integer)
        comp.component!('b', ['a']) { build { |a| a + 1 } }
        comp.declare('a', Integer) { 1 }
        comp.build!

        expect(comp['b']).to eq(2)
      end
    end

    describe 'start! failures' do
      it 'tears down started nodes, in reverse order, and re-raises' do
        calls = []
        comp = new_component
        comp.declare('a') { 1 }
        comp.declare('b') { 2 }
        comp.declare('c')
        comp.component!('a') { start { calls << :start_a }; teardown { calls << :teardown_a } }
        comp.component!('b', ['a']) { start { calls << :start_b }; teardown { calls << :teardown_b } }
        comp.component!('c', ['b']) { start { raise 'boom' }; teardown { calls << :teardown_c } }

        expect { comp.start! }.to raise_error(RuntimeError, 'boom')
        expect(calls).to eq(%i[start_a start_b teardown_b teardown_a])
        expect(comp.boot_status).to eq(:toredown)
        expect(comp.node('c').status).to eq(:built)
      end
    end

    describe 'teardown! failures' do
      it 'tears down every node, then re-raises the first error' do
        calls = []
        comp = new_component
        comp.declare('a') { 1 }
        comp.declare('b')
        comp.declare('c')
        comp.component!('a') { teardown { calls << :a } }
        comp.component!('b', ['a']) { teardown { calls << :b; raise 'b failed' } }
        comp.component!('c', ['b']) { teardown { calls << :c; raise 'c failed' } }
        comp.start!

        expect { comp.teardown! }.to raise_error(RuntimeError, 'c failed')
        expect(calls).to eq(%i[c b a])
        expect(comp.boot_status).to eq(:toredown)
      end
    end
  end

  describe 'reading values' do
    it 'raises until the component is built' do
      comp = new_component
      comp.declare('a') { 1 }

      expect { comp['a'] }.to raise_error(described_class::NotBuiltError)
      comp.prepare!
      expect { comp['a'] }.to raise_error(described_class::NotBuiltError)
      comp.build!
      expect(comp['a']).to eq(1)
    end

    it 'keeps values readable after teardown' do
      comp = new_component
      comp.declare('a') { 1 }
      comp.start!
      comp.teardown!

      expect(comp['a']).to eq(1)
    end

    it 'memoizes singletons' do
      comp = new_component
      comp.declare('a', String) { +'a' }
      comp.build!

      expect(comp['a']).to be(comp['a'])
    end

    it 'builds dynamic components on each read, with their deps' do
      counter = 0
      comp = new_component
      comp.declare('prefix', String) { 'req' }
      comp.declare('request_id', String)
      comp.component('request_id', ['prefix']) { build { |prefix| "#{prefix}-#{counter += 1}" } }
      comp.build!

      expect(comp['request_id']).to eq('req-1')
      expect(comp['request_id']).to eq('req-2')
    end

    it 'gives singletons that depend on dynamic components a value built once' do
      counter = 0
      comp = new_component
      comp.declare('id', Integer)
      comp.component('id') { build { counter += 1 } }
      comp.declare('first', Integer)
      comp.component!('first', ['id']) { build { |id| id } }
      comp.build!

      expect(comp['first']).to eq(1)
      expect(comp['first']).to eq(1)
      expect(comp['id']).to eq(2)
    end

    it 'parses dynamic values through the declared type' do
      comp = new_component
      comp.declare('n', Integer)
      comp.component('n') { build { 'nope' } }
      comp.build!

      expect { comp['n'] }.to raise_error(Plumb::ParseError, 'n: Must be a Integer')
    end

    it 'raises for undeclared keys and namespaces' do
      comp = new_component
      comp.declare('ns.x') { 1 }
      comp.build!

      expect { comp['nope'] }.to raise_error(described_class::UndeclaredComponentError, /nope is not declared/)
      expect { comp['ns'] }.to raise_error(described_class::UndeclaredComponentError, /ns is a namespace/)
    end

    it 'reads from mounted components through their own keys' do
      lib = new_component
      lib.declare('db', String) { 'lib db' }
      app = new_component
      app.mount('sourced', lib)
      app.build!

      expect(lib['db']).to eq('lib db')
      expect(lib.node('db')).to be(app.node('sourced.db'))
    end
  end

  describe '#graph' do
    it 'describes all declared components, their statuses, dependencies and types' do
      logger_type = Plumb::Types::Interface[:info]
      comp = new_component
      comp.declare('app')
      comp.declare('logger', logger_type)
      comp.declare('logger.output') { STDOUT }
      comp.declare('db', Plumb::Types::Interface[:append].nullable)
      comp.component!('app', %w[logger logger.output]) { start { |_v, _c| } }
      comp.config('logger', ['logger.output']) { |o| o }

      graph = comp.graph
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
      comp = new_component
      comp.declare('app')
      comp.declare('logger') { 'logger' }
      comp.config!('app', ['logger']) { |l| l }
      comp.start!

      graph = comp.graph
      expect(graph.status).to eq(:started)
      expect(graph.components.map { |c| [c[:key], c[:status]] }).to eq([['logger', :started], ['app', :started]])
    end

    it 'lists deps that are not declared, or are namespaces without an implementation, as missing' do
      comp = new_component
      comp.declare('ns.x') { 1 }
      comp.declare('app')
      comp.config!('app', %w[ns.x nope ns]) { 1 }

      expect(comp.graph.components.last).to include(key: 'app', deps: %w[ns.x nope ns], missing: %w[nope ns])
    end

    it 'leaves out namespaces, and includes namespaces with an implementation' do
      comp = new_component
      comp.declare('a.b.c') { 1 }
      comp.declare('x.y') { 1 }
      comp.config!('x') { 2 }

      expect(comp.graph.components.map { |c| c[:key] }).to eq(%w[a.b.c x x.y])
    end

    it 'includes providers' do
      provider = described_class::ENVProvider.new('A')
      comp = new_component
      comp.declare('a')
      comp.declare('b')
      comp.component!('a', provider)
      comp.env('B' => 'b')

      expect(comp.graph.components.map { |c| c[:provider] }).to match([provider, be_a(described_class::ENVProvider)])
    end

    it 'describes mounted components by full path, with deps relative to their implementers' do
      lib = new_component
      lib.declare('logger') { 'lib logger' }
      lib.declare('db')
      lib.config!('db', ['logger']) { |l| l }
      app = new_component
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

    it 'describes the components under a mounted component, with dependents only from its graph' do
      lib = new_component
      lib.declare('logger') { 'lib logger' }
      lib.declare('db')
      app = new_component
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
      comp = new_component
      comp.declare('email', described_class::T::Email)

      expect(comp.graph.components.first[:type_name]).to eq('Email')
    end
  end

  describe 'Graph#to_mermaid' do
    def classdefs = described_class::Graph::MERMAID_CLASSES.map { |name, style| "  classDef #{name} #{style}" }.join("\n")

    it 'draws components, dependency edges, modes and implementations' do
      comp = new_component
      comp.declare('output') { STDOUT }
      comp.declare('logger', Plumb::Types::Interface[:info])
      comp.declare('db', Plumb::Types::Interface[:exec].nullable)
      comp.declare('request_id', String)
      comp.declare('app')
      comp.config('logger', ['output']) { |o| o }
      comp.config('request_id') { 'x' }
      comp.config!('app', %w[logger db request_id nope]) { 1 }

      expect(comp.graph.to_mermaid).to eq(<<~MERMAID.chomp)
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
      comp = new_component
      comp.declare('app')
      comp.declare('logger') { 1 }
      comp.config!('app', ['logger']) { |l| l }
      comp.start!

      nodes = comp.graph.to_mermaid.lines.grep(/:::/).map(&:strip)
      expect(nodes).to eq([
        'c0["logger<br/>Any<br/><i>singleton, started</i>"]:::started',
        'c1["app<br/>Any<br/><i>singleton, started</i>"]:::started'
      ])
    end

    it 'draws deps outside the graph, ex. an app override in a library graph' do
      lib = new_component
      lib.declare('db')
      app = new_component
      app.declare('logger') { 1 }
      app.mount('sourced', lib)
      app.config!('sourced.db', ['logger']) { |l| l }

      expect(lib.graph.to_mermaid).to eq(<<~MERMAID.chomp)
        flowchart LR
          c0["sourced.db<br/>Any<br/><i>singleton, open</i>"]:::open
          c1["logger<br/><i>outside this component</i>"]:::external
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

  describe '#tree' do
    def app_with_library
      require 'logger'
      lib = new_component
      lib.declare('logger', Plumb::Types::Interface[:info]) { Logger.new(nil) }
      lib.declare('db', String)
      lib.config!('db', ['logger']) { 'lib db' }
      lib.declare('settings.retries', Integer) { 3 }

      app = new_component
      app.declare('logger') { 2 }
      app.mount('libs.sourced', lib)
      app.config!('libs.sourced.db', ['logger']) { 'app db' }
      app.declare('cache.redis', String) { 'redis://' }
      app.declare('cache.redis.pool', Integer)
      [app, lib]
    end

    it 'renders the tree of components, with mounted components and overrides' do
      app, = app_with_library

      expect(app.tree.to_s).to eq(<<~TREE.chomp)
        (root)
        ├── logger Any (singleton, open)
        ├── libs
        │   └── sourced [mounted]
        │       ├── logger Interface[info] (singleton, open)
        │       ├── db String (singleton, open) implemented by (root)
        │       └── settings
        │           └── retries Integer (singleton, open)
        └── cache
            └── redis String (singleton, open)
                └── pool Integer (not implemented, open)
      TREE
    end

    it 'shows statuses' do
      app, = app_with_library
      app.config!('cache.redis.pool') { 5 }
      app.start!

      expect(app.tree.status).to eq(:started)
      expect(app.tree.to_s).to include('pool Integer (singleton, started)')
    end

    it 'describes the nodes' do
      app, lib = app_with_library
      root = app.tree.root

      expect(root).to have_attributes(key: nil, path: nil, namespace: true, mounted: false, owner: nil)
      expect(root.children.map(&:key)).to eq(%w[logger libs cache])

      sourced = root.children[1].children.first
      expect(sourced).to have_attributes(key: 'sourced', path: 'libs.sourced', mounted: true, namespace: true, owner: 'libs.sourced')

      db = sourced.children[1]
      expect(db).to be_a(described_class::Tree::Node)
      expect(db).to have_attributes(
        key: 'db',
        path: 'libs.sourced.db',
        type: Plumb::Composable.wrap(String),
        type_name: 'String',
        namespace: false,
        mounted: false,
        implemented: true,
        mode: :singleton,
        status: :open,
        owner: 'libs.sourced',
        implementer: nil,
        children: []
      )
      expect(db).to be_overridden
      expect(sourced.children.first).not_to be_overridden # the library's own implementation
      expect(lib.node('db').path).to eq(db.path)
    end

    it 'converts to nested hashes' do
      app, = app_with_library
      hash = app.tree.to_h

      expect(hash[:status]).to eq(:open)
      expect(hash[:root][:children].map { |c| c[:key] }).to eq(%w[logger libs cache])
      expect(hash.dig(:root, :children, 2, :children, 0, :children, 0)).to include(key: 'pool', path: 'cache.redis.pool', implemented: false, children: [])
    end

    it 'renders the tree under a mounted component' do
      _app, lib = app_with_library

      expect(lib.tree.to_s).to eq(<<~TREE.chomp)
        libs.sourced [mounted]
        ├── logger Interface[info] (singleton, open)
        ├── db String (singleton, open) implemented by (root)
        └── settings
            └── retries Integer (singleton, open)
      TREE
    end

    it 'names implementers by path' do
      lib = new_component
      lib.declare('db') { 1 }
      app = new_component
      app.mount('libs.sourced', lib)
      app.node('libs').config!('sourced.db') { 2 }

      expect(app.tree.to_s).to include('db Any (singleton, open) implemented by libs')
    end

    it 'shows implemented namespaces as components with children' do
      comp = new_component
      comp.declare('db.url', String) { 'sqlite://' }
      comp.config!('db', ['db.url']) { |url| url }

      expect(comp.tree.to_s).to eq(<<~TREE.chomp)
        (root)
        └── db Any (singleton, open)
            └── url String (singleton, open)
      TREE
    end

    it 'renders an empty component' do
      expect(new_component.tree.to_s).to eq('(root)')
    end

    describe '#to_mermaid' do
      def classdefs = described_class::Tree::MERMAID_CLASSES.map { |name, style| "  classDef #{name} #{style}" }.join("\n")

      it 'draws a top-down tree, with roots, namespaces, components and overrides' do
        app, = app_with_library
        app.declare('request_id', String)
        app.config('request_id') { 'x' }

        expect(app.tree.to_mermaid).to eq(<<~MERMAID.chomp)
          flowchart TD
            n0{{"(root)"}}:::root
            n1["logger<br/>Any<br/><i>singleton, open</i>"]:::open
            n2("libs"):::namespace
            n3{{"sourced"}}:::root
            n4["logger<br/>Interface[info]<br/><i>singleton, open</i>"]:::open
            n5["db<br/>String<br/><i>singleton, open</i><br/><i>implemented by (root)</i>"]:::open
            n6("settings"):::namespace
            n7["retries<br/>Integer<br/><i>singleton, open</i>"]:::open
            n8("cache"):::namespace
            n9["redis<br/>String<br/><i>singleton, open</i>"]:::open
            n10["pool<br/>Integer<br/><i>not implemented</i>"]:::unimplemented
            n11(["request_id<br/>String<br/><i>dynamic, open</i>"]):::open
            n0 --> n1
            n0 --> n2
            n2 --> n3
            n3 --> n4
            n3 --> n5
            n3 --> n6
            n6 --> n7
            n0 --> n8
            n8 --> n9
            n9 --> n10
            n0 --> n11
          #{classdefs}
        MERMAID
      end

      it 'styles nodes by status' do
        comp = new_component
        comp.declare('a') { 1 }
        comp.start!

        expect(comp.tree.to_mermaid.lines[2].strip).to eq('n1["a<br/>Any<br/><i>singleton, started</i>"]:::started')
      end

      it 'draws the tree under a mounted component, from its full path' do
        _app, lib = app_with_library

        expect(lib.tree.to_mermaid.lines.first(3).map(&:strip)).to eq([
          'flowchart TD',
          'n0{{"libs.sourced"}}:::root',
          'n1["logger<br/>Interface[info]<br/><i>singleton, open</i>"]:::open'
        ])
      end

      it 'draws implemented components as hexagons, styled by status' do
        lib = new_component
        lib.declare('x') { 1 }
        app = new_component
        app.mount('lib', lib)
        app.config!('lib', ['lib.x']) { |x| x }

        expect(app.tree.to_mermaid.lines[2].strip).to eq('n1{{"lib<br/>Any<br/><i>singleton, open</i><br/><i>implemented by (root)</i>"}}:::open')
      end

      it 'escapes labels' do
        node = described_class::Tree::Node.new(
          key: 'a"b', path: 'a"b', type: nil, type_name: 'Hash<String> & more', namespace: false, mounted: false,
          implemented: false, mode: nil, status: :open, owner: nil, implementer: nil, children: []
        )
        tree = described_class::Tree.new(status: :open, root: node.with(key: nil, path: nil, namespace: true, children: [node]))

        expect(tree.to_mermaid.lines[2].strip).to eq(
          'n1["a#quot;b<br/>Hash#lt;String#gt; #amp; more<br/><i>not implemented</i>"]:::unimplemented'
        )
      end
    end
  end

  describe '#inspect' do
    it 'describes the node' do
      comp = new_component
      comp.declare('ns.a', Integer) { 1 }
      comp.declare('ns.b', String)
      comp.component('ns.b') { build { 'b' } }
      comp.declare('ns.c', String)

      expect(comp.inspect).to eq('#<Sourced::Component (root) (namespace)>')
      expect(comp.node('ns').inspect).to eq('#<Sourced::Component ns (namespace)>')
      expect(comp.node('ns.a').inspect).to eq('#<Sourced::Component ns.a Integer (singleton, open)>')
      expect(comp.node('ns.b').inspect).to eq('#<Sourced::Component ns.b String (dynamic, open)>')
      expect(comp.node('ns.c').inspect).to eq('#<Sourced::Component ns.c String (not implemented, open)>')
    end
  end

  describe 'lifecycle events' do
    def events_mod = described_class::Events

    def record(comp)
      [].tap do |events|
        comp.notifier.subscribe(described_class::Event) { |e| events << e }
      end
    end

    def summary(events)
      events.map { |e| (key = e.payload.to_h[:key]) ? "#{e.type} #{key}" : e.type }
    end

    it 'publishes events for every lifecycle step' do
      comp = new_component
      events = record(comp)
      comp.declare('output') { STDOUT }
      comp.declare('logger', String)
      comp.config!('logger', ['output']) { |o| o.class.name }
      comp.config!('logger', ['output']) { |_o| 'overridden' }
      comp.start!
      comp.teardown!

      expect(summary(events)).to eq([
        'components.declared output', 'components.implemented output',
        'components.declared logger', 'components.implemented logger', 'components.implemented logger',
        'root.preparing',
        'components.preparing output', 'components.prepared output',
        'components.preparing logger', 'components.prepared logger',
        'root.prepared',
        'root.building',
        'components.building output', 'components.built output',
        'components.building logger', 'components.built logger',
        'root.built',
        'root.starting',
        'components.starting output', 'components.started output',
        'components.starting logger', 'components.started logger',
        'root.started',
        'root.tearing_down',
        'components.tearing_down logger', 'components.toredown logger',
        'components.tearing_down output', 'components.toredown output',
        'root.toredown'
      ])
      expect(events).to all(be_valid)
      expect(events).to all(be_a(Sourced::Message))
      expect(events).to all(have_attributes(created_at: be_a(Time)))
    end

    it 'includes event details' do
      comp = new_component
      events = record(comp)
      comp.declare('output', Plumb::Types::Interface[:puts]) { STDOUT }
      comp.declare('logger')
      comp.config!('logger', ['output']) { 1 }
      comp.config('logger', ['output']) { 2 }
      comp.build!

      declared = events.find { |e| e.type == 'components.declared' }
      expect(declared).to be_a(events_mod::ComponentDeclared)
      expect(declared.payload).to have_attributes(key: 'output', type_name: 'Interface[puts]')

      implemented = events.select { |e| e.type == 'components.implemented' && e.payload.key == 'logger' }
      expect(implemented.map { |e| e.payload.to_h.slice(:mode, :deps, :implementer, :override) }).to eq([
        { mode: :singleton, deps: ['output'], implementer: nil, override: false },
        { mode: :dynamic, deps: ['output'], implementer: nil, override: true }
      ])

      completed = events.select { |e| e.payload.respond_to?(:duration) }
      expect(completed).not_to be_empty
      expect(completed.map { |e| e.payload.duration }).to all(be >= 0)
    end

    it 'names components by full path, and implementers by theirs' do
      lib = new_component
      lib.declare('logger')
      app = new_component
      events = record(app)
      app.mount('libs.sourced', lib)
      lib.declare('db') { 1 }
      app.node('libs').config!('sourced.logger') { 2 }

      expect(events.map { |e| e.payload.to_h.slice(:key, :implementer) }).to eq([
        { key: 'libs.sourced.db' },
        { key: 'libs.sourced.db', implementer: 'libs.sourced' },
        { key: 'libs.sourced.logger', implementer: 'libs' }
      ])
    end

    it "publishes mounted components' events to the root's notifier" do
      lib = new_component
      app = new_component
      app.mount('sourced', lib)

      expect(lib.notifier).to be(app.notifier)
      events = record(lib)
      lib.declare('db') { 1 }
      app.build!

      expect(summary(events)).to include('components.declared sourced.db', 'root.built')
    end

    it 'only publishes build events for singleton components' do
      comp = new_component
      events = record(comp)
      comp.declare('singleton') { 1 }
      comp.declare('dynamic')
      comp.config('dynamic') { 2 }
      comp.start!
      comp['dynamic']

      types = summary(events)
      expect(types).to include('components.built singleton', 'components.started dynamic', 'components.prepared dynamic')
      expect(types.grep(/build.* dynamic/)).to be_empty
    end

    it "doesn't publish events for steps that don't run" do
      comp = new_component
      comp.declare('a') { 1 }
      comp.start!
      events = record(comp)
      comp.prepare!
      comp.build!
      comp.start!

      expect(events).to be_empty
    end

    it 'publishes failures, including start rollbacks' do
      comp = new_component
      events = record(comp)
      comp.declare('a') { 1 }
      comp.declare('b')
      comp.component!('b', ['a']) { start { |_v, _c| raise ArgumentError, 'boom' } }

      expect { comp.start! }.to raise_error(ArgumentError)
      expect(summary(events).drop_while { |t| t != 'root.starting' }).to eq([
        'root.starting',
        'components.starting a', 'components.started a',
        'components.starting b', 'components.failed b',
        'components.tearing_down a', 'components.toredown a',
        'root.failed'
      ])

      component_failed, root_failed = events.select { |e| e.type.end_with?('failed') }
      expect(component_failed.payload).to have_attributes(key: 'b', stage: :start, error_class: 'ArgumentError', error_message: 'boom')
      expect(component_failed.payload.backtrace).to all(be_a(String))
      expect(component_failed.payload.backtrace).not_to be_empty
      expect(root_failed.payload).to have_attributes(stage: :start, error_class: 'ArgumentError')
    end

    it 'publishes teardown failures, and carries on tearing down' do
      comp = new_component
      comp.declare('a') { 1 }
      comp.declare('b')
      comp.component!('b', ['a']) { teardown { |_v| raise 'nope' } }
      comp.start!
      events = record(comp)

      expect { comp.teardown! }.to raise_error(RuntimeError, 'nope')
      expect(summary(events)).to eq([
        'root.tearing_down',
        'components.tearing_down b', 'components.failed b',
        'components.tearing_down a', 'components.toredown a',
        'root.failed'
      ])
      expect(events.last.payload.stage).to eq(:teardown)
    end

    it 'publishes component failures without a component' do
      comp = new_component
      events = record(comp)
      comp.declare('a')

      expect { comp.prepare! }.to raise_error(described_class::UnimplementedComponentError)
      expect(summary(events).last(2)).to eq(['root.preparing', 'root.failed'])
      expect(events.last.payload).to have_attributes(stage: :prepare, error_class: 'Sourced::Component::UnimplementedComponentError')
    end

    it 'publishes build failures, ex. type errors' do
      comp = new_component
      events = record(comp)
      comp.declare('n', Integer) { 'nope' }

      expect { comp.build! }.to raise_error(Plumb::ParseError)
      expect(events.last(2).map { |e| e.payload.to_h.slice(:key, :stage, :error_message) }).to eq([
        { key: 'n', stage: :build, error_message: 'n: Must be a Integer' },
        { stage: :build, error_message: 'n: Must be a Integer' }
      ])
    end

    describe 'runtime ids' do
      def runtime_of(event) = [event.payload.pid, event.payload.thread_id, event.payload.fiber_id]
      def here = [Process.pid, Thread.current.object_id, Fiber.current.object_id]

      # Run a block in a new thread and fiber, returning their runtime ids
      def in_thread_and_fiber
        ids = nil
        Thread.new do
          Fiber.new do
            ids = here
            yield
          end.resume
        end.join
        ids
      end

      it 'publishes every event with the process, thread and fiber it was published from' do
        comp = new_component
        events = record(comp)
        comp.declare('a') { 1 }
        comp.build!

        expect(events.map(&:type)).to include('components.declared', 'components.implemented', 'root.built')
        expect(events.map { |e| runtime_of(e) }.uniq).to eq([here])

        events.clear
        elsewhere = in_thread_and_fiber { comp.start! }

        expect(elsewhere).not_to eq(here)
        expect(events.map(&:type)).to include('root.starting', 'components.started', 'root.started')
        expect(events.map { |e| runtime_of(e) }.uniq).to eq([elsewhere])
      end
    end

    describe 'messages' do
      it 'subclasses Component::Event, which subclasses Sourced::Message' do
        expect(described_class::Event.superclass).to be(Sourced::Message)
        expect(events_mod::ComponentBuilt.ancestors).to include(events_mod::ComponentEvent, described_class::Event)
        expect(events_mod::RootBuilt.ancestors).to include(events_mod::RootEvent, described_class::Event)
      end

      it 'registers event types, visible from Component::Event and Sourced::Message' do
        expect(described_class::Event.registry['components.built']).to be(events_mod::ComponentBuilt)
        expect(Sourced::Message.registry['root.failed']).to be(events_mod::RootFailed)
        expect(described_class::Event.registry.all.to_a).to include(events_mod::ComponentDeclared, events_mod::RootPrepared)
      end

      it 'can be serialized and deserialized with the JSON codec' do
        require 'json'

        comp = new_component
        events = record(comp)
        comp.declare('a')
        comp.component!('a') { start { |_v, _c| raise 'boom' } }
        expect { comp.start! }.to raise_error(RuntimeError)

        codec = Sourced::Message::JSONCodec.new.compile!
        events.each do |event|
          decoded = codec.decode(JSON.parse(JSON.dump(codec.encode(event)), symbolize_names: true))
          expect(decoded).to be_a(event.class)
          expect(decoded.payload.to_h).to eq(event.payload.to_h)
        end
      end
    end

    describe described_class::Notifier do
      subject(:notifier) { described_class.new }

      def payload(**attrs) = { pid: 1, thread_id: 2, fiber_id: 3, duration: 0.1, **attrs }

      let(:built) { Sourced::Component::Events::ComponentBuilt.new(payload: payload(key: 'a')) }
      let(:started) { Sourced::Component::Events::ComponentStarted.new(payload: payload(key: 'a')) }
      let(:root_started) { Sourced::Component::Events::RootStarted.new(payload: payload) }

      it 'subscribes to event types, classes and their subclasses' do
        received = Hash.new { |h, k| h[k] = [] }
        notifier.subscribe('components.built') { |e| received[:type] << e }
        notifier.subscribe(:'components.built') { |e| received[:symbol] << e }
        notifier.subscribe(Sourced::Component::Events::ComponentStarted) { |e| received[:class] << e }
        notifier.subscribe(Sourced::Component::Events::ComponentEvent) { |e| received[:component] << e }
        notifier.subscribe(Sourced::Component::Event) { |e| received[:all] << e }

        [built, started, root_started].each { |e| notifier.publish(e) }

        expect(received).to eq(
          type: [built],
          symbol: [built],
          class: [started],
          component: [built, started],
          all: [built, started, root_started]
        )
      end

      it 'raises on unknown event types' do
        expect { notifier.subscribe('components.buitl') {} }.to raise_error(ArgumentError, /unknown event type/)
      end

      it 'requires a handler' do
        expect { notifier.subscribe('components.built') }.to raise_error(ArgumentError, /handler block is required/)
      end
    end

    it 'accepts a custom notifier' do
      notifier = Class.new do
        attr_reader :events
        def initialize = @events = []
        def publish(event) = @events << event
        def subscribe(*) = self
      end.new

      comp = described_class.new(notifier:)
      comp.declare('a') { 1 }
      comp.build!

      expect(comp.notifier).to be(notifier)
      expect(notifier.events.map(&:type)).to include('root.built', 'components.built')
    end

    it 'validates custom notifiers' do
      expect { described_class.new(notifier: Object.new) }.to raise_error(Plumb::ParseError)
    end
  end

  describe 'concurrency' do
    it 'boots once when started from multiple threads' do
      builds = 0
      comp = new_component
      comp.declare('a', Integer)
      comp.component!('a') do
        build do
          sleep 0.01
          builds += 1
        end
      end

      10.times.map { Thread.new { comp.start! } }.each(&:join)

      expect(builds).to eq(1)
      expect(comp.boot_status).to eq(:started)
    end
  end
end
