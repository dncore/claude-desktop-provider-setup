#!/bin/bash
# Lifecycle test, macOS.
#
# Exercises install, update, verify, backup, restore and uninstall against a
# synthetic home directory: a fake Claude Desktop bundle, a configuration
# library that already holds two other configurations, and a Claude Code
# settings file with a gateway configuration.
#
# This is a local script test. It does not launch Claude Desktop, so it proves
# the tool's file handling, not that the real app accepts the result. See
# docs/architecture.md for what each level of testing does and does not cover.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/src/macos/cli.sh"
STD_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

PASS=0
FAIL=0
FAILED=""

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); FAILED="$FAILED
  - $1"; printf 'FAIL: %s\n' "$1"; }

assert_eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2] got [$3]"; fi; }
assert_file() { if [ -f "$2" ]; then ok; else bad "$1: missing file $2"; fi; }
assert_no_file() { if [ ! -e "$2" ]; then ok; else bad "$1: should not exist: $2"; fi; }
assert_contains() { if printf '%s' "$2" | grep -qF -- "$3"; then ok; else bad "$1: [$(printf '%s' "$2" | head -c 300)] does not contain [$3]"; fi; }

jget() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

run_cli() {
  # run_cli <home> [args...] ; sets RC and OUT
  local home="$1"; shift
  OUT="$(env -i HOME="$home" PATH="$STD_PATH" TMPDIR="${TMPDIR:-/tmp}" \
         /bin/bash "$CLI" "$@" 2>&1)"
  RC=$?
}

main() {
  local home lib state
  home="$(mktemp -d "${TMPDIR:-/tmp}/cds-life.XXXXXX")"
  lib="$home/Library/Application Support/Claude-3p/configLibrary"
  state="$home/Library/Application Support/claude-desktop-provider-setup"

  cleanup() { rm -rf "$home"; }
  trap cleanup EXIT

  mkdir -p "$home/Applications/Claude.app/Contents" "$lib" "$home/.claude"
  cat > "$home/Applications/Claude.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.anthropic.claudefordesktop</string>
<key>CFBundleShortVersionString</key><string>0.0.0-test</string>
</dict></plist>
PLIST

  cat > "$lib/_meta.json" <<'META'
{
  "appliedId": "359f288e-c4ec-4dae-a5ea-a47bcaa38438",
  "entries": [
    { "id": "359f288e-c4ec-4dae-a5ea-a47bcaa38438", "name": "Default" },
    { "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "name": "Team 配置: prod" }
  ]
}
META
  printf '{"inferenceGatewayApiKey":"pre-existing","inferenceProvider":"gateway"}\n' \
    > "$lib/359f288e-c4ec-4dae-a5ea-a47bcaa38438.json"
  printf '{"inferenceProvider":"gateway"}\n' \
    > "$lib/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json"
  local original_meta_before
  original_meta_before="$(cat "$lib/_meta.json")"

  cat > "$home/.claude/settings.json" <<'SET'
{ "model": "top-level-ignored",
  "env": {
    "ANTHROPIC_BASE_URL": "https://gw.example.com/api/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "fake-token-1234567890",
    "ANTHROPIC_MODEL": "gw-default",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "gw-opus",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "gw-sonnet"
  },
  "permissions": { "allow": ["Bash"] } }
SET
  local settings_before
  settings_before="$(cat "$home/.claude/settings.json")"

  # --- install -------------------------------------------------------------
  run_cli "$home" install
  assert_eq "install exit" "0" "$RC"
  assert_contains "install mentions config id" "$OUT" "config id:"

  local id
  id="$(jget "$state/state.json" configId)"
  [ -n "$id" ] && ok || bad "state has no configId"

  assert_file "configuration written" "$lib/$id.json"
  assert_eq "appliedId is ours" "$id" "$(jget "$lib/_meta.json" appliedId)"
  assert_eq "three entries after install" "3" "$(jget "$lib/_meta.json" entries)"
  assert_eq "existing entry name preserved" "Team 配置: prod" \
    "$(jget "$lib/_meta.json" entries.1.name)"
  assert_eq "previous config untouched" "pre-existing" \
    "$(jget "$lib/359f288e-c4ec-4dae-a5ea-a47bcaa38438.json" inferenceGatewayApiKey)"
  assert_eq "no inline secret in ours" "" \
    "$(jget "$lib/$id.json" inferenceGatewayApiKey)"
  assert_eq "helper path recorded" "$state/helper/credential-helper.sh" \
    "$(jget "$lib/$id.json" inferenceCredentialHelper)"
  assert_eq "cli settings untouched" "$settings_before" "$(cat "$home/.claude/settings.json")"

  # --- helper reads live settings, so a rotation needs no reinstall --------
  local helper_out
  helper_out="$("$state/helper/credential-helper.sh" 2>/dev/null)"
  assert_eq "helper returns token" "fake-token-1234567890" "$helper_out"

  /usr/bin/plutil -replace env.ANTHROPIC_AUTH_TOKEN -string "rotated-token-XYZ" \
    "$home/.claude/settings.json"
  helper_out="$("$state/helper/credential-helper.sh" 2>/dev/null)"
  assert_eq "helper returns rotated token" "rotated-token-XYZ" "$helper_out"

  # The test itself just rewrote settings.json, so the "unmodified by the tool"
  # baseline moves with it.
  settings_before="$(cat "$home/.claude/settings.json")"

  # --- verify --------------------------------------------------------------
  run_cli "$home" verify
  assert_eq "verify exit" "0" "$RC"
  assert_contains "verify reports ok" "$OUT" "verify: OK"

  # --- update keeps the same id -------------------------------------------
  run_cli "$home" update
  assert_eq "update exit" "0" "$RC"
  assert_eq "update reuses the id" "$id" "$(jget "$state/state.json" configId)"
  assert_eq "still three entries" "3" "$(jget "$lib/_meta.json" entries)"

  # --- backup and restore --------------------------------------------------
  run_cli "$home" backup
  assert_eq "backup exit" "0" "$RC"
  run_cli "$home" list-backups
  assert_contains "backup is listed" "$OUT" "20"

  # --- uninstall restores the original state ------------------------------
  run_cli "$home" uninstall
  assert_eq "uninstall exit" "0" "$RC"
  assert_eq "appliedId restored" "359f288e-c4ec-4dae-a5ea-a47bcaa38438" \
    "$(jget "$lib/_meta.json" appliedId)"
  assert_eq "entries back to two" "2" "$(jget "$lib/_meta.json" entries)"
  assert_no_file "our configuration removed" "$lib/$id.json"
  assert_no_file "helper removed" "$state/helper/credential-helper.sh"
  assert_no_file "state removed" "$state/state.json"
  assert_eq "pre-existing config still untouched" "pre-existing" \
    "$(jget "$lib/359f288e-c4ec-4dae-a5ea-a47bcaa38438.json" inferenceGatewayApiKey)"
  assert_eq "cli settings still untouched" "$settings_before" \
    "$(cat "$home/.claude/settings.json")"

  # The library must be semantically identical to what we started with.
  local applied ids
  applied="$(jget "$lib/_meta.json" appliedId)"
  ids="$(jget "$lib/_meta.json" entries.0.id),$(jget "$lib/_meta.json" entries.1.id)"
  assert_eq "library restored" "359f288e-c4ec-4dae-a5ea-a47bcaa38438|359f288e-c4ec-4dae-a5ea-a47bcaa38438,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" \
    "$applied|$ids"

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  if [ "$FAIL" -ne 0 ]; then printf 'failed assertions:%s\n' "$FAILED"; exit 1; fi
  exit 0
}

main
