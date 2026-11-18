# frozen_string_literal: true

# No .install_sourced_component: autoloaded as usual, but not a component
module Support::Formatter
  def self.user(user) = "##{user[:id]} #{user[:name]}"
end
