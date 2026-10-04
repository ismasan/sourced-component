# frozen_string_literal: true

require 'sourced/message'

module Sourced
  class System
    # The parent class of all lifecycle events published to a system's notifier.
    # Events are Sourced::Message structs, so they build their own registry
    # (System::Event.registry), and can be serialized with Sourced::Message codecs.
    #
    # Every event's payload carries the process, thread and fiber it was published from:
    #   event.type            # => 'components.built'
    #   event.created_at      # => Time
    #   event.payload.pid     # => 12345
    #   event.payload.key     # => 'sourced.db' (component events)
    #
    # Payloads only hold JSON-friendly values: Sourced::Message's registry is shared by
    # every message type in the process, so these events are compiled by any
    # Sourced::Message::JSONCodec. That's why failures carry the error's class, message
    # and backtrace, rather than the exception itself.
    class Event < Sourced::Message
      # Define an event type, with the runtime ids every event carries
      def self.define(type_str, &block)
        super(type_str) do
          attribute :pid, Integer
          attribute :thread_id, Integer
          attribute :fiber_id, Integer
          class_eval(&block) if block
        end
      end
    end

    # Each event class has a #type string, which can be used to subscribe to it,
    # ex. notifier.subscribe('components.built') { |event| ... }
    # Events::SystemEvent and Events::ComponentEvent can be used to subscribe to all events of a kind.
    module Events
      # Events about the whole tree, published by its root
      class SystemEvent < Event; end

      # Events about a component, with its full path as the payload's key
      class ComponentEvent < Event
        def self.define(type_str, &block)
          super(type_str) do
            attribute :key, String
            class_eval(&block) if block
          end
        end
      end

      Completed = proc { attribute :duration, Float }
      Failed = proc do
        attribute :stage, Symbol # :prepare, :build, :start or :teardown
        attribute :error_class, String
        attribute :error_message, String
        attribute :backtrace, Plumb::Types::Array[String]
      end

      SystemPreparing = SystemEvent.define('system.preparing')
      SystemPrepared = SystemEvent.define('system.prepared', &Completed)
      SystemBuilding = SystemEvent.define('system.building')
      SystemBuilt = SystemEvent.define('system.built', &Completed)
      SystemStarting = SystemEvent.define('system.starting')
      SystemStarted = SystemEvent.define('system.started', &Completed)
      SystemTearingDown = SystemEvent.define('system.tearing_down')
      SystemToredown = SystemEvent.define('system.toredown', &Completed)
      SystemFailed = SystemEvent.define('system.failed', &Failed)

      ComponentDeclared = ComponentEvent.define('components.declared') do
        attribute :type_name, String
      end
      ComponentImplemented = ComponentEvent.define('components.implemented') do
        attribute :mode, Symbol
        attribute :deps, Plumb::Types::Array[String] # relative to the implementer
        attribute :implementer, Plumb::Types::String.nullable # the implementer's full path. nil for the root
        attribute :override, Plumb::Types::Boolean # whether it replaced a previous implementation
      end
      ComponentPreparing = ComponentEvent.define('components.preparing')
      ComponentPrepared = ComponentEvent.define('components.prepared', &Completed)
      ComponentBuilding = ComponentEvent.define('components.building')
      ComponentBuilt = ComponentEvent.define('components.built', &Completed)
      ComponentStarting = ComponentEvent.define('components.starting')
      ComponentStarted = ComponentEvent.define('components.started', &Completed)
      ComponentTearingDown = ComponentEvent.define('components.tearing_down')
      ComponentToredown = ComponentEvent.define('components.toredown', &Completed)
      ComponentFailed = ComponentEvent.define('components.failed', &Failed)
    end

    # Lifecycle stages, the status each one moves to, and their events
    STAGES = { prepare: :prepared, build: :built, start: :started, teardown: :toredown }.freeze

    SYSTEM_EVENTS = {
      prepare: [Events::SystemPreparing, Events::SystemPrepared],
      build: [Events::SystemBuilding, Events::SystemBuilt],
      start: [Events::SystemStarting, Events::SystemStarted],
      teardown: [Events::SystemTearingDown, Events::SystemToredown]
    }.freeze

    COMPONENT_EVENTS = {
      prepare: [Events::ComponentPreparing, Events::ComponentPrepared],
      build: [Events::ComponentBuilding, Events::ComponentBuilt],
      start: [Events::ComponentStarting, Events::ComponentStarted],
      teardown: [Events::ComponentTearingDown, Events::ComponentToredown]
    }.freeze
  end
end
