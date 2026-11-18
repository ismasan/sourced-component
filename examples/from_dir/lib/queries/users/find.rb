# frozen_string_literal: true

# One component, at 'lib.queries.users.find'
class Queries::Users::Find
  include App.inject('db')

  def self.install_sourced_component(c) = c.declare(self).factory(self)

  def call(id) = db.find { |user| user[:id] == id }
end
