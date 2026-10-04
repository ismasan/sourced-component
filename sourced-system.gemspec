# frozen_string_literal: true

require_relative "lib/sourced/system/version"

Gem::Specification.new do |spec|
  spec.name = "sourced-system"
  spec.version = Sourced::System::VERSION
  spec.authors = ["Ismael Celis"]
  spec.email = ["ismaelct@gmail.com"]

  spec.summary = "A tree of nested, typed components with dependencies and a managed lifecycle."
  spec.description = "Declare typed components as a tree of systems, implement them with dependencies and prepare/build/start/teardown hooks, and mount library systems into applications."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  # spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "plumb", "~> 0.4"
  spec.add_dependency "tsort", "~> 0.2"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
