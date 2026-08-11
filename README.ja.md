# Orchard

[English](README.md) | **日本語**

Orchard は、スキームや実行先を選ぶためだけに Xcode を開かなくても、シミュレーターや実機で Xcode アプリをビルド・実行できる macOS メニューバーアプリ(兼ヘッドレス CLI)です。

git worktree ベースのワークフローを前提に設計されています。リポジトリや worktree が置かれているディレクトリを Orchard に登録すると、各 worktree がブランチ名付きのプロジェクトとして一覧に現れます。プロジェクト・スキーム・実行先を選んで **Build & Run** を押すだけです。

## 特徴

- **メニューバー UI** — プロジェクト(git ブランチ)/スキーム/実行先をコンパクトなフォームで選び、ワンクリックで **Build & Run**。
- **worktree の自動検出** — 登録ディレクトリから git リポジトリと worktree(`git worktree list`)を探索し、それぞれに最も近い `.xcworkspace` / `.xcodeproj` を見つけます。複数ブランチを切り替えなしで同時に動かせます。
- **シミュレーターと実機** — 実機とお気に入りのシミュレーターをデフォルトで表示し、その他のシミュレーターもワンクリックで展開できます。お気に入りは記憶されます。
- **実行(Run)管理** — 各 Run が個別のコンソールログと **Stop** / **Rerun** / **Close** ボタン、ステータスを持ちます。Run はプロジェクトごとにグループ化され、同じ実行先で新しい Run を開始すると前の Run が置き換わります(Xcode の Run ボタンと同じ挙動)。
- **ビルドログではなくアプリのコンソールを表示** — ログビューには起動したアプリのコンソール出力が表示されます。Orchard 自身のビルド・インストールの診断ログは別の Console 画面にあります。
- **グローバルホットキー** — 設定でショートカットを登録すると、どのアプリからでも Orchard のウィンドウを開閉できます(アクセシビリティ権限は不要)。
- **Xcode とビルドキャッシュを共有** — ビルドは標準の DerivedData を使う `xcodebuild` で実行されるため、Orchard と Xcode が互いのビルド成果物を再利用できます。
- **自動化向けヘッドレス CLI** — 同じバイナリが `orchard` CLI としても動作し、GUI とまったく同じビルド・インストール・起動パイプラインを実行します。あいまいマッチ、NDJSON 出力、GUI と CLI が互いの Run を参照できる共有 Run ストアを備え、コーディングエージェントから操作されることを想定した設計です。

## 動作環境

- macOS 14 以降
- Xcode(`xcodebuild`・`simctl`・`devicectl` が使えること)

## インストール

ソースからビルドします:

```bash
git clone https://github.com/kyoya1123/Orchard.git
cd Orchard
Scripts/package-app.sh
open Orchard.app
```

CLI を使う場合は、バンドル内のバイナリを `PATH` にシンボリックリンクします:

```bash
ln -sf "$PWD/Orchard.app/Contents/MacOS/orchard" /usr/local/bin/orchard
```

> `Orchard.app` 内のバイナリを経由して実行することが重要です。素のバイナリには bundle identifier がないため、GUI と設定(スキャンディレクトリやお気に入り)を共有できません。

## 使い方

### GUI

1. メニューバーの Orchard アイコンから設定を開きます。
2. リポジトリや worktree が置かれているスキャンディレクトリを 1 つ以上追加します。
3. プロジェクト・スキーム・実行先を選んで **Build & Run** を押します。

### CLI

```bash
# ビルド + インストール + 起動(起動したアプリが終了するまでブロック)
orchard run --branch <branch> --scheme <scheme> --destination <name-or-udid> \
  [--device | --simulator] [--delegate] [--timeout <seconds>] [--dir <path> ...] [--json]

# 一覧
orchard list branches [--dir <path> ...] [--json]
orchard list schemes --branch <branch> [--dir <path> ...] [--json]
orchard list destinations [--device | --simulator] [--json]

# Run の観察(GUI 起点・CLI 起点の両方)
orchard runs [--json]        # 記録されたすべての Run を一覧
orchard runs <id> [--json]   # 特定の Run の詳細 + ログを表示
orchard runs <id> --log      # その Run のログだけを出力
```

ブランチ・スキーム・実行先はあいまいマッチで解決されます(完全一致 → 大文字小文字無視 → 前方一致 → 部分一致)。実行先の UDID は完全一致のみです。入力が曖昧な場合は候補が一覧表示されるので、絞り込んで再実行できます。

デフォルトでは `run` はアタッチ実行です。プロセス内でビルド・起動し、アプリのコンソールを stdout にストリームして、アプリが終了するまでブロックします。`--delegate` を付けると Run を Orchard アプリに委譲し、CLI は即座に戻ります(Run のライフサイクルは GUI が管理)。

出力はエージェントやスクリプトから扱いやすいよう設計されています:

- ビルド・ツールの進捗は **stderr**、起動したアプリのコンソール出力は **stdout** に出ます。
- `--json` は NDJSON イベントを出力します: `{"type":"progress"|"command"|"console"|"result"|"error", ...}`。
- 終了コード: `0` 成功(GUI からの停止を含む)、`2` 見つからない、`3` 曖昧、`4` ビルド・起動失敗、`130` 中断。

Run はディスク上の Run ストア(`~/Library/Application Support/Orchard/runs/`)を介して双方向に共有されます。CLI の Run は GUI の Runs リストに表示され(そこから停止・再実行も可能)、GUI の Run は `orchard runs` から参照できます。

worktree 探索ディレクトリの優先順位: `--dir` フラグ → 環境変数 `ORCHARD_DIRS`(コロン区切り)→ GUI で設定したディレクトリ。

## 開発

```bash
swift test              # テストを実行
Scripts/package-app.sh  # Orchard.app をビルド・パッケージング
```

パッケージは 2 つのターゲットで構成されています:

- `OrchardCore` — 探索(git worktree・Xcode プロジェクト)、`xcodebuild` / `simctl` / `devicectl` のオーケストレーション、選択解決、共有 Run ストア。
- `OrchardApp` — `MenuBarExtra` の GUI と CLI のエントリポイント。
