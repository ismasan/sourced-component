# frozen_string_literal: true

module Sourced
  class System
    # Helpers shared by Graph#to_mermaid and Tree#to_mermaid
    module Mermaid
      # Styles for component statuses, and for declared-but-unimplemented components
      STATUS_CLASSES = {
        open: 'fill:#f4f4f5,stroke:#71717a',
        prepared: 'fill:#e0f2fe,stroke:#0284c7',
        built: 'fill:#ede9fe,stroke:#7c3aed',
        started: 'fill:#dcfce7,stroke:#16a34a',
        toredown: 'fill:#e4e4e7,stroke:#52525b,color:#52525b',
        unimplemented: 'fill:#fef9c3,stroke:#ca8a04,stroke-dasharray:4 3'
      }.freeze

      # Escape label text, so type names with brackets, pipes or quotes are safe
      def self.escape(text)
        text.to_s.gsub('&', '#amp;').gsub('"', '#quot;').gsub('<', '#lt;').gsub('>', '#gt;')
      end

      # ex. 'singleton, started', or 'not implemented'
      def self.details(implemented, mode, status) = implemented ? "#{mode}, #{status}" : 'not implemented'

      # Open and close brackets: singletons are rectangles, dynamic components are rounded
      def self.component_shape(mode) = mode == :dynamic ? ['(["', '"])'] : ['["', '"]']

      def self.class_defs(classes) = classes.map { |name, style| "  classDef #{name} #{style}" }
    end
  end
end
