# Orchard

[English](README.md) | **日本語**

Orchard は、スキームや実行先を選ぶためだけに Xcode を開かなくても、シミュレーターや実機で Xcode アプリをビルド・実行できる macOS メニューバーアプリ(兼ヘッドレス CLI)です。

git worktree ベースのワークフローを前提に設計されています。CLIから使ったプロジェクトのリポジトリが自動登録され、各 worktree がブランチ名付きのプロジェクトとして一覧に現れます。プロジェクト・スキーム・実行先を選んで **Build & Run** を押すだけです。

## 特徴

- **メニューバー UI** — プロジェクト(git ブランチ)/スキーム/実行先をコンパクトなフォームで選び、ワンクリックで **Build & Run**。
- **worktree の自動検出** — CLIで自動登録したリポジトリと、任意で追加したディレクトリからworktree（`git worktree list`）を探索し、それぞれに最も近い `.xcworkspace` / `.xcodeproj` を見つけます。複数ブランチを切り替えなしで同時に動かせます。
- **シミュレーターと実機** — 実機とお気に入りのシミュレーターをデフォルトで表示し、その他のシミュレーターもワンクリックで展開できます。お気に入りは記憶されます。
- **実行(Run)管理** — 各 Run が個別のコンソールログと **Stop** / **Rerun** / **Close** ボタン、ステータスを持ちます。Run はプロジェクトごとにグループ化され、同じ実行先で新しい Run を開始すると前の Run が置き換わります(Xcode の Run ボタンと同じ挙動)。
- **ビルドログではなくアプリのコンソールを表示** — ログビューには起動したアプリのコンソール出力が表示されます。Orchard 自身のビルド・インストールの診断ログは別の Console 画面にあります。
- **グローバルホットキー** — 設定でショートカットを登録すると、どのアプリからでも Orchard のウィンドウを開閉できます(アクセシビリティ権限は不要)。
- **Xcode とビルドキャッシュを共有** — ビルドは標準の DerivedData を使う `xcodebuild` で実行されるため、Orchard と Xcode が互いのビルド成果物を再利用できます。
- **自動化向けヘッドレス CLI** — 同じバイナリが `orchard` CLI としても動作し、GUI とまったく同じビルド・インストール・起動パイプラインを実行します。あいまいマッチ、NDJSON 出力、GUI と CLI が互いの Run を参照できる共有 Run ストアを備え、コーディングエージェントから操作されることを想定した設計です。

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

Scheme 一覧・ビルド・成果物確認で同じ依存フォルダを使います。同じプロジェクトへの GUI / CLI のコマンドは成果物確認まで順番に実行し、別 worktree の並列ビルドは維持します。標準の DerivedData のビルド先は変わりません。依存解決・ビルドが成功し、固定された Git checkout が未変更で、バイナリの参照先も複製内に収まる場合だけテンプレートを公開します。ローカル・Registry パッケージや未対応の lockfile 形式では通常の Xcode の動作を使います。clone が失敗した場合も通常の依存解決へ戻り、通常コピーによる容量消費は行いません。

新しい worktree での容量増加を抑える機能です。既存の Build 成果物や Simulator データは削減しません。ビルド中のSPM共有処理は依存フォルダを削除しません。管理対象キャッシュに所有元と依存バージョンを記録し、別の整理処理でworktree消失と未変更の依存物を確認できた場合だけ回収します。記録のない既存キャッシュ、存在するworktreeのキャッシュ、手編集した依存物は保持します。無効化する場合は `ORCHARD_SPM_CACHE=0` を設定して Orchard / CLI を起動してください。ビルド停止後に `templates/` 配下を削除すると不要なテンプレートを回収できます。`worktrees/` 配下には編集内容が残る可能性があるため、削除前に確認が必要です。

## バックグラウンドでの整理

Orchardの起動・再オープン時、GUIからの実行時、CLIの`run`・`list`・`runs`・`simulator`を呼ぶたびに、所有元の分かる端末を確認します。ヘルプとcleanupのプレビューでは削除を予約しません。自動検査は既存の所有記録と`orphaned-devices`だけを使い、期限付きのロック・再試行と要求の集約を備えた別プロセスで動かします。失敗した要求は次回の呼び出しまで保留します。

