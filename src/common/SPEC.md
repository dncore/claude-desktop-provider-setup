# Normative core specification

This file is the single source of truth for behaviour that **both** platform
implementations (`src/macos/`, `src/windows/`) must reproduce byte-for-byte in
their observable output. Either implementation is a bug if it disagrees with
this document. The conformance suite (`tests/run-conformance.*`) enforces it.

Rationale for two implementations rather than one shared runtime: the project
must not require Node.js, Python, or a PowerShell install on macOS. A single
language available on both platforms without an extra runtime does not exist.
The shared part is therefore a **specification plus fixtures**, not shared code.

---

## 1. Inputs

### 1.1 User-scope Claude Code settings

`<home>/.claude/settings.json` — read only, never modified.

Recognised keys:

| Location in JSON | Meaning |
|---|---|
| `env.ANTHROPIC_BASE_URL` | gateway base URL |
| `env.ANTHROPIC_AUTH_TOKEN` | bearer credential |
| `env.ANTHROPIC_API_KEY` | `x-api-key` credential |
| `env.ANTHROPIC_MODEL` | default model |
| `env.ANTHROPIC_DEFAULT_OPUS_MODEL` | opus tier |
| `env.ANTHROPIC_DEFAULT_SONNET_MODEL` | sonnet tier |
| `env.ANTHROPIC_DEFAULT_HAIKU_MODEL` | haiku tier |
| `env.ANTHROPIC_DEFAULT_FABLE_MODEL` | fable tier |
| `model` (top level) | default model, lowest priority |

Unknown keys anywhere in the document are ignored and preserved. Arrays and
objects that are not read are ignored. The file is never rewritten.

### 1.2 Process environment

The environment inherited by the installer (normally the same shell the user
runs `claude` from). Only the eight variables named in §1.1 are read.

### 1.3 Model mapping file (optional)

`--mapping <path>`, else `<repo>/config/model-mapping.json` if present.
Schema: `src/common/model-mapping.schema.json`. Absent file is not an error.

---

## 2. Precedence

Claude Code resolves environment variables against settings as follows
(official, `code.claude.com/docs/en/env-vars#precedence`): **the settings
`env` block wins over the inherited shell environment**, and `ANTHROPIC_MODEL`
wins over the top-level `model` key.

Therefore, for each value, the first source in this list that yields a
non-empty string wins:

1. `settings.json` → `env.<VAR>`
2. process environment → `<VAR>`
3. `settings.json` → `model` (default model only; no equivalent for other keys)

A source yielding an empty string or whitespace-only string is treated as
absent.

### 2.1 Conflict reporting (required)

If source 1 and source 2 both yield a value and the values differ, the tool
MUST emit a `warning` of kind `env-shadowed` naming the variable and MUST use
source 1. It MUST NOT silently ignore the disagreement. Neither value may
appear in the warning; only the variable name and the source names.

---

## 3. Credential selection

Let `AUTH` = resolved `ANTHROPIC_AUTH_TOKEN`, `KEY` = resolved `ANTHROPIC_API_KEY`.

| AUTH | KEY | Result |
|---|---|---|
| non-empty | absent | `authScheme = bearer`, token = AUTH |
| absent | non-empty | `authScheme = x-api-key`, token = KEY |
| non-empty | non-empty, equal | `authScheme = bearer`, token = AUTH, warning `redundant-credentials` |
| non-empty | non-empty, different | **error `auth-ambiguity`, exit 4** |
| absent | absent | **error `missing-credential`, exit 3** |

`auth-ambiguity` is overridden only by an explicit `--auth-scheme bearer` or
`--auth-scheme x-api-key` (which selects the corresponding token). The error
message MUST state that Claude Code sends both `Authorization: Bearer` and
`X-Api-Key`, that Claude Desktop can send only one
(`inferenceGatewayAuthScheme`), and how to choose.

Whenever a run proceeds while both variables are set, it MUST warn
`redundant-credentials`, including when the caller overrode the choice, because
the other credential is then silently unused.

There is no implicit preference. "AUTH_TOKEN is more common" is not a valid
reason to pick it.

### 3.1 Source constraint on the credential

The credential **must** resolve from `settings.json` (`tokenSource = settings`).
If it resolves only from the process environment, abort with
`token-not-in-settings` (exit 3).

