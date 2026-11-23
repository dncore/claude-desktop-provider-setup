#!/bin/bash
# Pre-publication sanitisation check.
#
# Scans the working tree for material that must never be published: credentials,
# private gateway hostnames, and personal home-directory paths.
#
# It prints the rule name and a redacted sample, never the matched value, so
# running it can never itself leak a secret into a terminal log or an issue.
#
# Optional local denylist: create .sanitize-local-deny.txt (git-ignored) with
# one literal string per line for anything private to your environment. Those
# strings are matched literally and are never written to this file.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

DENY_FILE="$ROOT/.sanitize-local-deny.txt"
FINDINGS=0
REDACT_LEN=6

# Files that legitimately contain the patterns below.
is_exempt() {
  case "$1" in
    */.git/*) return 0 ;;
    ./LICENSE) return 0 ;;
    # This script necessarily contains the patterns it searches for.
    ./tools/sanitize-check.sh) return 0 ;;
  esac
  return 1
}

list_files() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Tracked files plus untracked-but-not-ignored files. Using only
    # `git ls-files` would report "clean" for a tree that has not been
    # committed yet, which is exactly when secrets are most likely to be
    # sitting around.
    git ls-files --cached --others --exclude-standard
  else
    find . -type f -not -path './.git/*' | sed 's|^\./||'
  fi
}

redact() {
  # redact <string> -> first N characters plus a length marker
  local s="$1"
  local n=${#s}
  if [ "$n" -le "$REDACT_LEN" ]; then printf '<%d chars>' "$n"; return; fi
  printf '%s…<%d chars>' "${s:0:2}" "$n"
}

report() {
  # report <rule> <file> <line> <value>
  FINDINGS=$((FINDINGS + 1))
  printf 'FINDING %-26s %s:%s  %s\n' "$1" "$2" "$3" "$(redact "$4")"
}

scan_pattern() {
  # scan_pattern <rule> <extended-regexp> <min-length-of-group-0-for-redaction>
  local rule="$1" pattern="$2" file line value
  while IFS= read -r f; do
    is_exempt "$f" && continue
    [ -f "$f" ] || continue
    # -I skips binaries; -n gives line numbers; -o prints only the match.
    # grep is given a single file, so it prints "LINE:MATCH" with no filename.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      line="${hit%%:*}"
      value="${hit#*:}"
      report "$rule" "$f" "$line" "$value"
    done < <(LC_ALL=C grep -InEo -e "$pattern" "$f" 2>/dev/null | head -20)
  done < <(list_files)
}

# --- credential shapes -----------------------------------------------------
scan_pattern 'anthropic-api-key'   'sk-ant-[A-Za-z0-9_-]{8,}' 0
scan_pattern 'openai-style-key'    'sk-[A-Za-z0-9]{20,}' 0
scan_pattern 'gateway-user-token'  '\buser_[A-Za-z0-9_-]{16,}' 0
scan_pattern 'aws-access-key'      'AKIA[0-9A-Z]{16}' 0
scan_pattern 'github-token'        'gh[pousr]_[A-Za-z0-9]{30,}' 0
scan_pattern 'slack-token'         'xox[baprs]-[A-Za-z0-9-]{10,}' 0
scan_pattern 'jwt'                 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}' 0
scan_pattern 'private-key-block'   'BEGIN [A-Z ]*PRIVATE KEY' 0
scan_pattern 'bearer-literal'      'Bearer [A-Za-z0-9._-]{20,}' 0

# --- private infrastructure -------------------------------------------------
scan_pattern 'private-host'        '[a-z0-9-]+\.(internal|corp|intranet|lan)\b' 0
scan_pattern 'rfc1918-with-port'   '\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))(\.[0-9]{1,3}){2}:[0-9]{2,5}' 0

# --- personal paths ---------------------------------------------------------
# Only real-looking account names. Doc placeholders are listed as safe.
scan_pattern 'macos-home-path'     '/Users/[A-Za-z0-9._-]+/' 0
scan_pattern 'windows-home-path'   'C:\\\\Users\\\\[A-Za-z0-9._-]+' 0

# --- local denylist ---------------------------------------------------------
if [ -f "$DENY_FILE" ]; then
  while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    case "$needle" in \#*) continue ;; esac
    while IFS= read -r f; do
      is_exempt "$f" && continue
      [ -f "$f" ] || continue
      while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        report 'local-denylist' "$f" "${hit%%:*}" "$needle"
      done < <(LC_ALL=C grep -InF -e "$needle" "$f" 2>/dev/null | head -5)
    done < <(list_files)
  done < "$DENY_FILE"
fi

echo
if [ "$FINDINGS" -eq 0 ]; then
  echo "sanitize-check: clean"
  exit 0
fi
echo "sanitize-check: $FINDINGS finding(s). Do not publish until these are resolved."
echo "Values are redacted above; open the file at the reported line to inspect it locally."
exit 1
