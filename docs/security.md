# Security

## Threat model

The asset is the gateway credential in `~/.claude/settings.json`. The people who
could take it are, in rough order of likelihood:

1. Someone with read access to your home directory — a shared machine, a backup
   that syncs, a mis-permissioned mount.
2. A process running as you, on a machine you are logged in to.
3. Anyone reading a file this tool wrote, or an issue you filed with a
   diagnostic report in it.
4. Someone who can write to `~/.claude/settings.json` and make the helper emit
   their token instead of yours (a local write primitive, i.e. a game over
   anyway).

This tool cannot defend against (4). It is designed to avoid *creating* new
exposure for (1), (2) and (3).

## What the tool writes, and where

| Path | Contents | Secret? |
|---|---|---|
| `<Claude-3p>/configLibrary/<uuid>.json` | gateway URL, auth scheme, helper path, model IDs, TTL | **No** |
| `<Claude-3p>/configLibrary/_meta.json` | entry ids and names | No |
| `<state>/state.json` | ids, base URL, auth scheme, token **length** | No |
| `<state>/helper/credential-helper.{sh,cmd,ps1}` | an absolute path to your settings file | No |
| `<state>/backups/<ts>/` | copies of what was in the library before | **Possibly** — see below |

There is no code path that writes the token to a file. `grep` for the token
pattern across this repository and across the files the tool creates: nothing
matches. That property is enforced by test: the conformance suite fails if the
fixture credential appears on stdout or stderr.

**Backups are the one place a secret can appear**, because a configuration you
saved earlier through the in-app window may hold a plaintext
`inferenceGatewayApiKey`, and a backup is a byte copy of what was there. This is
deliberate: a restore that silently dropped your previous key would not be a
restore. Backups live in a `0700` directory with `0600` files, are never
included in diagnostics, and are deleted by `--uninstall --purge`.

## Helper hardening

| Requirement | How it is met |
|---|---|
| No secret on a command line | The helper takes no arguments; `inferenceCredentialHelperArgs` is never set. |
| No secret in a temp file | The helper reads `settings.json` directly on every run. Nothing is cached to disk; Claude Desktop caches the value in memory for the TTL. |
| No path traversal or injectable read | The settings path is a literal baked into the generated script as a single-quoted value with correct escaping. It is never taken from argv, an environment variable, or a relative resolution. |
| Symlink refusal | The helper refuses to run if the path is a symlink (`-L`) or a reparse point (Windows), because a symlink could be swapped to point at an attacker-chosen file. |
| stdout discipline | stdout carries the token and nothing else. All diagnostics go to stderr, which Claude Desktop logs and otherwise ignores. |
| No interactive blocking | The helper never prompts, never opens a browser, and returns in milliseconds, well inside the 20 s mid-session-refresh clamp. |
| Bounded failure | Missing file → 6, no credential → 3, both credentials disagreeing → 4. Claude Desktop treats non-zero as a refresh failure and tells the user, which is the correct outcome. |
| Log hygiene | The helper prints nothing on success, so it does not fill the app's diagnostics log with one line per turn. |

The helper runs with your privileges and can read your settings file. That is
inherent: it *is* the credential source. It can do nothing else — no arguments
change its behaviour, and it has no network code.

## macOS Keychain: evaluated and rejected

The brief asked for this comparison explicitly.

**What Keychain would buy.** Encryption at rest for the item, and access
control per requesting application.

**Why it does not fit this design.**

1. *It duplicates the secret.* The token still has to live in
   `~/.claude/settings.json`, because that is where Claude Code reads it from
   and this tool must never modify that file. Copying it into the Keychain
   creates a **second** copy of the secret, in a place that must now be kept in
   sync. Rotation in `settings.json` would silently leave a stale key behind —
   the worst kind of failure, because it works until it does not.
2. *It breaks silent refresh.* A generic-password item created without `-A`
   prompts when read by a different process. `CLAUDE_HELPER_CONTEXT=mid-session-refresh`
   is exactly the case the official documentation says must not block. Passing
   `-A` to allow any application removes the prompt and, with it, most of the
   benefit: any process running as the user can now read it, which is the same
   exposure as a `0600` file.
3. *It adds a failure mode with no recovery path.* If the login keychain is
   reset or locked at launch, the helper fails and Desktop cannot connect. The
   settings-file design has no such state.

**Conclusion.** Reading `~/.claude/settings.json` directly is strictly better
here: one copy of the secret, automatically consistent with whatever Claude Code
uses, no prompt, no extra state. Keychain would be the right tool for a helper
that had to *acquire* a credential; it is the wrong tool for one that only has
to *relay* one that already exists.

Windows DPAPI has the same analysis and the same conclusion.

## Precedence and conflict handling

Claude Code sends `Authorization: Bearer` **and** `X-Api-Key` when both
variables are set; Claude Desktop can send exactly one. Picking one silently
would be a security-adjacent decision made on the user's behalf, so the tool
stops with exit code 4 and explains both options. If it proceeds after an
explicit `--auth-scheme`, it still warns that the other credential is now unused.

Likewise, when a settings-file `env` entry disagrees with your shell
environment, the tool uses the settings value (which is what Claude Code does)
and warns. It never silently picks the value that "looks better".

## Deliberate non-goals

- **It does not read your token to display it.** Diagnostics report a byte
  count. There is no `--show-token`.
- **It does not store the token in the configuration file**, even though
  `static` would be simpler.
- **It does not write to `~/.claude/settings.json`.**
- **It does not disable security controls.** The Windows launcher's
  `-ExecutionPolicy Bypass` is scoped to one process and changes no machine
  setting. Nothing on macOS bypasses Gatekeeper, TCC or SIP.
- **It does not install or download Claude Desktop.**
- **It does not run as administrator or root**, and never asks to.
- **It does not phone home.** There is no network code anywhere in this project.

## Redaction

Any value that could be the token passes through a redaction filter before being
printed, and the filter replaces both the whole value and its first eight
characters. The base URL is printed in full by `install` because you supplied it,
but `--diagnose` prints it too — if your gateway URL is itself sensitive, review
the output before pasting it into an issue.

## Reporting a vulnerability

Open a private security advisory on the repository rather than a public issue.
Include the version from `--diagnose` output with anything you consider
sensitive redacted.
