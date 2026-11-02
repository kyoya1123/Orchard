# Orchard

[English](README.md) | **日本語**

Orchard は、スキームや実行先を選ぶためだけに Xcode を開かなくても、シミュレーターや実機で Xcode アプリをビルド・実行できる macOS のコマンドラインツールです。コーディングエージェントから操作することを想定しています。

git worktree ベースのワークフローを前提に設計されています。一度使ったプロジェクトのリポジトリは自動登録され、各 worktree をブランチ名で指定できます。

## 特徴

- **worktree の自動検出** — 自動登録したリポジトリと、任意で追加したディレクトリからworktree（`git worktree list`）を探索し、それぞれに最も近い `.xcworkspace` / `.xcodeproj` を見つけます。複数ブランチを切り替えなしで同時に動かせます。
- **シミュレーターと実機** — 実行先はあいまいマッチで指定でき、空のbaseから複製したブランチ用Simulatorも使えます。
- **実行(Run)管理** — `run --delegate` はすぐに戻り、バックグラウンドのプロセスがアプリのコンソールに接続し続けます。`runs` で状態を追い、`stop` で終了します。同じ実行先で新しい Run を開始すると前の Run が置き換わります(Xcode の Run ボタンと同じ挙動)。
- **Xcode とビルドキャッシュを共有** — ビルドは標準の DerivedData を使う `xcodebuild` で実行されるため、Orchard と Xcode が互いのビルド成果物を再利用できます。
- **エージェント向けの出力** — あいまいマッチ、安定した終了コード、NDJSON 出力を備えています。

## 空のSimulator base

`orchard run --branch <branch> --scheme <scheme> --branch-simulator` で、ブランチ用Simulatorを自動準備できます。実行時に選択中のXcodeで利用可能なインストール済みiOSを確認し、対応する最新世代のiPhone（同世代ではProを優先）を選びます。機種・iOS・名前が一致する既存Simulatorは再利用し、新規Simulatorは `simctl clone` で複製します。ランタイムのダウンロードは行いません。`--device-type` / `--runtime` の明示指定を優先し、従来の `--destination` 指定の動作は変わりません。

baseは新規作成 → 初回起動完了を待機 → システムアプリのみであることを確認 → 停止、の手順で準備します。アプリのインストールやアプリ用の設定は行いません。通常の実行先に表示されない専用device set（`~/Library/Application Support/Orchard/SimulatorBases-v1/devices`）で管理します。機種・iOSのビルド・Xcodeのビルドとツールパス・初期化方式が一致するbaseは再利用し、変更時に作り直します。

新baseの準備と必要な複製が成功した後、管理台帳にある旧baseを削除します。起動中・名前や機種が変更されたもの・ユーザーアプリの入ったものは残し、診断を表示します。初期化や複製に失敗した場合は旧baseを残します。ブランチ用Simulator、アプリデータ、管理対象外のSimulator（従来の `base` という名前のものも含む）は削除しません。複数プロセスによる同時作成はロックで防ぎます。既存Simulatorの圧縮や、利用中に増えるログの削減を行う機能ではありません。

```bash
# baseだけを準備・更新。アプリのビルドやインストールは行わない
orchard simulator base --json

# ブランチ用Simulatorを準備。標準出力はUDID
orchard simulator ensure --name feature-example

# 最新機種・iOSを自動選択して実行
orchard run --branch feature/example --scheme MyScheme --branch-simulator --delegate
```

`Scripts/ios-run.sh` は従来のskillと互換の引数を持つアダプターです（`[branch-or-device] [scheme] [device-type] [iOS] [delegate|follow]`）。古いskillの `run.sh` を一度この版に更新すれば、以後のbase管理処理はOrchard側の更新で反映されます。機種・iOSの引数を省略すると `latest` を選択します。リポジトリの指示に機種やiOSが固定されている場合は、その指定の更新も必要です。

## Swift Package の容量対策

