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
        '#<System::Component logger (singleton, open) deps=[output]>'
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
          logger : Interface[info] (dynamic, open) deps=[output]
          output : Any (singleton, open)
          db : (Nil | Interface[append]) (not registered)
        >
      TXT

      sys.config!('db') { nil }
      sys.prepare!

      expect(sys.inspect).to eq(<<~TXT.chomp)
        #<System status=prepared components=3/3
          output : Any (singleton, prepared)
          logger : Interface[info] (dynamic, prepared) deps=[output]
          db : (Nil | Interface[append]) (singleton, prepared)
        >
      TXT
    end

    it 'is compact for empty systems' do
      expect(System.new.inspect).to eq('#<System status=open components=0/0>')
    end
  end

  describe '#graph' do
    it 'describes all declared components, their statuses, dependencies and types' do
      logger_type = Plumb::Types::Interface[:info]
      sys = System.new
      sys.declare('app')
      sys.declare('logger', logger_type)
      sys.declare('logger.output') { STDOUT }
      sys.declare('db', Plumb::Types::Interface[:append].nullable)
      sys.component!('app', %w[logger logger.output]) { start { |_v, _c| } }
      sys.config('logger', ['logger.output']) { |o| o }

      graph = sys.graph
      expect(graph).to be_a(System::Graph)
      expect(graph.status).to eq(:open)
      expect(graph.to_h).to eq(status: :open, components: graph.components)
      expect(graph.components.map { |c| c[:key] }).to eq(%w[app logger logger.output db])

      expect(graph.components[1]).to match(
        key: 'logger',
        type: logger_type,
        type_name: 'Interface[info]',
        registered: true,
        mode: :dynamic,
        status: :open,
        deps: ['logger.output'],
        dependents: ['app'],
        provider: be_a(System::BlockProvider),
        pid: nil,
        thread_id: nil,
        fiber_id: nil
      )
      expect(graph.components[2]).to include(deps: [], dependents: %w[app logger])
      expect(graph.components[3]).to include(
        key: 'db',
        type_name: '(Nil | Interface[append])',
        registered: false,
        mode: nil,
        status: nil,
        deps: [],
        dependents: [],
        provider: nil
      )
    end

    it 'lists components in dependency order, with their statuses, once prepared' do
      sys = System.new
      sys.declare('app')
      sys.declare('logger') { 'logger' }
      sys.config!('app', ['logger']) { |l| l }
      sys.start!

      graph = sys.graph
      expect(graph.status).to eq(:started)
      expect(graph.components.map { |c| [c[:key], c[:status]] }).to eq([['logger', :started], ['app', :started]])
    end
  end

  describe 'Graph#to_mermaid' do
    it 'draws components, dependency edges, modes and registration' do
      sys = System.new
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
          c2["db<br/>(Nil | Interface[exec])<br/><i>not registered</i>"]:::unregistered
          c3(["request_id<br/>String<br/><i>dynamic, open</i>"]):::open
          c4["app<br/>Any<br/><i>singleton, open</i>"]:::open
          c5["nope<br/><i>not declared</i>"]:::missing
          c0 --> c1
          c1 --> c4
          c2 --> c4
          c3 --> c4
          c5 --> c4
        #{System::Graph::MERMAID_CLASSES.map { |name, style| "  classDef #{name} #{style}" }.join("\n")}
      MERMAID
    end

    it 'styles nodes by status, in dependency order' do
      sys = System.new
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

    it 'escapes labels' do
      graph = System::Graph.new(status: :open, components: [
        { key: 'a"b', type_name: 'Hash<String> & more', registered: false, mode: nil, status: nil, deps: [] }
      ])

      expect(graph.to_mermaid.lines[1].strip).to eq(
        'c0["a#quot;b<br/>Hash#lt;String#gt; #amp; more<br/><i>not registered</i>"]:::unregistered'
      )
    end
  end

  describe 'component providers' do
    # A provider that is also its own builder, and records the declarations it's set up with
    let(:prefixer) do
      Class.new do
        attr_reader :declarations

        def initialize = @declarations = []
        def dependencies = ['prefix']

        def setup(declaration)
          @declarations << declaration
          self
        end

        def build(prefix) = "#{prefix}-value"
      end.new
    end

    # A provider that returns a separate builder, implementing every hook
    let(:full_provider) do
      builder_class = Class.new do
        attr_reader :calls

        def initialize = @calls = []
        def prepare = @calls << [:prepare]
        def build(dep) = (@calls << [:build, dep]) && "built(#{dep})"
        def start(value, context) = @calls << [:start, value, context]
        def teardown(value) = @calls << [:teardown, value]
      end

      Class.new do
        define_method(:dependencies) { ['dep'] }
        define_method(:setup) { |_declaration| builder_class.new }
      end.new
    end

    it 'sets up providers at registration, with the declaration, and builds with their dependencies' do
      sys = System.new
      sys.declare('prefix') { 'p' }
      sys.declare('thing', String)
      sys.component!('thing', prefixer)

      expect(prefixer.declarations.map { |d| [d.key, d.type] }).to eq([['thing', Plumb::Types::String]])
      expect(sys.components['thing'].deps).to eq(['prefix'])

      sys.build!
      expect(sys['thing']).to eq('p-value')
      expect(prefixer.declarations.size).to eq(1)
    end

    it 'type-checks provider values' do
      sys = System.new
      sys.declare('prefix') { 'p' }
      sys.declare('thing', Integer)
      sys.component!('thing', prefixer)

      expect { sys.build! }.to raise_error(Plumb::ParseError)
    end

    it 'calls every hook the builder implements, with their arguments' do
      sys = System.new
      sys.declare('dep') { 'd' }
      sys.declare('thing', String)
      sys.component!('thing', full_provider)
      sys.start!(:ctx)
      sys.teardown!

      expect(sys.components['thing'].builder.calls).to eq([
        [:prepare], [:build, 'd'], [:start, 'built(d)', :ctx], [:teardown, 'built(d)']
      ])
    end

    it 'completes builders with no-ops for missing hooks, without shadowing the hooks they implement' do
      torn_down = []
      builder = Object.new
      builder.define_singleton_method(:build) { 'value' }
      builder.define_singleton_method(:teardown) { |value| torn_down << value }
      provider = Struct.new(:builder) do
        def dependencies = []
        def setup(_declaration) = builder
        def inspect = '#<TestProvider>'
      end.new(builder)

      sys = System.new
      sys.declare('thing')
      sys.component!('thing', provider)
      component = sys.components['thing']

      expect(component.builder).to respond_to(:prepare, :start)
      expect(component.builder.__getobj__).to be(builder)
      expect(component.inspect).to eq('#<System::Component thing (singleton, open) provider=#<TestProvider>>')
      expect(sys.graph.components.first).to include(provider:)

      sys.start!
      sys.teardown!
      expect(torn_down).to eq(['value'])
    end

    it 'builds dynamic provider components on every read' do
      count = 0
      builder = Object.new
      builder.define_singleton_method(:build) { count += 1 }
      provider = Object.new
      provider.define_singleton_method(:dependencies) { [] }
      provider.define_singleton_method(:setup) { |_d| builder }

      sys = System.new
      sys.declare('counter', Integer)
      sys.component('counter', provider)
      sys.build!

      expect([sys['counter'], sys['counter']]).to eq([1, 2])
    end

    it 'sets up providers again when merged, with the receiving declaration' do
      other = System.new
      other.declare('prefix') { 'p' }
      other.declare('thing', String)
      other.component!('thing', prefixer)

      sys = System.new
      sys.declare('thing', String) { 'default' }
      sys.merge!(other)

      expect(prefixer.declarations.size).to eq(2)
      expect(prefixer.declarations.last).to be(sys.declarations['thing'])
      expect(values_of(sys, 'thing')).to eq(['p-value'])
    end

    it 'supports reusable, configurable providers' do
      env_var = Class.new do
        # name: the ENV variable. Defaults to the component key, ex. 'worker.interval' => WORKER_INTERVAL
        def initialize(name = nil, env: ENV)
          @name = name
          @env = env
        end

        def dependencies = []

        def setup(declaration)
          @name ||= declaration.key.upcase.tr('.', '_')
          self
        end

        def build = @env.fetch(@name) # coerced by the declared type
      end

      sys = System.new
      sys.declare('worker.interval', Plumb::Types::Lax::Integer)
      sys.declare('db.url', String)
      sys.component!('worker.interval', env_var.new(env: { 'WORKER_INTERVAL' => '30' }))
      sys.component!('db.url', env_var.new('DATABASE_URL', env: { 'DATABASE_URL' => 'postgres://db' }))

      expect(values_of(sys, 'worker.interval', 'db.url')).to eq([30, 'postgres://db'])
    end

    describe 'errors' do
      let(:sys) { System.new.declare('thing') }

      it 'raises on invalid providers and builders' do
        expect { sys.component!('thing', Object.new) }.to raise_error(Plumb::ParseError)

        no_build = Object.new
        no_build.define_singleton_method(:dependencies) { [] }
        no_build.define_singleton_method(:setup) { |_d| Object.new }
        expect { sys.component!('thing', no_build) }.to raise_error(Plumb::ParseError)
        expect(sys.components).to be_empty
      end

      it 'raises when given a provider and a block' do
        expect { sys.component!('thing', prefixer) { build { 1 } } }.to raise_error(ArgumentError, /not both/)
      end

      it 'raises on undeclared keys and locked systems, without setting up the provider' do
        expect { sys.component!('nope', prefixer) }.to raise_error(System::UndeclaredComponentError)
        sys.config!('thing') { 1 }
        sys.prepare!
        expect { sys.component!('thing', prefixer) }.to raise_error(System::LockedSystemError)
        expect(prefixer.declarations).to be_empty
      end
    end

    def values_of(sys, *keys)
      sys.build!
      keys.map { |k| sys[k] }
    end
  end

  describe '#merge!' do
    def values(sys, *keys)
      sys.build!
      keys.map { |k| sys[k] }
    end

    it 'declares and registers the other system components, as open copies' do
      calls = []
      other = System.new
      other.declare('output', String) { 'out' }
      other.declare('logger', String)
      other.component!('logger', ['output']) do
        build { |o| "logger(#{o})" }
        start { |v, _c| calls << [:start, v] }
      end
      other.start!

      sys = System.new
      sys.declare('app', String)
      sys.config!('app', ['logger']) { |l| "app(#{l})" }
      expect(sys.merge!(other)).to be(sys)

      expect(sys.declarations.keys).to eq(%w[app output logger])
      expect(sys.components.values.map(&:status)).to all(eq(:open))
      expect(sys.components['logger']).not_to be(other.components['logger'])
      expect(sys.components['logger']).to have_attributes(deps: ['output'], mode: :singleton, value: nil, pid: nil)
      expect(other.components['logger'].status).to eq(:started) # the other system is untouched

      sys.start!
      expect(sys['app']).to eq('app(logger(out))')
      expect(calls).to eq([[:start, 'logger(out)'], [:start, 'logger(out)']]) # once in each system
    end

    it "can't merge into a locked system" do
      sys = System.new
      sys.prepare!

      expect { sys.merge!(System.new) }.to raise_error(System::LockedSystemError)
    end

    it 'raises on conflicting types, before merging anything' do
      sys = System.new
      sys.declare('logger', String)
      other = System.new
      other.declare('new_one') { 1 }
      other.declare('logger', Integer)

      expect { sys.merge!(other) }.to raise_error(System::DeclarationConflictError, /logger is declared with different types/)
      expect(sys.declarations.keys).to eq(['logger'])
    end

    it 'accepts equivalent types' do
      sys = System.new
      sys.declare('db', Plumb::Types::Interface[:exec, :query])
      other = System.new
      other.declare('db', Plumb::Types::Interface[:query, :exec])

      expect { sys.merge!(other) }.not_to raise_error
    end

    describe 'defaults' do
      it "keeps the other's default when both have one" do
        sys = System.new.declare('a', String) { 'left' }
        sys.merge!(System.new.declare('a', String) { 'right' })

        expect(values(sys, 'a')).to eq(['right'])
      end

      it "uses the other's default when this one has none" do
        sys = System.new.declare('a', String)
        sys.merge!(System.new.declare('a', String) { 'right' })

        expect(values(sys, 'a')).to eq(['right'])
      end

      it "keeps this default when the other has none" do
        sys = System.new.declare('a', String) { 'left' }
        sys.merge!(System.new.declare('a', String))

        expect(values(sys, 'a')).to eq(['left'])
        expect(sys.declarations['a']).to be_default
      end

      it 'leaves the component unregistered when neither has a default' do
        sys = System.new.declare('a', String)
        sys.merge!(System.new.declare('a', String))

        expect(sys.components).not_to have_key('a')
      end
    end

    describe 'registered components' do
      it "replaces this system's components with the other's explicit ones" do
        sys = System.new.declare('a', String) { 'left default' }.declare('b', String)
        sys.config!('b') { 'left explicit' }
        other = System.new.declare('a', String).declare('b', String)
        other.config!('a') { 'right explicit a' }
        other.config!('b') { 'right explicit b' }
        sys.merge!(other)

        expect(values(sys, 'a', 'b')).to eq(['right explicit a', 'right explicit b'])
      end

      it "keeps this system's explicit components over the other's defaults" do
        sys = System.new.declare('a', String)
        sys.config!('a') { 'left explicit' }
        sys.merge!(System.new.declare('a', String) { 'right default' })

        expect(values(sys, 'a')).to eq(['left explicit'])
        expect(sys.declarations['a'].default.call).to eq('right default') # still the merged default
      end
    end

    it 'publishes declared events for new keys, and registered events for registrations' do
      sys = System.new.declare('a', String) { 'left' }.declare('b', String)
      sys.config!('b') { 'left' }
      events = []
      sys.notifier.subscribe(System::Events::ComponentEvent) { |e| events << "#{e.type} #{e.key}" }

      other = System.new.declare('a', String) { 'right' }.declare('b', String) { 'right' }.declare('c') { 1 }
      sys.merge!(other)

      expect(events).to eq(['components.registered a', 'components.declared c', 'components.registered c'])
    end

    it 'is a no-op when merging itself, and only merges systems' do
      sys = System.new.declare('a') { 1 }

      expect { sys.merge!(sys) }.not_to(change { sys.components['a'] })
      expect { sys.merge!(Object.new) }.to raise_error(ArgumentError, /not a System/)
    end
  end

  describe System::Declaration do
    it 'merges declarations of the same key, preferring the other default' do
      left = described_class.new('a', Plumb::Types::String, -> { 'left' })
      right = described_class.new('a', Plumb::Types::String, nil)

      expect(left.merge(right).default).to be(left.default)
      expect(right.merge(left).default).to be(left.default)
      expect(left.merge(right)).to be_frozen
      expect { left.merge(described_class.new('b', Plumb::Types::String, nil)) }.to raise_error(ArgumentError)
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

  describe 'lifecycle events' do
    def record(sys)
      [].tap do |events|
        sys.notifier.subscribe(System::Events::Event) { |e| events << e }
      end
    end

    def summary(events)
      events.map { |e| e.respond_to?(:key) ? "#{e.type} #{e.key}" : e.type }
    end

    it 'publishes events for every lifecycle step' do
      sys = System.new
      events = record(sys)
      sys.declare('output') { STDOUT }
      sys.declare('logger', String)
      sys.config!('logger', ['output']) { |o| o.class.name }
      sys.config!('logger', ['output']) { |_o| 'overridden' }
      sys.start!
      sys.teardown!

      expect(summary(events)).to eq([
        'components.declared output', 'components.registered output',
        'components.declared logger', 'components.registered logger', 'components.registered logger',
        'system.preparing',
        'components.preparing output', 'components.prepared output',
        'components.preparing logger', 'components.prepared logger',
        'system.prepared',
        'system.building',
        'components.building output', 'components.built output',
        'components.building logger', 'components.built logger',
        'system.built',
        'system.starting',
        'components.starting output', 'components.started output',
        'components.starting logger', 'components.started logger',
        'system.started',
        'system.tearing_down',
        'components.tearing_down logger', 'components.toredown logger',
        'components.tearing_down output', 'components.toredown output',
        'system.toredown'
      ])
      expect(events).to all(be_valid)
      expect(events).to all(have_attributes(timestamp: be_a(Time)))
    end

    it 'includes event details' do
      sys = System.new
      events = record(sys)
      sys.declare('output', Plumb::Types::Interface[:puts]) { STDOUT }
      sys.declare('logger')
      sys.config!('logger', ['output']) { 1 }
      sys.config('logger', ['output']) { 2 }
      sys.build!

      declared = events.find { |e| e.type == 'components.declared' }
      expect(declared).to have_attributes(key: 'output', type_name: 'Interface[puts]')

      registered = events.select { |e| e.type == 'components.registered' && e.key == 'logger' }
      expect(registered.map { |e| [e.mode, e.deps, e.override] }).to eq([
        [:singleton, ['output'], false],
        [:dynamic, ['output'], true]
      ])

      completed = events.select { |e| e.type.end_with?('ed') && e.respond_to?(:duration) }
      expect(completed).not_to be_empty
      expect(completed.map(&:duration)).to all(be >= 0)
    end

    it 'only publishes build events for singleton components' do
      sys = System.new
      events = record(sys)
      sys.declare('singleton') { 1 }
      sys.declare('dynamic')
      sys.config('dynamic') { 2 }
      sys.start!
      sys['dynamic']

      types = summary(events)
      expect(types).to include('components.built singleton', 'components.started dynamic', 'components.prepared dynamic')
      expect(types.grep(/build.* dynamic/)).to be_empty
    end

    it "doesn't publish events for steps that don't run" do
      sys = System.new
      sys.declare('a') { 1 }
      sys.start!
      events = record(sys)
      sys.prepare!
      sys.build!
      sys.start!

      expect(events).to be_empty
    end

    it 'publishes failures, including start rollbacks' do
      sys = System.new
      events = record(sys)
      sys.declare('a') { 1 }
      sys.declare('b')
      sys.component!('b', ['a']) { start { |_v, _c| raise ArgumentError, 'boom' } }

      expect { sys.start! }.to raise_error(ArgumentError)
      expect(summary(events).drop_while { |t| t != 'system.starting' }).to eq([
        'system.starting',
        'components.starting a', 'components.started a',
        'components.starting b', 'components.failed b',
        'components.tearing_down a', 'components.toredown a',
        'system.failed'
      ])

      component_failed, system_failed = events.select { |e| e.type.end_with?('failed') }
      expect(component_failed).to have_attributes(key: 'b', stage: :start, error: be_a(ArgumentError))
      expect(system_failed).to have_attributes(stage: :start, error: be_a(ArgumentError))
    end

    it 'publishes teardown failures, and carries on tearing down' do
      sys = System.new
      sys.declare('a') { 1 }
      sys.declare('b')
      sys.component!('b', ['a']) { teardown { |_v| raise 'nope' } }
      sys.start!
      events = record(sys)

      expect { sys.teardown! }.to raise_error(RuntimeError, 'nope')
      expect(summary(events)).to eq([
        'system.tearing_down',
        'components.tearing_down b', 'components.failed b',
        'components.tearing_down a', 'components.toredown a',
        'system.failed'
      ])
      expect(events.last).to have_attributes(stage: :teardown)
    end

    it 'publishes system failures without a component' do
      sys = System.new
      events = record(sys)
      sys.declare('a')

      expect { sys.prepare! }.to raise_error(System::UnregisteredComponentError)
      expect(summary(events).last(2)).to eq(['system.preparing', 'system.failed'])
      expect(events.last).to have_attributes(stage: :prepare, error: be_a(System::UnregisteredComponentError))
    end

    describe 'runtime ids' do
      def runtime_of(event) = [event.pid, event.thread_id, event.fiber_id]
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
        sys = System.new
        events = record(sys)
        sys.declare('a') { 1 }
        sys.build!

        expect(events.map(&:type)).to include('components.declared', 'components.registered', 'system.built')
        expect(events.map { |e| runtime_of(e) }.uniq).to eq([here])

        events.clear
        elsewhere = in_thread_and_fiber { sys.start! }

        expect(elsewhere).not_to eq(here)
        expect(events.map(&:type)).to include('system.starting', 'components.started', 'system.started')
        expect(events.map { |e| runtime_of(e) }.uniq).to eq([elsewhere])
      end

      it 'stamps components with the process, thread and fiber they were started in' do
        sys = System.new
        sys.declare('a') { 1 }
        expect(sys.components['a'].runtime).to eq(pid: nil, thread_id: nil, fiber_id: nil)

        pid, thread_id, fiber_id = in_thread_and_fiber { sys.start! }

        expect(sys.components['a'].runtime).to eq(pid:, thread_id:, fiber_id:)
        expect(sys.graph.components.first).to include(pid:, thread_id:, fiber_id:)
      end

      it 'publishes teardown events from where teardown runs, while the component keeps its start stamp' do
        sys = System.new
        sys.declare('a') { 1 }
        sys.component!('a') { teardown { |_v| } }
        started_in = in_thread_and_fiber { sys.start! }
        events = record(sys)
        sys.teardown!

        expect(events.map(&:type)).to eq(%w[system.tearing_down components.tearing_down components.toredown system.toredown])
        expect(events.map { |e| runtime_of(e) }.uniq).to eq([here])
        expect(runtime_of(sys.components['a'])).to eq(started_in)
      end

      it 'includes runtime ids in failures' do
        sys = System.new
        events = record(sys)
        sys.declare('a')
        sys.component!('a') { start { |_v, _c| raise 'nope' } }

        expect { sys.start! }.to raise_error(RuntimeError)
        failures = events.select { |e| e.type.end_with?('failed') }
        expect(failures.map(&:type)).to eq(%w[components.failed system.failed])
        expect(failures.map { |e| runtime_of(e) }).to all(eq(here))
      end

      it 'uses the pid of a forked process' do
        skip 'fork not supported' unless Process.respond_to?(:fork)

        sys = System.new
        sys.declare('a') { 1 }
        sys.build! # built in the parent, started in the child

        reader, writer = IO.pipe
        child = fork do
          reader.close
          events = record(sys)
          sys.start!
          writer.write(Marshal.dump([Process.pid, sys.components['a'].pid, events.map(&:pid).uniq]))
          writer.close
          exit!(0)
        end
        writer.close
        child_pid, stamped_pid, event_pids = Marshal.load(reader.read)
        Process.wait(child)

        expect(child_pid).not_to eq(Process.pid)
        expect(stamped_pid).to eq(child_pid)
        expect(event_pids).to eq([child_pid])
        expect(sys.components['a'].pid).to be_nil # the parent's copy was never started
      end
    end

    describe System::Notifier do
      subject(:notifier) { System::Notifier.new }

      let(:common) { { timestamp: Time.now, pid: 1, thread_id: 2, fiber_id: 3, duration: 0.1 } }
      let(:built) { System::Events::ComponentBuilt.new(key: 'a', **common) }
      let(:started) { System::Events::ComponentStarted.new(key: 'a', **common) }
      let(:system_started) { System::Events::SystemStarted.new(**common) }

      it 'subscribes to event types, classes and their subclasses' do
        received = Hash.new { |h, k| h[k] = [] }
        notifier.subscribe('components.built') { |e| received[:type] << e }
        notifier.subscribe(:'components.built') { |e| received[:symbol] << e }
        notifier.subscribe(System::Events::ComponentStarted) { |e| received[:class] << e }
        notifier.subscribe(System::Events::ComponentEvent) { |e| received[:component] << e }
        notifier.subscribe(System::Events::Event) { |e| received[:all] << e }

        [built, started, system_started].each { |e| notifier.publish(e) }

        expect(received).to eq(
          type: [built],
          symbol: [built],
          class: [started],
          component: [built, started],
          all: [built, started, system_started]
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

      sys = System.new(notifier:)
      sys.declare('a') { 1 }
      sys.build!

      expect(sys.notifier).to be(notifier)
      expect(notifier.events.map(&:type)).to include('system.built', 'components.built')
    end

    it 'validates custom notifiers' do
      expect { System.new(notifier: Object.new) }.to raise_error(Plumb::ParseError)
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
