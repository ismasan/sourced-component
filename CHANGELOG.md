## [Unreleased]

- `stop` lifecycle hook: runs when a started component is stopped, and before `teardown` when the root is torn down
- `#defer(key)`: the root's `#start!` skips the component, and everything depending on it
- `#start_component!`, `#stop_component!` and `#restart_component!` start and stop components by key, following the dependency graph
- `components.deferred`, `components.stopping` and `components.stopped` events, and `NotStartedError`
- `#tree` and `#graph` show deferred and stopped components
- `.__component_deps` on classes including an injector: every component injected into them, including inherited ones, as the key it's registered under mapped to the name it's injected as
- `#recycle_component!`, `#recycle_components!` and `#recycle!` run a component's whole lifecycle again, leaving every affected component in the status it was in. A recycle that raises can be retried: components remember the status to restore until one completes
- `root.recycling` and `root.recycled` events
- `#reconfigure(key) { |branch| ... }` re-declares one branch of a booted tree from scratch: what the block doesn't declare is removed, unchanged components keep running, and the new declaration set is validated before anything is torn down, so a failure leaves the tree as it was
- `root.reconfiguring`, `root.reconfigured` and `components.removed` events, and `RemovedComponentError`
- Document forking after `#prepare!`, with `#build!` and `#start!` in each child
- Fix: `#teardown!` left the rest of the tree running, and the root `:started`, when a hook raised something that wasn't a `StandardError` (ex. the `Interrupt` a signal handler raises). Every component is now torn down exactly once, and a component whose hooks already ran is never torn down again

## [0.1.0] - 2026-10-04

- Initial release
