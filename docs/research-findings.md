# Research findings

Everything in this document was established before any code was written. Each
statement carries one of these labels:

| Label | Meaning |
|---|---|
| **[DOC]** | Stated in Anthropic's official documentation at the cited URL. |
| **[SRC]** | Verified in the shipped application binary (`app.asar` of Claude Desktop 2.2553.1). |
| **[LOCAL]** | Observed in a real file or process on a real machine. |
| **[COMMUNITY]** | Reported by third parties; not independently confirmed here. |
| **[?]** | Not verified. Do not build on it without testing. |
| **[NO]** | Established as unsupported. |

Where documentation and observation disagree, the observation is reported and
the discrepancy is called out.

---

## 0. Method

- Read `claude.com/docs/third-party/claude-desktop/{configuration,
  configuration-format, credential-helper, mdm, in-app-configuration,
  installation, data-storage}.md`, `code.claude.com/docs/en/{settings,
  model-config, env-vars}`, and `support.claude.com/.../18466061`.
- Unpacked the shipped `app.asar` of Claude Desktop 2.2553.1 and read the
  configuration-library code rather than inferring its format.
- Inspected a live installation's `configLibrary` directory.
- Ran the finished tool end to end on macOS 27.0 (arm64) and Windows 10 22H2
  build 19045 with Windows PowerShell 5.1.19041.

---

## 1. Is a migration tool necessary at all?

**[DOC]** Yes. *"The desktop app takes its provider settings from its Claude
Desktop on 3P configuration, not from `ANTHROPIC_BASE_URL` or `settings.json`,
and passes them to the Code sessions it starts."*
(`support.claude.com/en/articles/18466061-move-claude-code-cli-users`)

There is no native import of a Claude Code gateway configuration. Without a
tool, the user re-enters base URL, credential and model IDs by hand. The
premise of this project holds.

---

## 2. Where Claude Desktop reads configuration

**[DOC]** (`configuration-format.md`, `mdm.md`)

