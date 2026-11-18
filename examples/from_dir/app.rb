# frozen_string_literal: true

# Run with: bundle exec ruby examples/from_dir/app.rb
# Or explore it in irb, booted, without the demo: bundle exec irb -r ./examples/from_dir/app.rb
#
# Declares components from the files in lib/, autoloaded by Zeitwerk, then edits a file and
# reloads, as a dev-mode file watcher would. The reload edits a copy of lib/ in a temp dir,
# so running the example leaves this one untouched.

require 'bundler/setup'
require 'sourced/component'
require 'zeitwerk'
require 'logger'
require 'tmpdir'
require 'fileutils'

T = Sourced::Component::T
$stdout.sync = true # keep output in order with the reload warning, on stderr

dir = Dir.mktmpdir
at_exit { FileUtils.rm_rf(dir) }
FileUtils.cp_r(File.join(__dir__, 'lib'), dir)
lib = File.join(dir, 'lib')

loader = Zeitwerk::Loader.new
loader.push_dir(lib)
loader.enable_reloading

# The loader is configuration for the whole tree
App = Sourced::Component.new(loader:)

App.declare('logger', Logger) { Logger.new($stdout, formatter: ->(_, _, _, msg) { "  [log] #{msg}\n" }) }
App.declare('db', T::Array) { [{ id: 1, name: 'Joe' }, { id: 2, name: 'Joan' }, { id: 3, name: 'Ann' }] }

# Every file under lib/, keyed by its path relative to root:
#   lib/queries/users/search.rb => 'lib.queries.users.search'
# Files are loaded on #prepare!, so 'db' and 'logger' only need to be declared before booting.
# On reload, the 'lib' branch is reconfigured from the reloaded constants.
App.from_dir(File.join(lib, '**/*.rb'), root: dir)

# Collects every user query, whichever files declare them
App.declare('user_queries', T::Hash)
App.config!('user_queries', ['lib.queries.users.*']) { |queries| queries }

LOADER = loader
LIB = lib # the temp copy of lib/: edit files here, then LOADER.reload

loader.setup
App.start!

return unless __FILE__ == $PROGRAM_NAME

puts App.tree
puts

puts 'Search "Jo":'
App['lib.queries.users.search'].call('Jo').each { |user| puts "  #{Support::Formatter.user(user)}" }
puts 'Find 3:'
puts "  #{Support::Formatter.user(App['lib.queries.users.find'].call(3))}"
App['lib.integrations.mailer.client'].deliver('joe@example.com', :welcome)
puts "User queries: #{App['user_queries'].keys}"
puts

puts 'Adding lib/queries/users/count.rb, removing find.rb, and reloading...'
File.write(File.join(lib, 'queries/users/count.rb'), <<~RUBY)
  class Queries::Users::Count
    include App.inject('db')
    def self.install_sourced_component(c) = c.declare(self).factory(self)
    def call = db.size
  end
RUBY
File.delete(File.join(lib, 'queries/users/find.rb'))
loader.reload

puts "User queries: #{App['user_queries'].keys}"
puts "Count: #{App['lib.queries.users.count'].call}"
puts "Find declared? #{App.declared?('lib.queries.users.find')}"
puts

puts 'Breaking search.rb and reloading: the tree keeps running as it was'
File.write(File.join(lib, 'queries/users/search.rb'), "class Queries::Users::Search\n  def oops(\nend\n")
loader.reload
puts "Search still works: #{App['lib.queries.users.search'].call('Ann').size} result"

App.teardown!
