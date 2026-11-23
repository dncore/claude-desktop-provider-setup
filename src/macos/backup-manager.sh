#!/bin/bash
# Backup, restore and state management, macOS.
# Implements src/common/SPEC.md section 9.
#
# A backup holds a byte-identical copy of _meta.json and of every configuration
# file present in the library at that moment. Those files may contain a gateway
# API key that the user previously saved through the in-app window, so the
# backup directory is 0700 with 0600 files and is never included in any
# diagnostic output.

BM_DIR=""
BM_MANIFEST="manifest.json"

bm_state_init() {
  mkdir -p "$CDS_STATE_DIR" 2>/dev/null || cds_die 5 io-error "cannot create $CDS_STATE_DIR"
  chmod 700 "$CDS_STATE_DIR" 2>/dev/null || true
  mkdir -p "$CDS_HELPER_DIR" 2>/dev/null || cds_die 5 io-error "cannot create $CDS_HELPER_DIR"
}

bm_backup() {
  # bm_backup <label> -> BM_DIR
  local label ts stamp target f name sum size
  ts="$(date -u '+%Y%m%dT%H%M%SZ')"
  stamp="$ts"
  target="$CDS_BACKUP_ROOT/$stamp"
  if [ -d "$target" ]; then target="$CDS_BACKUP_ROOT/${stamp}-$$"; fi

  mkdir -p "$target" 2>/dev/null || cds_die 6 io-error "cannot create $target"
  chmod 700 "$target" 2>/dev/null || true

  {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "createdAt": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '  "label": "%s",\n' "$(cds_json_escape "$label")"
    printf '  "libraryPath": "%s",\n' "$(cds_json_escape "$CDS_LIBRARY")"
    printf '  "files": ['
  } > "$target/$BM_MANIFEST"

  local first=1
  for f in "$CDS_LIBRARY/_meta.json" "$CDS_LIBRARY"/*.json; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    [ "$name" = "_meta.json" ] || cds_valid_uuid "${name%.json}" || continue
    cp -p "$f" "$target/$name" || cds_die 6 io-error "cannot copy $name into the backup"
    chmod 600 "$target/$name" 2>/dev/null || true
    sum="$(shasum -a 256 "$f" | awk '{print $1}')"
    size="$(wc -c < "$f" | tr -d ' ')"
    if [ "$first" -eq 1 ]; then first=0; else printf ',' >> "$target/$BM_MANIFEST"; fi
    printf '\n    {"name": "%s", "bytes": %s, "sha256": "%s"}' \
      "$(cds_json_escape "$name")" "$size" "$sum" >> "$target/$BM_MANIFEST"
  done

  printf '\n  ]\n}\n' >> "$target/$BM_MANIFEST"
  chmod 600 "$target/$BM_MANIFEST" 2>/dev/null || true
  BM_DIR="$target"
}

bm_verify() {
  # bm_verify <dir> -> 0 when every recorded file matches its digest
  local dir="$1" manifest="$1/$BM_MANIFEST" count i name want got
  [ -f "$manifest" ] || cds_die 5 backup-missing "no manifest in $dir"
  count="$(/usr/bin/plutil -extract files raw -o - "$manifest" 2>/dev/null || true)"
  # plutil returns the element count for an array path; anything else means
  # the manifest is malformed.
  case "$count" in ''|*[!0-9]*) cds_die 5 backup-invalid "manifest in $dir is malformed" ;; esac
  i=0
  while [ "$i" -lt "$count" ]; do
    name="$(/usr/bin/plutil -extract "files.$i.name" raw -o - "$manifest" 2>/dev/null || true)"
    want="$(/usr/bin/plutil -extract "files.$i.sha256" raw -o - "$manifest" 2>/dev/null || true)"
    [ -n "$name" ] || cds_die 5 backup-invalid "manifest entry $i has no name"
    [ -f "$dir/$name" ] || cds_die 5 backup-invalid "backup is missing $name"
    got="$(shasum -a 256 "$dir/$name" | awk '{print $1}')"
    [ "$got" = "$want" ] || cds_die 5 backup-corrupt "$name does not match its recorded digest"
    i=$((i + 1))
  done
}

bm_restore() {
  # bm_restore <dir>
  local dir="$1" f name
  # Accept either a full path or a bare timestamp from bm_list.
  if [ ! -d "$dir" ] && [ -d "$CDS_BACKUP_ROOT/$dir" ]; then dir="$CDS_BACKUP_ROOT/$dir"; fi
  [ -d "$dir" ] || cds_die 5 backup-missing "backup directory not found: $1"

  bm_verify "$dir"
  cm_require_library

  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    [ "$name" = "$BM_MANIFEST" ] && continue
    if [ "$name" != "_meta.json" ] && ! cds_valid_uuid "${name%.json}"; then
      cds_warn backup-skipped "$name is not a configuration file"
      continue
    fi
    cp -p "$f" "$CDS_LIBRARY/$name" || cds_die 6 io-error "cannot restore $name"
    chmod 600 "$CDS_LIBRARY/$name" 2>/dev/null || true
  done
  BM_RESTORED="$dir"
}

bm_list() {
  local d
  [ -d "$CDS_BACKUP_ROOT" ] || return 0
  for d in "$CDS_BACKUP_ROOT"/*; do
    [ -d "$d" ] || continue
    printf '%s\n' "$(basename "$d")"
  done
}

bm_latest() {
  local d
  d="$(bm_list | sort | tail -1)"
  [ -n "$d" ] && printf '%s' "$CDS_BACKUP_ROOT/$d"
}

# --- state.json -----------------------------------------------------------

bm_write_state() {
  # bm_write_state <configId> <configName> <prevApplied> <metaExisted> <helperFilesJson>
  local id="$1" name="$2" prev="$3" existed="$4" helpers="$5"
  bm_state_init
  local tmp="$CDS_STATE_FILE.tmp"
  {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "toolVersion": "%s",\n' "$(cds_json_escape "$CDS_TOOL_VERSION")"
    printf '  "platform": "macos",\n'
    printf '  "installedAt": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '  "configId": "%s",\n' "$(cds_json_escape "$id")"
    printf '  "configName": "%s",\n' "$(cds_json_escape "$name")"
    printf '  "previousAppliedId": "%s",\n' "$(cds_json_escape "$prev")"
    printf '  "metaExistedBefore": %s,\n' "$( [ "$existed" = "1" ] && printf 'true' || printf 'false' )"
    printf '  "helperFiles": %s,\n' "$helpers"
    printf '  "baseUrl": "%s",\n' "$(cds_json_escape "$CORE_BASE_URL")"
    printf '  "authScheme": "%s",\n' "$(cds_json_escape "$CORE_AUTH_SCHEME")"
    printf '  "tokenSource": "%s",\n' "$(cds_json_escape "$CORE_TOKEN_SOURCE")"
    printf '  "tokenLength": %s,\n' "$(cds_strlen "$CORE_TOKEN")"
    printf '  "modelIds": %s\n' "$(core_model_ids_json)"
    printf '}\n'
  } > "$tmp" || cds_die 6 io-error "cannot write state file"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$CDS_STATE_FILE" || cds_die 6 io-error "cannot install state file"
}

core_model_ids_json() {
  local i=0 n out='[' sep=''
  n="${#CORE_MODEL_IDS[@]}"
  while [ "$i" -lt "$n" ]; do
    out="$out$sep$(cds_json_str "${CORE_MODEL_IDS[$i]}")"
    sep=','
    i=$((i + 1))
  done
  printf '%s]' "$out"
}

bm_state_get() {
  # bm_state_get <keypath> -> BM_VALUE
  BM_VALUE=""
  [ -f "$CDS_STATE_FILE" ] || return 0
  BM_VALUE="$(/usr/bin/plutil -extract "$1" raw -o - "$CDS_STATE_FILE" 2>/dev/null || true)"
}

bm_require_state() {
  [ -f "$CDS_STATE_FILE" ] || cds_die 5 not-installed \
"$CDS_STATE_FILE does not exist. Nothing is recorded as installed by this tool."
}
