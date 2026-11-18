# frozen_string_literal: true

# Several components under 'lib.integrations.mailer': '.templates' and '.client'.
# Deps are relative to App, so the client refers to its sibling by its full key.
module Integrations::Mailer
  Client = Data.define(:templates, :logger) do
    def deliver(to, template) = logger.info("mail #{to}: #{templates.fetch(template)}")
  end

  def self.install_sourced_component(c)
    c['templates'].declare(Sourced::Component::T::Hash) { { welcome: 'Welcome aboard!' } }
    c['client'].declare(Client).config!([c['templates'].key, 'logger']) do |templates, logger|
      Client.new(templates:, logger:)
    end
  end
end
