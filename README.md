# Apple Container Desktop

Apple Container Desktop is a native macOS AppKit utility for managing Apple's `container` CLI from a quiet desktop interface.

The MVP focuses on local `container` operations: system status, onboarding, containers, images, builds, networks, volumes, registries, machines, and settings. It does not implement Docker Engine API compatibility, a `docker` CLI compatibility layer, Kubernetes management, telemetry, or a fork of Apple's container project.

## Requirements

- Apple silicon Mac
- macOS 26 or later
- Xcode 26 / Swift 6 for development
- Apple `container` CLI installed separately

Install Apple `container` separately from Apple's signed installer package on the GitHub releases page. The app detects `container` from PATH, `/usr/local/bin/container`, `/Library/Apple/usr/bin/container`, or a Settings override; it never installs the CLI automatically.

## Development

Install XcodeGen, then use the root Makefile:

```sh
brew install xcodegen
make generate
make build
make test
make run
```

The app uses `Process` with argument arrays to execute the resolved `container` executable. It does not invoke shell-expanded command strings.

## Implemented MVP scope

- Runtime status: compact sidebar indicator for CLI detection, service status/version/df, service start with explicit kernel-install choice, builder controls, machine state entry, and recent operation history.
- Resources: searchable/sortable object lists and JSON inspect for containers, images, networks, volumes, and registries.
- Operations: command history plus container create/run/start/stop/kill/delete/logs/stats/copy/export/Terminal exec/prune, image pull/build/push/tag/delete/prune, builder start/stop/delete/status, network and volume create/delete/prune, registry login/logout, and machine logs/stop/delete/set-default.
- Settings: CLI executable override, detection details, service status, and read-only runtime properties.

Passwords are passed to `container registry login` through stdin and are not shown in command previews. The app records command previews and exit status locally, but does not collect telemetry.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘R` | Refresh the current surface |
| `⌘F` | Focus search on resource lists |
| `⌘1` ... `⌘6` | Open Containers through Operations |
| `⌘0` | Open Runtime Status |
| `⌘,` | Open Settings |
| `⌘↩` | Start the selected container |
| `⌥⌘S` | Stop the selected container |
| `⌘L` | Show logs for the selected container |

## Distribution

Release builds create an ad-hoc signed DMG:

```sh
make dmg VERSION=0.1.0
```

Maintainers with Developer ID credentials can use:

```sh
cp .env.example .env
make notarize VERSION=0.1.0
```

Public ad-hoc builds may require removing Gatekeeper quarantine after reviewing the source:

```sh
xattr -dr com.apple.quarantine /Applications/AppleContainerDesktop.app
```

Apple `container` is not bundled with the app. Install and update the CLI separately through Apple's release installer.

## Current limitations

- The app is not sandboxed in the MVP because it must execute the external `container` CLI and user-selected paths.
- Long-running progress output is captured into operation results; a richer streamed progress view is planned.
- Terminal exec opens macOS Terminal instead of embedding a PTY.
