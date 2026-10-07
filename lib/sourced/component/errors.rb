# frozen_string_literal: true

module Sourced
  class Component
    ComponentError = Class.new(StandardError)
    DeclarationOverrideError = Class.new(ComponentError)
    OwnershipError = Class.new(ComponentError)
    LockedComponentError = Class.new(ComponentError)
    SubcomponentError = Class.new(ComponentError)
    UndeclaredComponentError = Class.new(ComponentError)
    UnimplementedComponentError = Class.new(ComponentError)
    MissingDependencyError = Class.new(ComponentError)
    CircularDependencyError = Class.new(ComponentError)
    NotBuiltError = Class.new(ComponentError)
    TornDownError = Class.new(ComponentError)
    NotStartedError = Class.new(ComponentError)
    RemovedComponentError = Class.new(ComponentError)
    InjectionError = Class.new(ComponentError)
  end
end
