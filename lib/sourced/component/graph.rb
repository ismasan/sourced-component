# frozen_string_literal: true

module Sourced
  class Component
    # Returned by Component#graph. #components are hashes describing each declared component, by full path:
    #   {
    #     key: 'sourced.db',          # the component's full path from the root
    #     type: <Plumb type>,
    #     type_name: 'Interface[exec]',
    #     implemented: true,
    #     mode: :singleton,           # nil if not implemented
    #     status: :built,
    #     deps: ['logger'],           # full paths of the components this one depends on
    #     missing: [],                # deps that aren't declared, or are namespaces without an implementation
    #     dependents: ['app'],        # components in the graph that depend on this one
    #     provider: <provider>        # the provider, or the block of #config!/#config. nil for blocks of hooks
    #   }
    class Graph < Data.define(:status, :components)
      # Mermaid classes for component statuses, plus declared-but-unimplemented components,
      # missing dependencies, and dependencies outside the graph (ex. a library's graph, with an app's overrides)
      MERMAID_CLASSES = Mermaid::STATUS_CLASSES.merge(
        missing: 'fill:#fee2e2,stroke:#dc2626,stroke-dasharray:4 3',
        external: 'fill:#ffffff,stroke:#a1a1aa,stroke-dasharray:2 2'
      ).freeze

      # A Mermaid flowchart of the dependency graph.
      # Edges point from each dependency to its dependents (build and start order).
      # Singletons are rectangles, dynamic components are rounded, and nodes are styled by status.
      # Unimplemented components, missing dependencies and dependencies outside the graph are included, with dashed borders.
      def to_mermaid
        ids = {}
        id_for = ->(key) { ids[key] ||= "c#{ids.size}" }
        lines = ['flowchart LR']

        components.each do |node|
          details = Mermaid.details(node[:implemented], node[:mode], node[:status])
          label = "#{Mermaid.escape(node[:key])}<br/>#{Mermaid.escape(node[:type_name])}<br/><i>#{details}</i>"
          open, close = Mermaid.component_shape(node[:mode])
          css_class = node[:implemented] ? node[:status] : :unimplemented
          lines << "  #{id_for.(node[:key])}#{open}#{label}#{close}:::#{css_class}"
        end

        keys = components.map { |node| node[:key] }
        missing = components.flat_map { |node| node.fetch(:missing, []) }.uniq
        outside = components.flat_map { |node| node[:deps] }.uniq - keys
        outside.each do |key|
          details, css_class = missing.include?(key) ? ['not declared', :missing] : ['outside this component', :external]
          lines << "  #{id_for.(key)}[\"#{Mermaid.escape(key)}<br/><i>#{details}</i>\"]:::#{css_class}"
        end

        components.each do |node|
          node[:deps].each { |dep| lines << "  #{id_for.(dep)} --> #{id_for.(node[:key])}" }
        end

        lines.concat(Mermaid.class_defs(MERMAID_CLASSES))
        lines.join("\n")
      end
    end
  end
end
