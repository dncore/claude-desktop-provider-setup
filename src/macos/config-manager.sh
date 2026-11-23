#!/bin/bash
# Config-library manager, macOS.
# Reads and writes ~/Library/Application Support/Claude-3p/configLibrary/
# Implements src/common/SPEC.md section 7.
#
# _meta.json is edited through a plist round trip rather than by string
# manipulation, so that user-authored entry names survive untouched regardless
# of the characters they contain. The configuration file itself is composed
# directly, because its key set is small, fixed, and validated.

CM_PLIST=""
CM_APPLIED=""
CM_ENTRY_N=0
CM_PREV_APPLIED=""
CM_META_EXISTED=0

# --- plist plumbing -------------------------------------------------------

cm_minimal_plist() {
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST
}

# cm_load_meta -> CM_PLIST (temp file), CM_APPLIED, CM_META_EXISTED
cm_load_meta() {
  CM_PLIST="$(mktemp "${TMPDIR:-/tmp}/cds-meta.XXXXXX")" || cds_die 6 io-error "cannot create temp file"
  CM_META_EXISTED=0
  if [ -f "$CDS_LIBRARY/_meta.json" ]; then
    if /usr/bin/plutil -convert xml1 -o "$CM_PLIST" "$CDS_LIBRARY/_meta.json" 2>/dev/null; then
      CM_META_EXISTED=1
    else
      # An unparseable _meta.json is treated as absent, but the original is
      # preserved by the backup step, and the caller is warned.
      cm_minimal_plist > "$CM_PLIST"
      cds_warn meta-unreadable "$CDS_LIBRARY/_meta.json could not be parsed"
    fi
  else
    cm_minimal_plist > "$CM_PLIST"
  fi
  if ! /usr/libexec/PlistBuddy -c 'Print :appliedId' "$CM_PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Add :appliedId string ' "$CM_PLIST" >/dev/null 2>&1
  fi
  if ! /usr/libexec/PlistBuddy -c 'Print :entries' "$CM_PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Add :entries array' "$CM_PLIST" >/dev/null 2>&1
  fi
  CM_APPLIED="$(/usr/libexec/PlistBuddy -c 'Print :appliedId' "$CM_PLIST" 2>/dev/null || true)"
}

cm_entry_count() {
  local i=0
  while /usr/libexec/PlistBuddy -c "Print :entries:$i" "$CM_PLIST" >/dev/null 2>&1; do
    i=$((i + 1))
  done
  CM_ENTRY_N="$i"
}

cm_entry_get() {
  # cm_entry_get <index> <field> -> CM_VALUE
  CM_VALUE="$(/usr/libexec/PlistBuddy -c "Print :entries:$1:$2" "$CM_PLIST" 2>/dev/null || true)"
}

cm_find_entry() {
  # cm_find_entry <id> -> CM_INDEX or -1
  local want="$1" i=0
  CM_INDEX=-1
  while [ "$i" -lt "$CM_ENTRY_N" ]; do
    cm_entry_get "$i" id
    if [ "$CM_VALUE" = "$want" ]; then CM_INDEX="$i"; return 0; fi
    i=$((i + 1))
  done
}

cm_add_entry() {
  local id="$1" name="$2"
  if ! /usr/libexec/PlistBuddy \
      -c "Add :entries:$CM_ENTRY_N dict" \
      -c "Add :entries:$CM_ENTRY_N:id string $id" \
      -c "Add :entries:$CM_ENTRY_N:name string $name" "$CM_PLIST" >/dev/null 2>&1; then
    cds_die 6 meta-write "could not add the configuration entry"
  fi
  CM_ENTRY_N=$((CM_ENTRY_N + 1))
}

cm_delete_entry() {
  local index="$1"
  /usr/libexec/PlistBuddy -c "Delete :entries:$index" "$CM_PLIST" >/dev/null 2>&1 \
    || cds_die 6 meta-write "could not remove the configuration entry"
  CM_ENTRY_N=$((CM_ENTRY_N - 1))
}

cm_set_applied() {
  local id="$1"
  /usr/libexec/PlistBuddy -c "Set :appliedId $id" "$CM_PLIST" >/dev/null 2>&1 \
    || cds_die 6 meta-write "could not set appliedId"
  CM_APPLIED="$id"
}

# Verify the invariant Claude Desktop enforces before it ever sees the file:
# appliedId is empty or names an entry that exists.
cm_assert_invariant() {
  local i=0 found=0
  if [ -z "$CM_APPLIED" ]; then return 0; fi
  cds_valid_uuid "$CM_APPLIED" \
    || cds_die 6 meta-invariant "appliedId '$CM_APPLIED' is not a valid configuration id"
  while [ "$i" -lt "$CM_ENTRY_N" ]; do
    cm_entry_get "$i" id
    [ "$CM_VALUE" = "$CM_APPLIED" ] && found=1
    i=$((i + 1))
  done
  [ "$found" -eq 1 ] \
    || cds_die 6 meta-invariant "appliedId '$CM_APPLIED' names no existing entry; refusing to write"
}

