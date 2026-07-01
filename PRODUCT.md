# Product

## Register

product

## Users

Apple silicon Mac で Linux コンテナを日常的に使う開発者。エディタ、ブラウザ、ターミナル、Git クライアントを行き来しながら、コンテナの起動、停止、ログ確認、イメージ管理、Dockerfile build、registry 操作を素早く済ませたい。

CLI に慣れているユーザーも対象だが、Apple `container` の全コマンドや JSON 出力を覚えなくても、状態を確認し、安全に操作できることを重視する。

## Product Purpose

Apple Container Desktop は、Apple `container` CLI / Containerization を macOS ネイティブ GUI から管理するための実務ツールである。

成功状態は、Docker Desktop の重さや広告感を持ち込まず、Apple `container` の軽量さと macOS らしい信頼感を保ったまま、Containers、Images、Builds、Networks、Volumes、Registry、System を安全に操作できること。

## Brand Personality

静か、信頼、実務的。

macOS 純正ユーティリティのように、UI は作業の邪魔をしない。過度な装飾ではなく、状態の見やすさ、操作の確実さ、失敗時の復旧しやすさで品質を感じさせる。

## Anti-references

- Docker Desktop の重さ、広告感、導線の詰め込みすぎ。
- 派手な SaaS ダッシュボード風の装飾、過剰なカード、意味のないグラデーション。
- CLI をそのまま貼り付けたような無骨さ。
- 破壊的操作が軽く見える UI。
- 標準 macOS の操作感から外れた独自すぎるフォーム、モーダル、スクロール、ターミナル表現。

## Design Principles

1. 状態を先に見せる。ユーザーが最初に知りたいのは、system service が動いているか、どの container が running か、何が失敗したかである。
2. 操作は軽く、破壊は重く扱う。start / stop / logs はすぐ届き、delete / prune / credential 操作は明確に確認する。
3. CLI の力を隠しすぎない。実行前後の command、stdout / stderr、exit code は必要なときに展開できる。
4. macOS に馴染ませる。見た目の個性より、split view、toolbar、sidebar、sheet、menu、keyboard shortcut の自然さを優先する。
5. 密度は高く、圧迫感は低く。開発者向けの情報量は保ちつつ、広告・販促・余計な装飾を置かない。

## Accessibility & Inclusion

WCAG 2.2 AA と macOS 標準アクセシビリティ対応を基準にする。

- VoiceOver で主要操作、状態、テーブル行、ログ領域を理解できる。
- すべての主要操作をキーボードで実行できる。
- 状態は色だけで伝えず、ラベル、アイコン、テキストを併用する。
- 本文コントラストは WCAG AA 以上、重要な状態・エラー・警告は余裕を持って読み取れる濃度にする。
- reduce motion 設定では、アニメーションを短縮または無効化する。
