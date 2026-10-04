# frozen_string_literal: true

module Sourced
  class System
    SystemError = Class.new(StandardError)
    DeclarationOverrideError = Class.new(SystemError)
    OwnershipError = Class.new(SystemError)
    LockedSystemError = Class.new(SystemError)
    SubsystemError = Class.new(SystemError)
    UndeclaredComponentError = Class.new(SystemError)
    UnimplementedComponentError = Class.new(SystemError)
    MissingDependencyError = Class.new(SystemError)
    CircularDependencyError = Class.new(SystemError)
    NotBuiltError = Class.new(SystemError)
  end
end
