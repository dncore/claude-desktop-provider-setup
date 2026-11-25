#!/bin/bash
# magpie bridge, macOS implementation.
# Implements src/common/SPEC.md section 13: export the provider this machine's
# Claude Code already uses into the format magpie can import.
#
# The token never leaves ~/.claude/settings.json: the import link is built
# without it and magpie asks for it once, in its own prompt.

MAGPIE_BIN=""
MAGPIE_VERSION=""
MAGPIE_NAME=""
MAGPIE_ROOT=""
MAGPIE_MODELS=""
MAGPIE_LINK=""

# magpie_detect -> MAGPIE_BIN when one is found.
magpie_detect() {
  local candidate
  MAGPIE_BIN=""
  MAGPIE_VERSION=""
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ -x "$candidate" ]; then MAGPIE_BIN="$candidate"; break; fi
  done <<EOF
$(command -v magpie 2>/dev/null || true)
$HOME/.local/bin/magpie
/usr/local/bin/magpie
/opt/homebrew/bin/magpie
EOF
  if [ -n "$MAGPIE_BIN" ]; then
    MAGPIE_VERSION="$("$MAGPIE_BIN" --version 2>/dev/null | head -1 || true)"
  fi
}

# magpie_default_name <host> -> a short, ASCII provider name.
# console.eu.example.com -> example; api.anthropic.com -> anthropic.
magpie_default_name() {
  local host="$1" rest last
  case "$host" in
    *:*) host="${host%%:*}" ;;
  esac
  case "$host" in
    ''|localhost|127.0.0.1) printf 'local'; return 0 ;;
  esac
  case "$host" in
    *.*)
      rest="${host%.*}"
      last="${rest##*.}"
      case "$last" in '') printf '%s' "${host%%.*}"; return 0 ;; esac
      printf '%s' "$last" ;;
    *) printf '%s' "$host" ;;
  esac
}

# magpie_anthropic_root <base-url> -> the Anthropic Messages root magpie wants.
# SPEC 13.2: strip a trailing /v1/messages, then a trailing /v1, then any
# trailing slash. magpie appends /v1/messages itself.
magpie_anthropic_root() {
  local url="$1"
  while :; do
    case "$url" in
      */) url="${url%/}" ;;
      *) break ;;
    esac
  done
  case "$url" in
    */v1/messages) url="${url%/v1/messages}" ;;
    */v1) url="${url%/v1}" ;;
  esac
  printf '%s' "$url"
}

# magpie_models_csv -> CORE_MODEL_IDS joined with commas, in tier order.
magpie_models_csv() {
  local i=0 out=""
  while [ "$i" -lt "${#CORE_MODEL_IDS[@]}" ]; do
    [ -n "${CORE_MODEL_IDS[$i]}" ] || { i=$((i + 1)); continue; }
    if [ -n "$out" ]; then out="$out,"; fi
    out="$out${CORE_MODEL_IDS[$i]}"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# magpie_tier_commands -> one `magpie claude <tier> <name>/<id>` per bound tier.
# magpie refuses a tier until the agent itself has a model, so the default
# pick always comes first (magpie: "pick a model ... first; sonnet can then
# have its own").
magpie_select_command() {
  [ -n "${CORE_MODEL_IDS[0]:-}" ] || return 0
  printf '%s claude %s/%s\n' "${MAGPIE_BIN:-magpie}" "$MAGPIE_NAME" "${CORE_MODEL_IDS[0]}"
}

magpie_tier_commands() {
  local tier id
  for tier in sonnet opus haiku fable; do
    case "$tier" in
      sonnet) id="$CORE_TIER_SONNET" ;;
      opus)   id="$CORE_TIER_OPUS" ;;
      haiku)  id="$CORE_TIER_HAIKU" ;;
      fable)  id="$CORE_TIER_FABLE" ;;
    esac
    [ -n "$id" ] || continue
    printf '%s claude %s %s/%s\n' "${MAGPIE_BIN:-magpie}" "$tier" "$MAGPIE_NAME" "$id"
  done
}