| Platform | Managed (administrator) | Local (user, no admin) | Precedence |
|---|---|---|---|
| macOS | `/Library/Managed Preferences/com.anthropic.claudefordesktop.plist` (machine) and `…/<user>/…plist` (user) | `~/Library/Application Support/Claude-3p/configLibrary/` | Managed > local |
| Windows | `HKLM\SOFTWARE\Policies\Claude` (machine), `HKCU\SOFTWARE\Policies\Claude` (user) | `%LOCALAPPDATA%\Claude-3p\configLibrary\` | HKLM > HKCU > local |

**[DOC]** The Windows hives are **not merged**: if any value exists under
`HKLM\SOFTWARE\Policies\Claude`, `HKCU` is ignored entirely — including when
the HKLM value is unreadable. A single `REG_EXPAND_SZ` under HKLM therefore
disables user policy without supplying configuration.

**[DOC]** Only `REG_SZ` and `REG_DWORD` are read. Values must sit directly
under the policy key; the app never reads subkeys, which is what some ADMX-based
tooling writes. `REG_QWORD`, `REG_MULTI_SZ` and `REG_BINARY` are invisible.

**Consequence for this project:** a user-level configuration exists on both
platforms and needs no administrator rights, no MDM, and no profile approval.

---

## 3. The local configuration library, verified from the binary

**[SRC]** From `app.asar`:

```js
lIe = /^[a-f0-9-]{36}$/                      // valid configuration id
Mu()  => join(appDataDir, "configLibrary")   // library directory
Nu(e) => join(Mu(), `${e}.json`)             // one configuration
Pu()  => join(Mu(), "_meta.json")            // index
Wun(e,t): throws "unknown config id" unless the id matches lIe and appears in t.entries
```

**[SRC]** A configuration entry is `{ id, name, note? }`.

**[LOCAL]** A real `_meta.json` on a working installation:

```json
{"appliedId":"359f288e-…","entries":[{"id":"359f288e-…","name":"Default"}]}
```

**[LOCAL]** The corresponding `359f288e-….json` is a flat JSON object of
configuration keys with native JSON types, and contained
`"inferenceGatewayApiKey": "…"` **in plaintext** on that installation.

**[DOC]** Tools that write these files are contemplated: *"Tools that read or
write the `configLibrary/` files: a tool that reads the key gets the encrypted
value… A tool that writes an unencrypted key still works."*

**[DOC]** The documented hazard is copying the directory **to another device or
OS account**, not writing it on the same device: an API key saved through the
UI is encrypted per OS user (Keychain / DPAPI), so a copy is undecryptable and
the app shows *"Claude can't read your saved key"*.

**[LOCAL]** The file observed on a real installation was not encrypted, which
shows the encryption depends on the write path and on secure storage being
available. **This project writes no key at all**, so the question does not
arise for configurations it creates.

---

## 4. Configuration keys

**[DOC]** All from `configuration.md`.

| Key | Type | Values / notes |
|---|---|---|
| `inferenceProvider` | enum | `gateway`, `anthropic`, `bedrock`, `mantle`, `vertex`, `foundry`. Setting it activates third-party mode. |
| `inferenceCredentialKind` | enum | `static`, `helper-script`, `interactive`, `vendor-profile`, `workforce`, `external-idp`. When set, only that source is used. |
| `inferenceGatewayBaseUrl` | string | "Full URL of the inference gateway endpoint." |
| `inferenceGatewayAuthScheme` | enum | `bearer` (default), `x-api-key`. **Singular**: one credential per request. |
| `inferenceGatewayApiKey` | string | Stored in plain configuration. Not available in the Admin Console. |
| `inferenceCredentialHelper` | string | Absolute path to an executable that prints the credential. |
| `inferenceCredentialHelperWindows` | string | Absolute Windows path; **same protocol**, other platforms ignore it. |
| `inferenceCredentialHelperArgs` | string[] | One argument per entry. Empty entries, `"`, `%` and control characters are rejected. |
| `inferenceCredentialHelperTtlSec` | integer | Default 3600. |
| `inferenceCredentialHelperTimeoutSec` | integer | Default 60, max 600; clamped to 20 s for mid-session refresh. |
| `inferenceCredentialHelperSilentRefreshEnabled` | boolean | Default true. |
| `modelDiscoveryEnabled` | boolean | Default on. With a gateway, discovery is skipped when `inferenceModels` is set and holds no tier alias. |
| `inferenceModels` | object[] | See below. First entry is the default model. |
| `deploymentMode` | enum | `any`, `3p`, `1p`. Allowed in the local file and in an MDM profile, ignored in a bootstrap response. `3p` hides the Claude.ai sign-in. |

**[DOC]** `inferenceModels` entries accept `name` (required), `labelOverride`,
`supports1m`, `prefer1m`, `anthropicFamilyTier`
(`sonnet|opus|haiku|fable|mythos`), `isFamilyDefault`, `behavesAs`, `maxEffort`
(`low|medium|high|xhigh|max`).

**[DOC]** With `modelDiscoveryEnabled: false`, `inferenceModels` is required and
must use full model IDs. Tier aliases such as `sonnet` "need discovery".

### Value encoding in a policy or profile

**[DOC]** In a plist or the registry every value may be a string; booleans are
`"true"`/`"false"` or `REG_DWORD`; integers are decimal strings; **arrays and
objects are a single JSON document encoded as a string**. Subkey paths such as
`inferenceGatewayOidc.clientId` are never read.

**[DOC]** In the local library the file is real JSON, so native types are used.

---

## 5. The credential helper protocol

**[DOC]** (`credential-helper.md`) One protocol for both platforms.

- No arguments are passed unless `inferenceCredentialHelperArgs` is set.
- Exit code must be `0`.
- stdout must be **exactly one of**: a bare token, or
  `{"token": "...", "headers": {...}}`.
