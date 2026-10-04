# frozen_string_literal: true

module Sourced
  class System
    # Returned by System#tree: the tree of systems under a system, as nested nodes.
    # Unlike System#graph (the dependency graph), it shows how components are nested,
    # which systems are mounted, and who declared and implemented each node.
    #   tree = App.tree
    #   tree.status  # => :built, the root's status
    #   tree.root    # => a Tree::Node, with #children
    #   puts tree    # => an ASCII tree
    #   tree.to_h    # => nested hashes
    class Tree < Data.define(:status, :root)
      # key:         the node's segment, ex. 'db'. nil for the root of a tree
      # path:        the full path from the root, ex. 'sourced.db'. nil for the root of a tree
      # namespace:   whether it has no type and no implementation
      # mounted:     whether it's a system mounted here (it owns itself)
      # owner:       the full path of the system that declared it. nil for the root
      # implementer: the full path of the system that implemented it. nil for the root, or if not implemented
      class Node < Data.define(
        :key, :path, :type, :type_name, :namespace, :mounted, :implemented, :mode, :status, :owner, :implementer, :children
      )
        # Whether it's implemented by a system other than the one that declared it, ex. an app overriding a library's component
        def overridden? = implemented && owner != implementer

        def to_h = super.merge(children: children.map(&:to_h))
      end

      def to_h = { status:, root: root.to_h }

      #   (root)
      #   ├── logger Interface[info] (singleton, built)
      #   ├── sourced [mounted]
      #   │   ├── logger Interface[info] (singleton, built)
      #   │   └── db DB (singleton, built) implemented by (root)
      #   └── cache
      #       └── redis String (singleton, built)
      def to_s
        lines = [label(root, root.path || '(root)')]
        render(root.children, '', lines)
        lines.join("\n")
      end

      # Mermaid classes for component statuses and unimplemented components, plus namespaces and systems
      MERMAID_CLASSES = Mermaid::STATUS_CLASSES.merge(
        namespace: 'fill:#ffffff,stroke:#a1a1aa',
        system: 'fill:#fafafa,stroke:#18181b,stroke-width:2px'
      ).freeze

      # A top-down Mermaid flowchart of the tree, with an edge from each node to its children.
      # Systems (the root of the tree, and mounted systems) are hexagons, namespaces are rounded,
      # and components are styled like Graph#to_mermaid: singletons are rectangles, dynamic components
      # are rounded, colored by status. Components implemented by another system say which one.
      #   flowchart TD
      #     n0{{"(root)"}}:::system
      #     n1["logger<br/>Interface[info]<br/><i>singleton, built</i>"]:::built
      #     n2{{"sourced"}}:::system
      #     n3["db<br/>DB<br/><i>singleton, built</i><br/><i>implemented by (root)</i>"]:::built
      #     n0 --> n1
      #     n0 --> n2
      #     n2 --> n3
      def to_mermaid
        nodes = []
        edges = []
        add = lambda do |node, name, parent_id, system|
          id = "n#{nodes.size}"
          nodes << "  #{id}#{mermaid_node(node, name, system)}"
          edges << "  #{parent_id} --> #{id}" if parent_id
          node.children.each { |child| add.(child, child.key, id, child.mounted) }
        end
        add.(root, root.path || '(root)', nil, true)

        ['flowchart TD', *nodes, *edges, *Mermaid.class_defs(MERMAID_CLASSES)].join("\n")
      end

      private def mermaid_node(node, name, system)
        lines = [Mermaid.escape(name)]
        unless node.namespace
          lines << Mermaid.escape(node.type_name)
          lines << "<i>#{Mermaid.details(node.implemented, node.mode, node.status)}</i>"
        end
        lines << "<i>implemented by #{Mermaid.escape(node.implementer || '(root)')}</i>" if node.overridden?
        label = lines.join('<br/>')

        css_class = if node.namespace then system ? :system : :namespace
                    elsif node.implemented then node.status
                    else :unimplemented
                    end
        open, close = if system then ['{{"', '"}}']
                      elsif node.namespace then ['("', '")']
                      else Mermaid.component_shape(node.mode)
                      end
        "#{open}#{label}#{close}:::#{css_class}"
      end

      private def render(nodes, prefix, lines)
        nodes.each_with_index do |node, i|
          last = i == nodes.size - 1
          lines << "#{prefix}#{last ? '└── ' : '├── '}#{label(node, node.key)}"
          render(node.children, prefix + (last ? '    ' : '│   '), lines)
        end
      end

      private def label(node, name)
        parts = [name]
        parts << '[mounted]' if node.mounted
        unless node.namespace
          parts << node.type_name
          parts << "(#{node.implemented ? node.mode : 'not implemented'}, #{node.status})"
        end
        parts << "implemented by #{node.implementer || '(root)'}" if node.overridden?
        parts.join(' ')
      end
    end
  end
end