Reason: the credential helper runs as a child of Claude Desktop, which does not
inherit the user's login shell. A token that lives only in the shell cannot be
re-read at refresh time. The only ways to make it readable are to copy it into
a plaintext file or into the Keychain in a form that either prompts on every
refresh (breaking silent mid-session refresh) or is readable by any local
process. Both are worse than telling the user to add one line to
`~/.claude/settings.json`, which is where their token belongs anyway.

The error message must name the missing variables and show the exact `env` block
to add. The tool never writes to `settings.json` itself.

Base URL and model IDs are *not* subject to this constraint: they are not
secret and are copied into the configuration at install time.

---

## 4. Base URL validation

Input is the resolved `ANTHROPIC_BASE_URL`. Rules, applied in order; first
failure aborts with `invalid-base-url` (exit 3):

1. Non-empty after trimming surrounding whitespace (trim only; never trim the middle).
2. No ASCII control characters, no space, no `"`, `<`, `>`, `\`, `^`, `` ` ``, `{`, `}`, `|`.
3. Scheme is `https`, or `http` with explicit `--allow-http`.
4. Matches `^[a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]+` (scheme + authority present).
5. Contains no userinfo (`@` before the first `/` after the authority).
6. Trailing `/` characters are stripped. One stripped trailing `/` produces
   warning `trailing-slash`.
7. Length 8..2048.

The URL path is preserved verbatim. The tool MUST NOT append `/v1`, `/v1/messages`,
or any suffix. The Cloud Desktop gateway base URL is passed through as the
user's CLI already uses it.

`http` is refused by default: a bearer token sent over cleartext is a
credential leak. `--allow-http` exists for loopback-only testing.

---

## 5. Model mapping

### 5.1 Extraction

From §2 precedence, resolve:

- `defaultModel` = `ANTHROPIC_MODEL` → shell env → `model`
- `tiers` = the four `ANTHROPIC_DEFAULT_*_MODEL` values, in the fixed order
  `opus, sonnet, haiku, fable`

### 5.2 Output list

`inferenceModels` is built as:

1. If `defaultModel` is non-empty, it is entry 0. Entry 0 is the Desktop
   default model (first entry wins).
2. Each non-empty tier model is appended, unless it equals an ID already
   present, in which case the existing entry gains the tier instead of being
   duplicated.
3. Entries originating from a tier carry `"anthropicFamilyTier": "<tier>"` and
   `"isFamilyDefault": true`.
4. Entries carry `"name"` = the model ID exactly as configured. No ID is
   invented, normalised, lowercased, or truncated.
5. The mapping file may add `labelOverride`, `supports1m`, `prefer1m`,
   `behavesAs`, `maxEffort`, and may override `anthropicFamilyTier` for a
   named ID. It may not add an ID that is absent from the CLI config unless
   `--allow-unlisted-models` is given.
6. If `defaultModel` is empty and no tier is set, `inferenceModels` is omitted
   entirely and `modelDiscoveryEnabled` is left at its default. The tool prints
   `models: discovery` and warns `no-model-config`.

Deduplication compares IDs with ordinal (byte) equality. No case folding.

### 5.3 Two normalisations Claude Desktop forces

**[LOCAL]** established against Claude Desktop 6.28899.6.0. Both are recorded in
`docs/research-findings.md` §7b.

**(a) The `[1m]` selector suffix is not part of a model ID.**
Claude Code documents `[1m]` as a suffix you append to a model alias or full
name to request the 1M context window. It is a Claude Code selector, not
something the provider serves. The tool strips one trailing `[1m]`
(case-insensitive), sets `supports1m: true` on that entry, and warns
`model-1m-suffix-stripped`. Emitting the raw value makes the model unusable.

**(b) Claude Desktop discards any model ID that does not reference an Anthropic
model.** Given `inferenceModels` entries whose `name` is, say,
`deepseek-v4.1-flash`, the app warns *"is not an Anthropic model and was removed
from the list — expected a gateway model route referencing an Anthropic model
(e.g. claude-sonnet-4-5, anthropic/claude-\*)"* and drops the entry. `behavesAs`
does not prevent the drop. Because the presence of `inferenceModels` also
suppresses model discovery, an all-dropped list leaves the picker empty and the
app reports "Your organization hasn't configured any models".

Therefore, after building the list:

1. An entry qualifies when its `name` contains `claude`, ASCII case-insensitive
   — the only property shared by both accepted examples.
