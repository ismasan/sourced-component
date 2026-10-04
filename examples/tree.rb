# frozen_string_literal: true

# Run with: bundle exec ruby examples/tree.rb (Ctrl-C to stop), or RUN_FOR=2 bundle exec ruby examples/tree.rb

require 'bundler/setup'
require 'sourced/system'
require 'logger'

T = Sourced::System::T

class FakeDB
  attr_reader :name, :logger

  def initialize(name, logger:)
    @name = name
    @logger = logger
  end

  def connect = logger.info("#{name}: connect")
  def disconnect = logger.info("#{name}: disconnect")
  def insert(job) = logger.info("#{name}: insert #{job}")
end

# A long-running component: processes jobs in a background thread.
# Start hooks run while holding the system lock, so #start spawns the thread and returns.
class Worker
  def initialize(db, logger:)
    @db = db
    @logger = logger
    @queue = Queue.new
    @thread = nil
  end

  def <<(job)
    @queue << job
    self
  end

  def start
    @thread = Thread.new do
      while (job = @queue.pop) != :stop
        @db.insert(job)
      end
    end
    @logger.info('worker: started')
  end

  # Process what's queued, then stop
  def stop
    return unless @thread

    @queue << :stop
    @thread.join
    @logger.info('worker: stopped')
  end
end

# Another long-running component: pushes a job to the worker on an interval
class Ticker
  def initialize(worker, interval:, logger:, &job)
    @worker = worker
    @interval = interval
    @logger = logger
    @job = job
    @thread = nil
  end

  def start
    @thread = Thread.new do
      loop do
        sleep @interval
        @worker << @job.call
      end
    end
    @logger.info("ticker: every #{@interval}s")
  end

  def stop
    @thread&.kill&.join
    @logger.info('ticker: stopped')
  end
end

# ---- A library, with its own system ----------------------------------------------

Library = Sourced::System.new
Library.declare('logger', T::Interface[:info]) { Logger.new($stdout, progname: 'sourced') }
Library.declare('db', FakeDB)
Library.component!('db', ['logger']) do
  build { |logger| FakeDB.new('sourced-db', logger:) }
  start { |db, _| db.connect }
  teardown { |db| db.disconnect }
end

# ---- An app, mounting it -----------------------------------------------------------

App = Sourced::System.new
App.declare('logger', T::Interface[:info]) { Logger.new($stdout, progname: 'app') }
App.mount('sourced', Library)

# Re-implement the library's db, with the app's own logger. Deps are relative to App
App.component!('sourced.db', ['logger']) do
  build { |logger| FakeDB.new('app-db', logger:) }
  start { |db, _| db.connect }
  teardown { |db| db.disconnect }
end

# Nested declarations: App owns 'cache' and 'cache.redis', so it can keep declaring under them
App.declare('cache.redis', String)
App.declare('cache.redis.pool', Integer)

# Configs: components with only a build step. config! is a singleton
App.config!('cache.redis') { 'redis://localhost' }
App.config!('cache.redis.pool', ['sourced.settings.retries']) { |retries| retries + 2 }

# A dynamic config, built on each read
counter = 0
App.declare('request_id', String)
App.config('request_id') { "req-#{counter += 1}" }

# The library can still declare more after being mounted; App's index picks them up
Library.declare('settings.retries', Integer) { 3 }

# The library's classes inject from the library's own system.
# Defined before the system is built: values are read on instantiation
class Dispatcher
  include Library.inject('db', 'settings.retries')

  def dispatch(event) = db.insert(event)
end

# Long-running components. The ticker depends on the worker, so it starts after it and is torn down before it
App.declare('worker', Worker)
App.component!('worker', ['sourced.db', 'logger']) do
  build { |db, logger| Worker.new(db, logger:) }
  start { |worker, _| worker.start }
  teardown { |worker| worker.stop }
end

App.declare('ticker', Ticker)
App.component!('ticker', ['worker', 'logger']) do
  # Read the dynamic request_id on each tick: a fresh value every time
  build { |worker, logger| Ticker.new(worker, interval: 0.5, logger:) { "job #{App['request_id']}" } }
  start { |ticker, _| ticker.start }
  teardown { |ticker| ticker.stop }
end

puts '== Ownership'
begin
  App.declare('sourced.extra', String)
rescue Sourced::System::OwnershipError => e
  puts "App.declare('sourced.extra') => #{e.class}: #{e.message}"
end

puts "\n== Index"
puts App.index.keys.join(', ')

puts "\n== Boot"
begin
  Library.start!
rescue Sourced::System::SubsystemError => e
  puts "Library.start! => #{e.class}: #{e.message}"
end
App.start!
puts App.ordered_nodes.map(&:inspect)

puts "\n== Read"
puts "App['sourced.db'].name      => #{App['sourced.db'].name}"
puts "Library['db'].name          => #{Library['db'].name} (the app's override, seen by the library)"
puts "same object                 => #{App['sourced.db'].equal?(Library['db'])}"
puts "Library['db'].logger        => #{Library['db'].logger.progname}"
puts "Dispatcher.new.db.name      => #{Dispatcher.new.db.name} (injected from the library's system)"
puts "Dispatcher.new.retries      => #{Dispatcher.new.retries}"
puts "Dispatcher.new(db: ...).db  => #{Dispatcher.new(db: :fake).db}"
puts "App['sourced.settings.retries'] => #{App['sourced.settings.retries']}"
puts "App['cache.redis.pool']     => #{App['cache.redis.pool']}"
puts "App['request_id'] x2        => #{App['request_id']}, #{App['request_id']}"
begin
  App['cache']
rescue Sourced::System::UndeclaredComponentError => e
  puts "App['cache'] => #{e.class}: #{e.message}"
end

begin
  App.declare('late', String)
rescue Sourced::System::LockedSystemError => e
  puts "App.declare('late') => #{e.class}: #{e.message}"
end

# Run until Ctrl-C or SIGTERM, or for RUN_FOR seconds, ex. RUN_FOR=2 bundle exec ruby examples/tree.rb
# Components run in their own threads, so the main thread only waits. Teardown always runs.
run_for = ENV['RUN_FOR']&.to_f
puts "\n== Running #{run_for ? "for #{run_for}s" : '(Ctrl-C to stop)'}"
trap('TERM') { Thread.main.raise(Interrupt) }
begin
  run_for ? sleep(run_for) : sleep
rescue Interrupt
  puts
ensure
  puts "\n== Teardown"
  App.teardown!
  puts "App: #{App.boot_status}, worker: #{App.node('worker').status}, sourced.db: #{App.node('sourced.db').status}"
end
