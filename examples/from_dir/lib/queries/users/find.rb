# frozen_string_literal: true

# One component, at 'lib.queries.users.find'
class Queries::Users::Find
  include Sourced::Component::Installable
  include App.inject('db')

  def call(id) = db.find { |user| user[:id] == id }
end
