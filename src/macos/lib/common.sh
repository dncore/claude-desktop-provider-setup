#!/bin/bash
# Shared shell helpers for the macOS implementation.
# Sourced by every macOS script in this project. Bash 3.2 compatible: macOS
# ships /bin/bash 3.2 and this project must not require Homebrew.

set -u

# ---------------------------------------------------------------------------
# Globals. Initialised by cds_init.
# ---------------------------------------------------------------------------
CDS_TOOL_NAME="claude-desktop-provider-setup"
CDS_TOOL_VERSION="0.1.0"
CDS_TOKEN=""            # never printed, never logged
CDS_WARNINGS=""         # newline separated "kind|detail"
CDS_VERBOSE=0
CDS_DRY_RUN=0
CDS_PLAN_MODE=0        # 1 => failures must be reported as JSON on stdout

cds_init() {
  CDS_HOME="${HOME:?HOME is not set}"
  CDS_SETTINGS="$CDS_HOME/.claude/settings.json"
  CDS_APP_DATA="$CDS_HOME/Library/Application Support/Claude-3p"
  CDS_LIBRARY="$CDS_APP_DATA/configLibrary"
  CDS_STATE_DIR="$CDS_HOME/Library/Application Support/$CDS_TOOL_NAME"
  CDS_STATE_FILE="$CDS_STATE_DIR/state.json"
  CDS_BACKUP_ROOT="$CDS_STATE_DIR/backups"
  CDS_HELPER_DIR="$CDS_STATE_DIR/helper"
  CDS_HELPER="$CDS_HELPER_DIR/credential-helper.sh"
}

# ---------------------------------------------------------------------------
# Output. Every human-facing line goes through cds_redact.
# ---------------------------------------------------------------------------
cds_redact() {
  local s="$1"
  if [ -n "${CDS_TOKEN:-}" ]; then
    # Replace the full token, and also its first 8 characters in case a
    # diagnostic builds a partial string.
    s="${s//"$CDS_TOKEN"/<redacted>}"
    if [ "${#CDS_TOKEN}" -ge 8 ]; then
      s="${s//"${CDS_TOKEN:0:8}"/<redacted>}"
    fi
  fi
  printf '%s' "$s"
}

cds_info() {
  printf '%s\n' "$(cds_redact "$*")"
}

cds_note() {
  printf '  %s\n' "$(cds_redact "$*")"
}

cds_debug() {
  [ "$CDS_VERBOSE" -eq 1 ] || return 0
  printf 'debug: %s\n' "$(cds_redact "$*")" >&2
}

cds_warn() {
  # cds_warn <kind> <detail>
  local kind="$1" detail="${2:-}"
  CDS_WARNINGS="${CDS_WARNINGS}${kind}|${detail}"$'\n'
  printf 'warning: %s%s\n' "$(cds_redact "$kind")" \
    "$( [ -n "$detail" ] && printf ' (%s)' "$(cds_redact "$detail")" )" >&2
}

cds_die() {
  # cds_die <exit-code> <kind> <message...>
  local code="$1" kind="$2"
  shift 2
  printf 'error: %s: %s\n' "$(cds_redact "$kind")" "$(cds_redact "$*")" >&2
  if [ "${CDS_PLAN_MODE:-0}" -eq 1 ]; then
    # The conformance suite consumes a machine-readable failure (SPEC 12).
    printf '{"ok":false,"errors":[{"kind":"%s","code":%s}],"warnings":%s}\n' \
      "$(cds_json_escape "$kind")" "$code" "$(core_warnings_json)"
  fi
  exit "$code"
}

# ---------------------------------------------------------------------------
# JSON emission helpers. Inputs are validated before they reach these, and
# they still escape so that a pathological path cannot corrupt the file.
# ---------------------------------------------------------------------------
cds_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

cds_json_str() {
  printf '"%s"' "$(cds_json_escape "$1")"
}

cds_json_bool() {
  if [ "$1" = "true" ]; then printf 'true'; else printf 'false'; fi
}

# Reject strings that must never reach a JSON string literal even after
# escaping, and reject control characters outright.
cds_assert_clean() {
  # cds_assert_clean <value> <label>
  case "$1" in
    *$'\n'*|*$'\r'*) cds_die 3 invalid-value "$2 contains a newline" ;;
  esac
  # ASCII control characters other than tab.
  if printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    # tab is allowed (it is escaped); anything else is not.
    if printf '%s' "$1" | LC_ALL=C grep -q '[\001-\010\013\014\016-\037\177]'; then
      cds_die 3 invalid-value "$2 contains a control character"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------
cds_has_cmd() { command -v "$1" >/dev/null 2>&1; }

cds_strlen() { printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' '; }

# Render a string as a single-quoted shell literal, so a path containing
# quotes, backticks, $ or spaces can be baked into the generated helper
# without any possibility of being evaluated.
cds_sh_quote() {
  local s="$1"
  s="${s//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

cds_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

cds_os_version() { sw_vers -productVersion 2>/dev/null || printf '0'; }

cds_arch() { uname -m 2>/dev/null || printf 'unknown'; }

# Locate the installed Claude Desktop bundle. Prints the path or nothing.
cds_find_app() {
  # A user-scoped install wins over the system one, which also keeps the test
  # fixtures hermetic on a machine that has the real app installed.
  local candidates=(
    "$CDS_HOME/Applications/Claude.app"
    "/Applications/Claude.app"
  )
  local c
  for c in "${candidates[@]}"; do
    if [ -d "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  # Fall back to Spotlight-free lookup through LaunchServices.
  local found
  found="$(/usr/bin/mdfind "kMDItemCFBundleIdentifier == 'com.anthropic.claudefordesktop'" 2>/dev/null | head -1)"
  if [ -n "$found" ] && [ -d "$found" ]; then printf '%s' "$found"; return 0; fi
  return 1
}

cds_app_version() {
  # cds_app_version <bundle>
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null
}

# Minimum config-library entry id shape enforced by Claude Desktop itself.
cds_valid_uuid() {
  printf '%s' "$1" | LC_ALL=C grep -Eq '^[a-f0-9-]{36}$'
}

cds_new_uuid() {
  local u
  u="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')"
  cds_valid_uuid "$u" || u="$(printf '%s' "$(uuidgen | tr 'A-Z' 'a-z')")"
  printf '%s' "$u"
}
