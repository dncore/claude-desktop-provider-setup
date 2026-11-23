#!/bin/bash
# Install, update, verify and diagnose, macOS.
# Implements src/common/SPEC.md sections 6-11.

SETUP_MIN_MACOS_MAJOR=13
SETUP_HELPER_MARKER="managed-by: claude-desktop-provider-setup"

# --- environment checks ---------------------------------------------------

setup_check_os() {
  local v major
  v="$(cds_os_version)"
  major="${v%%.*}"
  case "$major" in
    ''|*[!0-9]*) cds_die 5 unsupported-os "cannot determine the macOS version ($v)" ;;
  esac
  if [ "$major" -lt "$SETUP_MIN_MACOS_MAJOR" ]; then
    cds_die 5 unsupported-os \
"macOS $v is too old. Claude Desktop declares a minimum of macOS 13; this tool
targets the same floor."
  fi
  SETUP_OS_VERSION="$v"
}

setup_check_arch() {
  SETUP_ARCH="$(cds_arch)"
  case "$SETUP_ARCH" in
    arm64|x86_64) ;;
    *) cds_warn unknown-arch "unrecognised CPU architecture: $SETUP_ARCH" ;;
  esac
}

# setup_check_app [required]
setup_check_app() {
  SETUP_APP="$(cds_find_app || true)"
  if [ -z "$SETUP_APP" ]; then
    SETUP_APP=""
    SETUP_APP_VERSION=""
    if [ "${1:-required}" = "required" ]; then
      cds_die 5 app-not-installed \
"Claude Desktop was not found in /Applications or ~/Applications.
Install it from https://claude.ai/download, launch it once so it creates its
data directory, quit it, and run this installer again.

This tool never downloads or installs Claude Desktop itself."
    fi
    return 0
  fi
  SETUP_APP_VERSION="$(cds_app_version "$SETUP_APP")"
}

setup_check_settings() {
  if [ ! -f "$CDS_SETTINGS" ]; then
    cds_die 3 settings-missing \
"$CDS_SETTINGS was not found. This tool migrates an existing Claude Code
gateway configuration; there is nothing to read. Create that file first."
  fi
}

# Detect an administrator-managed configuration that would override, or
# silently replace, what this tool writes.
setup_check_managed() {
  local machine="/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
  local user="$HOME/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
  if [ -f "$machine" ]; then
    cds_warn managed-profile-present "$machine"
  elif [ -f "$user" ]; then
    cds_warn managed-profile-present "$user"
  fi
}

# --- credential helper ----------------------------------------------------

setup_render_helper() {
  local template="$CDS_ROOT/src/macos/credential-helper.sh"
  local literal content tmp
  [ -f "$template" ] || cds_die 5 missing-file "helper template not found: $template"
  cds_assert_clean "$CDS_SETTINGS" "settings path"
  literal="$(cds_sh_quote "$CDS_SETTINGS")"
  content="$(cat "$template")"
  case "$content" in
    *__CDS_SETTINGS_LITERAL__*) ;;
    *) cds_die 6 helper-template "the helper template has no substitution point" ;;
  esac
  content="${content/__CDS_SETTINGS_LITERAL__/$literal}"

  mkdir -p "$CDS_HELPER_DIR" 2>/dev/null || cds_die 5 io-error "cannot create $CDS_HELPER_DIR"
  chmod 700 "$CDS_HELPER_DIR" 2>/dev/null || true
  tmp="$CDS_HELPER.tmp"
  printf '%s\n' "$content" > "$tmp" || cds_die 6 io-error "cannot write $tmp"

  # Syntactic check before it becomes the live helper.
  /bin/bash -n "$tmp" 2>/dev/null || { rm -f "$tmp"; cds_die 6 helper-syntax "generated helper does not parse"; }

  chmod 700 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$CDS_HELPER" || cds_die 6 io-error "cannot install $CDS_HELPER"
  chmod 700 "$CDS_HELPER" 2>/dev/null || true
}

setup_run_helper() {
  # Runs the installed helper and reports only what is safe to report.
  local out code len
  out="$("$CDS_HELPER" 2>/dev/null)"
  code=$?
  len="$(cds_strlen "$out")"
  SETUP_HELPER_EXIT="$code"
  SETUP_HELPER_LEN="$len"
  unset out
  return 0
}

# --- install / update -----------------------------------------------------

