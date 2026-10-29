#!/usr/bin/env bash
# Resets the local dev stack and seeds two accounts, Alice and Bob, with the
# albums and photos in albums.json. Alice creates every album and Bob joins
# the ones marked shared. Every run ends in the same state.
#
#   tools/dev_seed/seed.sh
#
# WARNING: this deletes the local Postgres, Redis and MinIO data, and removes
# Miuchio from both devices.
#
# Devices are iOS simulator names or UDIDs, or Android device IDs from
# `flutter devices` (for example emulator-5554):
#   ALICE_DEVICE   default "iPhone 18 Pro"
#   BOB_DEVICE     default "iPhone 17"
#   SEED_HOST      address the devices use to reach this computer, default
#                  the LAN IP of en0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SEED_DIR="$ROOT/tools/dev_seed"
ALICE_DEVICE="${ALICE_DEVICE:-iPhone 18 Pro}"
BOB_DEVICE="${BOB_DEVICE:-iPhone 17}"
SEED_HOST="${SEED_HOST:-$(ipconfig getifaddr en0 2>/dev/null || true)}"
SEED_PORT=8765
APP_ID=com.freytastic.miuchio

[[ -n "$SEED_HOST" ]] || { echo "Set SEED_HOST to this computer's LAN IP" >&2; exit 1; }
# Dev mode accepts any sign-in code and turns off the rate limits, so the test
# signs in without a real code and creates albums back to back
grep -qE '^APP_ENV=dev$' "$ROOT/.env" ||
  { echo "Set APP_ENV=dev in .env (see .env.example)" >&2; exit 1; }
if ! grep -qE "^S3_PUBLIC_ENDPOINT=http://$SEED_HOST:9000$" "$ROOT/.env"; then
  echo "Warning: S3_PUBLIC_ENDPOINT in .env does not point at $SEED_HOST:9000, so photos may not load" >&2
fi
API="http://$SEED_HOST:8080/api/v1"

say() { printf '\n==> %s\n' "$*"; }

# Matches "iPhone 17 (" or a UDID, so "iPhone 17" never picks "iPhone 17e"
ios_line() {
  xcrun simctl list devices available | grep -E "^ +$1 \(|\($1\)" | head -1
}

is_ios() { [[ -n "$(ios_line "$1")" ]]; }

ios_udid() {
  ios_line "$1" | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}'
}

# Removing the app is enough: on the next install the app wipes any keychain
# items an earlier install left behind
reset_device() {
  if is_ios "$1"; then
    local udid
    udid="$(ios_udid "$1")"
    # Only the ID may reach stdout, since the caller captures it
    {
      xcrun simctl boot "$udid" || true
      xcrun simctl bootstatus "$udid"
      xcrun simctl uninstall "$udid" "$APP_ID" || true
    } >/dev/null 2>&1
    echo "$udid"
  else
    adb -s "$1" uninstall "$APP_ID" >/dev/null 2>&1 || true
    echo "$1"
  fi
}

seed() {
  local device="$1"
  shift
  # --no-uninstall keeps the app, and with it the keys the test just created
  (cd "$ROOT/client" && flutter test integration_test/dev_seed_test.dart \
    -d "$device" \
    --no-uninstall \
    --dart-define=API_BASE_URL="$API" \
    "$@")
}

say "Resetting the server data"
cd "$ROOT"
docker compose down -v
docker compose up -d --build
for _ in $(seq 1 90); do
  curl -sf http://localhost:8080/health >/dev/null && break
  sleep 2
done
curl -sf http://localhost:8080/health >/dev/null || { echo "Server did not become healthy" >&2; exit 1; }

say "Serving albums and photos on port $SEED_PORT"
python3 -m http.server "$SEED_PORT" --bind 0.0.0.0 --directory "$SEED_DIR" >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

say "Resetting the devices"
ALICE="$(reset_device "$ALICE_DEVICE")"
BOB="$(reset_device "$BOB_DEVICE")"

# Bob first: Alice needs his published keys to invite him
say "Seeding Bob on $BOB_DEVICE"
LOG="$(mktemp)"
seed "$BOB" --dart-define=SEED_EMAIL=bob@dev.test --dart-define=SEED_NAME=Bob | tee "$LOG"
BOB_ID="$(grep -oE 'SEED_MIUCHIO_ID=[^[:space:]]+' "$LOG" | tail -1 | cut -d= -f2)"
[[ -n "$BOB_ID" ]] || { echo "Did not get Bob's Miuchio ID" >&2; exit 1; }

say "Seeding Alice on $ALICE_DEVICE"
seed "$ALICE" \
  --dart-define=SEED_EMAIL=alice@dev.test \
  --dart-define=SEED_NAME=Alice \
  --dart-define=SEED_INVITE="$BOB_ID" \
  --dart-define=SEED_URL="http://$SEED_HOST:$SEED_PORT"

cat <<EOF

Done. $(python3 -c "
import json, sys
a = json.load(open(sys.argv[1]))
print(f'{len(a)} albums with {sum(len(x[\"photos\"]) for x in a)} photos. Alice is admin of all, Bob is in {sum(1 for x in a if x.get(\"shared\"))}.')
" "$SEED_DIR/albums.json")

Open each person's app:
  cd client && flutter run -d $ALICE --dart-define=API_BASE_URL=$API   # Alice
  cd client && flutter run -d $BOB --dart-define=API_BASE_URL=$API   # Bob

Both accounts sign in with any 6 digit code: alice@dev.test and bob@dev.test.
EOF
