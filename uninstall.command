#!/bin/bash
# Uninstall entry point for macOS.
# Pause rules are the same as install.command; see the comment there.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

/bin/bash "$HERE/src/macos/cli.sh" uninstall --restart "$@"
status=$?

if [ -z "${CDS_NO_PAUSE:-}" ] && [ -t 1 ]; then
  printf '\nPress Return to close this window.'
  read -r -t 300 _ || true
fi
exit "$status"