setup_install() {
  # setup_install <mode: install|update>
  local mode="$1" name helpers_json id

  # A dry run only exercises the resolution core. It must work on a machine
  # with no Claude Desktop installed, which is what the conformance suite
  # relies on.
  if [ "$CDS_DRY_RUN" -eq 1 ]; then
    core_run "$CDS_AUTH_SCHEME_OVERRIDE"
    core_plan_json
    printf '\n'
    return 0
  fi

  setup_check_os
  setup_check_arch
  setup_check_app required
  setup_check_settings
  setup_check_managed
  cm_require_library

  core_run "$CDS_AUTH_SCHEME_OVERRIDE"

  if [ "$mode" = "update" ]; then
    bm_require_state
    bm_state_get configId; id="$BM_VALUE"
    bm_state_get configName; name="$BM_VALUE"
    [ -n "$id" ] || cds_die 6 state-invalid "state.json has no configId"
    [ -n "$name" ] || name="Migrated from Claude Code"
    bm_backup "pre-update"
  else
    id=""
    name="${CDS_CONFIG_NAME:-Migrated from Claude Code}"
    case "$name" in *$'\n'*|*$'\r'*) cds_die 3 invalid-value "configuration name contains a newline" ;; esac
    bm_backup "pre-install"
  fi
  cds_note "backup: $BM_DIR"

  setup_render_helper
  cds_note "helper: $CDS_HELPER"

  cm_install "$(core_config_json)" "$name" "$id"

  helpers_json="[\"$(cds_json_escape "$CDS_HELPER")\"]"
  bm_write_state "$CM_RESULT_ID" "$name" "$CM_RESULT_PREV" "$CM_RESULT_META_EXISTED" "$helpers_json"

  setup_post_install_report "$mode"
}

