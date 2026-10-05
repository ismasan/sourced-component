# frozen_string_literal: true

module Sourced
  class Component
    # Returned by Component#tree: the tree of components under a component, as nested nodes.
    # Unlike Component#graph (the dependency graph), it shows how components are nested,
    # which components are mounted, and who declared and implemented each node.
    #   tree = App.tree
    #   tree.status  # => :built, the root's status
    #   tree.root    # => a Tree::Node, with #children
    #   puts tree    # => an ASCII tree
    #   tree.to_h    # => nested hashes
    class Tree < Data.define(:status, :root)
      # key:         the node's segment, ex. 'db'. nil for the root of a tree
      # path:        the full path from the root, ex. 'sourced.db'. nil for the root of a tree
      # namespace:   whether it has no type and no implementation
      # mounted:     whether it's a component mounted here (it owns itself)
      # deferred:    whether the root's start! skips it (see Component#defer)
      # owner:       the full path of the component that declared it. nil for the root
      # implementer: the full path of the component that implemented it. nil for the root, or if not implemented
      class Node < Data.define(
        :key, :path, :type, :type_name, :namespace, :mounted, :implemented, :mode, :status, :deferred, :owner, :implementer, :children
      )
        # Whether it's implemented by a component other than the one that declared it, ex. an app overriding a library's component
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

      # Mermaid classes for component statuses and unimplemented components, plus namespaces and roots
      MERMAID_CLASSES = Mermaid::STATUS_CLASSES.merge(
        namespace: 'fill:#ffffff,stroke:#a1a1aa',
        root: 'fill:#fafafa,stroke:#18181b,stroke-width:2px'
      ).freeze

      # A top-down Mermaid flowchart of the tree, with an edge from each node to its children.
      # Roots (the root of the tree, and mounted components) are hexagons, namespaces are rounded,
      # and components are styled like Graph#to_mermaid: singletons are rectangles, dynamic components
      # are rounded, colored by status. Components implemented by another component say which one.
      #   flowchart TD
      #     n0{{"(root)"}}:::root
      #     n1["logger<br/>Interface[info]<br/><i>singleton, built</i>"]:::built
      #     n2{{"sourced"}}:::root
      #     n3["db<br/>DB<br/><i>singleton, built</i><br/><i>implemented by (root)</i>"]:::built
      #     n0 --> n1
      #     n0 --> n2
      #     n2 --> n3
      def to_mermaid
        nodes = []
        edges = []
        add = lambda do |node, name, parent_id, subtree_root|
          id = "n#{nodes.size}"
          nodes << "  #{id}#{mermaid_node(node, name, subtree_root)}"
          edges << "  #{parent_id} --> #{id}" if parent_id
          node.children.each { |child| add.(child, child.key, id, child.mounted) }
        end
        add.(root, root.path || '(root)', nil, true)

        ['flowchart TD', *nodes, *edges, *Mermaid.class_defs(MERMAID_CLASSES)].join("\n")
      end

      private def mermaid_node(node, name, subtree_root)
        lines = [Mermaid.escape(name)]
        unless node.namespace
          lines << Mermaid.escape(node.type_name)
          lines << "<i>#{Mermaid.details(node.implemented, node.mode, node.status, node.deferred)}</i>"
        end
        lines << "<i>implemented by #{Mermaid.escape(node.implementer || '(root)')}</i>" if node.overridden?
        label = lines.join('<br/>')

        css_class = if node.namespace then subtree_root ? :root : :namespace
                    elsif node.implemented then node.status
                    else :unimplemented
                    end
        open, close = if subtree_root then ['{{"', '"}}']
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
          parts << "(#{[node.implemented ? node.mode : 'not implemented', node.status, ('deferred' if node.deferred)].compact.join(', ')})"
        end
        parts << "implemented by #{node.implementer || '(root)'}" if node.overridden?
        parts.join(' ')
      end
    end
  end
end