既存の `DerivedData/SourcePackages` があれば、その場所を引き続き使用します。新しい worktree には `~/Library/Caches/Orchard/SourcePackages-v1/` 配下に専用の依存フォルダを作り、APFS の Copy-on-Write でテンプレートから複製します。テンプレートは Git リポジトリ・`Package.resolved`・選択中の Xcode ごとに識別し、リポジトリごとに最大3世代を保持します。各 worktree の変更は独立しています。

Scheme 一覧・ビルド・成果物確認で同じ依存フォルダを使います。同じプロジェクトへのコマンドは、プロセスをまたいで成果物確認まで順番に実行し、別 worktree の並列ビルドは維持します。標準の DerivedData のビルド先は変わりません。依存解決・ビルドが成功し、固定された Git checkout が未変更で、バイナリの参照先も複製内に収まる場合だけテンプレートを公開します。ローカル・Registry パッケージや未対応の lockfile 形式では通常の Xcode の動作を使います。clone が失敗した場合も通常の依存解決へ戻り、通常コピーによる容量消費は行いません。

新しい worktree での容量増加を抑える機能です。既存の Build 成果物や Simulator データは削減しません。このSPM共有処理は既存の依存フォルダや worktree ごとの編集内容を削除しません。別のバックグラウンド整理処理は期限切れのDerivedDataを削除しますが、変更されたパッケージcheckoutは保護します。無効化する場合は `ORCHARD_SPM_CACHE=0` を設定して Orchard を実行してください。ビルド停止後に `templates/` 配下を削除すると不要なテンプレートを回収できます。`worktrees/` 配下には編集内容が残る可能性があるため、削除前に確認が必要です。

## バックグラウンドでの整理

ブランチ用Simulatorの準備時と、依存解決・ビルドの前後に不要な成果物を確認します。整理はCPU・ディスクI/Oの優先度を下げた別プロセスで動かします。同時に複数回呼ばれても、プロセス間ロックで整理を1つにまとめます。

- 対応するworktreeのディレクトリが存在しない、または最終利用から**7日間**経過したSimulator・DerivedDataを削除対象にします。一覧の再検出では利用日時を更新しません。
- 起動中・起動処理中のSimulatorは常に残し、整理のために終了させることはありません。停止済みのSimulatorのデータディレクトリから動き続けているプロセスは、削除前に終了させます。終了できないプロセスが残った場合は削除しません。標準名の端末、専用base、名前を変更した端末、所有者が分からない端末は保護します。
- Orchardのビルド・Simulator準備・インストール中はロックで保護します。コンソール接続だけでは、worktree消失後の端末を保持し続けません。外部の`xcodebuild`が実行中、Xcodeのビルドサービスが当該DerivedDataを開いている、またはパッケージcheckoutにローカル変更がある場合もDerivedDataの削除を見送ります。
- worktree自体、Gitブランチ、ソースファイルは削除しません。記録したプロジェクトのパスと設定済みリポジトリから所有者を特定し、Codexなど外部にあるworktreeも対象にします。既に消えた外部worktreeは過去の対応記録が必要で、名前だけから所有者を推測しません。

`orchard cleanup --json`で削除候補を確認できます。このコマンドではSimulator停止や成果物の削除を行いません。明示的に整理する場合は`orchard cleanup --apply`を使います。所有者と直近の結果は`~/Library/Application Support/Orchard/Cleanup-v1/`に保存します。特定プロジェクトを除外するには、このディレクトリの`settings.json`に`{"excludedPaths":["/absolute/path/to/project"]}`を設定します。

これは保持期間の制御で、容量の上限ではありません。削除した成果物は次回利用時に再ビルドします。cronやLaunchAgentの登録は不要です。Orchardを使わない間は整理せず、次の利用時に実行します。

## 動作環境

- macOS 14 以降
- Xcode(`xcodebuild`・`simctl`・`devicectl` が使えること)

## インストール

ソースからビルドし、`orchard` を `~/.local/bin` にインストールします（`PATH` 上の別の場所に入れる場合は `ORCHARD_INSTALL_DIR` を指定します）:

```bash
git clone https://github.com/kyoya1123/Orchard.git
cd Orchard
Scripts/install.sh
```

## 使い方

