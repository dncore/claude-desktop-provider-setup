#!/bin/bash
# Normative resolution core, macOS implementation.
# Implements src/common/SPEC.md sections 1-6 and the plan contract in 12.
# Every decision made here must be reproduced identically by
# src/windows/lib/Core.ps1; tests/run-conformance.sh enforces that.
#
# Deliberate style note: functions that can warn or abort never print their
# result on stdout and are never called as "$(fn)". A subshell would discard
# both the accumulated warnings and the exit status. They set a CORE_* global
# instead. Pure readers (core_settings_get, cds_json_str, ...) are safe to
# substitute.

CORE_BASE_URL=""
CORE_BASE_HOST=""
CORE_AUTH_SCHEME=""
CORE_TOKEN_SOURCE=""
CORE_DEFAULT_MODEL=""
CORE_HELPER_TTL=900
CORE_DEPLOYMENT_MODE="3p"
CORE_ALLOW_HTTP=0
CORE_DISCOVERY=""            # "", "true", "false"
CORE_ALLOW_UNLISTED=0
CORE_MAPPING_PATH=""
CORE_MODEL_IDS=()
CORE_MODEL_LABEL=()
CORE_MODEL_1M=()
CORE_MODEL_PREFER1M=()
CORE_MODEL_TIER=()
CORE_MODEL_FAMDEFAULT=()
CORE_MODEL_BEHAVES=()
CORE_MODEL_MAXEFFORT=()
CORE_MAP_IDS=()
CORE_MAP_LABEL=()
CORE_MAP_1M=()
CORE_MAP_PREFER1M=()
CORE_MAP_TIER=()
CORE_MAP_FAMDEFAULT=()
CORE_MAP_BEHAVES=()
CORE_MAP_MAXEFFORT=()
CORE_PICKED=""
CORE_IDX=-1
CORE_HAS_TIER=0

# --- pure readers ---------------------------------------------------------

# plutil cannot address a dictionary key that contains a dot, so only fixed
# key paths are used here.
core_settings_get() {
  [ -f "$CDS_SETTINGS" ] || return 0
  /usr/bin/plutil -extract "$1" raw -o - "$CDS_SETTINGS" 2>/dev/null || true
}

core_env_get() { printenv "$1" 2>/dev/null || true; }

core_validate_settings_json() {
  [ -f "$CDS_SETTINGS" ] || return 0
  if ! /usr/bin/plutil -convert json -o /dev/null "$CDS_SETTINGS" 2>/dev/null; then
    cds_die 3 invalid-json "$CDS_SETTINGS is not valid JSON"
  fi
}

# --- resolution with side effects ----------------------------------------

# core_pick <keypath> <ENV_VAR> -> CORE_PICKED
# The settings env block outranks the inherited environment (official
# precedence), and a disagreement is reported, never hidden (SPEC 2.1).
core_pick() {
  local kp="$1" var="$2" from_settings from_env
  from_settings="$(cds_trim "$(core_settings_get "$kp")")"
  from_env="$(cds_trim "$(core_env_get "$var")")"
  if [ -n "$from_settings" ] && [ -n "$from_env" ] && [ "$from_settings" != "$from_env" ]; then
    cds_warn env-shadowed "$var"
  fi
  if [ -n "$from_settings" ]; then
    CORE_PICKED="$from_settings"
  else
    CORE_PICKED="$from_env"
  fi
}

