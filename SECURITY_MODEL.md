# Security model — agy-cli-switcher (`agy-cs`)

_Threat model for security reviews and scans, written against `06886b3`. Items marked **(inferred)** are read from the code and not confirmed by the maintainer. There is no infrastructure to model: this is a local CLI with no deployment._

## System overview and trust boundaries
`agy-cs` is a single Swift executable (macOS 13+) that switches the Antigravity CLI (`agy`) login on one Mac. It runs as the logged-in user, with no server or network listener. Its only network calls are the HTTPS requests of `agy-cs refresh quota`, which looks up each saved account's plan and quota; a successful switch starts that command as a separate detached process.

Trust boundaries:
1. **User account ↔ other local accounts**: files under `~/.gemini/antigravity-cli/` and `~/.agy-cs/` rely on POSIX modes (dirs 700, files 600).
2. **agy-cs ↔ login keychain**: one generic password, service `gemini`, account `antigravity`, read, written and deleted by running `/usr/bin/security`, the same tool `agy` uses.
3. **agy-cs ↔ files it reads from disk**: saved token copies, `.meta.json` sidecars, the `active` file, the language file, and bundled i18n resources.
4. **agy-cs ↔ processes it starts**: `agy`, found on `$PATH` and spawned with posix_spawn; `$SHELL -ic agy` started with execv; `/usr/bin/pgrep`; `/usr/bin/security`, started by absolute path, which receives the login on stdin and returns it on stdout; `agy --version`, run on the same `$PATH` binary only after its code signature is checked against Google's Developer ID team `EQHXZ8M8AV`, and only when the recorded size or modification time no longer match.
5. **agy-cs ↔ Google**: in `agy-cs refresh quota` (run by the user, or started detached after a successful `switch`, `next` or new account), HTTPS POSTs to `oauth2.googleapis.com/token` (a saved refresh token and the OAuth client secret go out, a short-lived access token comes back) and to `daily-cloudcode-pa.googleapis.com` (`loadCodeAssist`, `retrieveUserQuotaSummary`). These are the endpoints `agy` itself uses; Google does not document them.

## Components
| Name | Code | Notes |
|---|---|---|
| **CLI** | `Sources/agy-cs/main.swift`, `Sources/AgyAccount/CLI.swift`, `Commands.swift` | Argument parsing, commands, interactive menu |
| **Keychain** | `Sources/AgyAccount/LoginKeychain.swift` | Runs `/usr/bin/security` to read, write, delete and restore the keychain item; write-then-verify with rollback |
| **Account files** | `Sources/AgyAccount/AccountFiles.swift`, `LoginRecord.swift` | `~/.gemini/antigravity-cli/accounts/<name>.token` and `.meta.json`, `active`, `AtomicFile`, name validation (`checkName`), blob decoding |
| **Tool profile** | `Sources/AgyAccount/ToolProfile.swift` | `~/.agy-cs/` non-secret records, language, `initialized`, import from Gemini sidecars |
| **Plan and quota** | `Sources/AgyAccount/CloudCodeUsage.swift`, `AccountUsage.swift` | Reads the OAuth client secret out of the `agy` binary, exchanges refresh tokens, parses the two answers, writes `~/.agy-cs/usage/<name>.json`, formats the `list` columns |
| **agy launcher** | `Sources/AgyAccount/AgySession.swift` | PATH lookup, posix_spawn, process group/tty handoff, SIGTERM/SIGKILL, `$SHELL -ic agy` |
| **Localization** | `Sources/AgyAccount/Localization.swift`, `StringCatalog.swift`, `i18n/*.txt` | Interface text loaded from the bundle |
| **CI** | `.github/workflows/ci.yml`, `no-ai-coauthor.yml` | macOS `swift test`; commit trailer check |

## Entry points and who can reach them
- Command-line arguments and the interactive menu (stdin), used by the local user.
- Environment: `PATH` (where `agy` is found), `SHELL`, `HOME`, preferred languages.
- Files on disk under `~/.gemini/antigravity-cli/` (readable/writable by agy itself and by anything running as the user) and `~/.agy-cs/`.
- The keychain item, which `agy` also writes while it logs in.
- HTTPS responses from the two Google hosts, and the bytes of the `agy` binary that is scanned for the client secret.
- CI: GitHub `pull_request`/`push` events, read-only `contents` permission.

## Assets and data sensitivity
- **Critical**: OAuth refresh and access tokens for each Antigravity/Google account (inferred), stored in the keychain blob (`go-keyring-base64:` + base64 JSON) and as plaintext copies in `accounts/*.token`.
- **High (inferred)**: the integrity of the current login. A failed rollback in `addAccount`/`writeBlob` can lose it.
- **Low**: emails, account names, auth method, expiry (in `.meta.json` and `~/.agy-cs/accounts/*.json`); plan and quota records (`~/.agy-cs/usage/*.json`); the size, modification time and version of `agy` and the offset of the working client secret (`~/.agy-cs/agy-client.json`).
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
- Plan and quota requests go only to two hard-coded `https://` hosts through an ephemeral `URLSession`, with a 10 second budget from the start to the last answer. Refresh tokens travel only in the body of the token request. Access tokens stay in memory and are never written to disk. The lookup runs in its own process (`agy-cs` re-executes its own binary, by the path it was started from, with stdin, stdout and stderr on `/dev/null` and in its own session), so a failure or a hang there cannot delay or undo a switch.
- The OAuth client secret is not in the repository. It is read at run time from the `agy` binary found on `PATH`. A planted binary can only supply a wrong secret, which Google rejects; the request still goes to the fixed Google host. It is not executed: `agy --version` runs only on a binary whose signature satisfies `anchor apple generic and certificate leaf[subject.OU] = "EQHXZ8M8AV"`, so a named `switch` or `next` does not start an unverified file.
- Strings taken from the Google answers are stripped of control characters and cut to 64 characters before they are recorded or printed. Records are written with `AtomicFile.write` under names that passed `checkName`, and carry the account email; `list` ignores a record whose email differs from the saved account.
- `.gitignore` excludes `*.token` and `accounts/`; AGENTS.md forbids printing tokens.
- CI workflows use `permissions: contents: read` (no-ai-coauthor) and no secrets.

## Out of scope / accepted risk
- **User-confirmed:** malware or code already running as the logged-in user. A finding that needs that position is out of scope, unless the tool gives such code more than it already has (for example, makes a token readable to *other* users).
- **User-confirmed (2026-11-21):** `agy-cs` reads the login without a keychain password prompt, the same way `agy` does. The item trusts `/usr/bin/security`, so any process running as the user can already read it through that tool.
- **User-confirmed (2026-11-21):** after each successful switch, and on `agy-cs refresh quota`, `agy-cs` sends the refresh token of every saved account to Google's token endpoint and asks the Cloud Code endpoints for plan and quota, identifying itself with `agy`'s User-Agent. These endpoints are undocumented.
- Nothing else is ruled out (user did not accept plaintext 600 token copies or CI as out of scope).

## Open questions
- Confirm that same-user malware is out of scope; the answers were mixed.
