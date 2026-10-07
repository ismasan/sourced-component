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
      # What a reconfiguration can change about one node: captured before its block runs, restored
      # if anything raises. The members drive both the capture and the restore, so a new one can't
      # be captured and then forgotten on the way back
      NodeState = Data.define(
        :implementation, :type, :implicit, :deps, :dep_nodes, :deferred, :held, :status, :value,
        :recycle_to, :children, :index
      )

      # The tree as it was before the block: every node's state, and the root's order
      Snapshot = Data.define(:order, :nodes)

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
        def defer(ckey) = @owner.defer(key(ckey))
        def node(ckey) = @owner.node(key(ckey))
        def declared?(ckey) = @owner.declared?(key(ckey))

        def inspect = "#<#{self.class} #{@prefix}>"

        private def key(ckey) = "#{@prefix}.#{ckey}"
      end

      # branch: the namespace node being re-declared. owner: the component #reconfigure was called on
      def initialize(branch, owner)
        @branch = branch
        @owner = owner
        @declared = Set.new # nodes the block declared, new and surviving
        @changed = Set.new  # nodes it re-implemented, or declared with another type
        @before = Set.new   # the nodes under the branch before the block
        @snapshot = nil
      end

      def branch_handle = Branch.new(@owner, @branch.path)

      def snapshot!
        root = @branch.root
        @before = @branch.index.values.to_set
        nodes = [root, *root.index.values]
        @snapshot = Snapshot.new(order: root.order&.dup, nodes: nodes.to_h { |n| [n, n.capture_state] })
        self
      end

      # Put it all back. Nothing has run any hooks yet, so this is all it takes
      def rollback!
        @snapshot.nodes.each { |n, state| n.restore_state!(state) }
        @branch.root.restore_order!(@snapshot.order)
        self
      end

      def declared!(node) = @declared << node
      def changed!(node) = @changed << node

      # Whether the tree didn't have this component before the block. Component#declare asks, to
      # announce only those
      def new?(node) = !@before.include?(node)

      # The order before the block ran, to tear removed components down in reverse
      def order_before = @snapshot.order || []

      # What the block changed, plus every node whose resolved deps are no longer the same nodes
      def affected
        redeps = @snapshot.nodes.filter_map { |n, state| n unless state.dep_nodes == n.dep_nodes }
        (@changed | created | redeps).reject { |n| n.removed? || n.namespace? }
      end

      # Components the tree didn't have: new nodes, and namespaces the block implemented
      def newly_components
        was_namespace = @snapshot.nodes.filter_map do |n, state|
          n if state.implementation.nil? && !n.implementation.nil?
        end
        (created | was_namespace).reject(&:namespace?)
      end

      # Components the block declared that the tree didn't have before
      def created = @declared - @before

      # Dropped components that still have declared descendants, ex. one at 'billing' whose file
      # became a 'billing/' directory. They revert to namespaces: removing them would orphan those
      def reverting = dropped.fetch(:reverting)

      # Everything to take out of the tree: dropped components with no declared descendants left,
      # plus the namespaces that leaves empty, pruned bottom-up until stable (dropping
      # 'billing.deep.x' can empty 'deep', which can empty 'billing')
      def removing
        gone = dropped.fetch(:removing).dup
        loop do
          empty = @before.select do |n|
            n.namespace? && !gone.include?(n) && n.children.any? && (n.children.values - gone).empty?
          end
          break gone if empty.empty?

          gone.concat(empty)
        end
      end

      # The nodes the block didn't declare, split into the ones to take out of the tree and the ones
      # that revert to namespaces. Computed once: the block has finished by the time anything asks
      private def dropped
        @dropped ||= begin
          kept, gone = (@before - @declared).partition { |n| keeps_children?(n) }
          { removing: gone, reverting: kept.reject(&:namespace?) }
        end
      end

      private def keeps_children?(node)
        node.index.values.any? { |d| @declared.include?(d) }
      end
    end
  end
end
