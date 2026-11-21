# Security model — agy-cli-switcher (`agy-cs`)

_Threat model for security reviews and scans, written against `06886b3`. Items marked **(inferred)** are read from the code and not confirmed by the maintainer. There is no infrastructure to model: this is a local CLI with no deployment._

## System overview and trust boundaries
`agy-cs` is a single Swift executable (macOS 13+) that switches the Antigravity CLI (`agy`) login on one Mac. It runs as the logged-in user, with no server, network listener, or network calls of its own.

Trust boundaries:
1. **User account ↔ other local accounts**: files under `~/.gemini/antigravity-cli/` and `~/.agy-cs/` rely on POSIX modes (dirs 700, files 600).
2. **agy-cs ↔ login keychain**: one generic password, service `gemini`, account `antigravity`, read, written and deleted by running `/usr/bin/security`, the same tool `agy` uses.
3. **agy-cs ↔ files it reads from disk**: saved token copies, `.meta.json` sidecars, the `active` file, the language file, and bundled i18n resources.
4. **agy-cs ↔ processes it starts**: `agy`, found on `$PATH` and spawned with posix_spawn; `$SHELL -ic agy` started with execv; `/usr/bin/pgrep`; `/usr/bin/security`, started by absolute path, which receives the login on stdin and returns it on stdout.

## Components
| Name | Code | Notes |
|---|---|---|
| **CLI** | `Sources/agy-cs/main.swift`, `Sources/AgyAccount/CLI.swift`, `Commands.swift` | Argument parsing, commands, interactive menu |
| **Keychain** | `Sources/AgyAccount/LoginKeychain.swift` | Runs `/usr/bin/security` to read, write, delete and restore the keychain item; write-then-verify with rollback |
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
- Keychain access goes through `/usr/bin/security`, started by absolute path and not looked up on `PATH`. Reads and deletes pass only the service and account names as arguments. Writes send `add-generic-password` on stdin (`security -i`), so tokens never appear in argv.
- Before a write, the login must be `go-keyring-base64:` followed by base64 characters only, and the whole command line must fit in 4095 bytes. A newline, a space or an over-long value cannot reach `security -i`, so no second command can be injected and no truncated login is stored.
- `writeBlob` verifies after writing and restores the original when they differ; `addAccount` checks that the snapshot can be written back and saves it to a token file before deleting the keychain item, and restores it on any error before the new login is saved (cancelled login, agy launch failure, keychain read denied, name clash); the spawned agy is terminated if polling throws.
- `.gitignore` excludes `*.token` and `accounts/`; AGENTS.md forbids printing tokens.
- CI workflows use `permissions: contents: read` (no-ai-coauthor) and no secrets.

## Out of scope / accepted risk
- **User-confirmed:** malware or code already running as the logged-in user. A finding that needs that position is out of scope, unless the tool gives such code more than it already has (for example, makes a token readable to *other* users).
- **User-confirmed (2026-11-21):** `agy-cs` reads the login without a keychain password prompt, the same way `agy` does. The item trusts `/usr/bin/security`, so any process running as the user can already read it through that tool.
- Nothing else is ruled out (user did not accept plaintext 600 token copies or CI as out of scope).

## Open questions
- Confirm that same-user malware is out of scope; the answers were mixed.