- stderr is logged for diagnostics and otherwise ignored.
- The output is cached for `inferenceCredentialHelperTtlSec`.
- `CLAUDE_HELPER_CONTEXT` is set on every invocation to `interactive`,
  `mid-session-refresh`, `scheduled-task`, `setup-test` or `background`;
  the legacy `CLAUDE_HELPER_MANUAL_RUN=1` accompanies `setup-test`.
- A helper should take its silent path for anything other than `interactive`
  and exit non-zero rather than block.
- The helper's `PATH` includes the login-shell `PATH`, so naming `aws`/`gcloud`
  works even when the app was launched from Finder or the Dock.
- Relative paths resolve against the helper's working directory, which may be
  `/` or `System32`, so absolute paths are mandatory.

**[DOC]** A `.cmd`/`.bat` helper receives each argument double-quoted and needs
`%~1` to strip them. A `.ps1`, `.exe` and any helper on macOS receives
arguments as written. So a PowerShell helper is a supported form on Windows.

**[NO]** There is **no macOS-specific helper field**. `inferenceCredentialHelperWindows`
is a path override, not a second protocol. Any design that assumes two
protocols is wrong.

---

## 6. Precedence on the Claude Code side

**[DOC]** (`code.claude.com/docs/en/settings#settings-precedence`,
`env-vars#precedence`)

- Settings files rank: managed > `--settings` > `.claude/settings.local.json`
  > `.claude/settings.json` > `~/.claude/settings.json`.
- *"Environment variables aren't a level in this stack… `ANTHROPIC_MODEL`
  exported in your shell applies over the `model` key from any file, while
  `ANTHROPIC_DEFAULT_MODEL` applies only when no file sets `model`."*
- *"When the same variable is set in both your shell and a settings file `env`
  block, **the settings file value applies** in most sessions. Claude Code
  writes each `env` entry into the process environment, replacing the value
  inherited from the shell."*
- *"`--model` and `/model` override `ANTHROPIC_MODEL`."*

**Consequence:** a migration tool must read the settings `env` block **before**
the process environment, which is the opposite of the intuitive order. This
project implements that order and reports disagreement as a warning rather than
silently preferring one.

**[DOC]** `ANTHROPIC_API_KEY` is sent as `X-Api-Key`; `ANTHROPIC_AUTH_TOKEN` is
sent as `Authorization: Bearer`. Both may be set at once, so Claude Code sends
**two** credentials. Claude Desktop can send only one.

**Consequence:** when the two differ, the tool refuses to guess. See
`src/common/SPEC.md` §3.

---

## 7. Writing a policy has side effects; writing the local library does not