setup_post_install_report() {
  local mode="$1"
  setup_run_helper
  if [ "$SETUP_HELPER_EXIT" -ne 0 ]; then
    cds_die 7 helper-failed \
"The credential helper exited $SETUP_HELPER_EXIT when tested. The configuration
was written, but Claude Desktop will not connect until the helper succeeds.
Run --diagnose for details, or --uninstall to revert."
  fi
  if [ "$SETUP_HELPER_LEN" -lt 1 ]; then
    cds_die 7 helper-failed "The credential helper produced no credential."
  fi

  cds_info ""
  cds_info "Claude Desktop is configured."
  cds_note "provider:   gateway"
  cds_note "base URL:   $(cds_redact "$CORE_BASE_URL")"
  cds_note "auth:       $CORE_AUTH_SCHEME"
  cds_note "credential: helper script (token read from settings.json, $(cds_strlen "$CORE_TOKEN") bytes)"
  cds_note "models:     ${#CORE_MODEL_IDS[@]} configured"
  local i=0
  while [ "$i" -lt "${#CORE_MODEL_IDS[@]}" ]; do
    local suffix=""
    [ -n "${CORE_MODEL_TIER[$i]}" ] && suffix=" ($(cds_redact "${CORE_MODEL_TIER[$i]}"))"
    cds_note "  - $(cds_redact "${CORE_MODEL_IDS[$i]}")$suffix"
    i=$((i + 1))
  done
  cds_note "config id:  $CM_RESULT_ID"

  if [ -n "$CDS_WARNINGS" ]; then
    cds_info ""
    cds_info "Warnings:"
    local line
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      cds_info "  - $(cds_redact "${line%%|*}"): $(cds_redact "${line#*|}")"
    done <<< "$CDS_WARNINGS"
  fi

  cds_info ""
  cds_info "Claude Desktop reads configuration at launch. Restart it to apply:"
  cds_info "  --restart was $( [ "$CDS_RESTART" -eq 1 ] && printf 'given' || printf 'not given' )"
  if [ "$CDS_RESTART" -eq 1 ]; then
    setup_restart_app
  fi
}

setup_restart_app() {
  if ! pgrep -x Claude >/dev/null 2>&1; then
    cds_note "launching Claude Desktop"
    open -a "$SETUP_APP" 2>/dev/null || cds_warn app-launch-failed "could not launch $SETUP_APP"
    return 0
  fi

  # A polite quit needs permission to send Apple Events to Claude, which
  # macOS may prompt for. If that is refused, ask the user to quit rather
  # than force-killing an app that may have unsaved work.
  cds_note "quitting Claude Desktop"
  osascript -e 'quit app "Claude"' >/dev/null 2>&1 || true
  local i=0
  while pgrep -x Claude >/dev/null 2>&1 && [ "$i" -lt 30 ]; do
    sleep 0.2; i=$((i + 1))
  done
  if pgrep -x Claude >/dev/null 2>&1; then
    cds_warn app-still-running \
      "Claude Desktop is still running. Quit it from its menu (Cmd+Q), then reopen it."
    return 0
  fi
  cds_note "launching Claude Desktop"
  open -a "$SETUP_APP" 2>/dev/null || cds_warn app-launch-failed "could not launch $SETUP_APP"
}

# --- verify ---------------------------------------------------------------

setup_verify() {
  local failures=0
  setup_check_os
  setup_check_app required
  bm_require_state
  cm_require_library

  bm_state_get configId; local id="$BM_VALUE"
  bm_state_get baseUrl;  local want_url="$BM_VALUE"
  bm_state_get authScheme; local want_scheme="$BM_VALUE"
  bm_state_get helperFiles; local helper_files="$BM_VALUE"

  cds_info "verify"
  cds_note "Claude Desktop: $SETUP_APP ($SETUP_APP_VERSION)"

  # 1. the configuration file exists and parses
  if [ -f "$CDS_LIBRARY/$id.json" ]; then
    cds_note "config file: present ($id.json)"
  else
    cds_note "config file: MISSING ($id.json)"
    failures=$((failures + 1))
  fi
  if /usr/bin/plutil -convert json -o /dev/null "$CDS_LIBRARY/$id.json" 2>/dev/null; then
    cds_note "config parses: yes"
  else
    cds_note "config parses: NO"
    failures=$((failures + 1))
  fi

  # 2. the library actually applies it
  local applied
  applied="$(/usr/bin/plutil -extract appliedId raw -o - "$CDS_LIBRARY/_meta.json" 2>/dev/null || true)"
  if [ "$applied" = "$id" ]; then
    cds_note "applied: yes"
  else
    cds_note "applied: NO (appliedId is '$applied')"
    failures=$((failures + 1))
  fi

  # 3. the live config still matches the plan
  local live_url live_scheme
  live_url="$(/usr/bin/plutil -extract inferenceGatewayBaseUrl raw -o - "$CDS_LIBRARY/$id.json" 2>/dev/null || true)"
  live_scheme="$(/usr/bin/plutil -extract inferenceGatewayAuthScheme raw -o - "$CDS_LIBRARY/$id.json" 2>/dev/null || true)"
  if [ "$live_url" = "$want_url" ]; then
    cds_note "base URL: matches"
  else
    cds_note "base URL: DRIFTED"
    failures=$((failures + 1))
  fi
  if [ "$live_scheme" = "$want_scheme" ]; then
    cds_note "auth scheme: matches"
  else
    cds_note "auth scheme: DRIFTED"
    failures=$((failures + 1))
  fi

  # 4. no secret leaked into the configuration
  if /usr/bin/plutil -extract inferenceGatewayApiKey raw -o - "$CDS_LIBRARY/$id.json" >/dev/null 2>&1; then
    cds_note "no inline secret: NO (inferenceGatewayApiKey is present)"
    failures=$((failures + 1))
  else
    cds_note "no inline secret: yes"
  fi

  # 5. the helper works
  if [ -x "$CDS_HELPER" ]; then
    setup_run_helper
    if [ "$SETUP_HELPER_EXIT" -eq 0 ] && [ "$SETUP_HELPER_LEN" -ge 1 ]; then
      cds_note "helper: ok (exit 0, credential $SETUP_HELPER_LEN bytes)"
    else
      cds_note "helper: FAILED (exit $SETUP_HELPER_EXIT)"
      failures=$((failures + 1))
    fi
  else
    cds_note "helper: MISSING or not executable"
    failures=$((failures + 1))
  fi

  # 6. a managed profile would take precedence
  if [ -f "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist" ]; then
    cds_note "managed profile: PRESENT — it overrides this configuration"
    failures=$((failures + 1))
  else
    cds_note "managed profile: absent"
  fi

  cds_info ""
  if [ "$failures" -eq 0 ]; then
    cds_info "verify: OK"
    return 0
  fi
  cds_info "verify: $failures check(s) failed"
  return 6
}

# --- diagnose -------------------------------------------------------------

setup_diagnose() {
  local v
  cds_info "claude-desktop-provider-setup $CDS_TOOL_VERSION"
  cds_info ""
  cds_info "environment"
  cds_note "macOS: $(cds_os_version) ($(cds_arch))"
  cds_note "home: $CDS_HOME"
  setup_check_app optional
  if [ -n "$SETUP_APP" ]; then
    cds_note "Claude Desktop: $SETUP_APP version ${SETUP_APP_VERSION:-unknown}"
  else
    cds_note "Claude Desktop: not installed"
  fi
  cds_note "bash: $BASH_VERSION"

  cds_info ""
  cds_info "Claude Code settings"
  if [ -f "$CDS_SETTINGS" ]; then
    cds_note "path: $CDS_SETTINGS"
    local kp k
    for kp in env.ANTHROPIC_BASE_URL env.ANTHROPIC_AUTH_TOKEN env.ANTHROPIC_API_KEY \
              env.ANTHROPIC_MODEL env.ANTHROPIC_DEFAULT_OPUS_MODEL \
              env.ANTHROPIC_DEFAULT_SONNET_MODEL env.ANTHROPIC_DEFAULT_HAIKU_MODEL \
              env.ANTHROPIC_DEFAULT_FABLE_MODEL model; do
      v="$(core_settings_get "$kp")"
      if [ -n "$v" ]; then
        case "$kp" in
          *TOKEN*|*API_KEY*) cds_note "$kp: set ($(cds_strlen "$v") bytes)" ;;
          *) cds_note "$kp: set" ;;
        esac
      else
        cds_note "$kp: unset"
      fi
    done
    if /usr/bin/plutil -convert json -o /dev/null "$CDS_SETTINGS" 2>/dev/null; then
      cds_note "parses: yes"
    else
      cds_note "parses: NO"
    fi
  else
    cds_note "path: $CDS_SETTINGS (absent)"
  fi

  cds_info ""
  cds_info "credential helper"
  if [ -x "$CDS_HELPER" ]; then
    cds_note "path: $CDS_HELPER"
    setup_run_helper
    cds_note "exit: $SETUP_HELPER_EXIT, credential bytes: $SETUP_HELPER_LEN"
  else
    cds_note "not installed"
  fi

  cds_info ""
  cds_info "installed state"
  if [ -f "$CDS_STATE_FILE" ]; then
    cds_note "state: $CDS_STATE_FILE"
    bm_state_get configId;        cds_note "configId: $BM_VALUE"
    bm_state_get configName;      cds_note "configName: $BM_VALUE"
    bm_state_get baseUrl;         cds_note "baseUrl: $(cds_redact "$BM_VALUE")"
    bm_state_get authScheme;      cds_note "authScheme: $BM_VALUE"
    bm_state_get tokenLength;     cds_note "tokenLength: $BM_VALUE"
  else
    cds_note "state: not installed"
  fi

  cds_info ""
  cds_info "configuration library"
  if [ -d "$CDS_LIBRARY" ]; then
    cds_note "path: $CDS_LIBRARY"
    if [ -f "$CDS_LIBRARY/_meta.json" ]; then
      local applied
      applied="$(/usr/bin/plutil -extract appliedId raw -o - "$CDS_LIBRARY/_meta.json" 2>/dev/null || true)"
      cds_note "appliedId: ${applied:-<empty>}"
    fi
  else
    cds_note "path: $CDS_LIBRARY (absent)"
  fi

  cds_info ""
  cds_info "managed configuration"
  if [ -f "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist" ]; then
    cds_note "machine profile: PRESENT (it wins over this tool's configuration)"
  else
    cds_note "machine profile: absent"
  fi
  if [ -f "$HOME/Library/Managed Preferences/com.anthropic.claudefordesktop.plist" ]; then
    cds_note "user profile: PRESENT"
  else
    cds_note "user profile: absent"
  fi

  cds_info ""
  cds_info "backups"
  local any=0 d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    cds_note "$d"
    any=1
  done <<< "$(bm_list)"
  [ "$any" -eq 0 ] && cds_note "none"

  cds_info ""
  cds_info "application log (errors only, last 20 matches)"
  local log="$CDS_APP_DATA/logs/main.log"
  [ -f "$log" ] || log="$HOME/Library/Logs/Claude/main.log"
  if [ -f "$log" ]; then
    cds_note "path: $log"
    grep -iE 'managed-settings|configLibrary|invalid|schema|error' "$log" 2>/dev/null \
      | tail -20 | while IFS= read -r v; do cds_note "  $(cds_redact "$v")"; done
  else
    cds_note "no log found"
  fi
}