# magpie_urlencode <text> -> RFC 3986 escaping of the bytes of an ASCII string.
magpie_urlencode() {
  local s="$1" out="" c i=0
  while [ "$i" -lt "${#s}" ]; do
    c="${s:$i:1}"
    case "$c" in
      [A-Za-z0-9._~-]) out="$out$c" ;;
      *) out="$out$(printf '%%%02X' "'$c")" ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# magpie_build -> fills MAGPIE_NAME, MAGPIE_ROOT, MAGPIE_MODELS, MAGPIE_LINK.
# SPEC 13.3: the link carries name, anthropic and models, and never the key.
magpie_build() {
  local name="${CDS_MAGPIE_NAME:-}"
  [ -n "$name" ] || name="$(magpie_default_name "$CORE_BASE_HOST")"

  case "$name" in
    *[!A-Za-z0-9._-]*)
      cds_die 2 usage "--provider-name must be ASCII letters, digits, dot, dash or underscore: $name" ;;
  esac

  MAGPIE_NAME="$name"
  MAGPIE_ROOT="$(magpie_anthropic_root "$CORE_BASE_URL")"
  MAGPIE_MODELS="$(magpie_models_csv)"
  MAGPIE_LINK="magpie://import?name=$(magpie_urlencode "$MAGPIE_NAME")&anthropic=$(magpie_urlencode "$MAGPIE_ROOT")"
  if [ -n "$MAGPIE_MODELS" ]; then
    MAGPIE_LINK="$MAGPIE_LINK&models=$(magpie_urlencode "$MAGPIE_MODELS")"
  fi

  case "$MAGPIE_ROOT" in
    https://*) ;;
    http://localhost*|http://127.0.0.1*) ;;
    http://*)
      cds_die 3 unusable-config "magpie only accepts https for a remote base URL: $MAGPIE_ROOT" ;;
  esac
}

# magpie_plan_json -> the plan contract for this command (SPEC 12 style).
magpie_plan_json() {
  local tiers
  tiers="$(magpie_tier_commands)"
  printf '{'
  printf '"ok":true'
  printf ',"mode":"magpie"'
  printf ',"baseUrl":%s' "$(cds_json_str "$CORE_BASE_URL")"
  printf ',"baseUrlHost":%s' "$(cds_json_str "$CORE_BASE_HOST")"
  printf ',"authScheme":%s' "$(cds_json_str "$CORE_AUTH_SCHEME")"
  printf ',"tokenSource":%s' "$(cds_json_str "$CORE_TOKEN_SOURCE")"
  printf ',"tokenLength":%s' "$(cds_strlen "$CORE_TOKEN")"
  printf ',"providerName":%s' "$(cds_json_str "$MAGPIE_NAME")"
  printf ',"anthropicRoot":%s' "$(cds_json_str "$MAGPIE_ROOT")"
  printf ',"models":['
  local i=0 sep=""
  while [ "$i" -lt "${#CORE_MODEL_IDS[@]}" ]; do
    [ -n "${CORE_MODEL_IDS[$i]}" ] || { i=$((i + 1)); continue; }
    printf '%s%s' "$sep" "$(cds_json_str "${CORE_MODEL_IDS[$i]}")"
    sep=','
    i=$((i + 1))
  done
  printf ']'
  printf ',"importLink":%s' "$(cds_json_str "$MAGPIE_LINK")"
  printf ',"magpieInstalled":%s' "$([ -n "$MAGPIE_BIN" ] && printf true || printf false)"
  printf ',"magpiePath":%s' "$(cds_json_str "$MAGPIE_BIN")"
  printf ',"magpieVersion":%s' "$(cds_json_str "$MAGPIE_VERSION")"
  printf ',"selectCommand":%s' "$(cds_json_str "$(magpie_select_command)")"
  printf ',"tierCommands":['
  local first=1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$first" -eq 1 ] || printf ','
    printf '%s' "$(cds_json_str "$line")"
    first=0
  done <<EOF
$tiers
EOF
  printf ']'
  printf ',"warnings":%s' "$(core_warnings_json)"
  printf ',"errors":[]'
  printf '}'
}

