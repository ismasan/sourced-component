# frozen_string_literal: true

module Sourced
  class System
    # The default notifier. Custom notifiers must implement the same #publish and #subscribe interface.
    # Handlers are called synchronously, in the order they subscribed, by the thread or fiber running the lifecycle step.
    # Errors raised by handlers propagate to the caller.
    class Notifier
      def initialize
        @subscriptions = [].freeze
        @lock = Mutex.new
      end

      # Subscribe to an event type string (ex. 'components.built'),
      # or an event class, which also matches its subclasses (ex. Events::ComponentEvent for all component events)
      def subscribe(event_class_or_type, &handler)
        raise ArgumentError, 'a handler block is required' unless handler

        matcher = case event_class_or_type
                  when Class
                    ->(event) { event.is_a?(event_class_or_type) }
                  when String, Symbol
                    type = event_class_or_type.to_s
                    raise ArgumentError, "unknown event type #{type}" unless Event.registry[type]

                    ->(event) { event.type == type }
                  else
                    raise ArgumentError, "can't subscribe to #{event_class_or_type.inspect}"
                  end

        # copy-on-write, so publishing never needs the lock
        @lock.synchronize { @subscriptions = [*@subscriptions, [matcher, handler]].freeze }
        self
      end

      def publish(event)
        @subscriptions.each { |matcher, handler| handler.call(event) if matcher.call(event) }
        self
      end
    end

    NotifierInterface = Plumb::Types::Interface[:publish, :subscribe]
  end
end