# cm_save_meta: convert the working plist back to JSON and install it atomically.
cm_save_meta() {
  local tmp_json
  tmp_json="$(mktemp "${TMPDIR:-/tmp}/cds-meta-json.XXXXXX")" || cds_die 6 io-error "temp file"
  if ! /usr/bin/plutil -convert json -o "$tmp_json" "$CM_PLIST" 2>/dev/null; then
    rm -f "$tmp_json"
    cds_die 6 meta-write "could not serialise _meta.json"
  fi
  # plutil emits no trailing newline; add one for a well-formed text file.
  printf '\n' >> "$tmp_json"
  chmod 600 "$tmp_json" 2>/dev/null || true
  mv -f "$tmp_json" "$CDS_LIBRARY/_meta.json" || cds_die 6 io-error "could not write _meta.json"
}

cm_cleanup() {
  [ -n "$CM_PLIST" ] && [ -f "$CM_PLIST" ] && rm -f "$CM_PLIST"
  CM_PLIST=""
}

# --- configuration file ---------------------------------------------------

cm_write_config() {
  # cm_write_config <id> <json>
  local id="$1" json="$2" target tmp
  target="$CDS_LIBRARY/$id.json"
  tmp="$CDS_LIBRARY/.$id.json.tmp"
  printf '%s\n' "$json" > "$tmp" || cds_die 6 io-error "could not write $tmp"
  chmod 600 "$tmp" 2>/dev/null || true

  # Parse the file we are about to install. If it is not valid JSON Claude
  # Desktop would reject the whole configuration, so fail here instead.
  if ! /usr/bin/plutil -convert json -o /dev/null "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    cds_die 6 invalid-output "generated configuration is not valid JSON"
  fi
  mv -f "$tmp" "$target" || cds_die 6 io-error "could not install $target"
}

# --- public operations ----------------------------------------------------

cm_require_library() {
  if [ -d "$CDS_LIBRARY" ]; then return 0; fi
  if [ -d "$CDS_APP_DATA" ]; then
    mkdir -p "$CDS_LIBRARY" 2>/dev/null || cds_die 5 io-error "cannot create $CDS_LIBRARY"
    return 0
  fi
  # No Claude Desktop data directory at all. Creating the whole tree risks
  # producing an install the app never reads, so stop and explain.
  cds_die 5 app-not-initialised \
"$CDS_APP_DATA does not exist, which means Claude Desktop has never run for this
user. Launch Claude Desktop once, quit it, and run this installer again."
}

# cm_install <config-json> <config-name> <existing-id-or-empty>
cm_install() {
  local json="$1" name="$2" existing="$3" id
  cm_load_meta
  cm_entry_count

  if [ -n "$existing" ]; then
    id="$existing"
    cm_find_entry "$id"
    if [ "$CM_INDEX" = "-1" ]; then
      cds_die 6 state-stale \
"The recorded configuration id $id is no longer present in the Claude Desktop
library. Run --uninstall to clear the stale record, then install again."
    fi
  else
    id="$(cds_new_uuid)"
    cds_valid_uuid "$id" || cds_die 6 io-error "uuidgen produced an unexpected value"
    cm_add_entry "$id" "$name"
  fi

  CM_PREV_APPLIED="$CM_APPLIED"
  cm_write_config "$id" "$json"
  cm_set_applied "$id"
  cm_assert_invariant
  cm_save_meta

  CM_RESULT_ID="$id"
  CM_RESULT_PREV="$CM_PREV_APPLIED"
  CM_RESULT_META_EXISTED="$CM_META_EXISTED"
  cm_cleanup
}

# cm_remove <id>
cm_remove() {
  local id="$1" i n next
  cm_load_meta
  cm_entry_count
  cm_find_entry "$id"
  if [ "$CM_INDEX" = "-1" ]; then
    cm_cleanup
    cds_warn not-installed "configuration id $id is already absent"
    CM_RESULT_CHANGED=0
    return 0
  fi

  cm_delete_entry "$CM_INDEX"

  if [ "$CM_APPLIED" = "$id" ]; then
    # Pick the recorded predecessor if it still exists, else the first
    # remaining entry, else empty. Never leave appliedId dangling.
    next=""
    if [ -n "${CM_RESTORE_TO:-}" ]; then
      cm_find_entry "$CM_RESTORE_TO"
      if [ "$CM_INDEX" != "-1" ]; then next="$CM_RESTORE_TO"; fi
    fi
    if [ -z "$next" ] && [ "$CM_ENTRY_N" -gt 0 ]; then
      cm_entry_get 0 id
      next="$CM_VALUE"
    fi
    cm_set_applied "$next"
  fi

  rm -f "$CDS_LIBRARY/$id.json"
  cm_assert_invariant
  cm_save_meta
  CM_RESULT_CHANGED=1
  cm_cleanup
}
