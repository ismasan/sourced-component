# frozen_string_literal: true

require 'spec_helper'

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
      sys.component('db', ['db.url']) { build { |url| "DB(#{url})" } }
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
      app.component('sourced.db') { build { 'app db' } }
      app.build!

      expect(app['sourced.db']).to eq('app db')
    end
  end

  describe '#component' do
    it 'implements a declared node with deps and lifecycle hooks' do
      sys = new_system
      sys.declare('url', String) { 'sqlite://' }
      sys.declare('db', String)
      sys.component('db', ['url']) do
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
      sys.component('a') { |c| c.build { 1 } }
      sys.build!

      expect(sys['a']).to eq(1)
    end

    it 'accepts callables as hooks' do
      sys = new_system
      sys.declare('a', Integer)
      sys.component('a') { build(-> { 2 }) }
      sys.build!

      expect(sys['a']).to eq(2)
    end

    it 'resolves deps relative to the implementing system' do
      lib = new_system
      lib.declare('logger', String) { 'lib logger' }
      lib.declare('db', String)
      lib.component('db', ['logger']) { build { |logger| "db with #{logger}" } }

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
      lib.component('db', ['logger']) { build { |logger| "db with #{logger}" } }

      app = new_system
      app.declare('logger', String) { 'app logger' }
      app.mount('sourced', lib)
      app.component('sourced.db', ['logger']) { build { |logger| "app db with #{logger}" } }
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
      app.component('db', ['sourced.logger']) { build { |logger| "db with #{logger}" } }
      app.build!

      expect(app['db']).to eq('db with lib logger')
    end

    it 'replaces previous implementations' do
      sys = new_system
      sys.declare('a', Integer) { 1 }
      sys.component('a') { build { 2 } }
      sys.build!

      expect(sys['a']).to eq(2)
    end

    it 'can implement a namespace node' do
      sys = new_system
      sys.declare('ns.x', Integer) { 1 }
      sys.component('ns', ['ns.x']) { build { |x| x + 1 } }
      sys.build!

      expect(sys['ns']).to eq(2)
      expect(sys.node('ns').namespace?).to be(false)
    end

    it 'raises for undeclared keys' do
      sys = new_system

      expect { sys.component('nope') { build { 1 } } }.to raise_error(described_class::UndeclaredComponentError, /nope is not declared/)
    end

    it 'raises for unknown modes' do
      sys = new_system
      sys.declare('a')

      expect { sys.component('a', mode: :lazy) { build { 1 } } }.to raise_error(ArgumentError, /unknown mode/)
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
      lib.component('logger') do
        prepare { calls << [:prepare, 'logger'] }
        build { calls << [:build, 'logger']; 'logger' }
        start { |value, context| calls << [:start, 'logger', value, context] }
        teardown { |value| calls << [:teardown, 'logger', value] }
      end

      app = new_system
      app.declare('db', String)
      app.component('db', ['sourced.logger']) do
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
      sys.component('a') { start { |_, ctx| context = ctx } }
      sys.start!

      expect(context).to be(Thread.current)
    end

    it 'is idempotent' do
      builds = 0
      sys = new_system
      sys.declare('a', Integer)
      sys.component('a') { build { builds += 1 } }

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
      sys.component('a') { teardown { torn = true } }
      sys.build!
      sys.teardown!

      expect(torn).to be(false)
      expect(sys.boot_status).to eq(:built)
    end

    it 'exposes nodes in dependency order once prepared' do
      sys = new_system
      sys.declare('b', Integer)
      sys.declare('a', Integer) { 1 }
      sys.component('b', ['a']) { build { |a| a + 1 } }

      expect { sys.ordered_nodes }.to raise_error(described_class::NotBuiltError)
      sys.prepare!
      expect(sys.ordered_nodes.map(&:path)).to eq(%w[a b])
    end

    it 'includes the root when it is implemented' do
      lib = new_system
      lib.declare('x', Integer) { 1 }
      app = new_system
      app.mount('lib', lib)
      app.component('lib', ['lib.x']) { build { |x| x * 10 } }
      app.build!

      expect(app['lib']).to eq(10)
    end

    it 'parses built values through the declared type' do
      sys = new_system
      sys.declare('n', Integer) { 'nope' }

      expect { sys.build! }.to raise_error(Plumb::ParseError)
    end

    it 'locks the tree once prepared' do
      lib = new_system
      app = new_system
      app.mount('lib', lib)
      app.prepare!

      expect { app.declare('a') }.to raise_error(described_class::LockedSystemError)
      expect { lib.declare('a') }.to raise_error(described_class::LockedSystemError)
      expect { app.component('lib') { build { 1 } } }.to raise_error(described_class::LockedSystemError)
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
        lib.component('x', ['nope']) { build { 1 } }
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
        sys.component('a', ['ns']) { build { 1 } }

        expect { sys.prepare! }.to raise_error(described_class::MissingDependencyError, /a depends on ns, which is not implemented/)
      end

      it "can't reach outside the implementer's tree" do
        lib = new_system
        lib.declare('x', Integer)
        lib.component('x', ['logger']) { build { 1 } }
        app = new_system
        app.declare('logger') { 'app logger' }
        app.mount('lib', lib)

        expect { app.prepare! }.to raise_error(described_class::MissingDependencyError, /lib\.x depends on lib\.logger/)
      end

      it 'raises for circular dependencies' do
        sys = new_system
        sys.declare('a', Integer)
        sys.declare('b', Integer)
        sys.component('a', ['b']) { build { |b| b } }
        sys.component('b', ['a']) { build { |a| a } }

        expect { sys.prepare! }.to raise_error(described_class::CircularDependencyError, /between a, b/)
      end

      it 'raises for self dependencies' do
        sys = new_system
        sys.declare('a', Integer)
        sys.component('a', ['a']) { build { |a| a } }

        expect { sys.prepare! }.to raise_error(described_class::CircularDependencyError, /between a/)
      end

      it 'resolves deps declared after the component' do
        sys = new_system
        sys.declare('b', Integer)
        sys.component('b', ['a']) { build { |a| a + 1 } }
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
        sys.component('a') { start { calls << :start_a }; teardown { calls << :teardown_a } }
        sys.component('b', ['a']) { start { calls << :start_b }; teardown { calls << :teardown_b } }
        sys.component('c', ['b']) { start { raise 'boom' }; teardown { calls << :teardown_c } }

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
        sys.component('a') { teardown { calls << :a } }
        sys.component('b', ['a']) { teardown { calls << :b; raise 'b failed' } }
        sys.component('c', ['b']) { teardown { calls << :c; raise 'c failed' } }
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
      sys.component('request_id', ['prefix'], mode: :dynamic) { build { |prefix| "#{prefix}-#{counter += 1}" } }
      sys.build!

      expect(sys['request_id']).to eq('req-1')
      expect(sys['request_id']).to eq('req-2')
    end

    it 'gives singletons that depend on dynamic components a value built once' do
      counter = 0
      sys = new_system
      sys.declare('id', Integer)
      sys.component('id', mode: :dynamic) { build { counter += 1 } }
      sys.declare('first', Integer)
      sys.component('first', ['id']) { build { |id| id } }
      sys.build!

      expect(sys['first']).to eq(1)
      expect(sys['first']).to eq(1)
      expect(sys['id']).to eq(2)
    end

    it 'parses dynamic values through the declared type' do
      sys = new_system
      sys.declare('n', Integer)
      sys.component('n', mode: :dynamic) { build { 'nope' } }
      sys.build!

      expect { sys['n'] }.to raise_error(Plumb::ParseError)
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

  describe '#inspect' do
    it 'describes the node' do
      sys = new_system
      sys.declare('ns.a', Integer) { 1 }
      sys.declare('ns.b', String)
      sys.component('ns.b', mode: :dynamic) { build { 'b' } }
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
      sys.component('a') do
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
