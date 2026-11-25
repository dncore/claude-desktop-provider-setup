# claude-desktop-provider-setup

**English** · [简体中文](README.zh-CN.md)

Point Claude Desktop at the same third-party gateway your Claude Code CLI
already uses — in one command, without retyping your base URL, token or model
IDs.

```
$ ./install.command

  backup: …/backups/20261123T013710Z
  helper: …/helper/credential-helper.sh

Claude Desktop is configured.
  provider:   gateway
  base URL:   https://gw.example.com/api/anthropic
  auth:       bearer
  credential: helper script (token read from settings.json, 21 bytes)
  models:     4 configured
    - gw-default
    - gw-opus (opus)
    - gw-sonnet (sonnet)
    - gw-haiku (haiku)
  config id:  7b4b4385-dabb-4fbe-af5d-6786f91d1e12
```

---

## 1. What this is

Claude Desktop takes its provider settings from its own third-party
configuration. It does **not** read `ANTHROPIC_BASE_URL` or your
`~/.claude/settings.json` — Anthropic says so explicitly in
[Move Claude Code CLI users](https://support.claude.com/en/articles/18466061-move-claude-code-cli-users).
So a developer who already points Claude Code at a gateway has to re-enter
everything by hand for Desktop.

This tool reads your existing Claude Code configuration, translates it into a
Claude Desktop third-party inference configuration, installs a credential
helper, maps your models, and restarts nothing without telling you.

It is **not** a replacement for Claude Desktop, a proxy, or a gateway. It moves
one configuration from one place to another and can take it back out again.

## 2. Using it with magpie

[magpie](https://github.com/yetone/magpie) (MIT, open source) puts every coding
agent behind one local gateway and writes each agent's configuration for you.
Paired with this tool you never re-type your gateway URL, token or model ids:
this tool reads the Claude Code configuration you already have and hands it to
magpie in the form magpie imports.

Pick one path:

| You want | Do this |
|---|---|
| Claude Desktop configured directly, no extra software | `install`, see [§5](#5-installing-and-using) |
| magpie to own the configuration and route every agent | the five steps below |

### Step 1 — install magpie

Download it from [github.com/yetone/magpie](https://github.com/yetone/magpie) or
from its [releases](https://github.com/yetone/magpie-releases/releases) — macOS,
Windows and Linux; the `magpie-cli-*` build is enough on a machine with no
desktop session. Then check it answers:

```sh
magpie --version
```

### Step 2 — see what this tool would export

```sh
./install.command magpie          # macOS
.\install.bat magpie              # Windows
```

Nothing is written. It prints the provider name, the Anthropic root, the model
ids and a link like this one:

```
magpie://import?name=wonlap&anthropic=https%3A%2F%2F…&models=…
```

### Step 3 — hand the link to magpie

```sh
./install.command magpie --apply
```

magpie asks for the API key once. Paste the token from your
`~/.claude/settings.json` — the same one Claude Code uses.

The link deliberately carries no key, so it is safe to print, paste or show to
someone. The trade-off: this step needs a terminal. With no terminal the tool
prints the link and stops rather than applying half of it.

### Step 4 — bind the model tiers (optional, and not free)

```sh
./install.command magpie --apply --set-tiers
```

This binds sonnet / opus / haiku / fable to the models your Claude Code
configuration names. It also **rewrites `~/.claude/settings.json` to point at
magpie's gateway**, so from then on Claude Code needs magpie running:

```sh
magpie daemon install
```

Skip this step and Claude Code keeps talking to your gateway directly.

### Step 5 — restart Claude Desktop

magpie writes the third-party profile and Claude Desktop reads it at launch. The
models it offers come from the gateway's catalogue.

### When something looks wrong

| Symptom | Cause | Fix |
|---|---|---|
| `magpie is not installed` | not on `PATH` | install it, then re-run step 2 |
| no prompt appears during `--apply` | no terminal | run it from a terminal window |
| Claude Code stops working after step 4 | magpie is not running | `magpie daemon install` |
| the model list is empty | the gateway publishes no `/v1/models` | add the provider in magpie by hand |
| you want out | — | `magpie claude default` puts Claude Code back; `uninstall` removes this tool |

## 3. Supported platforms

| Platform | Versions | Status |
|---|---|---|
| macOS | 13 Ventura and later, Apple silicon and Intel | implemented; conformance and lifecycle suites pass |
| Windows | 10 build 19041+ and Windows 11, PowerShell 5.1+ | implemented; conformance and lifecycle suites pass on Windows 10 22H2 / PS 5.1 |

Linux is not supported by this tool. Claude Desktop's Linux build exists, but it
was not tested here and the installer does not pretend otherwise.

## 4. Requirements

- Claude Desktop installed **and launched at least once** (it creates the
  configuration directory on first run). If it is missing the tool tells you
  where to get it and does not download anything.
- Claude Code configured with a gateway in `~/.claude/settings.json`.
- No administrator rights. No Homebrew, Node.js, Python or PowerShell 7.

See [macOS installation](docs/macos-installation.md) and
[Windows installation](docs/windows-installation.md).

## 5. Installing and using

```sh
git clone https://github.com/dncore/claude-desktop-provider-setup.git
cd claude-desktop-provider-setup
./install.command          # macOS
.\install.bat              # Windows
```

Look before you leap — this writes nothing:

```sh
./install.command plan
```

Then restart Claude Desktop. That is all.

### 4.1 What a run prints

```
  backup: …/backups/20261123T013710Z      a copy of the library before it changed
  helper: …/helper/credential-helper.sh   the script Desktop calls for a token

Claude Desktop is configured.
  provider:   gateway                     the only provider this tool writes
  base URL:   https://gw.example.com/api/anthropic
  auth:       bearer                      what Claude Code sends today
  credential: helper script (token read from settings.json, 21 bytes)
  models:     4 configured                first entry is Desktop's default
  config id:  7b4b4385-…                  the entry this tool owns
```

Nothing on those lines is a secret. The byte count is the token's length, not the
token.

### 4.2 Commands

| Command | Purpose | Writes anything? |
|---|---|---|
| `plan` | print the resolved plan as JSON | no |
| `install` | configure Claude Desktop (the default) | yes |
| `update` | re-apply after you change your Claude Code settings | yes |
| `verify` | check the installed configuration is intact and usable | no |
| `diagnose` | print a redacted report, safe to paste into an issue | no |
| `backup` / `restore` / `list-backups` | snapshot and revert the configuration library | yes |
| `magpie` | export the provider for magpie, see [§2](#2-using-it-with-magpie) | only with `--apply` |
| `uninstall` | remove only what this tool created | yes |

### 4.3 Everyday cases

**You rotated the token.** Nothing to do. The configuration holds a helper path,
not a secret, so Desktop reads the new value on its next request.

**You changed the model list.** Run `./install.command update`. It re-reads
`settings.json`, rewrites the same entry, and takes a backup first.

**Something looks wrong.** `./install.command verify` checks the files and the
helper protocol; `./install.command diagnose` prints the redacted report that
makes an issue actionable.

**You want it gone.** `./uninstall.command`. Your Claude Code file was never
touched, so nothing needs putting back there.

### 4.4 Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 2 | bad usage |
| 3 | the Claude Code configuration cannot be used (no URL, no model, or a mapping that names a model the file does not have) |
| 4 | two credentials disagree; pass `--auth-scheme bearer\|x-api-key` |
| 5 | an environment problem: Claude Desktop not installed, no backups to restore |
| 6 | a write, or the verification after a write, failed |
| 7 | the credential helper did not answer as specified |

A failure prints one `error: <kind>: <detail>` line on stderr. Nothing is left
half-written; `restore` puts the previous entry back.

### 4.5 On Windows

Paths live under `%LOCALAPPDATA%`, and the current MSIX build of Claude Desktop
keeps its data in a virtualized directory that this tool resolves at run time.
Run `.\install.bat` from the repository folder; the macOS `./install.command`
does not exist there.

Full option list: `./install.command --help`.

## 6. How it works

```
~/.claude/settings.json
        │  read only, never modified
        ▼
   resolve ──── settings env block outranks the shell environment
        │      (that is what Claude Code does; see docs/research-findings.md §6)
        ▼
   plan ────── reject a bad URL, refuse to guess between two credentials
        │
        ├──► <Claude-3p>/configLibrary/<uuid>.json     no secret inside
        ├──► <state>/helper/credential-helper.{sh,cmd} reads settings.json each run
        └──► <state>/state.json                        what we created, for uninstall
```

Three decisions are worth knowing about:

**The configuration file holds no credential.** It uses
`inferenceCredentialKind: helper-script`, so the token stays in the file Claude
Code already reads. Rotate the token there and Desktop picks it up on the next
request — no reinstall, no restart, no second copy of the secret to keep in
sync.

**It writes the per-user configuration library, not a managed policy.** On
Windows a policy under `HKCU` would make Claude Desktop treat the machine as
managed, which documents as refusing WSL Code sessions (only *machine* policy
can re-enable them), degrading remote file downloads, and sandboxing Code shell
egress. None of that happens with the local library, which is also where the
in-app configuration window writes. The trade-off is argued in
[docs/research-findings.md](docs/research-findings.md) §7.

**It refuses rather than guesses.** If `ANTHROPIC_AUTH_TOKEN` and
`ANTHROPIC_API_KEY` are both set with different values, Claude Code would send
both headers but Claude Desktop can send only one. The tool stops and asks.

More: [architecture](docs/architecture.md) ·
[research findings](docs/research-findings.md) ·
[security](docs/security.md).

## 7. Configuration example

Given this `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://gw.example.com/api/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "…",
    "ANTHROPIC_MODEL": "gw-sonnet-5",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "gw-opus-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "gw-haiku-5"
  }
}
```

the tool writes this into the Claude Desktop configuration library:

```json
{
  "inferenceProvider": "gateway",
  "inferenceGatewayBaseUrl": "https://gw.example.com/api/anthropic",
  "inferenceGatewayAuthScheme": "bearer",
  "inferenceCredentialKind": "helper-script",
  "inferenceCredentialHelper": "/Users/<you>/Library/Application Support/claude-desktop-provider-setup/helper/credential-helper.sh",
  "inferenceCredentialHelperTtlSec": 900,
  "inferenceModels": [
    { "name": "gw-sonnet-5" },
    { "name": "gw-opus-5",  "anthropicFamilyTier": "opus",  "isFamilyDefault": true },
    { "name": "gw-haiku-5", "anthropicFamilyTier": "haiku", "isFamilyDefault": true }
  ],
  "deploymentMode": "3p"
}
```

The first model is Claude Desktop's default. `anthropicFamilyTier` lets a tier
alias resolve to your gateway's model. On Windows the equivalent key is
`inferenceCredentialHelperWindows` with a path under `%LOCALAPPDATA%`.

No API key appears anywhere in that file.

## 8. Model mapping

Model IDs are taken verbatim from `ANTHROPIC_MODEL` and the four
`ANTHROPIC_DEFAULT_*_MODEL` variables. Nothing is invented, normalised or
lowercased.

When the gateway's model ID is not enough to describe what the model can do, add
a mapping file:

```sh
cp config/model-mapping.example.json config/model-mapping.json
./install.command --mapping config/model-mapping.json
```

```json
{
  "schemaVersion": 1,
  "models": [
    { "id": "gw-opus-5", "labelOverride": "Opus 5 (gateway)",
      "anthropicFamilyTier": "opus", "supports1m": true, "behavesAs": "claude-opus-5" }
  ]
}
```

`models` is an **array**, not an object keyed by model ID, because model IDs
routinely contain dots (`us.anthropic.claude-sonnet-5`) and the macOS
implementation reads JSON with `plutil`, which cannot address a dictionary key
containing a dot. This is documented in
[architecture](docs/architecture.md) because it looks like a style choice and
is not.

A mapping entry only supplies attributes: `labelOverride`, `supports1m`,
`prefer1m`, `anthropicFamilyTier`, `isFamilyDefault`, `behavesAs`, `maxEffort`.
It cannot add a model ID unless you pass `--allow-unlisted-models`, so you
cannot accidentally configure a model your account cannot serve.

`config/model-mapping.json` is git-ignored; only the example is committed.

## 9. Uninstalling and restoring

```sh
./uninstall.command        # macOS
.\uninstall.bat            # Windows
```

Removes the configuration entry it created, restores whichever configuration was
applied before, deletes the helper and the state file, and keeps the backups.
Every other configuration in the library is untouched, and
`~/.claude/settings.json` is never modified. `--purge` also deletes the backups.

Restoring a snapshot:

```sh
./install.command list-backups
./install.command restore                    # most recent
./install.command restore 20261123T013710Z   # a specific one
```

Restores are verified against a recorded SHA-256 per file before anything is
written.

## 10. Security

- **No secret is written by this tool.** Not to the configuration, not to
  `state.json`, not to logs. Diagnostics report a byte count, never the value.
  The test suite fails if the fixture credential appears in any output.
- **The helper is locked down.** No arguments, an absolute settings path baked
  in as a single-quoted literal, symlink refusal, stdout carrying only the
  token, exit codes 0/3/4/6, and no interactive prompt for any
  `CLAUDE_HELPER_CONTEXT`.
- **Backups may contain a pre-existing key** you saved earlier through the
  in-app window; they are `0600` inside a `0700` directory and never included
  in diagnostics.
- **Keychain / DPAPI were evaluated and rejected** — they would create a second
  copy of a secret that must stay in `settings.json`, and would either prompt
  during silent refresh or be readable by any local process. Full reasoning in
  [docs/security.md](docs/security.md).
- **Nothing calls home.** There is no network code in this project.

## 11. FAQ

**Do I need to re-enter my token?** No, if it is in the `env` block of
`~/.claude/settings.json`. If it is only in your shell environment, the tool
stops and tells you which line to add — Desktop does not inherit your shell, so
a helper could not read it later.

**Will this break Claude Code?** No. It only reads that file.

**Will it break my other Claude Desktop configurations?** No. It adds one entry
alongside yours and never rewrites another.

**Do I need admin / sudo?** No.

**Why not just use `inferenceGatewayApiKey`?** Because that writes your token
into a file in plaintext, ties the configuration to one machine's secure
storage, and makes the file unsafe to share or paste. Rotating the token would
also need a reinstall.

**Does it work with Bedrock, Vertex or Foundry?** Not in this version. It
targets Anthropic-compatible HTTP gateways. The other providers need
credentials this tool has no safe way to obtain.

**My gateway has no `/v1/models`.** Pass `--no-model-discovery`. The tool warns
that tier aliases are documented as needing discovery, because that interaction
is not fully specified.

**Where does it put things?**
macOS: `~/Library/Application Support/{Claude-3p/configLibrary,claude-desktop-provider-setup}`.
Windows: `%LOCALAPPDATA%\{Claude-3p\configLibrary,claude-desktop-provider-setup}`.

## 12. Known limitations

- **Not verified against a running Claude Desktop in automation.** The suites
  prove file handling, the plan and the helper protocol. That the app accepts
  the configuration was verified by reasoning from its shipped code and the
  official schema, not by an automated launch. Treat the first launch as the
  real acceptance test.
- **Windows uses a virtualized data path on the current MSIX build.** The tool
  resolves it at run time and creates the library when the app has not yet
  entered third-party mode; verified against Claude Desktop 6.28899.6.0 on
  Windows 10 22H2. See `docs/research-findings.md` §7a.
- **No model request was completed end to end**, because the test machine had
  no reachable gateway. The app did start in third-party mode with a
  tool-written configuration.
- **Gateways that serve only non-Anthropic model IDs cannot pin models.**
  Claude Desktop discards model IDs that do not reference an Anthropic model,
  so the tool omits `inferenceModels` and lets discovery populate the picker.
  To pin a specific model, the gateway must expose Anthropic-named route
  aliases. See `docs/research-findings.md` §7b.
- **`inferenceGatewayBaseUrl` validation rules are unpublished.** The URL is
  passed through unchanged; no `/v1` suffix is added.
- **Model discovery with tier aliases is under-specified.** See above.
- **Only the `gateway` provider.** Bedrock/Vertex/Foundry are out of scope.
- **The magpie bridge needs a terminal to import.** The import link carries no
  token on purpose, so magpie asks for it interactively; a run with no terminal
  prints the link and stops with exit 5 rather than half-applying it.
- **No Linux.** The code is portable in principle; it was not tested.

## 13. References

- [Claude Desktop third-party: configuration reference](https://claude.com/docs/third-party/claude-desktop/configuration.md)
- [Configuration implementation and value types](https://claude.com/docs/third-party/claude-desktop/configuration-format.md)
- [Write a credential helper](https://claude.com/docs/third-party/claude-desktop/credential-helper.md)
- [Deploy with MDM](https://claude.com/docs/third-party/claude-desktop/mdm.md)
- [In-app configuration](https://claude.com/docs/third-party/claude-desktop/in-app-configuration.md)
- [Installation and setup](https://claude.com/docs/third-party/claude-desktop/installation.md)
- [Data storage](https://claude.com/docs/third-party/claude-desktop/data-storage.md)
- [Claude Code settings and precedence](https://code.claude.com/docs/en/settings)
- [Claude Code environment variables](https://code.claude.com/docs/en/env-vars)
- [Move Claude Code CLI users](https://support.claude.com/en/articles/18466061-move-claude-code-cli-users)

## Contributing

`src/common/SPEC.md` is the source of truth. Change the spec, add a fixture
under `tests/fixtures/common/`, then implement it in both platforms. Run both
suites:

```sh
bash tests/run-conformance.sh        # macOS
.\tests\run-conformance.ps1          # Windows
bash tools/sanitize-check.sh         # before any push
```

## License

MIT. See [LICENSE](LICENSE).

Not affiliated with or endorsed by Anthropic.
