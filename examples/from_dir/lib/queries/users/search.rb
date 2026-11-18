# frozen_string_literal: true

# One component, at 'lib.queries.users.search': a new Search on every read, with its injected deps
class Queries::Users::Search
  include App.inject('db', 'logger')

  def self.install_sourced_component(c) = c.declare(self).factory(self)

  def call(term)
    logger.info("search #{term.inspect}")
    db.select { |user| user[:name].include?(term) }
  end
end
