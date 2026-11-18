# frozen_string_literal: true

module Sourced
  class Component
    # The default .__install_component for a class in a #from_dir directory: declared as its own
    # type and implemented with #factory, so the components it injects are its deps.
    #   class Queries::Users::Search
    #     include Sourced::Component::Installable
    #     include App.inject('db', 'logger')
    #   end
    # A class defining its own .__install_component keeps it. Subclasses install as themselves.
    module Installable
      def self.included(base) = base.extend(ClassMethods)

      module ClassMethods
        def __install_component(c) = c.declare(self).factory(self)
      end
    end
  end
end
