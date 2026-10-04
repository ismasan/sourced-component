# frozen_string_literal: true

# Run with: bundle exec ruby examples/env.rb
# Override any variable, ex: APP_PORT=9000 APP_DEBUG=false bundle exec ruby examples/env.rb

require 'date'
require 'bundler/setup'
require 'sourced/system'

T = Sourced::System::T

# Sample ENV, unless already set
ENV['USER_NAME'] ||= 'Ismael'
ENV['USER_DOB'] ||= '1977-11-29'
ENV['USER_EMAIL'] ||= 'ismael@example.com'
ENV['APP_HOST'] ||= 'localhost'
ENV['APP_PORT'] ||= '3000'
ENV['APP_DEBUG'] ||= 'true'

# Declared types. ENV values are strings, decoded into these types with Plumb::Codec::Forms
User = T::Data[name: String, dob: Date]
AppSettings = T::Data[
  host: String,
  port: Integer,
  debug: T::Boolean,
  workers: T::Integer.default(2) # no APP_WORKERS in ENV: uses the default
]
Shell = T::Data[user: String, home: String]

Sys = Sourced::System.new

Sys.declare('user.email', T::Email)
Sys.declare('app.port', Integer)
Sys.declare('user.info', User)
Sys.declare('app.settings', AppSettings)
Sys.declare('shell', Shell)

# Single variables, decoded into each declared type
Sys.env('USER_EMAIL' => 'user.email', 'APP_PORT' => 'app.port')

# Variables matching a regex, collected into a hash with the match removed,
# and downcased: USER_NAME => name, USER_DOB => dob
Sys.env(:downcase, /^USER_/ => 'user.info', /^APP_/ => 'app.settings')

# All variables, downcased: picks up the system's USER and HOME.
# This is why collecting with a regex matters for anything that isn't meant to read system variables.
Sys.env(:downcase, 'shell')

Sys.start!

puts "== Components\n\n"
%w[user.email app.port user.info app.settings shell].each do |key|
  value = Sys[key]
  puts "#{key}: #{(value.respond_to?(:to_h) ? value.to_h : value).inspect}"
end

puts "\n== System\n\n"
puts Sys.ordered_nodes.map(&:inspect)

# Missing or invalid variables fail the boot, naming each variable
puts "\n== Missing variables\n\n"

Broken = Sourced::System.new
Broken.declare('payments.settings', T::Data[api_key: String, region: String])
Broken.declare('payments.webhook', T::String[/\Ahttps:/])
Broken.env(:downcase, /^PAYMENTS_/ => 'payments.settings')
Broken.env('PAYMENTS_WEBHOOK_URL' => 'payments.webhook')

begin
  Broken.start!
  puts "payments.settings: #{Broken['payments.settings'].to_h.inspect}"
  puts "payments.webhook: #{Broken['payments.webhook'].inspect}"
rescue Plumb::ParseError => e
  puts "boot failed: #{e.class}\n#{e.message}\n\n"
  puts 'try: PAYMENTS_API_KEY=abc PAYMENTS_REGION=eu PAYMENTS_WEBHOOK_URL=https://example.com bundle exec ruby examples/env.rb'
end

Sys.teardown!