**[DOC]** A profile or policy makes the device **managed**, and that changes
behaviour beyond inference (`mdm.md`, "What a profile or policy changes on a
device"):

- WSL sessions are refused unless **machine** policy (`HKLM`) sets
  `disableWslSessions: false`. *"A per-user `false` doesn't count."*
  A `HKCU` policy — even one this tool would write — therefore breaks WSL Code
  sessions and cannot fix itself.
- `remoteFileDownloads` degrades from `all` to `limited`.
- Shell commands in Code sessions are sandboxed with an empty egress allowlist.

**[DOC]** The local library has none of these effects, and the in-app
configuration window writes to exactly this location.

**Decision and justification:** this project targets *the local library* by
default. That contradicts a naive reading of "prefer the officially supported
managed configuration", but following that reading would degrade the user's
Claude Desktop in three documented ways to gain nothing for a single-user
machine. `inferenceCredentialHelperWindows` and every key used here are also
valid in a policy, so a fleet deployment can reuse the same resolution core —
see `docs/architecture.md`.

---

## 7a. Windows: the current build is MSIX and its data is virtualized

**[LOCAL]** Established by installing Claude Desktop 6.28899.6.0 on Windows 10
22H2 build 19045 from the official signed installer.

- The published Windows download is a **bootstrapper**. It downloads an MSIX,
  verifies the MSIX signature against its own, provisions the package for all
  users, and then launches the app through
  `explorer.exe shell:AppsFolder\Claude_pzs8sxrjxfjjc!Claude`.
- The package lands in
  `C:\Program Files\WindowsApps\Claude_6.28899.6.0_x64__pzs8sxrjxfjjc`.
  `%LOCALAPPDATA%\AnthropicClaude` — the classic Squirrel path — is **never
  created**.
- The app registers an execution alias, `claude-desktop.exe`, on `PATH`. Its
  real executable inside the package is `app\Claude.exe`.
- **MSIX file-system virtualization is active.** The app's `%LOCALAPPDATA%`
  resolves to
  `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local`.
  A normal process writing `%LOCALAPPDATA%\Claude-3p` writes to a different
  directory that the app never reads.
- Consequently the configuration library the app uses is
  `…\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\configLibrary`,
  and its logs are in
  `…\LocalCache\Local\Claude\logs\main.log`.
- The app creates `Claude-3p` only when it runs in third-party mode, which it
  cannot do before a configuration exists. A tool therefore has to create the
  directory tree itself; waiting for the app is circular.
- `C:\Program Files\WindowsApps` is not enumerable by a standard user, so
  "search the install directory" is not a usable detection strategy. The
  execution alias is.

**[LOCAL]** Proof that the app accepted a configuration written this way: after
a tool-written configuration was placed in the virtualized library and the app
was restarted, the app created a full third-party user-data directory and its
own `config.json` recorded

```json
"hostGitConfinedInstall": { "reasons": ["third_party"] }
```

and `main.log` recorded `[managedConfig] configuration at launch { type: 'none',
remote: false, managedKeys: [] }`, confirming no policy was involved.

**[DOC]** This is consistent with the data-migration note that warns about a
`Local\Claude-3p` or `Roaming\Claude-3p` folder under
`…\Packages\Claude_pzs8sxrjxfjjc\LocalCache`, which this implementation
independently rediscovered before noticing that sentence.

## 8. What remains unverified

| Item | Status | Consequence for this project |
|---|---|---|
| Exact validation of `inferenceGatewayBaseUrl` beyond "full URL" | **[?]** | The tool passes the user's existing URL through unchanged, minus trailing slashes, and never invents a path suffix. |
| Whether the app appends `/v1/messages` to the gateway base URL | **[?]** | Pass-through is the only safe assumption; the format that works for Claude Code is assumed to work for Desktop, corroborated by a live configuration whose base URL includes `/api/anthropic`. |
| Whether the app issues a model request successfully through the helper | **[?]** | The helper was exercised directly (exit 0, token returned) and the app started in third-party mode, but no reachable gateway existed in the test environment to complete a turn. |
| Whether `anthropicFamilyTier` resolves without model discovery | **[?]** | Discovery is left at its default; `--no-model-discovery` warns that the combination is undocumented. |
| Whether `inferenceModels` IDs are validated against the gateway's `/v1/models` | **[?]** | Only IDs already present in the user's Claude Code configuration are emitted. |
| MSIX install path of Claude Desktop on Windows | **[LOCAL]** verified | Resolved. The current build is MSIX with a virtualized data directory; see §7a. Implemented and confirmed against a real install. |
| macOS per-user managed preferences requiring a signed profile | **[?]** | Not needed: the local library path is used. |

---

## 9. Sources

- https://claude.com/docs/third-party/claude-desktop/configuration.md
- https://claude.com/docs/third-party/claude-desktop/configuration-format.md
- https://claude.com/docs/third-party/claude-desktop/credential-helper.md
- https://claude.com/docs/third-party/claude-desktop/mdm.md
- https://claude.com/docs/third-party/claude-desktop/in-app-configuration.md
- https://claude.com/docs/third-party/claude-desktop/installation.md
- https://claude.com/docs/third-party/claude-desktop/data-storage.md
- https://code.claude.com/docs/en/settings
- https://code.claude.com/docs/en/env-vars
- https://code.claude.com/docs/en/model-config
- https://support.claude.com/en/articles/18466061-move-claude-code-cli-users
