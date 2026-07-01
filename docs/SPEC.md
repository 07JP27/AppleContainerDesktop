# Apple Container Desktop 仕様書

## 1. 概要

Apple Container Desktop は、Apple が公開している `container` CLI / Containerization 技術を、Docker Desktop のようにデスクトップ GUI から扱えるようにする macOS ネイティブアプリである。

目的は、Apple silicon 上で `container` が提供する OCI イメージ、Linux コンテナ、ビルド、ネットワーク、ボリューム、レジストリ、システムサービスを、CLI を覚えなくても安全に管理できる体験を提供すること。

## 2. 参考リポジトリから踏襲する方針

ビルド、テスト、配布方法は `07JP27/SkimDown` の構成を踏襲する。

- Swift 6 + AppKit のネイティブ macOS アプリとして実装する。
- Xcode プロジェクトは `src/project.yml` から xcodegen で生成する。
- `Makefile` に開発・リリース・DMG 作成・公証用ターゲットを集約する。
- CI は GitHub Actions の `macos-26` runner 上で xcodegen、Debug build、test を実行する。
- Release workflow は `v*` タグまたは `workflow_dispatch` の version input で起動し、Release build、ad-hoc codesign、DMG 作成、GitHub Release 公開を行う。
- Developer ID 証明書を持つメンテナ向けに、ローカルで署名・公証できる `make notarize` を用意する。
- 公開 DMG が ad-hoc 署名の場合は、SkimDown と同様に Gatekeeper / quarantine 解除手順をリリースノートへ明記する。

## 3. 対象環境

### 必須

- Apple silicon Mac
- macOS 26+
- Xcode 26+ / Swift 6 toolchain
- Apple `container` CLI は macOS 標準搭載ではないため、Apple の GitHub Release signed installer package で別途インストール済み、または初回起動時にインストール導線を提示できること

### 開発時

- xcodegen
- GitHub Actions `macos-26`
- Apple Developer Program は公証付き配布を行う場合のみ必須

## 4. プロダクト方針

### MVP の位置づけ

MVP は Docker Engine の完全互換実装ではなく、Apple `container` CLI のデスクトップ管理アプリとして定義する。

ただし、情報設計と用語は Docker Desktop 利用者が理解しやすいように寄せる。主要ナビゲーションは Containers、Images、Networks、Volumes、Registries、Operations、Settings とし、CLI / runtime 状態は sidebar 下部の compact status indicator として扱う。Build は Images の action、Machines は runtime control state として扱う。

### 非目標

- MVP では Docker Engine API 互換 daemon を実装しない。
- MVP では `docker` CLI 互換 layer を実装しない。
- Docker Engine API / `docker` CLI 互換は本仕様の初期スコープに含めず、必要になった場合は別仕様として再検討する。
- MVP では Kubernetes 管理機能を実装しない。
- MVP では Docker Desktop 拡張機構との互換性を提供しない。
- MVP では Apple `container` 本体を fork しない。
- MVP では外部テレメトリを送信しない。

## 5. 主要ユーザー

- Apple silicon Mac で軽量な Linux コンテナを使いたい開発者
- Docker Desktop の GUI 体験に慣れているが、Apple `container` を使いたいユーザー
- OCI イメージの pull / build / push を GUI で扱いたいユーザー
- コンテナのログ、リソース使用量、状態を素早く確認したいユーザー

## 6. 機能要件

### 6.1 初回起動とオンボーディング

- Apple silicon / macOS version を検査する。
- `container` CLI の存在、version、実行パス、インストール元を検出する。
- `container` CLI は以下の順で検出する。
  - ユーザーが Settings で指定した executable path
  - `PATH` 上の `container`
  - GitHub Release installer package の既定インストール先: `/usr/local/bin/container`
  - Apple platform install location: `/Library/Apple/usr/bin/container`
- `container system status --format json` と `container system version --format json` を使い、CLI と system service の状態を表示する。
- `container` が未インストールの場合、GitHub Release signed installer package への外部リンクを表示する。
  - アプリは `container` CLI を同梱せず、自動インストールもしない。
  - Homebrew formula を案内しない。誤った `container` パッケージをインストールするリスクを避ける。
- system service が停止中の場合、`container system start` を実行するボタンを表示する。
- 初回起動時に、ローカル専用・テレメトリなし・管理者権限が必要な操作の扱いを説明する。

### 6.2 ダッシュボード

- system service の running / stopped / unhealthy を表示する。
- CLI version と API server version を表示する。
- `container system df --format json` によるディスク使用量を表示する。
- 最近の container / image / build 操作をローカル履歴として表示する。
- `container system logs` を表示できる入口を提供する。

