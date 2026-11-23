#!/bin/bash
# Command-line entry point, macOS.
# Parses arguments, then dispatches. All behaviour lives in the modules.

set -u

CDS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$CDS_ROOT/src/macos/lib/common.sh"
. "$CDS_ROOT/src/macos/lib/core.sh"
. "$CDS_ROOT/src/macos/config-manager.sh"
. "$CDS_ROOT/src/macos/backup-manager.sh"
. "$CDS_ROOT/src/macos/setup.sh"

CDS_COMMAND="install"
CDS_AUTH_SCHEME_OVERRIDE=""
CDS_CONFIG_NAME=""
CDS_RESTART=0
CDS_PURGE=0
CDS_RESTORE_ARG=""
CDS_BACKUP_LABEL=""
CDS_POSITIONAL=""

cli_usage() {
  cat <<'USAGE_EOF'
claude-desktop-provider-setup — point Claude Desktop at the same gateway as Claude Code

USAGE
  ./install.command [command] [options]

COMMANDS
  install       Read ~/.claude/settings.json and configure Claude Desktop (default)
  update        Re-apply the configuration after the Claude Code settings changed
  verify        Check that the installed configuration is intact and usable
  diagnose      Print a redacted report; safe to paste into an issue
  backup        Take a backup of the Claude Desktop configuration library
  restore       Restore a backup by timestamp, or the most recent one
  list-backups  List available backups
  uninstall     Remove only what this tool created
  plan          Print the resolved plan as JSON and change nothing

OPTIONS
  --auth-scheme bearer|x-api-key  Choose when both token variables are set
  --mapping <path>                Model mapping file (default: config/model-mapping.json)
  --allow-unlisted-models         Let the mapping add model IDs absent from Claude Code
  --allow-http                    Permit an http base URL (loopback testing only)
  --no-model-discovery            Emit modelDiscoveryEnabled=false
  --require-model-discovery       Emit modelDiscoveryEnabled=true
  --deployment-mode 3p|any        Hide the Claude.ai sign-in (default: 3p)
  --helper-ttl <seconds>          Credential helper cache lifetime (default: 900)
  --config-name <name>            Name shown in the Claude Desktop config picker
  --dry-run                       Same as `plan`
  --restart                       Quit and relaunch Claude Desktop afterwards
  --purge                         With uninstall: also delete backups and state
  --verbose                       Extra diagnostics on stderr
  -h, --help                      Show this help

EXIT CODES
  0 ok   2 usage   3 unusable config   4 ambiguity   5 environment   6 write/verify   7 helper
USAGE_EOF
}

cli_need_value() {
  # cli_need_value <option> <remaining-args-count>
  [ "$2" -ge 1 ] || cds_die 2 usage "$1 needs a value"
}

cli_parse() {
  while [ $# -gt 0 ]; do
    case "$1" in
      install|update|verify|diagnose|backup|restore|list-backups|uninstall|plan)
        CDS_COMMAND="$1" ;;
      --print-plan) CDS_COMMAND="plan" ;;
      --dry-run)    CDS_COMMAND="plan" ;;
      --auth-scheme)
        shift; cli_need_value "--auth-scheme" $#
        case "$1" in bearer|x-api-key) CDS_AUTH_SCHEME_OVERRIDE="$1" ;;
          *) cds_die 2 usage "--auth-scheme must be bearer or x-api-key" ;; esac ;;
      --mapping)
        shift; cli_need_value "--mapping" $#
        CORE_MAPPING_PATH="$1" ;;
      --allow-unlisted-models) CORE_ALLOW_UNLISTED=1 ;;
      --allow-http)            CORE_ALLOW_HTTP=1 ;;
      --no-model-discovery)    CORE_DISCOVERY="false" ;;
      --require-model-discovery) CORE_DISCOVERY="true" ;;
      --deployment-mode)
        shift; cli_need_value "--deployment-mode" $#
        case "$1" in 3p|any) CORE_DEPLOYMENT_MODE="$1" ;;
          *) cds_die 2 usage "--deployment-mode must be 3p or any" ;; esac ;;
      --helper-ttl)
        shift; cli_need_value "--helper-ttl" $#
        case "$1" in ''|*[!0-9]*) cds_die 2 usage "--helper-ttl must be a positive integer" ;; esac
        [ "$1" -ge 1 ] || cds_die 2 usage "--helper-ttl must be at least 1"
        CORE_HELPER_TTL="$1" ;;
      --config-name)
        shift; cli_need_value "--config-name" $#
        CDS_CONFIG_NAME="$1" ;;
      --restart) CDS_RESTART=1 ;;
      --purge)   CDS_PURGE=1 ;;
      --verbose) CDS_VERBOSE=1 ;;
      -h|--help) cli_usage; exit 0 ;;
      -*) cds_die 2 usage "unknown argument: $1 (try --help)" ;;
      *)  CDS_POSITIONAL="$1" ;;
    esac
    shift
  done
}

# --- uninstall ------------------------------------------------------------

