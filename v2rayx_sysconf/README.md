# v2rayx_sysconf helper

This helper manages system proxy settings and the tun route whitelist used by V2RayXS.

## Commands

- `v2rayx_sysconf tun start <socksPort>`: starts the tun session and the UNIX socket control server.
- `v2rayx_sysconf tun stop [--json]`: stops the active tun session.
- `v2rayx_sysconf tun status [--json]`: reports the current tun session status.
- `v2rayx_sysconf route add <ip...> [--json] [--require-active]`: adds IPv4 or IPv6 addresses to the whitelist store and, when possible, the active tun session.
- `v2rayx_sysconf route del <ip...> [--json] [--require-active]`: removes addresses from the whitelist store and active tun session.
- `v2rayx_sysconf route list [--json]`: prints the persisted and active whitelist entries.
- `v2rayx_sysconf route clear [--json] [--require-active]`: clears the whitelist store and active tun session.
- `v2rayx_sysconf route apply [--json]`: applies the persisted store to the active tun session.
- `v2rayx_sysconf route sync-file <path> [--json] [--require-active]`: replaces the whitelist store with the JSON array stored at `path`.

## Files

- `system_route_backup.plist`: runtime tun session backup and route recovery state.
- `route_whitelist_store.plist`: persisted whitelist configuration.
- `tun_route.sock`: UNIX socket used for tun session control.

All files live in `~/Library/Application Support/V2RayXS/` unless `V2RAYXS_APP_SUPPORT_PATH` is set for tests.

## JSON output

Commands that support `--json` emit a JSON object with `ok`, `message`, and command-specific fields. `route` commands return `persisted`, `applied`, `pending`, `removed`, or `invalid` fields depending on the operation.

## Strict online mode

When `--require-active` is present on `route` mutations, the helper only reports success if it can contact the active tun session and complete the requested operation. The persisted whitelist store is left untouched on failure.
