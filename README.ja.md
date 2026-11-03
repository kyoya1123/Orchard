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

baseは機種とruntimeごとに共存します。新baseの準備と必要な複製が成功した後、同じ機種・runtimeの旧baseだけを削除します。起動中の旧baseは停止してから削除します。名前や機種が変更されたもの・ユーザーアプリの入ったものは残し、診断を表示します。初期化や複製に失敗した場合は旧baseを残します。管理対象外のSimulator（従来の `base` という名前のものも含む）は削除しません。複数プロセスによる同時作成はロックで防ぎます。既存Simulatorの圧縮や、利用中に増えるログの削減を行う機能ではありません。

Orchardが複製したブランチ用Simulatorは、Xcodeやsimctlの更新だけでは作り直しません。同じruntimeのビルドが変わった場合だけ、停止中の旧Simulatorを削除して同じ名前で複製し直します。起動中のものはそのまま使い続け、停止後の次回準備で置き換えます。別の機種・runtimeを選んでも、他のSimulatorは削除しません。`--destination` で指定した管理対象Simulatorも同じ手順で解決し直すため、置き換え前の古いUDIDで起動することはありません。

`--runtime` を省略すると、指定機種に対応するインストール済みの最新iOSを選びます。`simctl` のruntime別対応機種一覧を優先し、一覧がない場合は機種の最小・最大runtimeで確認します。対応しない組み合わせは、作成・削除の前に対応runtimeの一覧付きでエラーにします。

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

ブランチ用Simulatorの準備時と、依存解決・ビルドの前後に不要な成果物を確認します。さらに`run`・`list`・`runs`・`simulator`を呼ぶたびに、既存の所有記録だけを使って端末（Simulatorと目印付きのAVD）を確認します。整理はCPU優先度を下げた別プロセスで動かし、`simctl`・`adb`・`avdmanager`の呼び出しだけはutility QoSで実行して停止を防ぎます。同時要求はまとめ、整理中に届いた要求は次の検査で処理します。失敗した要求は`invocation-error.json`に記録して次回の呼び出しまで保留します。

- 対応するworktreeのディレクトリが存在しないSimulator・DerivedDataを削除対象にします。worktreeが残っている場合、DerivedDataは最終利用から**7日間**、停止中のSimulatorは**1日**を超えたもの、またはキャッシュ済みの既定ブランチへマージ済みと確認できたものが対象です。一覧の再検出では利用日時を更新しません。
- 起動中のSimulatorは、所有するworktreeがすべて消えた場合だけ停止して削除します。所有するworktreeがすべて別ブランチに切り替わっている場合（フォルダの使い回し）は停止だけを行い、その後は停止中の規則で整理します。この場合、そのフォルダで開かれているファイルは利用中の根拠にしません。detached HEADやGitの判定に失敗したworktreeは切り替えとみなしません。それ以外で起動中のものは、古さやマージ状況によらず残します。停止後も外部の利用がないかを再確認し、利用があれば停止したまま残します。停止済みのSimulatorのデータディレクトリから動き続けているプロセスは、削除前に終了させます。終了できないプロセスが残った場合は削除しません。標準名の端末、専用base、名前を変更した端末、所有者が分からない端末は保護します。
- 削除するSimulatorのDevice Hubのウィンドウは、名前とruntimeが一意に一致する独立したcompactウィンドウだけを、macOSのアクセシビリティで閉じます。`simctl shutdown`・`delete`だけではウィンドウは閉じません。`orchard`を実行するアプリにアクセシビリティの許可がない場合や、タブ・fullウィンドウ・識別できないウィンドウの場合は閉じずに整理を続け、レポートに`window-left-open`を残します。Device Hub全体は終了しません。
- Orchardのビルド・Simulator準備・インストール中はロックで保護します。コンソール接続だけでは、worktree消失後の端末を保持し続けません。外部のテストなどで端末を使う場合は`orchard device-use --simulator <UDID> -- xcodebuild ... test`のように実行すると、終了まで保護し、最終利用日時も更新します。外部の`xcodebuild`が実行中、Xcodeのビルドサービスが当該DerivedDataを開いている、またはパッケージcheckoutにローカル変更がある場合もDerivedDataの削除を見送ります。
- worktree自体、Gitブランチ、ソースファイルは削除しません。記録したプロジェクトのパスと設定済みリポジトリから所有者を特定し、Codexなど外部にあるworktreeも対象にします。既に消えた外部worktreeは過去の対応記録が必要で、名前だけから所有者を推測しません。

