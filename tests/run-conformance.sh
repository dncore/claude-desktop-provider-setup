#!/bin/bash
# Conformance runner, macOS.
#
# Runs every fixture in tests/fixtures/common through `cli.sh plan` in a
# throwaway HOME with a scrubbed environment, then compares the resulting plan
# with the fixture's expect.json field by field.
#
# tests/run-conformance.ps1 must accept the same fixtures and reach the same
# verdict. That equivalence is the whole point: the two implementations share a
# specification, not code, so only shared fixtures can hold them together.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures/common"
CLI="$ROOT/src/macos/cli.sh"
STD_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

FILTER="${1:-}"
PASS=0
FAIL=0
FAILED=""

jget() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

fail_case() {
  FAIL=$((FAIL + 1))
  FAILED="$FAILED
  - $CASE: $1"
  printf 'FAIL %s: %s\n' "$CASE" "$1"
}

check() {
  # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then return 0; fi
  fail_case "$1: expected [$2] got [$3]"
  return 1
}

check_count() {
  # check_count <label> <array-key> <file> <expected-count>
  local got
  got="$(jget "$3" "$2")"
  [ -n "$got" ] || got=0
  check "$1 count" "$4" "$got"
}

MODEL_FIELDS="name labelOverride supports1m prefer1m anthropicFamilyTier isFamilyDefault behavesAs maxEffort"

run_case() {
  local case_dir="$1" home tmp out err code
  CASE="$(basename "$case_dir")"

  if [ -n "$FILTER" ]; then
    case "$CASE" in *"$FILTER"*) ;; *) return 0 ;; esac
  fi

  home="$(mktemp -d "${TMPDIR:-/tmp}/cds-conf-home.XXXXXX")" || { fail_case "mktemp failed"; return; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cds-conf-tmp.XXXXXX")"

  mkdir -p "$home/.claude"
  if [ -f "$case_dir/settings.json" ]; then
    cp "$case_dir/settings.json" "$home/.claude/settings.json"
  fi

  # Fixture-provided environment, applied to an otherwise empty environment.
  local -a envargs
  envargs=()
  if [ -f "$case_dir/env.json" ]; then
    local k v
    for k in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY \
             ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
             ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
             ANTHROPIC_DEFAULT_FABLE_MODEL; do
      v="$(jget "$case_dir/env.json" "$k")"
      # An empty-string value is a meaningful fixture (it means "set to empty",
      # which the spec treats as absent); encode it explicitly.
      if [ -n "$v" ] || /usr/bin/plutil -extract "$k" raw -o - "$case_dir/env.json" >/dev/null 2>&1; then
        envargs+=("$k=$v")
      fi
    done
  fi

  local -a args
  args=()
  if [ -f "$case_dir/args.json" ]; then
    local ai=0 a
    while : ; do
      a="$(jget "$case_dir/args.json" "$ai")"
      [ -n "$a" ] || break
      args+=("$a")
      ai=$((ai + 1))
    done
  fi
  if [ -f "$case_dir/mapping.json" ]; then
    args+=("--mapping" "$case_dir/mapping.json")
  fi

  out="$tmp/stdout"; err="$tmp/stderr"
  env -i HOME="$home" PATH="$STD_PATH" TMPDIR="$tmp" ${envargs[@]+"${envargs[@]}"} \
    /bin/bash "$CLI" plan ${args[@]+"${args[@]}"} >"$out" 2>"$err"
  code=$?

  _compare_case "$case_dir" "$out" "$code" "$home" "$err"
  rm -rf "$home" "$tmp"
}

_compare_case() {
  local case_dir="$1" out="$2" code="$3" home="$4" err="$5"
  local exp="$case_dir/expect.json"
  local want_ok want_code

  # One top-level JSON object is expected on failure as well as on success.
  if ! /usr/bin/plutil -convert json -o /dev/null "$out" 2>/dev/null; then
    fail_case "plan output is not valid JSON (exit $code): $(head -c 200 "$out" | tr '\n' ' ')"
    return
  fi

  want_ok="$(jget "$exp" ok)"

  if [ "$want_ok" = "true" ]; then
    check "exit code" "0" "$code"
    for f in baseUrl baseUrlHost authScheme tokenSource tokenLength \
             credentialKind deploymentMode helperTtlSec modelDiscoveryEnabled; do
      check "$f" "$(jget "$exp" "$f")" "$(jget "$out" "$f")"
    done

    local wn an i field
    wn="$(jget "$exp" models)"; [ -n "$wn" ] || wn=0
    an="$(jget "$out" models)"; [ -n "$an" ] || an=0
    if check "models count" "$wn" "$an"; then
      i=0
      while [ "$i" -lt "$wn" ]; do
        for field in $MODEL_FIELDS; do
          check "models[$i].$field" \
            "$(jget "$exp" "models.$i.$field")" \
            "$(jget "$out" "models.$i.$field")"
        done
        i=$((i + 1))
      done
    fi

    local expw actw
    expw="$(jget "$exp" warnings)"; [ -n "$expw" ] || expw=0
    actw="$(jget "$out" warnings)"; [ -n "$actw" ] || actw=0
    if check "warnings count" "$expw" "$actw"; then
      i=0
      while [ "$i" -lt "$expw" ]; do
        check "warnings[$i].kind" \
          "$(jget "$exp" "warnings.$i.kind")" \
          "$(jget "$out" "warnings.$i.kind")"
        i=$((i + 1))
      done
    fi
    check "errors count" "0" "$(jget "$out" errors)"
  else
    want_code="$(jget "$exp" errors.0.code)"
    check "error kind" "$(jget "$exp" errors.0.kind)" "$(jget "$out" errors.0.kind)"
    check "exit code" "$want_code" "$code"
    check "ok flag" "false" "$(jget "$out" ok)"
    check "errors count" "1" "$(jget "$out" errors)"
  fi

  # Redaction: the fixture's credential must not appear in either stream.
  local token
  token="$(jget "$home/.claude/settings.json" env.ANTHROPIC_AUTH_TOKEN)"
  if [ -z "$token" ]; then
    token="$(jget "$home/.claude/settings.json" env.ANTHROPIC_API_KEY)"
  fi
  if [ -n "$token" ]; then
    if grep -qF -- "$token" "$out" 2>/dev/null; then fail_case "credential leaked on stdout"; fi
    if grep -qF -- "$token" "$err" 2>/dev/null; then fail_case "credential leaked on stderr"; fi
  fi
}

main() {
  local d
  if [ ! -d "$FIXTURES" ]; then
    printf 'missing fixtures directory: %s\n' "$FIXTURES" >&2
    exit 2
  fi
  for d in "$FIXTURES"/*/; do
    [ -d "$d" ] || continue
    local before="$FAIL"
    run_case "${d%/}"
    [ "$FAIL" -eq "$before" ] && PASS=$((PASS + 1))
  done

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  if [ "$FAIL" -ne 0 ]; then
    printf 'failed cases:%s\n' "$FAILED"
    exit 1
  fi
  exit 0
}

main
