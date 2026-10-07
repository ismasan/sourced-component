## [Unreleased]

- `stop` lifecycle hook: runs when a started component is stopped, and before `teardown` when the root is torn down
- `#defer(key)`: the root's `#start!` skips the component, and everything depending on it
- `#start_component!`, `#stop_component!` and `#restart_component!` start and stop components by key, following the dependency graph
- `components.deferred`, `components.stopping` and `components.stopped` events, and `NotStartedError`
- `#tree` and `#graph` show deferred and stopped components
- `.__component_deps` on classes including an injector: the keys of every component injected into them, including inherited ones

## [0.1.0] - 2026-10-04

- Initial release
