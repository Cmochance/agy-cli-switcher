# Security model — agy-cli-switcher (`agy-cs`)

_Threat model for security reviews and scans, written against `06886b3`. Items marked **(inferred)** are read from the code and not confirmed by the maintainer. There is no infrastructure to model: this is a local CLI and menu bar tool. The only deployment is a release workflow that uploads two packages to a draft GitHub release._

## System overview and trust boundaries
`agy-cs` is a single Swift executable (macOS 13+) that switches Antigravity CLI (`agy`) and Google Colab CLI (`colab`) logins on one Mac. It runs as the logged-in user, with no server or network listener. Its only network calls are `agy-cs refresh quota` / `agy-cs colab refresh quota` (plus one-time email lookup via Google OAuth `tokeninfo` when an unseen Colab refresh token is discovered in the keychain).

The same executable is also the menu bar tool Agy Switcher. Inside `Agy Switcher.app` it is the bundle's main executable; when LaunchServices starts it, it shows a panel instead of reading arguments. Everything the panel does is one of the `agy-cs` commands, run in the same process.

Trust boundaries:
1. **User account ↔ other local accounts**: files under `~/.gemini/antigravity-cli/`, `~/.config/colab-cli/`, and `~/.agy-cs/` rely on POSIX modes (dirs 700, files 600).
2. **agy-cs ↔ login keychain**:
   - Antigravity: one generic password, service `gemini`, account `antigravity`, read, written and deleted by running `/usr/bin/security`, the same tool `agy` uses.
   - Colab: one generic password, service `google-colab-cli`, account `oauth_token`, read, written and deleted by spawning the `#!` Python interpreter used by `colab` and exchanging stdin/stdout JSON with its `keyring` module (so tokens never enter `argv` and macOS keychain ACL/`cdhash` partition stays intact without password prompts).
   - `current`, `list`, the panel (on opening and every two seconds while open), `switch`, `next`, `save`, `rm` and `rename` without a source name read the active provider item; `help`, `language`, `move` and the quota lookup itself do not. Only the email is kept unless the login has never been saved.
3. **agy-cs ↔ files it reads from disk**: saved token copies, `.meta.json` sidecars, Colab `sessions.json`/`sessions.attached.json` backups and `settings.json` capability flags, the `active`, `provider`, and language files, and bundled i18n resources.
4. **agy-cs ↔ processes it starts**: `agy` or `colab whoami` (on `$PATH`, spawned with `posix_spawn` in foreground tty); `$SHELL -ic agy` started with `execv`; `/usr/bin/pgrep`; `/usr/bin/security`, started by absolute path; the Python interpreter resolved from `colab`'s `#!` shebang for `keyring` operations; `agy --version`, run only after verifying Google's Developer ID team `EQHXZ8M8AV`; and the user's default terminal application opening `~/.agy-cs/add-account.command`.
5. **agy-cs ↔ Google**: HTTPS requests to `oauth2.googleapis.com` (`token`, `tokeninfo`), `daily-cloudcode-pa.googleapis.com` (Antigravity `loadCodeAssist`, `retrieveUserQuotaSummary`, `fetchAvailableModels`), and `colab.research.google.com/tun/m/ccu-info` (Colab compute units and active assignment count). Access tokens stay in memory and are never written to disk.
6. **Release packages ↔ the people who download them**: `Agy-Switcher-v<version>-macOS-universal.dmg` and `agy-cs-v<version>-macOS-universal.tar.gz` are built by GitHub Actions from a tag, signed ad-hoc and not notarized. Each has a `.sha256` file next to it on the release page.

## Components
| Name | Code | Notes |
|---|---|---|
| **Entry point** | `Sources/agy-cs/main.swift`, `launchMode` in `Sources/AgyAccount/AccountBoard.swift` | Decides between the menu bar panel and the command line |
| **CLI** | `Sources/AgyAccount/CLI.swift`, `Commands.swift` | Argument parsing, commands, interactive menu |
| **Menu bar panel** | `Sources/AgyMenuBar/*.swift`, `Sources/AgyAccount/AccountBoard.swift` | SwiftUI panel in the menu bar; runs commands in-process through `AccountBoard.perform`, collects what they say; writes and opens `add-account.command` |
| **Keychain** | `Sources/AgyAccount/LoginKeychain.swift` | Runs `/usr/bin/security` to read, write, delete and restore the keychain item; write-then-verify with rollback |
| **Account files** | `Sources/AgyAccount/AccountFiles.swift`, `LoginRecord.swift` | `~/.gemini/antigravity-cli/accounts/<name>.token` and `.meta.json`, `active`, `AtomicFile`, name validation (`checkName`), blob decoding |
| **Tool profile** | `Sources/AgyAccount/ToolProfile.swift` | `~/.agy-cs/` non-secret records, language, `initialized`, import from Gemini sidecars; `state.lock`, the `flock` that lets one process at a time change the accounts; `not-saved`, the email of a login the user deleted with `--force` and does not want saved again. While an account is being added, such a login is kept in `~/.gemini/antigravity-cli/accounts/.add-rollback` (mode 600) so that an interrupted add can put it back into the keychain; the file is removed once the new login is stored or the old one is restored |
| **Plan and quota** | `Sources/AgyAccount/CloudCodeUsage.swift`, `AccountUsage.swift` | Reads the OAuth client secret out of the `agy` binary, exchanges refresh tokens, parses the two answers, writes `~/.agy-cs/usage/<name>.json`, formats the `list` columns |
| **agy launcher** | `Sources/AgyAccount/AgySession.swift` | PATH lookup, posix_spawn, process group/tty handoff, SIGTERM/SIGKILL, `$SHELL -ic agy` |
| **Localization** | `Sources/AgyAccount/Localization.swift`, `StringCatalog.swift`, `i18n/*.txt` | Interface text, compiled into the binary |
| **Packaging** | `Makefile`, `Packaging/Info.plist`, `Packaging/AppIcon.icns` | `make app` and `make dist` assemble and ad-hoc sign the app bundle and the two release packages |
| **CI and release** | `.github/workflows/ci.yml`, `no-ai-coauthor.yml`, `release.yml` | macOS `swift test` and a packaging check; commit trailer check; on a `v*` tag, a draft release with the packages |