# magpie_explain -> the human-readable plan.
magpie_explain() {
  cds_info "provider name   $MAGPIE_NAME"
  cds_info "anthropic root  $MAGPIE_ROOT"
  cds_info "models          ${MAGPIE_MODELS:-<none>}"
  cds_info "auth            $CORE_AUTH_SCHEME (magpie sends both headers by default)"
  if [ -n "$MAGPIE_BIN" ]; then
    cds_info "magpie          $MAGPIE_BIN ${MAGPIE_VERSION}"
  else
    cds_note "magpie          not found"
  fi
}

# magpie_install_hint -> what to run when magpie is absent.
magpie_install_hint() {
  cds_note "install magpie, then run this again:"
  cds_note "  curl -fsSL https://usemagpie.ai/install.sh | sh"
  cds_note "or download the signed build from https://usemagpie.ai"
}

# magpie_apply -> hand the link to magpie. Its own prompt asks for the key.
magpie_apply() {
  [ -n "$MAGPIE_BIN" ] || { magpie_install_hint; cds_die 5 magpie-missing "magpie is not installed"; }

  # The link carries no key on purpose, so magpie asks for it on a terminal.
  # Without one it fails with a message that reads like a bug (SPEC 13.6).
  if [ ! -t 0 ]; then
    cds_note "magpie asks for the API key on a terminal, and this run has none."
    cds_note "Run this again in a terminal window, or import the link by hand:"
    printf '%s\n' "$MAGPIE_LINK"
    cds_die 5 magpie-no-tty "no terminal for the key prompt"
  fi

  cds_note "running: $MAGPIE_BIN import <link>"
  cds_note "magpie will ask for the API key; it is not in the link."
  if ! "$MAGPIE_BIN" import "$MAGPIE_LINK"; then
    cds_die 6 magpie-import "magpie import failed"
  fi
  cds_note "provider imported. Check it with: $MAGPIE_BIN providers"

  local tiers
  tiers="$(magpie_tier_commands)"
  if [ -z "$tiers" ]; then
    return 0
  fi
  if [ "${CDS_MAGPIE_SET_TIERS:-0}" = "1" ]; then
    local tier id select
    select="$(magpie_select_command)"
    if [ -n "$select" ]; then
      cds_note "running: $select"
      # shellcheck disable=SC2086
      set -- $select
      "$1" "$2" "$3" "$4" || cds_die 6 magpie-select "picking the main model failed"
      set --
    fi
    for tier in sonnet opus haiku fable; do
      case "$tier" in
        sonnet) id="$CORE_TIER_SONNET" ;;
        opus)   id="$CORE_TIER_OPUS" ;;
        haiku)  id="$CORE_TIER_HAIKU" ;;
        fable)  id="$CORE_TIER_FABLE" ;;
      esac
      [ -n "$id" ] || continue
      cds_note "running: $MAGPIE_BIN claude $tier $MAGPIE_NAME/$id"
      "$MAGPIE_BIN" claude "$tier" "$MAGPIE_NAME/$id" \
        || cds_die 6 magpie-tier "tier binding failed for $tier"
    done
    cds_note "tiers bound. Claude Code now goes through magpie's gateway, so magpie must stay running:"
    cds_note "  $MAGPIE_BIN daemon install   # or keep the magpie app open"
  else
    cds_note "tier bindings were not applied (they rewrite ~/.claude/settings.json). Re-run with --set-tiers:"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      cds_note "  $line"
    done <<EOF
$tiers
EOF
  fi
}

magpie_main() {
  # Desktop's filter (SPEC 5.3b) does not exist on this path, and applying it
  # would empty the model list we are here to export.
  CDS_NO_ANTHROPIC_FILTER=1
  core_run "$CDS_AUTH_SCHEME_OVERRIDE"
  magpie_detect
  magpie_build

  if [ "$CDS_PLAN_MODE" = "1" ]; then
    magpie_plan_json
    printf '\n'
    return 0
  fi

  magpie_explain

  if [ "${CDS_MAGPIE_APPLY:-0}" = "1" ]; then
    magpie_apply
  else
    printf '%s\n' "$MAGPIE_LINK"
    cds_note "nothing was changed. Re-run with --apply to hand this link to magpie."
  fi
}
