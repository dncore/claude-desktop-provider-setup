# Troubleshooting

Start with:

```
macOS:    ./install.command diagnose
Windows:  .\install.bat diagnose
```

The output is redacted and safe to paste into an issue, unless your gateway URL
is itself sensitive.

---

## The installer stops before writing anything

That is by design: everything is validated before the first write. The exit code
tells you which class of problem it is.

| Exit | Meaning | Look at |
|---|---|---|
| 2 | usage error | the message names the bad argument |
| 3 | your Claude Code configuration is unusable | the messages below |
| 4 | ambiguity you must resolve | `--auth-scheme` |
| 5 | environment problem | the app, the version, a missing directory |
| 6 | write or verify failure | filesystem permissions, disk full |
| 7 | the helper did not produce a credential | `diagnose` |

### `settings-missing`

`~/.claude/settings.json` does not exist (or `%USERPROFILE%\.claude\settings.json`
on Windows). This tool migrates an existing configuration; there is nothing to
read.

### `invalid-json`

That file is not valid JSON. A trailing comma is the usual cause. Fix it —
Claude Code itself would also be having trouble.

### `missing-credential`

Neither `env.ANTHROPIC_AUTH_TOKEN` nor `env.ANTHROPIC_API_KEY` is set **inside
the `env` block** of the settings file. Note the emphasis: a variable exported
in your shell does not count. See the next entry for why.

### `token-not-in-settings`

The credential exists only in your environment. Claude Desktop is not started
from your login shell, so its credential helper could not read it later. Add it
to the `env` block:

```json
{ "env": { "ANTHROPIC_BASE_URL": "https://gw.example.com", "ANTHROPIC_AUTH_TOKEN": "…" } }
```

The tool will not do this for you: it never modifies your Claude Code settings.

### `auth-ambiguity`

Both `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY` are set with **different**
values. Claude Code sends `Authorization: Bearer` *and* `X-Api-Key`; Claude
Desktop can send only one. Choose:

```
./install.command --auth-scheme bearer      # ANTHROPIC_AUTH_TOKEN
./install.command --auth-scheme x-api-key   # ANTHROPIC_API_KEY
```

If your gateway accepts either, `bearer` is the usual choice for a gateway.

### `invalid-base-url`

The URL must be `https://host/...`. Plain `http` is refused because the
credential would cross the network in cleartext; `--allow-http` exists for
loopback testing only. URLs with embedded `user:pass@` are refused.

Note that the tool never appends `/v1` or `/v1/messages`. Whatever worked as
`ANTHROPIC_BASE_URL` for Claude Code is passed through unchanged.

### `mapping-unlisted`

Your model mapping file names a model ID that is not in your Claude Code
configuration. Either add it to `ANTHROPIC_MODEL` / `ANTHROPIC_DEFAULT_*_MODEL`,
or pass `--allow-unlisted-models` if you know the gateway serves it.

---

## It installed, but Claude Desktop still asks for a Claude.ai login

1. **Quit the app properly.** Configuration is read at launch; closing the
   window is not quitting. macOS: <kbd>⌘Q</kbd>. Windows: close from the
   notification area.
2. **Check for a managed profile.** A profile overrides the local configuration
   completely.
   - macOS: is `/Library/Managed Preferences/com.anthropic.claudefordesktop.plist`
     present? `diagnose` says.
   - Windows: does `HKLM:\SOFTWARE\Policies\Claude` exist? If it does, Claude
     Desktop ignores everything this tool wrote, including `HKCU` policy.
3. **Check `deploymentMode`.** `3p` hides the Claude.ai option. If something set
   `deploymentMode` to `1p`, the app always signs in to Claude.ai.

## "Your organization hasn't configured any models"

Claude Desktop accepts only `inferenceModels` entries whose `name` references an
Anthropic model. Anything else is discarded, and because the presence of
`inferenceModels` also suppresses model discovery, an all-discarded list leaves
the picker empty. Check the app log
(`...\LocalCache\Local\Claude-3p\logs\main.log` on an MSIX install) for:

```
inferenceModels: "X" is not an Anthropic model and was removed from the list
Model discovery: skipped (inferenceModels obviates discovery); picker = 0 (empty)
```

The tool now detects this before writing: it drops such IDs and, when none
survive, omits `inferenceModels` so the app discovers the gateway's list
instead. You will see `model-not-anthropic` and `models-discovery-fallback`
warnings. Re-run `update` to apply it.

If it still fails, the gateway's `/v1/models` may be unreachable from the
machine — discovery needs it whenever the list is omitted.

## It connects, but every turn fails

Run `.\install.bat verify` / `./install.command verify`. Then:

- **`helper: FAILED`** — run the helper yourself:
  `~/Library/Application Support/claude-desktop-provider-setup/helper/credential-helper.sh; echo $?`
  (Windows: `%LOCALAPPDATA%\claude-desktop-provider-setup\helper\credential-helper.cmd; echo %ERRORLEVEL%`).
  Exit 3 means no credential in the settings file; 4 means the two variables
  disagree; 6 means the file is missing, unreadable, or a symlink.
- **The gateway rejects the token.** The helper returns exactly what is in
  `settings.json`. If Claude Code works and Desktop does not, compare the base
  URL in the two: some gateways require the same path prefix.
- **401 or 403 with `x-api-key`.** Your gateway may expect a bearer token.
  Re-run with `--auth-scheme bearer`.

## Only some models appear, or the wrong one is the default

The first entry of `inferenceModels` is the default model, and entries come from
`ANTHROPIC_MODEL` followed by `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL`.
If a model is missing, it was not set in `settings.json`. Fix the source, then
`./(install.command|install.bat) update`.

If model *discovery* is failing on your network (a gateway without
`/v1/models`), pass `--no-model-discovery`. The tool warns that tier aliases are
documented as needing discovery, because that interaction is not fully
specified — see `docs/research-findings.md` §8.

## "Claude can't read your saved key"

That banner refers to an API key saved through the in-app configuration window,
encrypted for a different OS user or machine. It is not from this tool — this
tool never writes a key. Open the configuration window, enter the key again for
the configuration that has it, or delete that configuration. If you have a
backup, `restore` will bring back the previous state.

## The installer says the app has never run

`configLibrary/` does not exist. Launch Claude Desktop once, quit it, and run
the installer again. Creating the directory tree yourself produces an install
the app may not read.

## I want to see exactly what it will change

```
./install.command plan        # macOS
.\install.bat plan            # Windows
```

Prints the resolved plan as JSON. Nothing is written.

## I want to go back

```
./uninstall.command           # macOS
.\uninstall.bat               # Windows
```

Removes only this tool's entry and restores the previously applied
configuration. Backups are kept. `restore` additionally reverts the library to a
recorded snapshot:

```
./install.command restore                     # most recent backup
./install.command restore 20261123T013710Z    # a specific one
./install.command list-backups
```

## Known limits

- **No automated test against a real Claude Desktop.** The suites prove file
  handling, the plan, and the helper protocol; they do not prove the app
  accepts the result. That needs a machine with the app installed and is listed
  as a known gap rather than claimed.
- **Windows MSIX virtualization is handled but subtle.** The current Windows
  build packages the app as MSIX, so its `%LOCALAPPDATA%` is redirected to
  `%LOCALAPPDATA%\Packages\Claude_<pfn>\LocalCache\Local`. The tool resolves
  this automatically. If you ever move a configuration by hand, use that
  virtualized path, not `%LOCALAPPDATA%\Claude-3p`.
- **`inferenceGatewayBaseUrl` validation rules beyond "full URL" are unknown.**
  The tool passes the user's URL through rather than guessing.
- **The model-discovery / tier-alias interaction is not fully specified.** See
  above.