### 6.3 Containers

- `container list --all --format json` でコンテナ一覧を表示する。
- 状態、名前、ID、イメージ、作成日時、ポート公開、ネットワーク、リソース使用量を一覧で確認できる。
- 詳細画面では `container inspect` の JSON を構造化表示する。
- 以下の操作を提供する。
  - create
  - run
  - start
  - stop
  - kill
  - delete / rm
  - exec
  - logs
  - stats
  - copy / cp
  - export
  - prune
- logs は stream 表示と検索を提供する。
- exec はアプリ内ターミナルまたは macOS Terminal 連携で提供する。

### 6.4 Images

- `container image list --format json` でローカルイメージ一覧を表示する。
- pull / push / tag / delete / prune / inspect を提供する。
- `container build` による Dockerfile build UI を提供する。
- build context、Dockerfile path、tag、platform、build args、secret、progress mode を指定できる。
- pull / push / build は進捗ログを表示し、キャンセル可能にする。

### 6.5 Builder

- `container builder status --format json` を表示する。
- builder start / stop / delete を提供する。
- 大きな build 向けの CPU / memory 設定を Settings から調整できるようにする。

### 6.6 Networks

- `container network list --format json` でネットワーク一覧を表示する。
- create / delete / prune / inspect を提供する。
- subnet、IPv6 prefix、MTU、MAC address など Apple `container` がサポートする設定を UI から指定できるようにする。

### 6.7 Volumes

- `container volume list --format json` でボリューム一覧を表示する。
- create / delete / prune / inspect を提供する。
- コンテナ作成 / 実行時に volume mount を選択できる。

### 6.8 Registry

- `container registry list --format json` でログイン済み registry を表示する。
- login / logout を提供する。
- 認証情報は `container` CLI の既存 credential 管理に委ねる。アプリ側で保存が必要な値は Keychain を使う。

### 6.9 Machines

- `container machine list --format json` で machine 一覧を表示する。
- create / run / inspect / set / set-default / logs / stop / delete を段階的に提供する。
- MVP では一覧、inspect、logs、stop、delete を優先し、create / run の高度なオプション UI は後続で拡張する。

### 6.10 Settings

- `container system property list --format json` を読み取り表示する。
- `container` CLI の executable path、検出結果、インストール元、version を表示する。
- executable path は手動指定でき、無効な path の場合は理由を明示する。
- CPU / memory、network subnet、Rosetta、builder、default machine など、Apple `container` が公開する設定を UI にマッピングする。
- 設定変更は変更内容、実行される CLI command、再起動要否を明示してから実行する。
- app preference は `UserDefaults`、機密値は Keychain に保存する。

## 7. UI/UXデザイン仕様

UI は Docker Desktop の代替品ではなく、Apple `container` CLI を扱う macOS 純正ツールに近い位置づけにする。方向性は `PRODUCT.md` と `DESIGN.md` を視覚・体験の基準とし、実装時はこれらを source of truth として扱う。

### 7.1 デザイン方針

- Register は product。デザインはブランド表現よりタスク遂行を優先する。
- ブランド人格は「静か・信頼・実務的」。
- macOS の sidebar、toolbar、split view、sheet、table、keyboard shortcut を自然に使う。
- Docker Desktop の重さ、広告感、導線の詰め込みすぎを避ける。
- CLI の詳細は隠しすぎず、必要なときに command、stdout / stderr、exit code を展開できる。

### 7.2 画面構成

- 基本 layout は 3 pane 構成にする。
  - Sidebar: Containers、Images、Networks、Volumes、Registries、Operations、Settings と下部 runtime status indicator
  - Main: table、list、form、runtime control、settings
  - Inspector: 選択項目の metadata、JSON inspect、logs、actions
- Runtime detail は主ナビではなく、下部 status indicator から開く。CLI / API server version、disk usage、lifecycle controls を扱う。
- Runtime detail は View > Runtime Status (`⌘0`) からも開ける。runtime は主ナビではないが、service start が必要な場合に keyboard / VoiceOver で到達可能にする。
- Build は top-level object collection ではなく Images の action として扱う。
- Machines は top-level collection ではなく runtime control state として扱う。
- `container` CLI が未検出の場合は、初期画面の Containers に concise install-required state を表示し、GitHub Release signed installer package を案内する。長い runtime 説明を初期画面に出さない。
- Containers / Images / Networks / Volumes / Registries は table-first UI にする。
- Logs、build progress、pull / push progress は terminal-like panel として表示するが、app chrome は macOS native に保つ。

### 7.3 視覚システム

