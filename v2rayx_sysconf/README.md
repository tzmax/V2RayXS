# v2rayx_sysconf helper

`v2rayx_sysconf` manages system proxy settings and the tun route whitelist used by V2RayXS.

The current tun implementation is split into two layers:

- a clean-slate daemon that owns the active tun runtime, tun device lifecycle, and active route orchestration
- a CLI layer that parses commands, talks to the daemon over a UNIX socket, and provides diagnostics, history, and cleanup when the daemon is not running

For tun mode, the helper preserves the system default route and installs IPv4 takeover CIDRs instead of switching the default route to `utun`.

## Runtime model

- The daemon is the only source of truth for the current active tun session.
- The daemon starts in a clean state and does not restore old tun sessions from backup files.
- The CLI keeps history and diagnostics behavior separate from runtime truth.
- Active tun sessions use one of two data plane kinds:
  - `embedded`: the daemon starts the embedded tun2socks data plane
  - `fd_handoff`: the daemon creates a tun device, returns its file descriptor, and later activates that daemon-owned lease

## Commands

### Daemon commands

- `v2rayx_sysconf daemon run`: starts the clean-slate daemon and its UNIX control socket.
- `v2rayx_sysconf daemon status [--json]`: prints daemon availability and the current runtime session state.
- `v2rayx_sysconf daemon stop [--json]`: stops the daemon itself. This is different from stopping only the current tun session.

### Tun commands

- `v2rayx_sysconf tun start <socksPort> [--json]`: asks the daemon to start an `embedded` tun session backed by tun2socks.
- `v2rayx_sysconf tun allocate [<utunName>] [--json]`: asks the daemon to create a tun device and return a daemon-owned lease plus the tun file descriptor.
- `v2rayx_sysconf tun activate [<leaseId>] [--json]`: activates the pending daemon-owned lease as an `fd_handoff` tun session.
- `v2rayx_sysconf tun stop [--json]`: stops the current active tun session but keeps the daemon alive.
- `v2rayx_sysconf tun deactivate [--json]`: alias-style session stop used for `fd_handoff` sessions.
- `v2rayx_sysconf tun status [--json]`: prints tun status. When the daemon is running this reports daemon runtime truth; otherwise it falls back to CLI diagnostics/history.
- `v2rayx_sysconf tun cleanup [--json]`: CLI-side cleanup for stale socket, lock, and history artifacts.

### Route commands

- `v2rayx_sysconf route add <ip...> [--json] [--require-active]`: adds IPv4 or IPv6 addresses to the whitelist store and, when possible, the active daemon session.
- `v2rayx_sysconf route del <ip...> [--json] [--require-active]`: removes addresses from the whitelist store and active daemon session.
- `v2rayx_sysconf route list [--json]`: prints the persisted and currently applied whitelist entries.
- `v2rayx_sysconf route clear [--json] [--require-active]`: clears the whitelist store and active daemon session.
- `v2rayx_sysconf route apply [--json]`: applies the persisted store to the active daemon session.
- `v2rayx_sysconf route sync-file <path> [--json] [--require-active]`: replaces the whitelist store with the JSON array stored at `path`.

### Proxy commands

- `v2rayx_sysconf off [--debug]`
- `v2rayx_sysconf auto [--debug]`
- `v2rayx_sysconf global <socksPort> <httpPort> [--debug]`
- `v2rayx_sysconf save [--debug]`
- `v2rayx_sysconf restore [--debug]`

These commands are separate from the tun daemon and continue to manage system proxy settings and proxy backup files.

## Session flow

### Embedded mode

1. Start the daemon with `daemon run`.
2. Start an embedded session with `tun start <socksPort>`.
3. The daemon creates the tun2socks session, resolves the current default egress, installs takeover routes, and applies the persisted whitelist.
4. Stop only the session with `tun stop`.
5. Stop the daemon explicitly with `daemon stop` when needed.

### fd_handoff mode

1. Start the daemon with `daemon run`.
2. Call `tun allocate` to get a daemon-owned lease and a tun file descriptor.
3. Pass the received tun fd to the external data plane process.
4. Call `tun activate [<leaseId>]` to activate the lease and install routes.
5. Stop the session with `tun deactivate` or `tun stop`.

The helper no longer aims to support arbitrary long-term adoption of pre-created external tun devices. The daemon is expected to create and own the tun lease lifecycle.

## Status behavior

### `daemon status`

When the daemon is reachable, `daemon status --json` returns:

- daemon availability
- current session state
- data plane kind
- tun name
- lease id
- socks port for embedded sessions
- nested runtime session status payload

### `tun status`

When the daemon is reachable, `tun status --json` reports current runtime truth, including:

- `session`
- `sessionType`
- `sessionOwner`
- `controlPlane`
- `tunName`
- `leaseId`
- `tunExists`
- `tunUp`
- `defaultGatewayV4/V6`
- `defaultInterfaceV4/V6`
- `ipv4TakeoverRoutes`
- `whitelistPersistedCount`
- `whitelistAppliedCount`
- `lastError`

When the daemon is not reachable, `tun status --json` falls back to CLI diagnostics/history and reports:

- daemon availability
- stale socket / stale lock hints
- whether history files exist
- last recorded error / session type / tun name

## Files

All files live in `~/Library/Application Support/V2RayXS/` unless `V2RAYXS_APP_SUPPORT_PATH` is set for tests.

- `route_whitelist_store.plist`: persisted route whitelist configuration.
- `system_proxy_backup.plist`: saved system proxy state used by proxy commands.
- `system_route_backup.plist`: history and diagnostics snapshot written by tun flows. It is not treated as current runtime truth and is not used to restore daemon state on startup.
- `tun_route.sock`: daemon UNIX control socket.
- `tun_session.lock`: lock file guarding tun start/stop style lifecycle operations.

## Tun route behavior

- The helper preserves the existing IPv4 default route.
- The daemon installs IPv4 takeover CIDRs `0.0.0.0/1` and `128.0.0.0/1` to the active `utun` interface.
- Persisted route whitelist entries are applied as host bypass routes via the current default gateway/interface.
- `tun stop` / `tun deactivate` remove helper-managed takeover routes and applied bypass routes.
- The daemon does not reconstruct the system default route because it does not delete the default route in the first place.

## JSON output

Commands that support `--json` emit a JSON object with `ok`, `message`, and command-specific fields.

- runtime session responses commonly include `session`, `sessionType`, `sessionOwner`, `controlPlane`, `tunName`, and `leaseId`
- daemon status responses include daemon-level fields plus a nested `status` object
- route commands return fields such as `persisted`, `applied`, `pending`, `removed`, `invalid`, or `failed` depending on the operation
- CLI diagnostic status responses include `diagnostics` and `history` instead of daemon runtime truth

## Strict online mode

When `--require-active` is present on `route` mutations, the helper only reports success if it can contact the active daemon session and complete the requested operation. The persisted whitelist store is left untouched on failure.