cli_file_is_ours() {
  # cli_file_is_ours <path>: true when the file carries this tool's marker and
  # lives inside our own state directory.
  local f="$1" state_real file_real
  [ -f "$f" ] || return 1
  case "$f" in
    "$CDS_STATE_DIR"/*) ;;
    *) return 1 ;;
  esac
  grep -q 'managed-by: claude-desktop-provider-setup' "$f" 2>/dev/null || return 1
  # Guard against a symlinked path escaping the state directory.
  state_real="$(cd "$CDS_STATE_DIR" 2>/dev/null && pwd -P)" || return 1
  file_real="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)" || return 1
  case "$file_real/" in
    "$state_real"/*) return 0 ;;
    *) return 1 ;;
  esac
}

cli_uninstall() {
  local id prev helpers helper removed=0
  bm_require_state

  bm_state_get configId;       id="$BM_VALUE"
  bm_state_get previousAppliedId; prev="$BM_VALUE"
  bm_state_get helperFiles;    helpers="$BM_VALUE"
  [ -n "$id" ] || cds_die 6 state-invalid "state.json has no configId"

  if [ "$CDS_DRY_RUN" -eq 1 ]; then
    cds_info "would remove configuration $id and the helper it installed"
    return 0
  fi

  # Back up first: uninstall must be reversible too.
  if [ -d "$CDS_LIBRARY" ]; then
    bm_backup "pre-uninstall"
    cds_note "backup: $BM_DIR"
  fi

  CM_RESTORE_TO="$prev"
  cm_remove "$id"
  if [ "$CM_RESULT_CHANGED" -eq 1 ]; then
    cds_note "removed configuration $id"
    removed=1
  fi

  # helperFiles is a JSON array of absolute paths; read it with plutil.
  local i=0
  while : ; do
    helper="$(/usr/bin/plutil -extract "helperFiles.$i" raw -o - "$CDS_STATE_FILE" 2>/dev/null || true)"
    [ -n "$helper" ] || break
    if cli_file_is_ours "$helper"; then
      rm -f "$helper" && cds_note "removed helper $helper"
    else
      cds_warn helper-not-ours "left in place: $helper"
    fi
    i=$((i + 1))
  done

  if [ "$CDS_PURGE" -eq 1 ]; then
    rm -rf "$CDS_STATE_DIR"
    cds_note "removed $CDS_STATE_DIR (state and all backups)"
  else
    rm -f "$CDS_STATE_FILE"
    cds_note "removed $CDS_STATE_FILE; backups kept in $CDS_BACKUP_ROOT"
    cds_note "run --purge to delete the backups as well"
  fi

  cds_info ""
  if [ "$removed" -eq 1 ]; then
    cds_info "Claude Desktop no longer points at your gateway through this tool."
  else
    cds_info "Nothing of this tool's configuration was present; state cleared."
  fi
  cds_info "Claude Code's own settings were never modified."
  [ "$CDS_RESTART" -eq 1 ] && setup_restart_app
  return 0
}

# --- dispatch -------------------------------------------------------------

main() {
  cli_parse "$@"
  cds_init

  [ "$CDS_COMMAND" = "plan" ] && CDS_PLAN_MODE=1

  # A positional argument is only meaningful for restore.
  if [ -n "$CDS_POSITIONAL" ]; then
    case "$CDS_COMMAND" in
      restore) CDS_RESTORE_ARG="$CDS_POSITIONAL" ;;
      *) cds_die 2 usage "unexpected argument: $CDS_POSITIONAL" ;;
    esac
  fi

  # Fall back to the project's own mapping file when one is checked in.
  if [ -z "$CORE_MAPPING_PATH" ] && [ -f "$CDS_ROOT/config/model-mapping.json" ]; then
    CORE_MAPPING_PATH="$CDS_ROOT/config/model-mapping.json"
  fi

  case "$CDS_COMMAND" in
    plan)
      core_run "$CDS_AUTH_SCHEME_OVERRIDE"
      core_plan_json
      printf '\n' ;;
    install) setup_install install ;;
    update)  setup_install update ;;
    verify)
      setup_verify; exit $? ;;
    diagnose) setup_diagnose ;;
    backup)
      cm_require_library
      bm_backup "${CDS_BACKUP_LABEL:-manual}"
      cds_note "backup written to $BM_DIR" ;;
    list-backups)
      local found=0 d
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        printf '%s\n' "$d"; found=1
      done <<< "$(bm_list)"
      [ "$found" -eq 0 ] && cds_info "no backups" ;;
    restore)
      if [ -n "$CDS_RESTORE_ARG" ]; then bm_restore "$CDS_RESTORE_ARG"
      else
        local latest; latest="$(bm_latest)"
        [ -n "$latest" ] || cds_die 5 backup-missing "no backups to restore"
        bm_restore "$latest"
      fi
      cds_note "restored from $BM_RESTORED" ;;
    uninstall) cli_uninstall ;;
    *) cds_die 2 usage "unknown command: $CDS_COMMAND" ;;
  esac
}

main "$@"
