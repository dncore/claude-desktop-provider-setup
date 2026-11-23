#!/bin/bash
# Entry point for macOS. Double-clickable from Finder and runnable from a
# terminal.
#
# A double-clicked Terminal window closes as soon as the script exits, so keep
# it open for the human reading the result. The guard is deliberately narrow:
# only when stdout is a terminal (so pipes and CI never block), the wait is
# bounded, and CDS_NO_PAUSE=1 disables it entirely.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

/bin/bash "$HERE/src/macos/cli.sh" "$@"
status=$?

if [ -z "${CDS_NO_PAUSE:-}" ] && [ -t 1 ]; then
  printf '\nPress Return to close this window.'
  # Bounded wait: never block forever if nothing is attached to stdin.
  read -r -t 300 _ || true
fi
exit "$status"