# core_validate_url <raw> -> CORE_BASE_URL, CORE_BASE_HOST
core_validate_url() {
  local url scheme authority host len
  url="$(cds_trim "$1")"

  [ -n "$url" ] || cds_die 3 invalid-base-url "ANTHROPIC_BASE_URL is empty"
  cds_assert_clean "$url" "ANTHROPIC_BASE_URL"

  case "$url" in
    *' '*|*'"'*|*'<'*|*'>'*|*'\'*|*'^'*|*'`'*|*'{'*|*'|'*|*'}'*)
      cds_die 3 invalid-base-url \
        "ANTHROPIC_BASE_URL contains a character that cannot appear in a URL" ;;
  esac

  case "$url" in
    *'://'*) ;;
    *) cds_die 3 invalid-base-url \
         "ANTHROPIC_BASE_URL has no scheme; expected https://host/..." ;;
  esac

  scheme="${url%%://*}"
  authority="${url#*://}"
  authority="${authority%%/*}"

  [ -n "$authority" ] || cds_die 3 invalid-base-url "ANTHROPIC_BASE_URL has no host"

  case "$authority" in
    *@*) cds_die 3 invalid-base-url \
           "ANTHROPIC_BASE_URL must not embed credentials (user@host)" ;;
  esac

  case "$scheme" in
    https) ;;
    http)
      if [ "$CORE_ALLOW_HTTP" -ne 1 ]; then
        cds_die 3 invalid-base-url \
          "ANTHROPIC_BASE_URL uses http, so the credential would cross the network in cleartext. Use https, or pass --allow-http for loopback testing only."
      fi
      cds_warn insecure-http "$authority"
      ;;
    *) cds_die 3 invalid-base-url "ANTHROPIC_BASE_URL scheme must be https" ;;
  esac

  case "$url" in
    *'/')
      while [ "${url%/}" != "$url" ]; do url="${url%/}"; done
      cds_warn trailing-slash "removed trailing slash"
      ;;
  esac

  len="$(cds_strlen "$url")"
  [ "$len" -ge 8 ]    || cds_die 3 invalid-base-url "ANTHROPIC_BASE_URL is too short"
  [ "$len" -le 2048 ] || cds_die 3 invalid-base-url "ANTHROPIC_BASE_URL is too long"

  host="${authority%%:*}"
  CORE_BASE_URL="$url"
  CORE_BASE_HOST="$host"
}

# core_resolve_credential [override-scheme] -> CORE_TOKEN, CORE_AUTH_SCHEME,
# CORE_TOKEN_SOURCE, and CDS_TOKEN for redaction.
core_resolve_credential() {
  local override="${1:-}"
  local auth_s key_s auth_e key_e auth auth_from key key_from value scheme from

  auth_s="$(cds_trim "$(core_settings_get env.ANTHROPIC_AUTH_TOKEN)")"
  key_s="$(cds_trim "$(core_settings_get env.ANTHROPIC_API_KEY)")"
  auth_e="$(cds_trim "$(core_env_get ANTHROPIC_AUTH_TOKEN)")"
  key_e="$(cds_trim "$(core_env_get ANTHROPIC_API_KEY)")"

  if [ -n "$auth_s" ] && [ -n "$auth_e" ] && [ "$auth_s" != "$auth_e" ]; then
    cds_warn env-shadowed "ANTHROPIC_AUTH_TOKEN"
  fi
  if [ -n "$key_s" ] && [ -n "$key_e" ] && [ "$key_s" != "$key_e" ]; then
    cds_warn env-shadowed "ANTHROPIC_API_KEY"
  fi

  if [ -n "$auth_s" ]; then auth="$auth_s"; auth_from=settings; else auth="$auth_e"; auth_from=env; fi
  if [ -n "$key_s" ];  then key="$key_s";  key_from=settings;  else key="$key_e";  key_from=env;  fi

  case "$override" in
    bearer)
      [ -n "$auth" ] || cds_die 3 missing-credential \
        "--auth-scheme bearer was given but ANTHROPIC_AUTH_TOKEN is not set"
      # The other variable, if set, is now silently unused; say so.
      if [ -n "$key" ] && [ "$key" != "$auth" ]; then
        cds_warn redundant-credentials "ANTHROPIC_API_KEY is set but not used"
      fi
      value="$auth"; scheme="bearer"; from="$auth_from" ;;
    x-api-key)
      [ -n "$key" ] || cds_die 3 missing-credential \
        "--auth-scheme x-api-key was given but ANTHROPIC_API_KEY is not set"
      if [ -n "$auth" ] && [ "$auth" != "$key" ]; then
        cds_warn redundant-credentials "ANTHROPIC_AUTH_TOKEN is set but not used"
      fi
      value="$key"; scheme="x-api-key"; from="$key_from" ;;
    "")
      if [ -n "$auth" ] && [ -n "$key" ]; then
        if [ "$auth" = "$key" ]; then
          cds_warn redundant-credentials "both token variables hold the same value"
          value="$auth"; scheme="bearer"; from="$auth_from"
        else
          cds_die 4 auth-ambiguity \
"Both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY are set with different values.
Claude Code sends both Authorization: Bearer and X-Api-Key, but Claude Desktop
can send only one (inferenceGatewayAuthScheme). Choose explicitly:
  --auth-scheme bearer     (use ANTHROPIC_AUTH_TOKEN)
  --auth-scheme x-api-key  (use ANTHROPIC_API_KEY)"
        fi
      elif [ -n "$auth" ]; then
        value="$auth"; scheme="bearer"; from="$auth_from"
      elif [ -n "$key" ]; then
        value="$key"; scheme="x-api-key"; from="$key_from"
      else
        cds_die 3 missing-credential \
"Neither ANTHROPIC_AUTH_TOKEN nor ANTHROPIC_API_KEY is set in $CDS_SETTINGS.
Claude Code is not configured for a gateway on this machine, so there is
nothing to migrate."
      fi ;;
    *) cds_die 2 usage "unknown auth scheme: $override" ;;
  esac

  # SPEC 3.1: the helper can only read the settings file.
  if [ "$from" = "env" ]; then
    local wanted
    if [ "$scheme" = "bearer" ]; then wanted="ANTHROPIC_AUTH_TOKEN"; else wanted="ANTHROPIC_API_KEY"; fi
    cds_die 3 token-not-in-settings \
"The credential was found only in the environment, not in $CDS_SETTINGS.
Claude Desktop does not inherit your shell environment, so its credential
helper could not read it later. Add it to the env block of that file:

  { \"env\": { \"ANTHROPIC_BASE_URL\": \"...\", \"$wanted\": \"...\" } }

This tool never writes to that file."
  fi

  CORE_TOKEN="$value"
  CORE_AUTH_SCHEME="$scheme"
  CORE_TOKEN_SOURCE="$from"
  CDS_TOKEN="$value"
}

# --- models (SPEC 5) -----------------------------------------------------

core_model_index() {
  local id="$1" i=0
  while [ "$i" -lt "${#CORE_MODEL_IDS[@]}" ]; do
    if [ "${CORE_MODEL_IDS[$i]}" = "$id" ]; then CORE_IDX="$i"; return 0; fi
    i=$((i + 1))
  done
  CORE_IDX=-1
}

# core_model_ensure <id> -> CORE_IDX, appending when absent
core_model_ensure() {
  local id="$1"
  core_model_index "$id"
  [ "$CORE_IDX" != "-1" ] && return 0
  cds_assert_clean "$id" "model id"
  CORE_IDX="${#CORE_MODEL_IDS[@]}"
  CORE_MODEL_IDS[$CORE_IDX]="$id"
  CORE_MODEL_LABEL[$CORE_IDX]=""
  CORE_MODEL_1M[$CORE_IDX]=""
  CORE_MODEL_PREFER1M[$CORE_IDX]=""
  CORE_MODEL_TIER[$CORE_IDX]=""
  CORE_MODEL_FAMDEFAULT[$CORE_IDX]=""
  CORE_MODEL_BEHAVES[$CORE_IDX]=""
  CORE_MODEL_MAXEFFORT[$CORE_IDX]=""
}

Core_map_scalar() {
  # Core_map_scalar <index> <field> -> CORE_MAP_VALUE
  CORE_MAP_VALUE=""
  [ -n "${CORE_MAPPING_PATH:-}" ] || return 0
  CORE_MAP_VALUE="$(/usr/bin/plutil -extract "models.$1.$2" raw -o - "$CORE_MAPPING_PATH" 2>/dev/null || true)"
}

core_load_mapping() {
  local path="$1" sv i id
  CORE_MAP_IDS=()
  if [ -z "$path" ]; then return 0; fi
  [ -f "$path" ] || cds_die 3 mapping-missing "model mapping file not found: $path"
  /usr/bin/plutil -convert json -o /dev/null "$path" 2>/dev/null \
    || cds_die 3 mapping-invalid "$path is not valid JSON"
  sv="$(/usr/bin/plutil -extract schemaVersion raw -o - "$path" 2>/dev/null || true)"
  [ "$sv" = "1" ] || cds_die 3 mapping-invalid "$path must set schemaVersion to 1"

  i=0
  while : ; do
    id="$(/usr/bin/plutil -extract "models.$i.id" raw -o - "$path" 2>/dev/null || true)"
    [ -n "$id" ] || break
    CORE_MAP_IDS[$i]="$id"
    Core_map_scalar "$i" labelOverride;        CORE_MAP_LABEL[$i]="$CORE_MAP_VALUE"
    Core_map_scalar "$i" supports1m;           CORE_MAP_1M[$i]="$CORE_MAP_VALUE"
    Core_map_scalar "$i" prefer1m;             CORE_MAP_PREFER1M[$i]="$CORE_MAP_VALUE"
    Core_map_scalar "$i" anthropicFamilyTier;  CORE_MAP_TIER[$i]="$CORE_MAP_VALUE"
    Core_map_scalar "$i" isFamilyDefault;      CORE_MAP_FAMDEFAULT[$i]="$CORE_MAP_VALUE"
    Core_map_scalar "$i" behavesAs;            CORE_MAP_BEHAVES[$i]="$CORE_MAP_VALUE"
    Core_map_scalar "$i" maxEffort;            CORE_MAP_MAXEFFORT[$i]="$CORE_MAP_VALUE"
    i=$((i + 1))
  done
  CORE_MAPPING_PATH="$path"
}

core_build_models() {
  local tier tier_var val i n id
  CORE_MODEL_IDS=()

  core_pick env.ANTHROPIC_MODEL ANTHROPIC_MODEL
  CORE_DEFAULT_MODEL="$CORE_PICKED"
  if [ -z "$CORE_DEFAULT_MODEL" ]; then
    CORE_DEFAULT_MODEL="$(cds_trim "$(core_settings_get model)")"
  fi

  # Entry 0 is the Desktop default model.
  if [ -n "$CORE_DEFAULT_MODEL" ]; then
    core_model_ensure "$CORE_DEFAULT_MODEL"
  fi

  for tier in opus sonnet haiku fable; do
    case "$tier" in
      opus)   tier_var=ANTHROPIC_DEFAULT_OPUS_MODEL ;;
      sonnet) tier_var=ANTHROPIC_DEFAULT_SONNET_MODEL ;;
      haiku)  tier_var=ANTHROPIC_DEFAULT_HAIKU_MODEL ;;
      fable)  tier_var=ANTHROPIC_DEFAULT_FABLE_MODEL ;;
    esac
    core_pick "env.$tier_var" "$tier_var"
    val="$CORE_PICKED"
    [ -n "$val" ] || continue
    core_model_ensure "$val"
    CORE_MODEL_TIER[$CORE_IDX]="$tier"
    CORE_MODEL_FAMDEFAULT[$CORE_IDX]="true"
  done

  n="${#CORE_MAP_IDS[@]}"
  i=0
  while [ "$i" -lt "$n" ]; do
    id="${CORE_MAP_IDS[$i]}"
    core_model_index "$id"
    if [ "$CORE_IDX" = "-1" ]; then
      if [ "$CORE_ALLOW_UNLISTED" -ne 1 ]; then
        cds_die 3 mapping-unlisted \
"Model mapping names '$id', which is not present in the Claude Code configuration.
Set it in ANTHROPIC_MODEL or ANTHROPIC_DEFAULT_*_MODEL, or pass
--allow-unlisted-models to add it anyway."
      fi
      core_model_ensure "$id"
      cds_warn mapping-added-model "$id"
    fi
    local idx="$CORE_IDX"
    [ -n "${CORE_MAP_LABEL[$i]}" ]      && CORE_MODEL_LABEL[$idx]="${CORE_MAP_LABEL[$i]}"
    [ -n "${CORE_MAP_1M[$i]}" ]         && CORE_MODEL_1M[$idx]="${CORE_MAP_1M[$i]}"
    [ -n "${CORE_MAP_PREFER1M[$i]}" ]   && CORE_MODEL_PREFER1M[$idx]="${CORE_MAP_PREFER1M[$i]}"
    [ -n "${CORE_MAP_TIER[$i]}" ]       && CORE_MODEL_TIER[$idx]="${CORE_MAP_TIER[$i]}"
    [ -n "${CORE_MAP_FAMDEFAULT[$i]}" ] && CORE_MODEL_FAMDEFAULT[$idx]="${CORE_MAP_FAMDEFAULT[$i]}"
    [ -n "${CORE_MAP_BEHAVES[$i]}" ]    && CORE_MODEL_BEHAVES[$idx]="${CORE_MAP_BEHAVES[$i]}"
    [ -n "${CORE_MAP_MAXEFFORT[$i]}" ]  && CORE_MODEL_MAXEFFORT[$idx]="${CORE_MAP_MAXEFFORT[$i]}"
    i=$((i + 1))
  done

  if [ "${#CORE_MODEL_IDS[@]}" -eq 0 ]; then
    cds_warn no-model-config "no model information in the Claude Code configuration"
    return 0
  fi

  local j=0
  CORE_HAS_TIER=0
  while [ "$j" -lt "${#CORE_MODEL_IDS[@]}" ]; do
    if [ -n "${CORE_MODEL_TIER[$j]}" ]; then CORE_HAS_TIER=1; break; fi
    j=$((j + 1))
  done

  if [ "$CORE_DISCOVERY" = "false" ] && [ "$CORE_HAS_TIER" -eq 1 ]; then
    cds_warn discovery-off-with-tiers \
      "tier aliases are documented as requiring model discovery"
  fi
  return 0
}

# --- emitted JSON (pure) --------------------------------------------------

core_models_json() {
  local i=0 n sep='' out='['
  n="${#CORE_MODEL_IDS[@]}"
  if [ "$n" -eq 0 ]; then printf ''; return 0; fi
  while [ "$i" -lt "$n" ]; do
    out="$out$sep{\"name\":$(cds_json_str "${CORE_MODEL_IDS[$i]}")"
    [ -n "${CORE_MODEL_LABEL[$i]}" ]      && out="$out,\"labelOverride\":$(cds_json_str "${CORE_MODEL_LABEL[$i]}")"
    [ -n "${CORE_MODEL_1M[$i]}" ]         && out="$out,\"supports1m\":$(cds_json_bool "${CORE_MODEL_1M[$i]}")"
    [ -n "${CORE_MODEL_PREFER1M[$i]}" ]   && out="$out,\"prefer1m\":$(cds_json_bool "${CORE_MODEL_PREFER1M[$i]}")"
    [ -n "${CORE_MODEL_TIER[$i]}" ]       && out="$out,\"anthropicFamilyTier\":$(cds_json_str "${CORE_MODEL_TIER[$i]}")"
    [ -n "${CORE_MODEL_FAMDEFAULT[$i]}" ] && out="$out,\"isFamilyDefault\":$(cds_json_bool "${CORE_MODEL_FAMDEFAULT[$i]}")"
    [ -n "${CORE_MODEL_BEHAVES[$i]}" ]    && out="$out,\"behavesAs\":$(cds_json_str "${CORE_MODEL_BEHAVES[$i]}")"
    [ -n "${CORE_MODEL_MAXEFFORT[$i]}" ]  && out="$out,\"maxEffort\":$(cds_json_str "${CORE_MODEL_MAXEFFORT[$i]}")"
    out="$out}"
    sep=','
    i=$((i + 1))
  done
  printf '%s]' "$out"
}

core_warnings_json() {
  local line kind detail sep='' out='['
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind="${line%%|*}"
    detail="${line#*|}"
    out="$out$sep{\"kind\":$(cds_json_str "$kind")"
    [ -n "$detail" ] && out="$out,\"detail\":$(cds_json_str "$detail")"
    out="$out}"
    sep=','
  done <<< "$CDS_WARNINGS"
  printf '%s]' "$out"
}

core_plan_json() {
  local models
  models="$(core_models_json)"
  printf '{'
  printf '"ok":true'
  printf ',"baseUrl":%s' "$(cds_json_str "$CORE_BASE_URL")"
  printf ',"baseUrlHost":%s' "$(cds_json_str "$CORE_BASE_HOST")"
  printf ',"authScheme":%s' "$(cds_json_str "$CORE_AUTH_SCHEME")"
  printf ',"tokenSource":%s' "$(cds_json_str "$CORE_TOKEN_SOURCE")"
  printf ',"tokenLength":%s' "$(cds_strlen "$CORE_TOKEN")"
  printf ',"credentialKind":"helper-script"'
  printf ',"deploymentMode":%s' "$(cds_json_str "$CORE_DEPLOYMENT_MODE")"
  printf ',"helperTtlSec":%s' "$CORE_HELPER_TTL"
  [ -n "$CORE_DISCOVERY" ] && printf ',"modelDiscoveryEnabled":%s' "$CORE_DISCOVERY"
  if [ -n "$models" ]; then printf ',"models":%s' "$models"; else printf ',"models":[]'; fi
  printf ',"warnings":%s' "$(core_warnings_json)"
  printf ',"errors":[]'
  printf '}'
}

# The configuration object written into <configLibrary>/<uuid>.json (SPEC 6).
core_config_json() {
  local models
  printf '{'
  printf '"inferenceProvider":"gateway"'
  printf ',"inferenceGatewayBaseUrl":%s' "$(cds_json_str "$CORE_BASE_URL")"
  printf ',"inferenceGatewayAuthScheme":%s' "$(cds_json_str "$CORE_AUTH_SCHEME")"
  printf ',"inferenceCredentialKind":"helper-script"'
  printf ',"inferenceCredentialHelper":%s' "$(cds_json_str "$CDS_HELPER")"
  printf ',"inferenceCredentialHelperTtlSec":%s' "$CORE_HELPER_TTL"
  models="$(core_models_json)"
  if [ -n "$models" ]; then printf ',"inferenceModels":%s' "$models"; fi
  if [ -n "$CORE_DISCOVERY" ]; then printf ',"modelDiscoveryEnabled":%s' "$CORE_DISCOVERY"; fi
  printf ',"deploymentMode":%s' "$(cds_json_str "$CORE_DEPLOYMENT_MODE")"
  printf '}'
}

# --- entry point ---------------------------------------------------------

core_run() {
  local override="$1"
  if [ ! -f "$CDS_SETTINGS" ]; then
    cds_die 3 settings-missing \
"$CDS_SETTINGS was not found. This tool migrates an existing Claude Code gateway
configuration; there is nothing to read. Create that file first."
  fi
  core_validate_settings_json

  core_pick env.ANTHROPIC_BASE_URL ANTHROPIC_BASE_URL
  core_validate_url "$CORE_PICKED"

  core_resolve_credential "$override"

  core_load_mapping "$CORE_MAPPING_PATH"
  core_build_models
}