2. If **no** entry qualifies, omit `inferenceModels` from the configuration
   entirely and warn `models-discovery-fallback`. Omitting it is the only way
   to let the app populate its picker from the gateway's `/v1/models`.
3. If **some** entries qualify, keep those in their original order and drop the
   rest, warning `model-not-anthropic` once per dropped ID.

The tool never renames a model to make it qualify. A gateway that serves only
non-Anthropic IDs needs Anthropic-named route aliases on the gateway side; that
is the operator's call, not something a client-side rename can fake.

### 5.4 Discovery interaction

`anthropicFamilyTier` is emitted by default. Because tier aliases interact with
model discovery, the tool emits `modelDiscoveryEnabled` **only** when the user
passes `--no-model-discovery` (value `false`) or `--require-model-discovery`
(value `true`). Leaving the key unset preserves Claude Desktop's default of
"on", which the official docs describe as the consistent combination with a
tier-annotated model list.

`--no-model-discovery` prints a warning `discovery-off-with-tiers` because the
combination is not documented as supported.

---

## 6. Output configuration

Exactly these keys are written into the created configuration file, and no
others. A key is omitted when its value is unavailable.

| Key | Value | Condition |
|---|---|---|
| `inferenceProvider` | `"gateway"` | always |
| `inferenceGatewayBaseUrl` | validated URL | always |
| `inferenceGatewayAuthScheme` | `"bearer"` or `"x-api-key"` | always |
| `inferenceCredentialKind` | `"helper-script"` | always |
| `inferenceCredentialHelper` | absolute POSIX path | macOS |
| `inferenceCredentialHelperWindows` | absolute Windows path | Windows |
| `inferenceCredentialHelperTtlSec` | integer, default `900` | always |
| `inferenceModels` | array per §5 | when non-empty |
| `modelDiscoveryEnabled` | boolean | only when explicitly requested |
| `deploymentMode` | `"3p"` or `"any"` | default `3p` |

`inferenceGatewayApiKey` is **never** written. The whole point of the helper is
that no secret ever enters a configuration file.

Keys the tool does not own are never written, even to "help".

---

## 7. Configuration library (both platforms)

Claude Desktop reads a directory of saved configurations.