**関連する全worktreeが消失した端末、または最終使用から24時間を超えた端末**を整理します。ブランチごとの端末は維持します。ビルド・インストール・起動などを使用として記録し、起動しっぱなし・コンソール出力・cleanup列挙では期限を延ばしません。既存iOSはOrchardの使用日時（旧版が取り込んだ実行更新日時を含む保守的な値）、Androidは検証済み起動記録の更新日時を引き継ぎます。作成日時や移行時の現在時刻は使いません。所有元・日時不明、アクセス不能、壊れたリンク、識別情報の不一致は保持します。セッションDB・会話ファイル・プロセス一覧は読みません。

Orchardのビルド中はロックで保護し、処理完了時に最終使用を更新します。外部iOSテストは`orchard device-use --simulator UDID -- xcodebuild ... test`、Androidは`orchard device-use --avd NAME -- ./gradlew ...`で実行すると、その端末を処理終了まで保護します。待機上限は既定2時間、最大24時間です。このラッパーを使わない外部処理はプロセス一覧から推測しません。

iOSの停止・削除前に、端末名とruntimeが一意に一致するDevice Hubの独立したcompactウィンドウだけを、macOS Accessibilityの閉じるボタンで閉じます。`simctl delete`だけではDevice Hubのウィンドウは閉じません。権限が必要なときはOrchardメニューに案内が出ます。「許可を設定」を押すとmacOSの案内とアクセシビリティ設定を開きます。設定でOrchardを許可して戻ると再確認し、対象端末のcleanupを再試行します。許可後はメニューの案内が消え、Settingsには小さな許可済み表示だけが残ります。「後で」で案内を閉じても、歯車のSettings画面から再試行できます。起動・cleanup・CLIだけでは許可ダイアログを出しません。操作は短い期限付きです。タブ・fullウィンドウ・識別不明・権限不足・閉鎖未確認では端末を保持し、Device Hub全体は終了しません。runtime移行でも同じ順序です。

ウィンドウ閉鎖後に対象が起動中なら、iOSはそのUDIDを`simctl`で停止・削除し、Androidは対応するADBシリアルだけを停止して`avdmanager`で削除します。削除直前にworktree・所有元・端末識別子を再確認します。停止を確認できなければ削除せず、他の端末・worktree・ブランチ・ソースは変更しません。端末を削除すると、その中のアプリと保存データも失われます。

```sh
orchard cleanup --scope orphaned-devices --no-discover --json
orchard cleanup --scope orphaned-devices --no-discover --apply --json
```

旧`archived-devices`は互換エイリアスで、アーカイブ情報は読みません。`simulators`は同じ24時間・worktree存在条件をiOSだけに適用します。明示的な`derived-data`・`source-packages`は従来のキャッシュ整理を維持しますが、自動検査では呼びません。明示的なcleanupの既定scopeは`all`です。

プレビューでは停止・削除を行わず、端末ID・名前・状態・保持／削除理由を表示します。所有記録、`last-report.json`、呼び出しの保留・完了記録は`~/Library/Application Support/Orchard/Cleanup-v1/`に保存します。除外は`settings.json`に`{"excludedPaths":["/absolute/path/to/project"]}`を設定します。失敗は`invocation-error.json`に記録し、後の検査が成功したら消去します。隔離テストでは`ORCHARD_DISABLE_BACKGROUND_CLEANUP=1`で自動workerを無効にできます。

cronやLaunchAgentは登録しません。Go・Gradle・npm、DeviceSupport、Simulatorランタイム、ソースworktreeは自動整理の対象外です。

## 動作環境

- macOS 14 以降
- Xcode(`xcodebuild`・`simctl`・`devicectl` が使えること)

## インストール

ソースからビルドします:

```bash
git clone https://github.com/kyoya1123/Orchard.git
cd Orchard
export ORCHARD_SIGNING_IDENTITY="Apple Development: Your Name (Certificate ID)"
Scripts/package-app.sh
open Orchard.app
```

CLI を使う場合は、バンドル内のバイナリを `PATH` にシンボリックリンクします:

