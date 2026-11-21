# Security model — agy-cli-switcher (`agy-cs`)

_Threat model for security reviews and scans, written against `06886b3`. Items marked **(inferred)** are read from the code and not confirmed by the maintainer. There is no infrastructure to model: this is a local CLI with no deployment._

## System overview and trust boundaries
`agy-cs` is a single Swift executable (macOS 13+) that switches the Antigravity CLI (`agy`) login on one Mac. It runs as the logged-in user, with no server, network listener, or network calls of its own.

Trust boundaries:
1. **User account ↔ other local accounts**: files under `~/.gemini/antigravity-cli/` and `~/.agy-cs/` rely on POSIX modes (dirs 700, files 600).
2. **agy-cs ↔ login keychain**: one generic password, service `gemini`, account `antigravity`, read and written in-process through Security.framework.
3. **agy-cs ↔ files it reads from disk**: saved token copies, `.meta.json` sidecars, the `active` file, the language file, and bundled i18n resources.
4. **agy-cs ↔ processes it starts**: `agy`, found on `$PATH` and spawned with posix_spawn; `$SHELL -ic agy` started with execv; `/usr/bin/pgrep`.

## Components
| Name | Code | Notes |
|---|---|---|
| **CLI** | `Sources/agy-cs/main.swift`, `Sources/AgyAccount/CLI.swift`, `Commands.swift` | Argument parsing, commands, interactive menu |
| **Keychain** | `Sources/AgyAccount/LoginKeychain.swift` | Reads, writes, deletes and restores the keychain item; write-then-verify with rollback |
| **Account files** | `Sources/AgyAccount/AccountFiles.swift`, `LoginRecord.swift` | `~/.gemini/antigravity-cli/accounts/<name>.token` and `.meta.json`, `active`, `AtomicFile`, name validation (`checkName`), blob decoding |
| **Tool profile** | `Sources/AgyAccount/ToolProfile.swift` | `~/.agy-cs/` non-secret records, language, `initialized`, import from Gemini sidecars |
| **agy launcher** | `Sources/AgyAccount/AgySession.swift` | PATH lookup, posix_spawn, process group/tty handoff, SIGTERM/SIGKILL, `$SHELL -ic agy` |
| **Localization** | `Sources/AgyAccount/Localization.swift`, `StringCatalog.swift`, `i18n/*.txt` | Interface text loaded from the bundle |
| **CI** | `.github/workflows/ci.yml`, `no-ai-coauthor.yml` | macOS `swift test`; commit trailer check |

## Entry points and who can reach them
- Command-line arguments and the interactive menu (stdin), used by the local user.
- Environment: `PATH` (where `agy` is found), `SHELL`, `HOME`, preferred languages.
- Files on disk under `~/.gemini/antigravity-cli/` (readable/writable by agy itself and by anything running as the user) and `~/.agy-cs/`.
- The keychain item, which `agy` also writes while it logs in.
- CI: GitHub `pull_request`/`push` events, read-only `contents` permission.

## Assets and data sensitivity
- **Critical**: OAuth refresh and access tokens for each Antigravity/Google account (inferred), stored in the keychain blob (`go-keyring-base64:` + base64 JSON) and as plaintext copies in `accounts/*.token`.
- **High (inferred)**: the integrity of the current login. A failed rollback in `addAccount`/`writeBlob` can lose it.
- **Low**: emails, account names, auth method, expiry (in `.meta.json` and `~/.agy-cs/accounts/*.json`).
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
- Keychain access goes through Security.framework, not the `security` CLI, so tokens never appear in argv.
- `writeBlob` verifies after writing and restores the original when they differ; `addAccount` restores the snapshot when the login is cancelled or agy fails to launch.
- `.gitignore` excludes `*.token` and `accounts/`; AGENTS.md forbids printing tokens.
- CI workflows use `permissions: contents: read` (no-ai-coauthor) and no secrets.

## Out of scope / accepted risk
- **User-confirmed:** malware or code already running as the logged-in user. A finding that needs that position is out of scope, unless the tool gives such code more than it already has (for example, makes a token readable to *other* users).
- Nothing else is ruled out (user did not accept plaintext 600 token copies or CI as out of scope).

## Open questions
- Confirm that same-user malware is out of scope; the answers were mixed.