## Entry points and who can reach them
- Command-line arguments and the interactive menu (stdin), used by the local user.
- A LaunchServices start of `Agy Switcher.app` (Finder, Dock, `open`), and after that clicks and typed account names in the panel. Typed names go through the same `checkName` and `checkNewName` as the command line.
- Environment: `PATH` (where `agy` is found), `SHELL`, `HOME`, preferred languages, and `AGY_CS_MENU_BAR`, the marker that `Packaging/Info.plist` sets through `LSEnvironment`.
- Files on disk under `~/.gemini/antigravity-cli/` (readable/writable by agy itself and by anything running as the user) and `~/.agy-cs/`.
- The keychain item, which `agy` also writes while it logs in.
- HTTPS responses from the two Google hosts, and the bytes of the `agy` binary that is scanned for the client secret. That binary is looked for on `PATH`, then at the path recorded in `~/.agy-cs/agy-client.json`, then in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`.
- CI: GitHub `pull_request`/`push` events, read-only `contents` permission. A pushed `v*` tag starts `release.yml`, which has `contents: write` to create the draft release.

## Assets and data sensitivity
- **Critical**: OAuth refresh and access tokens for each Antigravity/Google account (inferred), stored in the keychain blob (`go-keyring-base64:` + base64 JSON) and as plaintext copies in `accounts/*.token`.
- **High (inferred)**: the integrity of the current login. A failed rollback in `addAccount`/`writeBlob` can lose it.
- **Low**: emails, account names, auth method, expiry (in `.meta.json` and `~/.agy-cs/accounts/*.json`); plan and quota records, which include the account's Cloud Code project id (`~/.agy-cs/usage/*.json`); the path, size, modification time and version of `agy` and the offset of the working client secret (`~/.agy-cs/agy-client.json`); `~/.agy-cs/add-account.command`, which holds only the path of this executable; `~/.agy-cs/order`, the account names in the order chosen with `move`. A line in `order` is used only when it equals the name of an existing record, so nothing in that file becomes a path.
- `~/.gemini/antigravity-cli/conversations` must never be moved or deleted.

## Attacker profiles
**User-confirmed (2026-11-21):** these attackers are in scope:
- **Other macOS user accounts on the same Mac**, which are kept out only by directory and file modes.
- **Untrusted files or environment planted where the tool trusts them**, such as home dir files, `PATH` (a fake `agy`) and `SHELL`.
- **Token leaks** through stdout/stderr, logs, error messages, temp files (`*.tmp`) or the git repo.
- **Malware already running as the same user is out of scope** (user's answer). Such code can already read the keychain item and the 600 files. The user ticked this attacker and also marked it out of scope; It is treated as out of scope until confirmed.

## Existing controls
- `checkName`: names are `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`, which blocks `/` and a leading `.`, so names cannot traverse paths.
- `AtomicFile.write`: temp file opened 0600 with O_CREAT|O_TRUNC (no O_EXCL/O_NOFOLLOW), fsync, rename, then chmod 600; the parent directory is chmod 700.
- Keychain access goes through `/usr/bin/security`, started by absolute path and not looked up on `PATH`. Reads and deletes pass only the service and account names as arguments. Writes send `add-generic-password` on stdin (`security -i`), so tokens never appear in argv.
- Before a write, the login must be `go-keyring-base64:` followed by base64 characters only, and the whole command line must fit in 4095 bytes. A newline, a space or an over-long value cannot reach `security -i`, so no second command can be injected and no truncated login is stored.
- `writeBlob` verifies after writing and restores the original when they differ; `addAccount` checks that the snapshot can be written back and saves it to a token file before deleting the keychain item, and restores it on any error before the new login is saved (cancelled login, agy launch failure, keychain read denied, name clash); the spawned agy is terminated if polling throws.
- Plan and quota requests go only to two hard-coded `https://` hosts through an ephemeral `URLSession`, with a 10 second budget from the start to the last answer. Refresh tokens travel only in the body of the token request. One request without any credentials is sent first to open the connection early. Access tokens stay in memory and are never written to disk. The lookup runs in its own process (`agy-cs` re-executes its own binary, by the path it was started from, with stdin, stdout and stderr on `/dev/null` and in its own session), so a failure or a hang there cannot delay or undo a switch.
- The OAuth client secret is not in the repository. It is read at run time from the `agy` binary. A planted binary can only supply a wrong secret, which Google rejects; the request still goes to the fixed Google host. It is not executed: `agy --version` runs only on a binary whose signature satisfies `anchor apple generic and certificate leaf[subject.OU] = "EQHXZ8M8AV"`, so a named `switch` or `next` does not start an unverified file.
- The places beyond `PATH` (the recorded path and the three usual directories) are used only for that read and that signature-checked `--version`. A menu bar process started by LaunchServices has only `/usr/bin:/bin:/usr/sbin:/sbin` on `PATH`. The `agy` that is spawned for a login is still taken from `PATH` alone.
- The menu bar panel starts only when three things hold together: no arguments, the parent process is launchd, and `AGY_CS_MENU_BAR=1` is in the environment. The marker is removed from the environment before anything else is started. Run from a terminal, the executable inside the app bundle behaves as the command line.
- The panel has no terminal, so `switch` without a name and `switch add` fail there with the "needs a terminal" message before the keychain item is touched. A login always runs in a real terminal, through the command line's own rollback.
- `save <name>` does not replace a copy that belongs to another account; that needs `--force`, on the command line and in the panel alike. A saved login that is replaced cannot be recovered.
- A row in the panel can be out of date by the time it is clicked. What the panel sends after a confirmation carries `--expect <email>`, and the command checks who is stored under the name right before it writes or deletes: `rm` refuses when the email differs, also with `--force`; `save --force --expect <email>` replaces only that account's copy. The check and the write are not one atomic step across processes; there is no lock around account records.
- The README's terminal install downloads into a directory from `mktemp -d` (mode 700) and chains every step with `&&`, so a disk image planted by another local user in a shared temporary directory is never mounted. The image is attached read-only at a mount point inside that directory.
- `add-account.command` is `#!/bin/sh` plus `exec '<path of this executable>' switch add`. The path is inside single quotes, with any single quote in it written as `'\''`, so spaces, `$`, backticks and newlines in the path stay data. It is written with `AtomicFile.write` into `~/.agy-cs/` (mode 700) and set to mode 700. A test runs the generated file with a path that contains all of those characters.
- The interface text is compiled into the executable. There is no resource bundle next to it that could be replaced.
- Strings taken from the Google answers are stripped of control characters and cut to 64 characters before they are recorded or printed. Records are written with `AtomicFile.write` under names that passed `checkName`, and carry the account email; `list` ignores a record whose email differs from the saved account.
- `.gitignore` excludes `*.token` and `accounts/`; AGENTS.md forbids printing tokens.
- `ci.yml` and `no-ai-coauthor.yml` use `permissions: contents: read` and no secrets. `release.yml` runs only on a pushed `v*` tag, has `contents: write` for the one `gh release create --draft` call, checks out with `persist-credentials: false`, and refuses a tag that does not match the version in `Packaging/Info.plist`. It never publishes; a person turns the draft into a release.

## Out of scope / accepted risk
- **User-confirmed (2026-11-21):** release packages are signed ad-hoc and not notarized, because there is no Developer ID certificate. Gatekeeper cannot tie a download to this project; the SHA-256 list on the release page and GitHub's transport are the only checks. A browser download has to be allowed once in System Settings.
- **User-confirmed (2026-11-21):** "Add account…" in the panel writes a two-line shell file and has the default terminal application run it.
- **User-confirmed:** malware or code already running as the logged-in user. A finding that needs that position is out of scope, unless the tool gives such code more than it already has (for example, makes a token readable to *other* users).
- **User-confirmed (2026-11-21):** `agy-cs` reads the login without a keychain password prompt, the same way `agy` does. The item trusts `/usr/bin/security`, so any process running as the user can already read it through that tool.
- **User-confirmed (2026-11-21):** after each successful switch, and on `agy-cs refresh quota`, `agy-cs` sends the refresh token of every saved account to Google's token endpoint and asks the Cloud Code endpoints for plan and quota, identifying itself with `agy`'s User-Agent. These endpoints are undocumented.
- Nothing else is ruled out (user did not accept plaintext 600 token copies or CI as out of scope).

## Open questions
- Confirm that same-user malware is out of scope; the answers were mixed.
