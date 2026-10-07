# frozen_string_literal: true

module Sourced
  class Component
    # A re-declaration of one branch of a booted tree, driven by Component#reconfigure: it records
    # what the block declares, and snapshots what's needed to roll back if anything raises.
    #   Branch        what the block declares through, see below
    #   #snapshot!    everything the block or the validation can touch
    #   #declared!    one per key the block declares, from Component#declare
    #   #implemented! one per key it re-implements, from Component#implement_node
    #   #retyped!     one per surviving node whose type changed, from Component#declare
    class Reconfiguration
      # Declares into +branch+ on behalf of +owner+, the component #reconfigure was called on: keys
      # are prefixed and passed on, so the owner declares them as it would itself. That's what makes
      # nested keys work, since a branch node can't declare under namespaces the root created.
      class Branch
        def initialize(owner, prefix)
          @owner = owner
          @prefix = prefix
        end

        def declare(ckey, ...) = @owner.declare(key(ckey), ...)
        def component!(ckey, ...) = @owner.component!(key(ckey), ...)
        def component(ckey, ...) = @owner.component(key(ckey), ...)
        def config!(ckey, ...) = @owner.config!(key(ckey), ...)
        def config(ckey, ...) = @owner.config(key(ckey), ...)
        def alias(ckey, ...) = @owner.alias(key(ckey), ...)
        def env(...) = @owner.env(...)
        def defer(ckey) = @owner.defer(key(ckey))
        def node(ckey) = @owner.node(key(ckey))
        def declared?(ckey) = @owner.declared?(key(ckey))

        def inspect = "#<#{self.class} #{@prefix}>"

        private def key(ckey) = "#{@prefix}.#{ckey}"
      end

      # Component#declare asks which nodes are new, to announce only those
      attr_reader :created

      # branch: the namespace node being re-declared. owner: the component #reconfigure was called on
      def initialize(branch, owner)
        @branch = branch
        @owner = owner
        @declared = []    # nodes the block declared, new and surviving
        @implemented = [] # nodes the block gave a new implementation
        @retyped = []     # surviving nodes whose declared type changed
        @created = []     # nodes that didn't exist before the block
        @before = []      # the nodes under the branch before the block
        @snapshot = nil
      end

      def branch_handle = Branch.new(@owner, @branch.path)

      # Each node's state, and the tree's shape. Shallow copies: #index!/#attach rebuild the hashes,
      # and the arrays are frozen
      def snapshot!(root)
        @before = @branch.index.values
        nodes = [root, *root.index.values]
        @snapshot = {
          root:,
          order: root.order&.dup,
          nodes: nodes.to_h { |n| [n, n.reconfigurable_state] },
          children: nodes.to_h { |n| [n, n.children.dup] },
          index: nodes.to_h { |n| [n, n.index.dup] }
        }
        self
      end

      # Put it all back. Nothing has run any hooks yet, so this is all it takes
      def rollback!
        @snapshot[:nodes].each { |n, state| n.reconfigurable_state = state }
        @snapshot[:children].each { |n, children| n.restore_children!(children) }
        @snapshot[:index].each { |n, index| n.restore_index!(index) }
        @snapshot[:root].restore_order!(@snapshot[:order])
        self
      end

      def declared!(node)
        @declared << node unless @declared.include?(node)
        @created << node unless @before.include?(node) || @created.include?(node)
      end

      def implemented!(node)
        @implemented << node unless @implemented.include?(node)
      end

      def retyped!(node)
        @retyped << node unless @retyped.include?(node)
      end

      # The order before the block ran, to tear removed components down in reverse
      def order_before = @snapshot[:order] || []

      # What the block changed, plus every node whose resolved deps are no longer the same nodes
      def affected
        redeps = @snapshot[:nodes].filter_map { |n, state| n unless state[:dep_nodes] == n.dep_nodes }
        (@implemented | @retyped | @created | redeps).reject { |n| n.removed? || n.namespace? }
      end

      # Components the tree didn't have: new nodes, and namespaces the block implemented
      def newly_components
        was_namespace = @snapshot[:nodes].filter_map do |n, state|
          n if state[:implementation].nil? && !n.implementation.nil?
        end
        (@created | was_namespace).reject(&:namespace?)
      end

      # The nodes under the branch the block didn't declare
      def dropped = @before.reject { |n| @declared.include?(n) }

      # Dropped components with no declared descendants left: gone for good
      def removable = dropped.reject { |n| keeps_children?(n) }

      # Dropped components that still have declared descendants, ex. one at 'billing' whose file
      # became a 'billing/' directory. They revert to namespaces: removing them would orphan those
      def reverting = dropped.select { |n| keeps_children?(n) && !n.namespace? }

      # Namespaces left empty once +removed+ are gone, pruned bottom-up until stable: dropping
      # 'billing.deep.x' can empty 'deep', which can empty 'billing'
      def emptied_namespaces(removed)
        gone = removed.dup
        loop do
          empty = @before.select do |n|
            n.namespace? && !gone.include?(n) && n.children.any? && (n.children.values - gone).empty?
          end
          break gone if empty.empty?

          gone.concat(empty)
        end
      end

      private def keeps_children?(node)
        node.index.values.any? { |d| @declared.include?(d) }
      end
    end
  end
end