- Theme は light / dark の adaptive 対応を必須にする。
- Color strategy は Restrained。背景・surface はニュートラル、primary は選択・主要操作・進行中操作に限定する。
- canonical color は OKLCH で定義し、Swift 実装では `NSColor` / `Color` の light / dark dynamic color に変換する。
- primary は蜂蜜色 / ochre 系を少量だけ使い、状態色は success / warning / danger / info の semantic role に分ける。
- Typography は SF Pro Text / SF Pro Display / SF Mono を使う。
- type scale は product UI 向けに固定値で設計し、過度な display heading や流動的な hero typography は使わない。

### 7.4 コンポーネント要件

- すべての interactive component は default、hover、focus、active、disabled、loading、error state を持つ。
- Table は検索、filter chip、sort、keyboard row navigation、empty state を持つ。
- Status chip は色だけでなく、label と icon / shape で running、stopped、unhealthy、building、failed を伝える。
- 長時間 operation は progress、command preview、elapsed time、stdout / stderr 展開、cancel、final result を持つ operation row として表示する。
- Create / Run / Build form は progressive disclosure を使い、基本項目と advanced CLI option を分ける。
- Empty state は次の行動を提示する。例: Containers が空なら Run Container、Pull Image への導線を出す。
- Error state は human summary、stderr、exit code、実行 command、次の対処を表示する。

### 7.5 Interaction / Motion

- Motion は状態変化を伝える用途に限定する。
- hover、selection、panel reveal、operation completion は 150-220 ms を目安にする。
- page-load sequence や装飾的な motion は使わない。
- Reduce Motion が有効な場合は不要な animation を無効化し、必要な変化は instant または crossfade にする。
- 破壊的操作は sheet / confirmation で対象名、影響範囲、取り消し可否を明示する。

### 7.6 Accessibility

- WCAG 2.2 AA と macOS 標準アクセシビリティ対応を基準にする。
- VoiceOver で object type、name、state、主要 action を理解できる。
- keyboard だけで navigation、refresh、search、start / stop、logs 表示、settings 表示ができる。
- 状態は色だけで伝えない。
- Logs は autoscroll pause、検索、コピー、等幅表示を提供する。

## 8. 非機能要件

- Swift Concurrency を使い、CLI 実行やログ stream で UI thread を塞がない。
- CLI command は絶対パス解決後に `Process` で実行し、shell 経由で任意文字列を渡さない。
- 失敗時は exit code、stderr、再試行可能性を表示する。
- 破壊的操作は確認 dialog を表示する。
- container name / image reference / registry URL は入力検証する。
- UI は dark mode、keyboard navigation、VoiceOver を考慮する。
- 外部通信は registry / release check などユーザー操作に必要な範囲に限定する。
- テレメトリは送信しない。
- macOS sandbox は配布形態と `container` CLI 操作要件を検証してから採用可否を決める。

## 9. アーキテクチャ

### 9.1 レイヤー

| レイヤー | 役割 |
| --- | --- |
| App | 起動、menu、window、navigation、global error handling |
| UI | AppKit views / view controllers、状態表示、form、dialogs |
| Domain | Container、Image、Network、Volume、Registry、Machine、System models |
| Services | Use case 単位の操作、状態 refresh、operation history |
| CLI Bridge | `container` CLI 実行、JSON decode、streaming、cancellation |
| Persistence | UserDefaults、Keychain、operation history |
| Resources | icon、entitlements、localized strings、help assets |

### 9.2 CLI Bridge

`ContainerCLIClient` を中心に、Apple `container` CLI を型安全に扱う。

- `container` executable path を起動時に検出し、Settings で上書き可能にする。
- list / status / version / df など JSON 対応 command は `--format json` を使用する。
- inspect 系 command は JSON output を decode する。
- logs / build / pull / push は stdout / stderr を stream として扱う。
- command arguments は配列として構築し、shell 展開を使わない。
- command 実行結果は success / failure / cancelled を明確に分ける。

### 9.3 将来の直接 API 利用

MVP は CLI Bridge を採用する。Apple Containerization Swift package の直接利用は、CLI では実現しづらい高度な操作、低遅延の状態取得、または CLI output 互換性の問題が出た段階で検討する。

## 10. リポジトリ構成案

```text
.
├── Makefile
├── PRODUCT.md
├── DESIGN.md
├── README.md
├── README_ja.md
├── SPEC.md
├── .env.example
├── .github/
│   └── workflows/
│       ├── ci.yml
│       └── release.yml
├── scripts/
│   └── launch-smoke-test.sh
└── src/
    ├── project.yml
    └── AppleContainerDesktop/
        ├── App/
        ├── Core/
        ├── CLI/
        ├── Containers/
        ├── Images/
        ├── Networks/
        ├── Volumes/
        ├── Registry/
        ├── Settings/
        ├── Models/
        ├── Utilities/
        └── Resources/
```

