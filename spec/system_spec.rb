require 'spec_helper'

RSpec.describe System do
  it 'builds a system of dependent components, with prepare, build, start and teardown lifecycle' do
    sys = System.new
    sys.declare('logger.output')
    sys.declare('logger', Plumb::Types::Interface[:info, :debug])
    sys.declare('db', Plumb::Types::Interface[:append].nullable)
    sys.declare('sourced.store')

    sys.config!('logger.output') { STDOUT }
    sys.config!('db') { nil }
    sys.config!('sourced.store') { nil }

    sys.component!('logger', ['logger.output']) do
      prepare do
        require 'logger'
      end

      build do |output|
        Logger.new(output)
      end
    end

    sys.prepare!
    expect(sys.status).to eq(:prepared)
    sys.build!
    expect(sys.status).to eq(:built)
    sys.start!
    expect(sys.status).to eq(:started)

    expect(sys['logger']).to be_a(Logger)
    expect(sys['logger']).to be(sys['logger'])
    expect(sys['logger.output']).to be(STDOUT)

    sys.teardown!
    expect(sys.status).to eq(:toredown)
  end

  it 'runs hooks in dependency order, and teardown in reverse' do
    calls = []
    sys = System.new
    %w[a b c].each { |k| sys.declare(k) }

    # registered out of order on purpose
    sys.component!('c', %w[b]) do
      prepare { calls << [:prepare, :c] }
      build { |b| calls << [:build, :c]; "c(#{b})" }
      start { |_value, ctx| calls << [:start, :c, ctx] }
      teardown { |_value| calls << [:teardown, :c] }
    end
    sys.component!('b', %w[a]) do
      prepare { calls << [:prepare, :b] }
      build { |a| calls << [:build, :b]; "b(#{a})" }
      start { |_value, ctx| calls << [:start, :b, ctx] }
      teardown { |_value| calls << [:teardown, :b] }
    end
    sys.config!('a') { calls << [:build, :a]; 'a' }

    sys.start!(:ctx)
    sys.teardown!

    expect(calls).to eq([
      [:prepare, :b], [:prepare, :c],
      [:build, :a], [:build, :b], [:build, :c],
      [:start, :b, :ctx], [:start, :c, :ctx],
      [:teardown, :c], [:teardown, :b]
    ])
    expect(sys['c']).to eq('c(b(a))')
  end

  it 'is idempotent' do
    count = 0
    sys = System.new
    sys.declare('a')
    sys.config!('a') { count += 1 }

    2.times { sys.prepare!; sys.build!; sys.start! }
    expect(count).to eq(1)
  end

  it 'updates component statuses even when they have no hooks' do
    sys = System.new
    sys.declare('empty')
    sys.component!('empty')
    component = sys.components['empty']

    expect(component.status).to eq(:open)
    sys.prepare!
    expect(component.status).to eq(:prepared)
    sys.build!
    expect(component.status).to eq(:built)
    expect(sys['empty']).to be_nil
    sys.start!
    expect(component.status).to eq(:started)
    sys.teardown!
    expect(component.status).to eq(:toredown)
  end

  it 'builds dynamic components on each access' do
    count = 0
    sys = System.new
    sys.declare('counter', Plumb::Types::Integer)
    sys.config('counter') { count += 1 }
    sys.build!

    expect(sys['counter']).to eq(1)
    expect(sys['counter']).to eq(2)
  end

  it 'validates built values against declared types' do
    sys = System.new
    sys.declare('db', Plumb::Types::Interface[:append])
    sys.config!('db') { 'not a db' }

    expect { sys.build! }.to raise_error(Plumb::ParseError)
  end

  it 'noops teardown if the system is not started' do
    sys = System.new
    sys.declare('a')
    sys.component!('a') { teardown { raise 'should not run' } }
    sys.build!

    expect { sys.teardown! }.not_to raise_error
    expect(sys.status).to eq(:built)
  end

  it 'passes the built value to start and teardown hooks' do
    calls = []
    sys = System.new
    sys.declare('a')
    sys.declare('b')
    sys.component!('a') do
      build { 'value' }
      start { |value, ctx| calls << [:start, value, ctx] }
      teardown { |value| calls << [:teardown, value] }
    end
    sys.component('b') do
      build { 'dynamic' }
      start { |value, ctx| calls << [:start_dynamic, value, ctx] }
    end
    sys.start!(:ctx)
    sys.teardown!

    expect(calls).to eq([[:start, 'value', :ctx], [:start_dynamic, nil, :ctx], [:teardown, 'value']])
  end

  it 'expresses optional components with nullable types' do
    sys = System.new
    sys.declare('cache', Plumb::Types::Interface[:get, :set].nullable)
    sys.config!('cache') { nil }
    sys.build!

    expect(sys['cache']).to be_nil
  end

  describe 'declaring defaults' do
    it 'registers the default block as a singleton component' do
      sys = System.new
      sys.declare('output', StringIO) { StringIO.new }
      sys.declare('cache', Plumb::Types::Interface[:get, :set].nullable) { nil }
      sys.start!

      expect(sys['output']).to be_a(StringIO)
      expect(sys['output']).to be(sys['output'])
      expect(sys['cache']).to be_nil
      expect(sys.components['output']).to be_singleton
    end

    it 'builds defaults lazily, and not at all if overridden' do
      calls = []
      sys = System.new
      sys.declare('a') { calls << :default_a; 'a' }
      sys.declare('b') { calls << :default_b; 'b' }
      sys.config!('b') { 'override' }

      expect(calls).to be_empty
      sys.build!
      expect(calls).to eq([:default_a])
      expect(sys['b']).to eq('override')
    end

    it 'validates the default against the type on build' do
      sys = System.new
      sys.declare('output', StringIO) { 'nope' }

      expect { sys.build! }.to raise_error(Plumb::ParseError)
    end

    it 'lets defaults be overridden with components with their own deps and lifecycle' do
      calls = []
      sys = System.new
      sys.declare('level', String) { 'info' }
      sys.declare('logger', Plumb::Types::String) { 'default logger' }

      sys.component!('logger', ['level']) do
        start { |_value, _ctx| calls << :started }
        build { |level| "logger at #{level}" }
      end
      sys.start!

      expect(sys['logger']).to eq('logger at info')
      expect(calls).to eq([:started])
    end

    it 'still validates overrides against the declared type' do
      sys = System.new
      sys.declare('logger', Plumb::Types::String) { 'default logger' }
      sys.config!('logger') { 123 }

      expect { sys.build! }.to raise_error(Plumb::ParseError)
    end
  end

  describe 'overriding components' do
    it 'replaces a previously registered component, including its deps and mode' do
      sys = System.new
      sys.declare('level')
      sys.declare('greeting', Plumb::Types::String)
      sys.config!('level') { 'debug' }

      # app default
      sys.config!('greeting') { 'hello' }
      # extension override, with new deps
      sys.component('greeting', ['level']) do
        build { |level| "hello at #{level}" }
      end
      sys.build!

      expect(sys.components['greeting']).to be_dynamic
      expect(sys['greeting']).to eq('hello at debug')
    end

    it 'validates overrides against the original declared type' do
      sys = System.new
      sys.declare('db', Plumb::Types::Interface[:append])
      sys.config!('db') { [] }
      sys.config!('db') { 'not a db' }

      expect { sys.build! }.to raise_error(Plumb::ParseError)
    end

    it "can't override components once the system is locked" do
      sys = System.new
      sys.declare('a')
      sys.config!('a') { 1 }
      sys.prepare!

      expect { sys.config!('a') { 2 } }.to raise_error(System::LockedSystemError)
    end
  end

  describe '#inspect' do
    it 'summarises components' do
      sys = System.new
      sys.declare('output') { STDOUT }
      sys.declare('logger')
      sys.component!('logger', ['output']) do
        prepare { }
        build { |o| o }
      end

      expect(sys.components['logger'].inspect).to eq(
        '#<System::Component logger (singleton, open) deps=[output] hooks=[prepare, build]>'
      )
    end

    it 'lists declarations in dependency order once prepared, with types and unregistered components' do
      sys = System.new
      sys.declare('logger', Plumb::Types::Interface[:info])
      sys.declare('output') { STDOUT }
      sys.declare('db', Plumb::Types::Interface[:append].nullable)
      sys.config('logger', ['output']) { |o| o }

      expect(sys.inspect).to eq(<<~TXT.chomp)
        #<System status=open components=2/3
          logger : Interface[info] (dynamic, open) deps=[output] hooks=[build]
          output : Any (singleton, open) hooks=[build]
          db : (Nil | Interface[append]) (not registered)
        >
      TXT

      sys.config!('db') { nil }
      sys.prepare!

      expect(sys.inspect).to eq(<<~TXT.chomp)
        #<System status=prepared components=3/3
          output : Any (singleton, prepared) hooks=[build]
          logger : Interface[info] (dynamic, prepared) deps=[output] hooks=[build]
          db : (Nil | Interface[append]) (singleton, prepared) hooks=[build]
        >
      TXT
    end

    it 'is compact for empty systems' do
      expect(System.new.inspect).to eq('#<System status=open components=0/0>')
    end
  end

  describe '#tree' do
    it 'describes all declared components, their statuses, dependencies and types' do
      logger_type = Plumb::Types::Interface[:info]
      sys = System.new
      sys.declare('app')
      sys.declare('logger', logger_type)
      sys.declare('logger.output') { STDOUT }
      sys.declare('db', Plumb::Types::Interface[:append].nullable)
      sys.component!('app', %w[logger logger.output]) { start { |_v, _c| } }
      sys.config('logger', ['logger.output']) { |o| o }

      tree = sys.tree
      expect(tree[:status]).to eq(:open)
      expect(tree[:components].map { |c| c[:key] }).to eq(%w[app logger logger.output db])

      expect(tree[:components][1]).to eq(
        key: 'logger',
        type: logger_type,
        type_name: 'Interface[info]',
        registered: true,
        mode: :dynamic,
        status: :open,
        deps: ['logger.output'],
        dependents: ['app'],
        hooks: [:build]
      )
      expect(tree[:components][2]).to include(deps: [], dependents: %w[app logger])
      expect(tree[:components][3]).to include(
        key: 'db',
        type_name: '(Nil | Interface[append])',
        registered: false,
        mode: nil,
        status: nil,
        deps: [],
        dependents: [],
        hooks: []
      )
    end

    it 'lists components in dependency order, with their statuses, once prepared' do
      sys = System.new
      sys.declare('app')
      sys.declare('logger') { 'logger' }
      sys.config!('app', ['logger']) { |l| l }
      sys.start!

      tree = sys.tree
      expect(tree[:status]).to eq(:started)
      expect(tree[:components].map { |c| [c[:key], c[:status]] }).to eq([['logger', :started], ['app', :started]])
    end
  end

  describe '#inject' do
    # a local, rather than let, so that Class.new blocks can see it
    def new_system
      System.new.tap do |s|
        s.declare('logger') { 'the logger' }
        s.declare('sourced.store') { 'the store' }
        s.declare('counter', Plumb::Types::Integer)
        s.config('counter') { @count = (@count || 0) + 1 }
      end
    end

    it 'injects components as kwargs with readers, defaulting to system values' do
      sys = new_system
      sys.build!
      klass = Class.new { include sys.inject('logger') }

      expect(klass.new.logger).to eq('the logger')
      expect(klass.new(logger: 'custom').logger).to eq('custom')
      expect(klass.new(logger: nil).logger).to be_nil
    end

    it 'names kwargs after the last segment of dotted keys, and takes multiple keys' do
      sys = new_system
      sys.build!
      klass = Class.new { include sys.inject('logger', 'sourced.store') }
      obj = klass.new(store: 'custom store')

      expect(obj.logger).to eq('the logger')
      expect(obj.store).to eq('custom store')
    end

    it 'aliases keys to custom kwargs with a hash' do
      sys = new_system
      sys.build!
      klass = Class.new { include sys.inject('logger', 'sourced.store' => 'st') }

      expect(klass.new.st).to eq('the store')
      expect(klass.new(st: 'custom').st).to eq('custom')
      expect(klass.new).not_to respond_to(:store)
    end

    it 'composes multiple injections with the class own #initialize' do
      sys = new_system
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
      sys = new_system
      sys.build!
      parent = Class.new { include sys.inject('logger') }
      child = Class.new(parent) { include sys.inject('sourced.store') }
      obj = child.new(logger: 'custom')

      expect(obj.logger).to eq('custom')
      expect(obj.store).to eq('the store')
    end

    it 'resolves values on instantiation, so classes can be defined before the system is built' do
      sys = new_system
      klass = Class.new { include sys.inject('counter') }
      expect { klass.new }.to raise_error(System::NotBuiltError)

      sys.build!
      expect(klass.new.counter).to eq(1)
      expect(klass.new.counter).to eq(2)
    end

    it 'raises on undeclared components' do
      sys = new_system
      expect { sys.inject('nope') }.to raise_error(System::UndeclaredComponentError)
    end

    it 'raises on duplicate names' do
      sys = new_system
      sys.declare('other.logger')
      expect { sys.inject('logger', 'other.logger') }.to raise_error(ArgumentError, /duplicate injected names: logger/)

      klass = Class.new { include sys.inject('logger') }
      expect { klass.include(sys.inject('other.logger')) }.to raise_error(ArgumentError, /already injects logger/)
    end
  end

  describe 'concurrency' do
    def counting_system(calls)
      System.new.tap do |sys|
        sys.declare('db')
        sys.component!('db') do
          build { calls << :build; sleep 0.01; Object.new }
          start { |_v, _c| calls << :start; sleep 0.01 }
        end
      end
    end

    it 'runs lifecycle hooks once when booted from multiple threads' do
      calls = Queue.new
      sys = counting_system(calls)
      values = 5.times.map { Thread.new { sys.start!; sys['db'] } }.map(&:value)

      expect(calls.size.times.map { calls.pop }).to eq(%i[build start])
      expect(values.uniq.size).to eq(1)
      expect(sys.status).to eq(:started)
    end

    it 'runs lifecycle hooks once when booted from multiple fibers' do
      require 'async'

      calls = []
      sys = counting_system(calls)
      values = Sync do |task|
        5.times.map { task.async { sys.start!; sys['db'] } }.map(&:wait)
      end

      expect(calls).to eq(%i[build start])
      expect(values.uniq.size).to eq(1)
    end

    it 'is reentrant, so hooks can call the system' do
      sys = System.new
      sys.declare('a')
      sys.component!('a') { start { |_v, _c| sys.build! } }

      expect { sys.start! }.not_to raise_error
      expect(sys.status).to eq(:started)
    end

    it "can't declare components once locked" do
      sys = System.new
      sys.prepare!

      expect { sys.declare('a') }.to raise_error(System::LockedSystemError)
    end
  end

  describe 'start! failures' do
    def failing_system(calls, teardown_error: nil)
      System.new.tap do |sys|
        %w[a b c d].each { |k| sys.declare(k) }
        sys.component!('a') do
          start { |_v, _c| calls << [:start, :a] }
          teardown { |_v| calls << [:teardown, :a] }
        end
        sys.component!('b', ['a']) do
          start { |_v, _c| calls << [:start, :b] }
          teardown { |_v| calls << [:teardown, :b]; raise teardown_error if teardown_error }
        end
        sys.component!('c', ['b']) do
          start { |_v, _c| calls << [:start, :c]; raise ArgumentError, 'boom' }
          teardown { |_v| calls << [:teardown, :c] }
        end
        sys.component!('d', ['c']) do
          start { |_v, _c| calls << [:start, :d] }
        end
      end
    end

    it 'tears down already started components in reverse order, and re-raises' do
      calls = []
      sys = failing_system(calls)

      expect { sys.start! }.to raise_error(ArgumentError, 'boom')
      expect(calls).to eq([[:start, :a], [:start, :b], [:start, :c], [:teardown, :b], [:teardown, :a]])
      expect(sys.status).to eq(:toredown)
      expect(sys.components.transform_values(&:status)).to eq(
        'a' => :toredown, 'b' => :toredown, 'c' => :built, 'd' => :built
      )
    end

    it 're-raises the original error even if teardown hooks fail' do
      calls = []
      sys = failing_system(calls, teardown_error: RuntimeError.new('teardown failed'))

      expect { sys.start! }.to raise_error(ArgumentError, 'boom')
      expect(calls.last).to eq([:teardown, :a])
    end

    it 'is a no-op if started again after failing' do
      calls = []
      sys = failing_system(calls)
      expect { sys.start! }.to raise_error(ArgumentError)

      expect { sys.start! }.not_to(change { calls.dup })
    end
  end

  it 'tears down all components even if some teardown hooks fail, then raises the first error' do
    calls = []
    sys = System.new
    %w[a b c].each { |k| sys.declare(k) }
    sys.component!('a') { teardown { |_v| calls << :a } }
    sys.component!('b', ['a']) { teardown { |_v| calls << :b; raise 'b failed' } }
    sys.component!('c', ['b']) { teardown { |_v| calls << :c; raise 'c failed' } }
    sys.start!

    expect { sys.teardown! }.to raise_error(RuntimeError, 'c failed')
    expect(calls).to eq(%i[c b a])
    expect(sys.status).to eq(:toredown)
  end

  describe 'errors' do
    it 'raises on undeclared components' do
      expect { System.new.config!('nope') { 1 } }.to raise_error(System::UndeclaredComponentError)
    end

    it 'raises on duplicate declarations' do
      sys = System.new
      sys.declare('a')
      expect { sys.declare(:a) }.to raise_error(System::DeclarationOverrideError)
    end

    it 'raises on declared components that are not registered' do
      sys = System.new
      sys.declare('a')
      sys.declare('b')
      sys.declare('c', Plumb::Types::String.nullable)
      sys.config!('b') { 1 }

      expect { sys.prepare! }.to raise_error(System::UnregisteredComponentError, /not registered: a, c$/)
      expect(sys.status).to eq(:open)
    end

    it 'raises on dependencies that are not declared' do
      sys = System.new
      sys.declare('a')
      sys.config!('a', ['b']) { 1 }

      expect { sys.prepare! }.to raise_error(System::MissingDependencyError, /a depends on unregistered components: b/)
    end

    it 'raises on circular dependencies' do
      sys = System.new
      sys.declare('a')
      sys.declare('b')
      sys.config!('a', ['b']) { 1 }
      sys.config!('b', ['a']) { 1 }

      expect { sys.prepare! }.to raise_error(System::CircularDependencyError)
    end

    it 'raises when adding components to a locked system' do
      sys = System.new
      sys.prepare!

      expect { sys.config!('a') { 1 } }.to raise_error(System::LockedSystemError)
    end

    it 'raises when accessing values before build' do
      sys = System.new
      sys.declare('a')
      sys.config!('a') { 1 }

      expect { sys['a'] }.to raise_error(System::NotBuiltError)
    end
  end
end
