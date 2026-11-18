# frozen_string_literal: true

# One component, at 'lib.queries.users.search': a new Search on every read, with its injected deps.
# Installable declares it as c.declare(self).factory(self)
class Queries::Users::Search
  include Sourced::Component::Installable
  include App.inject('db', 'logger')

  def call(term)
    logger.info("search #{term.inspect}")
    db.select { |user| user[:name].include?(term) }
  end
end
