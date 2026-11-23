# Windows installation

## Requirements

| Item | Requirement | Why |
|---|---|---|
| Windows | 10 build 19041 (2004) or later, or Windows 11 | Claude Desktop's documented floor |
| PowerShell | 5.1 (shipped with Windows 10/11) | PowerShell 7 is not required and is not assumed |
| Claude Desktop | installed | the tool writes into the app's configuration library, creating it if the app has not entered third-party mode yet |
| Claude Code | configured with a gateway in `%USERPROFILE%\.claude\settings.json` | this is the thing being migrated |
| Administrator | **not required** | the tool never writes outside your user profile |

## Install

```powershell
git clone https://github.com/dncore/claude-desktop-provider-setup.git
cd claude-desktop-provider-setup
.\install.bat
```

Or double-click `install.bat`. It runs the engine and pauses at the end so the
result stays readable. Set `CDS_NO_PAUSE=1` in automation.

The engine can also be called directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\windows\Cli.ps1 install
```

### A note on execution policy

`install.bat` and the installed credential helper both pass
`-ExecutionPolicy Bypass`. This is scoped to that single process. It does not
change the machine policy and does not weaken anything globally. It is there
because some Windows client builds default to `Restricted`, which would refuse a
local script you installed deliberately. If your organisation enforces policy
through Group Policy, that setting still applies everywhere else.

## What it does, in order

1. Checks the Windows build is ≥ 19041.
2. Finds Claude Desktop and reads its version.
3. Reads `%USERPROFILE%\.claude\settings.json` and resolves the gateway
   configuration.
4. Warns if `HKLM:\SOFTWARE\Policies\Claude` exists, because machine policy
   makes Claude Desktop ignore everything this tool writes.
5. Backs up `_meta.json` and every configuration file in the library.
6. Writes `credential-helper.cmd` and `credential-helper.ps1` to
   `%LOCALAPPDATA%\claude-desktop-provider-setup\helper\`.
7. Adds a configuration entry named **Migrated from Claude Code** and makes it
   the applied one. Other entries are untouched.
8. Writes `state.json` recording exactly what was created.
9. Runs the helper and fails if it does not produce a credential.
10. Tells you to restart Claude Desktop, or restarts it with `--restart`.

## See what it will do first

```powershell
.\install.bat plan
```

Prints the resolved plan as JSON and writes nothing.

## Options

| Option | Effect |
|---|---|
| `--auth-scheme bearer\|x-api-key` | required when `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY` are both set with different values |
| `--mapping <path>` | model mapping file |
| `--allow-unlisted-models` | let the mapping add model IDs that are not in your Claude Code config |
| `--allow-http` | permit a plaintext http base URL (loopback testing only) |
| `--deployment-mode 3p\|any` | `3p` (default) hides the Claude.ai sign-in |
| `--helper-ttl <seconds>` | credential cache lifetime, default 900 |
| `--config-name <name>` | the name shown in Claude Desktop's configuration picker |
| `--restart` | close and relaunch Claude Desktop when done |
| `--verbose` | extra diagnostics on stderr |

## After installing

1. Claude Desktop reads configuration **at launch**. Close it completely
   (including from the notification area) and start it again.
2. The login screen should offer your gateway. With `deploymentMode: 3p` the
   Claude.ai option is hidden.
3. Send one message. If it fails, see [troubleshooting](troubleshooting.md).

## Verifying

```powershell
.\install.bat verify
```

```powershell
.\install.bat diagnose
```

`diagnose` prints a redacted report: the credential appears only as a byte
count. It also reports whether machine policy or user policy exists, because
either would take precedence over the local configuration.

## Updating

```powershell
.\install.bat update
```

Reuses the same configuration id. A token rotation needs no update — the helper
re-reads `settings.json` on every run.

## Uninstalling

```powershell
.\uninstall.bat
```

Removes only the entry this tool created, restores the previously applied
configuration, deletes the helper and `state.json`, and keeps the backups. Your
Claude Code settings file is never touched. Add `--purge` to delete the backups.

## Where the configuration actually goes

The current Windows build installs Claude Desktop as an MSIX package, and MSIX
virtualizes the file system. The app's `%LOCALAPPDATA%` is redirected to:

```
%LOCALAPPDATA%\Packages\<PackageFamilyName>\LocalCache\Local
```

so the configuration library is
`…\LocalCache\Local\Claude-3p\configLibrary\`, and the real
`%LOCALAPPDATA%\Claude-3p` is never used. The tool resolves this at run time
and tells you which path it used under `--diagnose`.

The app creates `Claude-3p` only once it runs in third-party mode, which it
cannot do until a configuration exists. The tool therefore creates the directory
itself and reports a `library-created` warning when it does.

## WSL

Claude Desktop can run Code sessions inside WSL, but only when **machine**
policy sets `disableWslSessions` to `false`. A per-user policy cannot enable it.
Because this tool deliberately does not write policy at all, your WSL behaviour
is unchanged by installing it — which is the point. A tool that wrote
`HKCU\SOFTWARE\Policies\Claude` would silently break WSL sessions and have no
way to fix them from the same hive.

## Manual fallback

1. Open the application menu (☰), **Help → Troubleshooting → Enable Developer
   Mode**, then **Developer → Configure Third-Party Inference…**
2. Set **Inference provider** to `gateway` and fill in **Gateway base URL**.
3. Set **Credential kind** to `Helper script`, with **Helper script (Windows)**
   pointing at an executable you trust.
4. Add your model IDs under **Models**.
5. **Apply Changes**, then **Relaunch now**.

If you have hand-edited files in `configLibrary\`, `.\install.bat restore` puts
back the backup taken before installation.
