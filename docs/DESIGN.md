# Design

## Mood

Apple silicon の開発者が、明るい作業部屋でも夜の暗いデスクでも、エディタとターミナルの隣で常時開いておける静かな管理ツール。

UI は macOS 純正ユーティリティのように控えめで、状態・ログ・実行結果の信頼性を最優先する。ブランド感は大きな装飾ではなく、余白、階層、正確な状態表現、少量の蜂蜜色アクセントで出す。

## Color Strategy

Restrained。背景とパネルは macOS に馴染むニュートラルを基本にし、primary は現在選択、主要アクション、進行中の操作だけに使う。アクセント使用量は画面全体の 10% 以下に抑える。

Canonical color values are specified in OKLCH. Swift 実装ではこの設計値を元に `NSColor` / `Color` の light / dark dynamic color にマッピングする。

### Light

```css
--color-bg: oklch(1.000 0.000 0);
--color-surface: oklch(0.978 0.000 0);
--color-sidebar: oklch(0.955 0.006 260);
--color-border: oklch(0.875 0.006 260);
--color-ink: oklch(0.215 0.018 260);
--color-muted: oklch(0.485 0.014 260);
--color-primary: oklch(0.640 0.130 77);
--color-primary-soft: oklch(0.940 0.040 77);
--color-accent: oklch(0.420 0.090 255);
--color-success: oklch(0.545 0.125 150);
--color-warning: oklch(0.690 0.130 77);
--color-danger: oklch(0.560 0.165 28);
--color-info: oklch(0.530 0.110 250);
```

### Dark

```css
--color-bg: oklch(0.105 0.000 0);
--color-surface: oklch(0.165 0.004 260);
--color-sidebar: oklch(0.135 0.004 260);
--color-border: oklch(0.300 0.006 260);
--color-ink: oklch(0.925 0.004 260);
--color-muted: oklch(0.700 0.010 260);
--color-primary: oklch(0.720 0.120 77);
--color-primary-soft: oklch(0.250 0.045 77);
--color-accent: oklch(0.700 0.080 255);
--color-success: oklch(0.690 0.120 150);
--color-warning: oklch(0.760 0.120 77);
--color-danger: oklch(0.690 0.145 28);
--color-info: oklch(0.710 0.100 250);
```

## Typography

- UI font: SF Pro Text / system default.
- Display use: SF Pro Display only for window-level empty states and onboarding headings.
- Monospace: SF Mono for container IDs, image digests, command previews, logs, environment variables, paths.
- Type scale is fixed, not fluid: 11, 12, 13, 15, 17, 22, 28.
- Tables and sidebars use 12-13 pt. Detail panels use 13-15 pt. Onboarding and empty states can use 22-28 pt.
- Long descriptions stay within 65-75 characters per line where practical.

## App Shell

The app uses a three-zone macOS layout.

1. Sidebar: Containers, Images, Networks, Volumes, Registries, Operations, Settings, plus a compact runtime status indicator at the bottom.
2. Primary content: object table, build form, operation history, settings surface, or runtime detail when opened from the status indicator.
3. Detail / inspector: selected item summary, JSON inspect, logs, actions, metadata.

The titlebar stays quiet: global actions live in menus and navigation rather than duplicated titlebar icons. Refresh is available from View > Refresh / Command-R; Settings remains available from the sidebar and app menu. Destructive actions never sit as a titlebar action.

## Navigation

- Runtime is not a primary navigation item. It is a compact bottom status indicator; opening it shows CLI availability, service health, versions, disk usage, and lifecycle controls.
- The compact runtime status indicator always names runtime state. If Apple container CLI is missing, the indicator says the runtime is unavailable and the Runtime screen explains that the missing CLI is the cause.
- Runtime remains keyboard-accessible from View > Runtime Status (`⌘0`) because it can contain required service-start controls.
- The default surface is Containers. If `container` is missing, resource lists show a concise install-required state with Apple's signed GitHub Release installer package as the primary path.
- Containers uses a table-first layout with a persistent detail inspector.
- Images uses table + tag / digest metadata + pull / push / build operations.
- Build image is an Images action with command preview and streamed progress output, not a top-level collection.
- Machines and builder controls are technical runtime details and stay out of the default Runtime screen.
- Operations exposes command history and execution results.
- Logs and exec use a terminal-like panel but keep app chrome native.
- Settings groups runtime properties, CLI path, service control, resource defaults, and accessibility preferences.

## Component System

### Tables

Tables are the default for containers, images, networks, volumes, and registries. Each table supports search, filter chips, sortable columns, keyboard row navigation, and empty states.

### Status chips

Status chips combine shape, text, and semantic color. Running, stopped, unhealthy, building, pulling, pushing, failed, and unknown must be distinguishable without relying on color alone.

### Operation rows

Long-running operations appear as rows with progress, command preview, elapsed time, stdout / stderr expansion, cancel when supported, and final result.

### Technical details

Raw command output and JSON are hidden by default on primary screens. Surface them for failures, explicit technical-detail disclosure, or Operations / inspector contexts. The default UI should show state, value, and next action before implementation details.

### Forms

Create / run / build forms use progressive disclosure. Common fields are visible first; advanced CLI options are collapsed but searchable. Before execution, the generated `container ...` command can be inspected.

### Empty states

Empty states teach the next action. For example, an empty Containers screen should offer Run Container, Pull Image, and View system status instead of only saying there are no containers.

The missing-CLI empty state is not an error wall. It should explain that Apple `container` is not bundled with the app, point to Apple's signed GitHub Release installer package, show the expected detected paths, and make clear that the app never installs packages automatically.

### Errors

Errors show the human summary first, then stderr, exit code, command, and suggested next action. Permission and service-state errors must explain whether the user needs to start the service, install `container`, or grant administrator approval.

## Motion

- 150-220 ms for hover, selection, panel reveal, and operation completion.
- Motion conveys state changes only: row insertion, progress completion, sheet presentation, status changes.
- No decorative page-load sequences.
- Reduce Motion disables nonessential transitions and keeps state changes instant or crossfaded.

## Accessibility

- WCAG 2.2 AA minimum.
- All interactive controls have default, hover, focus, active, disabled, loading, and error states.
- Keyboard shortcuts mirror macOS expectations: refresh, open settings, focus search, start / stop selected container, show logs.
- VoiceOver labels include object type and state, e.g. "container web, running, image nginx latest".
- Logs are readable by assistive technology and support pause autoscroll.

## Anti-patterns

- No marketing cards inside the product shell.
- No decorative glass panels.
- No gradient text.
- No side-stripe accent cards.
- No hero metric dashboard template.
- No custom controls when native AppKit controls communicate the task better.
- No hidden destructive operations behind ambiguous icons.
