# frozen_string_literal: true

module Sourced
  class System
    # Returned by System#graph. #components are hashes describing each declared component, by full path:
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
      MERMAID_CLASSES = {
        open: 'fill:#f4f4f5,stroke:#71717a',
        prepared: 'fill:#e0f2fe,stroke:#0284c7',
        built: 'fill:#ede9fe,stroke:#7c3aed',
        started: 'fill:#dcfce7,stroke:#16a34a',
        toredown: 'fill:#e4e4e7,stroke:#52525b,color:#52525b',
        unimplemented: 'fill:#fef9c3,stroke:#ca8a04,stroke-dasharray:4 3',
        missing: 'fill:#fee2e2,stroke:#dc2626,stroke-dasharray:4 3',
        external: 'fill:#ffffff,stroke:#a1a1aa,stroke-dasharray:2 2'
      }.freeze

      # A Mermaid flowchart of the dependency graph.
      # Edges point from each dependency to its dependents (build and start order).
      # Singletons are rectangles, dynamic components are rounded, and nodes are styled by status.
      # Unimplemented components, missing dependencies and dependencies outside the graph are included, with dashed borders.
      def to_mermaid
        ids = {}
        id_for = ->(key) { ids[key] ||= "c#{ids.size}" }
        lines = ['flowchart LR']

        components.each do |node|
          details = node[:implemented] ? "#{node[:mode]}, #{node[:status]}" : 'not implemented'
          label = "#{mermaid_escape(node[:key])}<br/>#{mermaid_escape(node[:type_name])}<br/><i>#{details}</i>"
          open, close = node[:mode] == :dynamic ? ['(["', '"])'] : ['["', '"]']
          css_class = node[:implemented] ? node[:status] : :unimplemented
          lines << "  #{id_for.(node[:key])}#{open}#{label}#{close}:::#{css_class}"
        end

        keys = components.map { |node| node[:key] }
        missing = components.flat_map { |node| node.fetch(:missing, []) }.uniq
        outside = components.flat_map { |node| node[:deps] }.uniq - keys
        outside.each do |key|
          details, css_class = missing.include?(key) ? ['not declared', :missing] : ['outside this system', :external]
          lines << "  #{id_for.(key)}[\"#{mermaid_escape(key)}<br/><i>#{details}</i>\"]:::#{css_class}"
        end

        components.each do |node|
          node[:deps].each { |dep| lines << "  #{id_for.(dep)} --> #{id_for.(node[:key])}" }
        end

        MERMAID_CLASSES.each { |name, style| lines << "  classDef #{name} #{style}" }
        lines.join("\n")
      end

      private def mermaid_escape(text)
        text.to_s.gsub('&', '#amp;').gsub('"', '#quot;').gsub('<', '#lt;').gsub('>', '#gt;')
      end
    end
  end
end
