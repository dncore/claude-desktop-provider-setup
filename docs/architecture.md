# Architecture

## The problem this shape solves

Two platforms must reach the same decision from the same input, and neither may
require a runtime the user does not already have. There is no language that is
guaranteed present on both a stock macOS 13 machine and a stock Windows 10
machine: macOS has no PowerShell, Windows has no POSIX shell worth the name,
and Node.js and Python are explicitly out of scope.

So the "shared core" here is a **specification plus fixtures**, not shared
code:

```
src/common/SPEC.md              normative behaviour
src/common/*.schema.json        normative shapes
tests/fixtures/common/<case>/   input and expected output, one directory per case
src/macos/                      implementation A
src/windows/                    implementation B
tests/run-conformance.{sh,ps1}  the two runners that hold A and B together
```

A change to behaviour starts in `SPEC.md`, gains a fixture, and is implemented
twice. If the runners disagree on any fixture, one implementation is wrong by
definition. This is the only arrangement under which "no extra runtime" and
"one behaviour" can both be true.

## Layers

```
install.command / install.bat        entry points; keep the window open on double-click
        │
        ▼
src/{macos,windows}/cli.*            argument parsing and dispatch, nothing else
        │
        ├── core                        read Claude Code settings, resolve, map models
        ├── config-manager              read/write the Claude Desktop configuration library
        ├── backup-manager              backups, restore, state.json
        ├── setup                       install / update / verify / diagnose
        └── credential-helper (template) generated per user, then run by Claude Desktop
```

Each module has one job and no module reaches around another. `core` never
touches the filesystem outside the settings file; `config-manager` never
decides what the configuration should contain.

## Why the credential helper

`inferenceCredentialKind: static` with `inferenceGatewayApiKey` would work and
would be simpler. It is rejected because it writes a secret into a
configuration file that:

- the app stores in plaintext when secure storage is unavailable [DOC];
- cannot be copied to another machine or account, because an encrypted value is
  undecryptable there and the app then refuses to start sessions [DOC];
- is read by `--diagnose` and by anyone who can read the user's home.

`helper-script` inverts this. The configuration file contains **no secret at
all**, and the helper reads `~/.claude/settings.json` at each invocation. The
consequences are all good:

- rotating the token in `settings.json` is picked up on the next helper run —
  no reinstall, no restart (verified on both platforms);
- the configuration file is safe to inspect, diff, back up and paste into an
  issue;
- there is no per-machine encryption state to become unreadable.

The cost is one process spawn per cache window, which is why the TTL defaults
to 900 s rather than a very small value.

### Why the helper refuses to run on an environment-only token

Claude Desktop is not started from the user's login shell, so a helper inherits
almost nothing from it. A token that exists only in `ANTHROPIC_AUTH_TOKEN` in
`~/.zshrc` cannot be re-read at refresh time. The only ways to bridge that are a
plaintext copy or a Keychain item that either prompts on every refresh (killing
silent mid-session refresh) or is readable by any local process. Refusing, with
an instruction to add one line to `settings.json`, is better than all of them.
See `SPEC.md` §3.1.

## Why the local library and not a managed policy

Summarised here, argued in `docs/research-findings.md` §7 and
`docs/security.md`. A policy marks the device managed, which on Windows refuses
WSL Code sessions unless *machine* policy supplies a key that a *user* policy
cannot, degrades remote file downloads, and sandboxes Code shell egress. The
local library has no such effects, needs no administrator, and is the exact
location the in-app configuration window writes.

## Install transaction

The order matters and is not arbitrary:

1. **Resolve and validate** everything from Claude Code's settings. Fail before
   touching anything.
2. **Back up** `_meta.json` and every configuration file in the library.
3. **Write the helper** to `<state>/helper/`, after a syntax check.
4. **Write `<uuid>.json`**, validated as JSON before it is moved into place.
5. **Update `_meta.json`**: append the entry, set `appliedId`, assert the
   invariant Claude Desktop enforces (`appliedId` must name an existing entry),
   then write atomically.
6. **Write `state.json`** describing exactly what was created.
7. **Run the helper** and fail the install if it does not produce a credential.

A crash between 4 and 5 leaves an unreferenced `<uuid>.json` that Claude
Desktop ignores, and no state file — a re-install creates a new id and leaves
the orphan. That is the least harmful failure mode available, and it is
documented rather than hidden.

The existing entries are never rewritten. `_meta.json` is edited through a
plist round trip on macOS (`plutil` + `PlistBuddy`) and through
`ConvertFrom-Json`/`ConvertTo-Json` on Windows, so a user's entry names — which
may contain quotes, colons, tabs and non-ASCII text — survive byte-for-byte in
meaning. Verified with the name `Team 配置: prod`.

## Uninstall is a transaction too

Uninstall removes exactly the id recorded in `state.json` and its entry, then
restores `appliedId` to the value recorded at install time **if that id still
exists**, else the first remaining entry, else the empty string. It never
deletes `_meta.json`, never touches another entry, and never touches
`~/.claude/settings.json`. A backup is taken first, so uninstall is itself
reversible. Verified on both platforms: the library returns to its original
`appliedId` and entry list.

## Testing levels

| Level | What it proves | Where |
|---|---|---|
| Conformance | Both implementations resolve 28 fixtures identically | `tests/run-conformance.*`, run in CI on `macos-latest` and `windows-latest` |
| Lifecycle | install → rotate → verify → update → backup → uninstall leaves the library as it found it | `tests/macos/test-lifecycle.sh`, `tests/windows/test-lifecycle.ps1` |
| Helper protocol | Exit codes 0/3/4/6 and stdout carrying only the token | exercised inside the lifecycle suites |
| Real application | That Claude Desktop accepts the configuration and connects | **not automated**; see "Known limits" in the README |

The conformance suite runs in a throwaway `HOME`/`USERPROFILE` with every
`ANTHROPIC_*` variable cleared, so a developer's own environment cannot mask a
regression. It also asserts that the fixture's credential never appears in
either output stream.

## Platform-specific choices worth knowing

- **macOS** reads JSON with `plutil` and rewrites `_meta.json` through a plist
  round trip, because `plutil` cannot address a dictionary key containing a
  dot — which is why the model mapping file is an array, not an object keyed by
  model ID.
- **Windows** writes files with `UTF8Encoding($false)` everywhere. PowerShell
  5.1's `-Encoding UTF8` emits a BOM, and a BOM makes the consumer's
  `JSON.parse` fail. This is the single most likely way to break Desktop
  silently, so it is centralised in `Write-TextNoBom`.
- **Windows** helpers are a `.cmd` launcher over a `.ps1`. The launcher passes
  `-ExecutionPolicy Bypass` scoped to that one process, because some Windows
  client builds default to `Restricted` and would otherwise refuse a script the
  user installed deliberately. No machine-wide setting is changed.
- **Windows** property lookups are case-sensitive by hand (`Get-Prop`), because
  PowerShell's normal member access is case-insensitive and would diverge from
  `plutil` reading the same JSON.
- **Windows data paths are virtualized for the current MSIX build.** The app's
  `%LOCALAPPDATA%` resolves to
  `%LOCALAPPDATA%\Packages\<PackageFamilyName>\LocalCache\Local`, so the
  library lives there, not in the real `%LOCALAPPDATA%\Claude-3p`. Writing the
  real path produces a configuration the app silently never reads. Paths are
  therefore resolved at start-up (`Initialize-ClaudePaths`) rather than when a
  module is loaded, and the library directory is created by the tool when the
  app has never entered third-party mode. See
  `docs/research-findings.md` §7a.