```bash
ln -sf "$PWD/Orchard.app/Contents/MacOS/orchard" /usr/local/bin/orchard
```

> アプリ内のCLIと単体バイナリは、自動登録とGUIの設定（`dev.codex.Orchard`）を共有します。`--delegate`でGUIを自動起動する場合はアプリ内のCLIを使います。

## 使い方

### GUI

1. プロジェクトで `orchard run`、`orchard list schemes`、または `orchard simulator ensure` を使うと、そのリポジトリとworktreeがGUIに自動登録されます。
2. メニューバーのOrchardを開きます。設定画面でのフォルダ追加もできますが、必須ではありません。
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

探索対象の優先順位は `--dir` → `ORCHARD_DIRS`（コロン区切り）→ 現在のXcodeプロジェクト／Gitリポジトリ → 自動登録済みリポジトリとGUIで追加したディレクトリです。現在のリポジトリを優先するため、別リポジトリの同名ブランチがローカル実行に混ざりません。

`run`と`list schemes`は、スキーム一覧の取得やビルドより先に、選択したプロジェクトを登録します。`simulator ensure`は実行フォルダのプロジェクトをSimulator準備前に登録します。ビルドに失敗しても登録は残ります。事前設定や自動登録を無効にするオプションはありません。`list branches`・`list destinations`・`runs`は一覧の参照だけで、プロジェクトを登録しません。Gitを使わないXcodeプロジェクトも登録できます。

登録先は `~/Library/Application Support/Orchard/Repositories-v1/` です。Gitの共通ディレクトリでリポジトリを識別し、worktreeやシンボリックリンク経由の重複を避けます。サブフォルダのプロジェクトはworktreeルートからの相対位置を記録します。最初に登録したworktreeを削除しても、Codexなどの外部worktreeを含む残りのworktreeを探索できます。複数CLIからの同時登録はプロセスロックとatomic writeで保護します。GUIはファイル変更を監視し、メインアクターの外で再探索します。同じプロジェクトの再実行では登録を書き直しません。手動のフォルダ設定と、クリーンアップ用の所有者履歴は独立して保持します。

## 開発

```bash
swift test              # テストを実行
ORCHARD_SIGNING_IDENTITY="Apple Development: Your Name (Certificate ID)" Scripts/package-app.sh  # Orchard.app をビルド・パッケージング
```

パッケージは 2 つのターゲットで構成されています:

- `OrchardCore` — 探索(git worktree・Xcode プロジェクト)、`xcodebuild` / `simctl` / `devicectl` のオーケストレーション、選択解決、共有 Run ストア。
- `OrchardApp` — `MenuBarExtra` の GUI と CLI のエントリポイント。

## Xcode・runtime更新時

選択中XcodeのSimulator SDK以上の利用可能runtimeが必要です。未インストールなら`Runtime migration pending`を表示し、旧端末への暗黙のフォールバックやruntime移行による削除を行いません。runtimeパッケージはダウンロード・アンインストールしません。

毎回の呼び出しでruntime識別子・build、Xcode版・build、simctlパス、形式revisionを確認します。新baseの起動・検証・停止成功後に、旧世代のOrchard管理端末だけを個別停止・削除します。ビルド・テスト中や識別不明の端末は保護します。GUI起動・再実行とCLIの明示destinationも管理端末を再解決し、保存された古いUDIDを再利用しません。ブランチ端末は必要時に再作成されます。移行状況はcleanupレポート、削除記録は`SimulatorBases-v1/last-migration.json`に保存します。

パッケージングには、`ORCHARD_SIGNING_IDENTITY`で指定するApple DevelopmentまたはDeveloper ID Applicationの固定証明書が必要です。アプリ全体を組み立てた後に署名・検証します。adhoc署名はビルドごとに識別が変わり、macOSのプライバシー許可を安定して引き継げません。旧adhoc版からの切り替え時には新しい署名のアプリを一度許可する必要がある場合があります。Orchardは設定の変更・リセットを行いません。GUI自身の権限診断は`~/Library/Application Support/Orchard/Diagnostics-v1/gui-accessibility.json`に保存します。
