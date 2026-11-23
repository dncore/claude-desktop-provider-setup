#!/bin/bash
# managed-by: claude-desktop-provider-setup
#
# Claude Desktop credential helper.
#
# Contract: claude.com/docs/third-party/claude-desktop/credential-helper.md
#   - no arguments are passed, and any that are get ignored
#   - stdout carries the token and nothing else
#   - stderr carries diagnostics only
#   - exit 0 on success
#
# This script holds no credential. It reads the user's existing Claude Code
# settings at every invocation, so a rotated token is picked up on the next
# run without reinstalling or restarting Claude Desktop.
#
# The path below was written by the installer as a single-quoted shell literal.
# No environment variable, argument, or working directory can redirect it.

SETTINGS_FILE=__CDS_SETTINGS_LITERAL__

GONE=3          # usable file, no token
AMBIGUOUS=4     # both variables set, different values
UNREADABLE=6    # missing, unreadable, or a symlink

note() { printf 'credential-helper: %s\n' "$*" >&2; }

# Claude Desktop sets CLAUDE_HELPER_CONTEXT so a helper can decide whether
# interactive sign-in is acceptable. This helper never prompts for any context,
# and it stays silent on success so Desktop's diagnostics log is not filled
# with one line per turn. The context is reported only when something fails.

if [ -z "$SETTINGS_FILE" ]; then
  note "no settings path is configured; reinstall the helper"
  exit "$UNREADABLE"
fi

# Refuse a symlink: a symlink at this path could point the helper at a file an
# attacker controls. -L is lstat, so it fires even when the target exists.
if [ -L "$SETTINGS_FILE" ]; then
  note "refusing to follow a symlink at $SETTINGS_FILE"
  exit "$UNREADABLE"
fi

if [ ! -f "$SETTINGS_FILE" ]; then
  note "settings file not found: $SETTINGS_FILE"
  exit "$UNREADABLE"
fi

if [ ! -r "$SETTINGS_FILE" ]; then
  note "settings file is not readable: $SETTINGS_FILE"
  exit "$UNREADABLE"
fi

read_key() {
  /usr/bin/plutil -extract "$1" raw -o - "$SETTINGS_FILE" 2>/dev/null || true
}

auth="$(read_key env.ANTHROPIC_AUTH_TOKEN)"
key="$(read_key env.ANTHROPIC_API_KEY)"

# Trim leading and trailing whitespace the same way the installer does.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
auth="$(trim "$auth")"
key="$(trim "$key")"

if [ -n "$auth" ] && [ -n "$key" ] && [ "$auth" != "$key" ]; then
  note "both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY are set with different values;"
  note "Claude Desktop can send only one. Re-run the installer with --auth-scheme to choose."
  exit "$AMBIGUOUS"
fi

if [ -n "$auth" ]; then
  printf '%s\n' "$auth"
  exit 0
fi

if [ -n "$key" ]; then
  printf '%s\n' "$key"
  exit 0
fi

note "neither ANTHROPIC_AUTH_TOKEN nor ANTHROPIC_API_KEY is set in $SETTINGS_FILE"
note "context=${CLAUDE_HELPER_CONTEXT:-unset}"
exit "$GONE"