## 11. Makefile 仕様

SkimDown と同等の開発体験を提供する。

```make
generate       # src/project.yml から .xcodeproj を生成
build          # Debug build
test           # unit tests
run            # Debug app を起動
launch-check   # GUI smoke test
release        # Release build
notarize       # Release build + Apple notarization
dmg            # Release build + DMG packaging
clean          # build artifacts と生成済み .xcodeproj を削除
docs           # docs site dev server
docs-build     # docs site build
```

想定成果物名:

- Debug app: `build/DerivedData/Build/Products/Debug/AppleContainerDesktop.app`
- Release app: `build/DerivedData/Build/Products/Release/AppleContainerDesktop.app`
- DMG: `build/AppleContainerDesktop-$(VERSION).dmg`
- Notary zip: `build/AppleContainerDesktop-$(VERSION).zip`

## 12. CI 仕様

`.github/workflows/ci.yml`

- trigger: pull request to `master`
- runner: `macos-26`
- steps:
  - checkout
  - Xcode version 表示
  - `brew install xcodegen`
  - `cd src && xcodegen generate`
  - Debug build
  - test
- CI では signing を無効化する。
  - `CODE_SIGN_IDENTITY="-"`
  - `CODE_SIGNING_REQUIRED=NO`
  - `CODE_SIGNING_ALLOWED=NO`

## 13. Release 仕様

`.github/workflows/release.yml`

- trigger:
  - push tags: `v*`
  - workflow_dispatch input: `version`
- permissions:
  - `contents: write`
- runner: `macos-26`
- steps:
  - checkout
  - version 決定
  - Xcode version 表示
  - `brew install xcodegen`
  - Xcode project 生成
  - Release build
  - ad-hoc codesign
  - DMG staging 作成
  - `.app` と `/Applications` symlink を含む compressed DMG 作成
  - `softprops/action-gh-release@v2` で GitHub Release 作成

DMG 名:

```text
AppleContainerDesktop-v${VERSION}.dmg
```

Release note には以下を含める。

- インストール手順
- Applications への drag and drop
- ad-hoc 署名の場合の quarantine 解除手順
- Apple `container` CLI は同梱せず、Apple の GitHub Release installer package で別途インストールが必要であること
- 対応 macOS / Apple silicon 要件

## 14. 公証仕様

ローカル公証用に `.env.example` を提供する。

```text
APPLE_ID=
APPLE_TEAM_ID=
APPLE_APP_PASSWORD=
```

`make notarize` は以下を行う。

- Release build
- `.app` を zip 化
- `xcrun notarytool submit --wait`
- `xcrun stapler staple`

`.env` は gitignore に含め、コミットしない。

## 15. テスト方針

### Unit tests

- CLI argument builder
- JSON decoder
- command failure mapping
- model formatting
- destructive action confirmation policy
- Settings persistence

### Integration tests

- fake `container` executable を使った CLI Bridge tests
- missing-CLI install guidance の tests
- macOS 26 + Apple silicon + `container` installed 環境での opt-in tests
- system status / image list / container list の read-only smoke tests

### GUI smoke test

SkimDown の `launch-smoke-test.sh` と同様に、Release / Debug app を起動し、window が生成されることを確認する。

## 16. 実装マイルストーン

### Phase 1: Foundation

- XcodeGen project
- AppKit app shell
- PRODUCT.md / DESIGN.md に基づく design tokens と component vocabulary
- Makefile
- CI / Release workflow
- CLI Bridge
- Onboarding and system status

### Phase 2: Read-only System and collections

- System
- Containers list / inspect
- Images list / inspect
- Networks / Volumes / Registries read-only views
- loading / empty / error states

### Phase 3: Container operations

- run / create / start / stop / kill / delete
- logs / stats / exec
- destructive action confirmation

### Phase 4: Image and build operations

- pull / push / tag / delete / prune
- Dockerfile build UI
- builder status / start / stop

### Phase 5: Distribution hardening

- app icon / entitlements
- ad-hoc release DMG
- optional Developer ID signing and notarization
- installation docs

## 17. 未決事項

- Apple `container` installer package をアプリ内から直接ダウンロードするか、外部リンクに留めるか。
- Bundle ID と正式アプリ名。
- sandbox を有効化するか。
- docs site を初期から含めるか、README / SPEC のみで始めるか。
- 公開 Release を ad-hoc 署名で始めるか、初回から Developer ID 公証済みにするか。
