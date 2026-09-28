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
