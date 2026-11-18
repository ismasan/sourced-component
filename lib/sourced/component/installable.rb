# frozen_string_literal: true

module Sourced
  class Component
    # The default .__install_component for a class in a #from_dir directory: declared as its own
    # type and implemented with #factory, so the components it injects are its deps.
    #   class Queries::Users::Search
    #     include Sourced::Component::Installable
    #     include App.inject('db', 'logger')
    #   end
    # A class defining its own .__install_component keeps it. Subclasses install as themselves, and
    # a base class only there to be subclassed opts out, without opting out its subclasses:
    #   class Queries::Base
    #     include Sourced::Component::Installable
    #     __abstract_component!
    #   end
    module Installable
      def self.included(base) = base.extend(ClassMethods)

      module ClassMethods
        # Set on this class only: an instance variable of the class, which subclasses don't share
        def __abstract_component! = @__abstract_component = true

        def __install_component(c)
          return if @__abstract_component

          c.declare(self).factory(self)
        end
      end
    end
  end
end
