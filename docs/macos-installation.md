# macOS installation

## Requirements

| Item | Requirement | Why |
|---|---|---|
| macOS | 13 Ventura or later | Claude Desktop declares `LSMinimumSystemVersion` 13.0 |
| CPU | Apple silicon or Intel | the app ships as a universal binary |
| Claude Desktop | installed, and **launched at least once** | the tool writes into `~/Library/Application Support/Claude-3p/configLibrary/`, which the app creates on first run |
| Claude Code | configured with a gateway in `~/.claude/settings.json` | this is the thing being migrated |
| Shell | `/bin/bash` (present on every macOS) | no Homebrew, Node.js or Python needed |
| Administrator | **not required** | the tool never writes outside your home directory |

## Install

```sh
git clone https://github.com/dncore/claude-desktop-provider-setup.git
cd claude-desktop-provider-setup
./install.command
```

Or double-click `install.command` in Finder. If Finder refuses to run it
because the file arrived through a quarantine-flagged archive, either clone with
`git` instead (recommended — no quarantine attribute is applied) or allow it in
**System Settings → Privacy & Security**. Do not disable Gatekeeper.

You can also run the engine directly, which is what the `.command` file does:

```sh
./src/macos/cli.sh install
```

## What it does, in order

1. Checks macOS ≥ 13 and reports your architecture.
2. Finds `Claude.app` and reads its version.
3. Reads `~/.claude/settings.json` and resolves the gateway configuration.
4. Warns if a managed profile exists that would override it.
5. Backs up `_meta.json` and every configuration file in the library.
6. Writes the credential helper to
   `~/Library/Application Support/claude-desktop-provider-setup/helper/`.
7. Adds a configuration entry named **Migrated from Claude Code** and makes it
   the applied one. Other entries are untouched.
8. Writes `state.json` recording exactly what was created.
9. Runs the helper and fails if it does not produce a credential.
10. Tells you to restart Claude Desktop, or restarts it with `--restart`.

## See what it will do first

```sh
./install.command plan
```

This prints the resolved plan as JSON and writes nothing. Useful before a first
install, and it is the same command the test suite uses.

## Options

| Option | Effect |
|---|---|
| `--auth-scheme bearer\|x-api-key` | required when `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY` are both set with different values |
| `--mapping <path>` | model mapping file (default `config/model-mapping.json` if present) |
| `--allow-unlisted-models` | let the mapping add model IDs that are not in your Claude Code config |
| `--allow-http` | permit a plaintext http base URL (loopback testing only) |
| `--deployment-mode 3p\|any` | `3p` (default) hides the Claude.ai sign-in |
| `--helper-ttl <seconds>` | credential cache lifetime, default 900 |
| `--config-name <name>` | the name shown in Claude Desktop's configuration picker |
| `--restart` | quit and relaunch Claude Desktop when done |
| `--verbose` | extra diagnostics on stderr |

## After installing

1. Claude Desktop reads configuration **at launch**. Quit it completely
   (<kbd>⌘Q</kbd>) and reopen it.
2. The login screen should offer your gateway instead of Claude.ai. With
   `deploymentMode: 3p` the Claude.ai option is hidden.
3. Send one message. If it fails, see [troubleshooting](troubleshooting.md).

## Verifying

```sh
./install.command verify
```

Checks that the configuration file exists and parses, that the library actually
applies it, that it has not drifted from what was installed, that no secret is
inline, that the helper returns a credential, and that no managed profile is
shadowing it.

```sh
./install.command diagnose
```

Prints a redacted report. The credential is reported as a byte count. Review it
before pasting into an issue if your gateway URL itself is sensitive.

## Updating

After changing your Claude Code settings (a new model, a rotated URL):

```sh
./install.command update
```

This reuses the same configuration id, so Claude Desktop sees an update rather
than a second entry. A token rotation needs **no** update: the helper reads the
settings file every time it runs.

## Uninstalling

```sh
./uninstall.command
```

Removes only the entry this tool created, restores the previously applied
configuration, deletes the helper and `state.json`, and keeps the backups. The
Claude Desktop library returns to the state it was in before installation, and
`~/.claude/settings.json` is never touched. Add `--purge` to delete the backups
too.

## Manual fallback

If the tool cannot finish, it says which step failed and writes nothing further.
The equivalent manual steps are:

1. **Help → Troubleshooting → Enable Developer Mode**, then
   **Developer → Configure Third-Party Inference…**
2. Set **Inference provider** to `gateway`, fill in **Gateway base URL**.
3. Set **Credential kind** to `Helper script` and point it at an executable you
   trust that prints your token.
4. Add your model IDs under **Models**.
5. **Apply Changes**, then **Relaunch now**.

Do not hand-edit files in `configLibrary/` — use the in-app window instead. If
you already have, `./install.command restore` will put back the backup taken
before installation.