- macOS: `~/Library/Application Support/Claude-3p/configLibrary/`
- Windows: `%LOCALAPPDATA%\Claude-3p\configLibrary\`

Layout (verified against the shipped app and a live install):

- `_meta.json` = `{"appliedId": "<uuid>", "entries": [{"id": "<uuid>", "name": "<string>", "note"?: "<string>"}]}`
- `<uuid>.json` = a flat JSON object of configuration keys, native JSON types.

Constraints enforced by the app: an id must match `^[a-f0-9-]{36}$`, and
`appliedId` must name an id present in `entries`, otherwise the app throws
`unknown config id`.

### 7.1 Mutations

Install:

1. Read `_meta.json`. If absent or unparseable, treat as `{"appliedId":"","entries":[]}`
   and record that it was absent (for restore).
2. Generate a fresh lowercase UUID v4. Never reuse an id from `entries`.
3. Write `<uuid>.json` with the §6 object, mode `0600`, UTF-8 **without BOM**,
   key order as in §6, trailing newline.
4. Add `{"id": uuid, "name": "<config name>"}` to `entries`.
5. Set `appliedId` to the new uuid.
6. Write `_meta.json`, mode `0600`, without BOM.

Update: same as install but reuses the recorded uuid, rewriting `<uuid>.json`
in place, leaving other entries untouched.

Uninstall (`--uninstall`):

1. Delete only `<uuid>.json` for the recorded uuid.
2. Remove only that id's record from `entries`.
3. If `appliedId` is the recorded uuid, set it to the previously recorded
   appliedId **if that id still exists in `entries`**; otherwise to the first
   remaining entry's id; otherwise `""`.
4. Never delete `_meta.json`, never touch another entry.

Any operation that would leave `appliedId` naming a non-existent id is a bug
and must abort with `meta-invariant` (exit 6) before writing.

---

## 8. Credential helper contract

Implements `claude.com/docs/third-party/claude-desktop/credential-helper.md`.

- Receives no arguments. `inferenceCredentialHelperArgs` is never set.
- Reads `<home>/.claude/settings.json` at an absolute path baked in at install
  time. The path is a literal in the generated script; it is not taken from an
  environment variable, argv, or a relative resolution, so no input can
  redirect it to another file.
- Refuses to follow a symlink at that path (`lstat` check) — a symlink could
  point the helper at an attacker-chosen file.
- Resolves the token by the same §2/§3 rules.

  Because of §3.1 the helper only ever reads the settings file (source 1).
  It carries no credential of its own: rotating the token in
  `~/.claude/settings.json` is picked up at the next helper run, with no
  reinstall and no Desktop restart.

- stdout: the bare token and nothing else. No JSON wrapper (no extra headers
  are needed).
- stderr: diagnostics, never the token.
- exit `0` on success; `3` when the file or key is missing; `4` on ambiguity;
  `6` when the file is a symlink or unreadable.
- Honours `CLAUDE_HELPER_CONTEXT`: never prompts, never blocks, never opens a
  browser, for any value. Must finish in well under 20 s (the mid-session
  refresh clamp); both implementations run in tens of milliseconds.

---

## 9. State and backups

State directory:

- macOS: `~/Library/Application Support/claude-desktop-provider-setup/`
- Windows: `%LOCALAPPDATA%\claude-desktop-provider-setup\`

`state.json` fields (no secrets, ever):

```json
{
  "schemaVersion": 1,
  "toolVersion": "x.y.z",
  "platform": "macos|windows",
  "installedAt": "<ISO-8601 UTC>",
  "configId": "<uuid>",
  "configName": "<string>",
  "previousAppliedId": "<uuid or empty>",
  "metaExistedBefore": true,
  "helperFiles": ["<abs path>", "..."],
  "baseUrl": "<url>",
  "authScheme": "bearer|x-api-key",
  "tokenSource": "settings",
  "tokenLength": 64,
  "modelIds": ["..."]
}
```

`baseUrl` is stored because `verify` must confirm the live config still matches.
It is never a token. The state directory is `0700`; files are `0600`.

Backups: `backups/<UTC timestamp>/` holding a copy of `_meta.json` and every
`<uuid>.json` present at backup time, plus `manifest.json` recording the
relative path, byte size, and SHA-256 of each. Restore verifies the manifest
before writing anything.

---

## 10. Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 2 | usage / bad arguments |
| 3 | unusable CLI configuration (missing token, bad URL, bad JSON) |
| 4 | ambiguity requiring explicit disambiguation |
| 5 | environment problem (app absent, unwritable path) |
| 6 | write or verify failure, invariant violation |
| 7 | credential helper failed during verification |

---

## 11. Redaction

Never printed, logged, or written anywhere except the helper's stdout:

- the token value, in whole or in any prefix of 6+ characters
- the base URL's path and query

Printed instead: `tokenLength`, `tokenSource`, base URL scheme + host.

Diagnostics may print file paths, key names, versions, and exit codes.

If any output routine is about to print a value that equals the token, it must
print `<redacted>` instead. The conformance suite asserts that no fixture token
appears in any plan output.

---

## 12. Plan output (conformance contract)

Both implementations must produce the same **plan** object under
`--print-plan` (a dry run that writes nothing):

```json
{
  "ok": true,
  "baseUrl": "https://gw.example.com/api/anthropic",
  "baseUrlHost": "gw.example.com",
  "authScheme": "bearer",
  "tokenSource": "settings",
  "tokenLength": 32,
  "credentialKind": "helper-script",
  "deploymentMode": "3p",
  "helperTtlSec": 900,
  "modelDiscoveryEnabled": false,
  "models": [{"name": "m1", "anthropicFamilyTier": "opus", "isFamilyDefault": true}],
  "warnings": [{"kind": "env-shadowed", "detail": "ANTHROPIC_MODEL"}],
  "errors": []
}
```

`modelDiscoveryEnabled` is present only when `--no-model-discovery` or
`--require-model-discovery` was given; otherwise it is absent from the plan.

On failure:

```json
{"ok": false, "errors": [{"kind": "auth-ambiguity", "code": 4}], "warnings": []}
```

Keys of each model object are emitted in this fixed order and only when
present: `name`, `labelOverride`, `supports1m`, `prefer1m`,
`anthropicFamilyTier`, `isFamilyDefault`, `behavesAs`, `maxEffort`.
Arrays keep insertion order. Comparison is structural, not textual: key order
in the serialised JSON does not matter for the conformance diff, but the
*set and values* must match exactly.

Warnings are compared by `kind` and position only; `detail` is diagnostic prose
in the user's locale and is not part of the contract. Everything else — every
field of every model object, in order — is compared exactly.
