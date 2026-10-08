#!/usr/bin/env bash
# Usage: run.sh [branch-name|device-name] [scheme] [device-type] [iOS] [delegate|follow]
#        run.sh --status <full-run-id>
set -uo pipefail

RAW_ARG="${1:-}"
ARG_SCHEME="${2:-}"
ARG_DEVICE_TYPE="${3:-}"
ARG_IOS_VERSION="${4:-}"
ARG_MODE="${5:-delegate}"

if [ "$RAW_ARG" = "--status" ]; then
  if [ "$#" -ne 2 ] || [ -z "$ARG_SCHEME" ]; then
    echo 'Usage: run.sh --status <full-run-id>' >&2
    exit 2
  fi
elif [ "$#" -gt 5 ] || { [ "$ARG_MODE" != "delegate" ] && [ "$ARG_MODE" != "follow" ]; }; then
  echo 'mode は delegate または follow を指定してください（引数は最大5個）。' >&2
  exit 2
fi

ORCHARD="$(command -v orchard || true)"
if [ -z "$ORCHARD" ]; then
  for cand in \
    "$HOME/Projects/Orchard/Orchard.app/Contents/MacOS/orchard" \
    "/Applications/Orchard.app/Contents/MacOS/orchard" \
    "$HOME/Applications/Orchard.app/Contents/MacOS/orchard" \
    "$HOME/Projects/Orchard/.build/release/orchard"; do
    [ -x "$cand" ] && ORCHARD="$cand" && break
  done
fi
if [ -z "$ORCHARD" ]; then
  echo 'orchard が見つかりません。Orchard.appの同梱CLIをPATHに通してください。' >&2
  exit 6
fi

if [ "$RAW_ARG" = "--status" ]; then
  "$ORCHARD" runs "$ARG_SCHEME" --json | python3 -c '
import json, sys
try:
    record = json.load(sys.stdin)
except (ValueError, OSError) as error:
    print("runの状態を取得できません: " + str(error), file=sys.stderr)
    sys.exit(2)
if record.get("id") != sys.argv[1]:
    print("取り違えを避けるため、完全なrun IDを指定してください。", file=sys.stderr)
    sys.exit(3)
keys = ("id", "status", "activityText", "branchName", "projectRootPath", "scheme", "destination", "updatedAt")
print(json.dumps({key: record.get(key) for key in keys}, ensure_ascii=False, indent=2))
' "$ARG_SCHEME"
  exit $?
fi

if ! CURRENT_BRANCH=$(git branch --show-current) || [ -z "$CURRENT_BRANCH" ]; then
  echo '現在のGitブランチを確認できません。対象worktreeで実行してください。' >&2
  exit 2
fi

DEVICE_UDID=""
RAW_BRANCH="$CURRENT_BRANCH"
if [ -n "$RAW_ARG" ]; then
  DC_JSON=$(mktemp -t ios-run-devices) || exit 2
  trap 'rm -f "$DC_JSON"' EXIT
  if ! xcrun devicectl list devices --json-output "$DC_JSON" >/dev/null; then
    echo '端末一覧の取得に失敗しました。Simulatorへ切り替えず停止します。' >&2
    exit 2
  fi
  DEVICE_UDID=$(python3 - "$DC_JSON" "$RAW_ARG" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as stream:
        data = json.load(stream)
except (ValueError, OSError) as error:
    print("端末一覧を読み取れません: " + str(error), file=sys.stderr)
    sys.exit(2)
matches = [dev for dev in data.get("result", {}).get("devices", [])
           if dev.get("deviceProperties", {}).get("name") == sys.argv[2]
           and dev.get("hardwareProperties", {}).get("platform") == "iOS"
           and dev.get("hardwareProperties", {}).get("reality") == "physical"]
if len(matches) > 1:
    print("同名の実機が複数あります。対象UDIDを確認してください。", file=sys.stderr)
    sys.exit(3)
if matches:
    dev = matches[0]
    udid = dev.get("hardwareProperties", {}).get("udid")
    if dev.get("connectionProperties", {}).get("tunnelState") != "connected" or not udid:
        print("指定された実機は未接続です。接続・信頼・ロック解除を確認してください。", file=sys.stderr)
        sys.exit(2)
    print(udid)
PY
)
  DEVICE_STATUS=$?
  rm -f "$DC_JSON"
  trap - EXIT
  [ "$DEVICE_STATUS" -eq 0 ] || exit "$DEVICE_STATUS"
  if [ -z "$DEVICE_UDID" ]; then
    if ! git show-ref --verify --quiet "refs/heads/$RAW_ARG"; then
      echo "実機名またはローカルブランチ名に完全一致しません: $RAW_ARG" >&2
      exit 2
    fi
    RAW_BRANCH="$RAW_ARG"
  fi
fi

if [ -n "$DEVICE_UDID" ]; then
  MODE="device"
  DEST="$DEVICE_UDID"
  KIND_FLAG="--device"
else
  MODE="simulator"
  SIM_NAME=$(printf '%s' "$RAW_BRANCH" | tr '/' '-')
  KIND_FLAG="--simulator"
fi

if [ -n "$ARG_SCHEME" ]; then
  SCHEME="$ARG_SCHEME"
else
  SCHEME_LIST=$("$ORCHARD" list schemes --branch "$RAW_BRANCH" --dir "$PWD")
  SCHEME_STATUS=$?
  [ "$SCHEME_STATUS" -eq 0 ] || exit "$SCHEME_STATUS"
  SCHEME_COUNT=$(printf '%s\n' "$SCHEME_LIST" | grep -c .)
  if [ "$SCHEME_COUNT" -eq 1 ]; then
    SCHEME="$SCHEME_LIST"
  elif [ "$SCHEME_COUNT" -eq 0 ]; then
    echo "スキームが見つかりません（branch=${RAW_BRANCH}）。" >&2
    exit 2
  else
    echo '複数のスキームが見つかりました。第2引数で指定してください:' >&2
    printf '%s\n' "$SCHEME_LIST" >&2
    exit 5
  fi
fi

if [ "$MODE" = "simulator" ]; then
  if ! DEST=$("$ORCHARD" simulator ensure --name "$SIM_NAME" \
      --device-type "${ARG_DEVICE_TYPE:-latest}" --runtime "${ARG_IOS_VERSION:-latest}"); then
    echo 'OrchardによるSimulatorの準備に失敗しました。simulator ensure対応版を使用してください。' >&2
    exit 7
  fi
  if [ -z "$DEST" ]; then
    echo 'SimulatorのUDIDを取得できませんでした。' >&2
    exit 7
  fi
fi

RUN_FLAGS=("$KIND_FLAG")
[ "$ARG_MODE" = "delegate" ] && RUN_FLAGS+=(--delegate)
echo "orchard=$ORCHARD" >&2
echo "mode=$MODE run_mode=$ARG_MODE destination=$DEST scheme=$SCHEME branch=$RAW_BRANCH" >&2
exec "$ORCHARD" run --dir "$PWD" --branch "$RAW_BRANCH" --scheme "$SCHEME" --destination "$DEST" "${RUN_FLAGS[@]}"
