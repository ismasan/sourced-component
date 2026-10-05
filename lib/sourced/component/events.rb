# frozen_string_literal: true

require 'sourced/message'

module Sourced
  class Component
    # The parent class of all lifecycle events published to a component's notifier.
    # Events are Sourced::Message structs, so they build their own registry
    # (Component::Event.registry), and can be serialized with Sourced::Message codecs.
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
    # Events::RootEvent and Events::ComponentEvent can be used to subscribe to all events of a kind.
    module Events
      # Events about the whole tree, published by its root
      class RootEvent < Event; end

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
        attribute :stage, Symbol # :prepare, :build, :start, :stop or :teardown
        attribute :error_class, String
        attribute :error_message, String
        attribute :backtrace, Plumb::Types::Array[String]
      end

      RootPreparing = RootEvent.define('root.preparing')
      RootPrepared = RootEvent.define('root.prepared', &Completed)
      RootBuilding = RootEvent.define('root.building')
      RootBuilt = RootEvent.define('root.built', &Completed)
      RootStarting = RootEvent.define('root.starting')
      RootStarted = RootEvent.define('root.started', &Completed)
      RootTearingDown = RootEvent.define('root.tearing_down')
      RootTornDown = RootEvent.define('root.torn_down', &Completed)
      RootFailed = RootEvent.define('root.failed', &Failed)

      ComponentDeclared = ComponentEvent.define('components.declared') do
        attribute :type_name, String
      end
      ComponentImplemented = ComponentEvent.define('components.implemented') do
        attribute :mode, Symbol
        attribute :deps, Plumb::Types::Array[String] # relative to the implementer
        attribute :implementer, Plumb::Types::String.nullable # the implementer's full path. nil for the root
        attribute :override, Plumb::Types::Boolean # whether it replaced a previous implementation
      end
      ComponentDeferred = ComponentEvent.define('components.deferred') do
        attribute :deferrer, Plumb::Types::String.nullable # the full path of the component that deferred it. nil for the root
      end
      ComponentPreparing = ComponentEvent.define('components.preparing')
      ComponentPrepared = ComponentEvent.define('components.prepared', &Completed)
      ComponentBuilding = ComponentEvent.define('components.building')
      ComponentBuilt = ComponentEvent.define('components.built', &Completed)
      ComponentStarting = ComponentEvent.define('components.starting')
      ComponentStarted = ComponentEvent.define('components.started', &Completed)
      ComponentStopping = ComponentEvent.define('components.stopping')
      ComponentStopped = ComponentEvent.define('components.stopped', &Completed)
      ComponentTearingDown = ComponentEvent.define('components.tearing_down')
      ComponentTornDown = ComponentEvent.define('components.torn_down', &Completed)
      ComponentFailed = ComponentEvent.define('components.failed', &Failed)
    end

    # Lifecycle stages, the status each one moves to, and their events
    STAGES = { prepare: :prepared, build: :built, start: :started, stop: :stopped, teardown: :torn_down }.freeze

    ROOT_EVENTS = {
      prepare: [Events::RootPreparing, Events::RootPrepared],
      build: [Events::RootBuilding, Events::RootBuilt],
      start: [Events::RootStarting, Events::RootStarted],
      teardown: [Events::RootTearingDown, Events::RootTornDown]
    }.freeze

    COMPONENT_EVENTS = {
      prepare: [Events::ComponentPreparing, Events::ComponentPrepared],
      build: [Events::ComponentBuilding, Events::ComponentBuilt],
      start: [Events::ComponentStarting, Events::ComponentStarted],
      stop: [Events::ComponentStopping, Events::ComponentStopped],
      teardown: [Events::ComponentTearingDown, Events::ComponentTornDown]
    }.freeze
  end
end