### Device Hubのウィンドウを閉じるためのアクセシビリティ権限

ウィンドウを閉じる操作は、`orchard`を起動したアプリ（Claude Codeのデスクトップアプリなら`Claude`、ターミナルから実行するなら`Terminal`・`Ghostty`・`iTerm`など、Codexなら`Codex`）の権限で行われます。`orchard`本体ではなく、そのアプリにアクセシビリティを許可してください。

1. 次のコマンドで「システム設定 › プライバシーとセキュリティ › アクセシビリティ」を開きます。

   ```bash
   open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
   ```

2. 一覧に対象のアプリがあればスイッチをオンにします。なければ「+」から`/Applications`（Terminalは`/System/Applications/Utilities`）のアプリを追加します。
3. 反映されない場合は、そのアプリを終了して開き直します。

許可した状態は`orchard cleanup --json`で確認できます。Device Hubの起動中に`"target" : "Device Hub windows"`の項目が`"outcome" : "available"`なら許可済み、`"permission-required"`なら未許可です。許可を取り消すには同じ画面でスイッチをオフにします（`tccutil reset Accessibility com.anthropic.claudefordesktop`のようにバンドルIDを指定してリセットもできます）。アクセシビリティは許可したアプリが他のアプリを操作できるようにする権限なので、必要なアプリだけに付けてください。

`orchard cleanup --json`で削除候補を確認できます。このコマンドでは端末の停止や成果物の削除を行いません。各候補には状態と停止の必要性（`requiresShutdown`）を表示します。明示的に整理する場合は`orchard cleanup --apply`を使います。`--scope`で`devices`（Simulatorと目印付きのAVD）・`simulators`・`emulators`・`derived-data`・`source-packages`に限定できます。所有者と直近の結果は`~/Library/Application Support/Orchard/Cleanup-v1/`に保存します。特定プロジェクトを除外するには、このディレクトリの`settings.json`に`{"excludedPaths":["/absolute/path/to/project"]}`を設定します。隔離テストでは`ORCHARD_DISABLE_BACKGROUND_CLEANUP=1`で自動整理を無効にできます。

## Android AVDの整理

OrchardはAndroidエミュレーターの作成や起動を行わず、持ち主が目印を付けたAVDの削除だけを行います。worktree用にAVDを作るツールは、AVDのディレクトリ（`<ANDROID_AVD_HOME>/<name>.avd/`）に、worktreeの絶対パスを書いた`orchard-owner.json`を置きます。

```json
{"worktreePath": "/absolute/path/to/worktree", "branch": "feature/example", "lastUsedAt": 1793000000}
```

`branch`と`lastUsedAt`（Unix秒）は省略できます。AVDを使うたびに書き直すと、利用日時として扱います。

そのworktreeが存在しなくなると、起動中なら対応するADBシリアルだけを`emu kill`で停止し、切断を確認してから`avdmanager delete avd`で削除します。worktreeが`branch`とは別のブランチに切り替わっている場合は、起動中なら停止し、`lastUsedAt`から1日を超えたら削除します。`branch`がない目印やdetached HEADでは、この規則を適用しません。目印のないAVDには一切触れず、名前や起動したディレクトリから所有者を推測しません。目印がシンボリックリンク・読めない・相対パスの場合や、worktreeにアクセスできない場合は残します。経過時間だけでは削除しません。Android SDKは`ANDROID_HOME`・`ANDROID_SDK_ROOT`・`~/Library/Android/sdk`、AVDの保存先は`ANDROID_AVD_HOME`・`~/.android/avd`の順に探します。

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

# 端末
orchard simulator ensure --name <name> [--device-type <type>] [--runtime <runtime>]
orchard device-use --simulator <udid> [--timeout <seconds>] -- <command> ...
orchard cleanup [--apply] [--scope <scope>] [--no-discover]
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