```bash
# ビルド + インストール + 起動(起動したアプリが終了するまでブロック)
orchard run --branch <branch> --scheme <scheme> --destination <name-or-udid> \
  [--device | --simulator] [--delegate] [--timeout <seconds>] [--dir <path> ...] [--json]

# 一覧
orchard list branches [--dir <path> ...] [--json]
orchard list schemes --branch <branch> [--dir <path> ...] [--json]
orchard list destinations [--device | --simulator] [--json]

# Run の確認と停止
orchard runs [--json]        # 記録されたすべての Run を一覧
orchard runs <id> [--json]   # 特定の Run の詳細 + ログを表示
orchard runs <id> --log      # その Run のログだけを出力
orchard stop <id>            # Run を停止し、起動したアプリを終了
```

ブランチ・スキーム・実行先はあいまいマッチで解決されます(完全一致 → 大文字小文字無視 → 前方一致 → 部分一致)。実行先の UDID は完全一致のみです。入力が曖昧な場合は候補が一覧表示されるので、絞り込んで再実行できます。

デフォルトでは `run` はアタッチ実行です。プロセス内でビルド・起動し、アプリのコンソールを stdout にストリームして、アプリが終了するまでブロックします。`--delegate` を付けると、切り離したバックグラウンドのプロセスで実行し、Run が始まった時点で ID を出力して戻ります（`Delegated to Orchard: … · run <id>`）。呼び出し元のシェルが終了しても Run は続きます。`orchard runs <id>` で状態を確認し、`orchard stop <id>` で停止します。状態が `running` で `activityText` が空なら、アプリが起動してコンソールに接続済みです。

出力はエージェントやスクリプトから扱いやすいよう設計されています:

- ビルド・ツールの進捗は **stderr**、起動したアプリのコンソール出力は **stdout** に出ます。
- `--json` は NDJSON イベントを出力します: `{"type":"progress"|"command"|"console"|"result"|"error", ...}`。
- 終了コード: `0` 成功(`orchard stop` や新しい Run による停止を含む)、`2` 見つからない、`3` 曖昧、`4` ビルド・起動失敗、`130` 中断。

Run はすべて `~/Library/Application Support/Orchard/runs/` に記録されます。プロセスが終了済みの記録は `stopped` として表示し、終了した記録は24時間後に削除します。

探索対象の優先順位は `--dir` → `ORCHARD_DIRS`（コロン区切り）→ 現在のXcodeプロジェクト／Gitリポジトリ → 自動登録済みリポジトリと `defaults read dev.codex.Orchard configuredDirectoryPaths` のディレクトリです。現在のリポジトリを優先するため、別リポジトリの同名ブランチがローカル実行に混ざりません。

`run`と`list schemes`は、スキーム一覧の取得やビルドより先に、選択したプロジェクトを登録します。`simulator ensure`は実行フォルダのプロジェクトをSimulator準備前に登録します。ビルドに失敗しても登録は残ります。事前設定や自動登録を無効にするオプションはありません。`list branches`・`list destinations`・`runs`は一覧の参照だけで、プロジェクトを登録しません。Gitを使わないXcodeプロジェクトも登録できます。

登録先は `~/Library/Application Support/Orchard/Repositories-v1/` です。Gitの共通ディレクトリでリポジトリを識別し、worktreeやシンボリックリンク経由の重複を避けます。サブフォルダのプロジェクトはworktreeルートからの相対位置を記録します。最初に登録したworktreeを削除しても、Codexなどの外部worktreeを含む残りのworktreeを探索できます。複数プロセスからの同時登録はプロセスロックとatomic writeで保護します。同じプロジェクトの再実行では登録を書き直しません。追加ディレクトリの設定と、クリーンアップ用の所有者履歴は独立して保持します。

## 開発

```bash
swift test           # テストを実行
Scripts/install.sh   # リリースビルドしてインストール
```

パッケージは 2 つのターゲットで構成されています:

- `OrchardCore` — 探索(git worktree・Xcode プロジェクト)、`xcodebuild` / `simctl` / `devicectl` のオーケストレーション、選択解決、Run ストア。
- `OrchardCLI` — `orchard` コマンド。
