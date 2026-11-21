# agy-cli-switcher

<p align="center">
  <a href="README.md">简体中文</a> |
  <a href="README.en.md">English</a> |
  <a href="documents/CHANGELOG.md">Changelog</a>
</p>

<p align="center">
  <a href="https://github.com/Cmochance/agy-cli-switcher/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/Cmochance/agy-cli-switcher?style=social"></a>
  <a href="LICENSE.txt"><img alt="License" src="https://img.shields.io/github/license/Cmochance/agy-cli-switcher"></a>
  <a href="https://www.swift.org/"><img alt="Swift" src="https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white"></a>
  <a href="https://developer.apple.com/macos/"><img alt="macOS" src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white"></a>
</p>

**agy-cli-switcher** switches Antigravity CLI (`agy`) logins on macOS. The command is `agy-cs`.

Current version **v0.1.0** (see [Changelog](documents/CHANGELOG.md)).

## What it does

- Switch between `agy` logins, and keep the name, email, and active record
- `agy-cs ls` shows each account's plan, and how much of the Gemini 5-hour, 7-day and Argon quota is left and when it resets
- `agy-cs switch` chooses in the terminal. Item 1 is the current account and cannot be selected. Item 2 adds an account. Later items are saved accounts. `agy` then starts in this terminal
- `agy-cs switch add` adds an account directly, without the menu. The current login is kept, then `agy` opens
- `agy-cs switch <name>` only switches. It does not start `agy`
- On the first run, when no account is recorded yet, read the current login once and save it under the characters before `@`
- Switching to another email deletes `~/.gemini/antigravity-cli/.quota_cache.json`. `~/.gemini/antigravity-cli/conversations` stays in place
- With no language chosen, the interface follows the system language. Codes: `zh-Hans`, `zh-Hant`, `en`, `ja`

## Quick start

Requires macOS 13 and Swift from Xcode or the Command Line Tools.

```bash
git clone https://github.com/Cmochance/agy-cli-switcher.git
cd agy-cli-switcher
make install
```

`make install` builds the release binary and points `~/.local/bin/agy-cs` at `build/agy-cs` in this checkout. The terminal needs that directory on `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

1. Run `agy-cs` to see saved accounts
2. Run `agy-cs switch` to choose an account, or to sign in to a new one
3. Run `agy-cs help` to see every command

## Commands

| Command | What it does |
|---|---|
| `agy-cs` | List saved accounts |
| `current` | Show the recorded email |
| `list` | List saved accounts with the most recently recorded plan and quota. `ls` is the same |
| `save <name>` | Save the current login under a name |
| `switch` | Choose in the terminal. Item 1 is the current account and cannot be selected. Item 2 adds an account. Later items are saved accounts. `agy` then starts in this terminal |
| `switch add` | Add an account directly, without the menu. The current login is kept, then `agy` opens |
| `switch <name>` | Switch to a saved account without starting `agy` |
| `next` | Switch to the next saved account |
| `refresh quota` | Look up the plan and quota of every saved account again, then list them |
| `rename <new>` | Rename the current account |
| `rename <old> <new>` | Rename one saved account |
| `rm <name>` | Delete a saved copy. The current login stays |
| `language` | Show or change the interface language. `lg` is the same |
| `help` | Show every command |

## Plan and quota

```
* alice  alice@example.com  Pro   5h 62% 11-21 23:35  7d 100%             Argon 100%
  bob    bob@example.com    Free  5h —                7d 99% 11-28 18:23  Argon —
```

- Each entry is the percentage left, followed by the reset time in the local time zone. At 100% the reset time is not shown
- An entry whose reset time has passed is shown as 100%
- `—` means the account has no such quota. Free accounts have no 5-hour quota, and only some accounts have Argon
- `ls` only reads the recorded results and makes no request
- `agy-cs refresh quota` asks for every account right away and lists the result
- After a `switch`, `next`, or a new account, a separate background process does the lookup. The switch does not wait for it and is not affected by it; `ls` is usually up to date a few seconds later. If that background lookup missed an account, the next `ls` says so
- The requests go to the endpoints `agy` itself uses. Google does not document them, and they may stop working after an `agy` update

## Where data lives

| Location | Contents |
|---|---|
| `~/.agy-cs/` | Names, emails, the active record, the language, and the plan and quota records. No login secrets |
| `~/.gemini/antigravity-cli/accounts/` | `agy`'s own login copies |
| One generic password in the login keychain, service `gemini`, account `antigravity` | The current login. A switch replaces only this item |

Directories are mode `700`. Files are mode `600`.

## Interface text

The four languages live in [`Sources/AgyAccount/i18n`](Sources/AgyAccount/i18n). Edit the txt file directly. The format is in that directory's `README.md`. Then run `make install`.

## Local development

```bash
make test       # swift test --disable-sandbox
make install    # rebuild and update ~/.local/bin/agy-cs
```

`make test` runs `swift test --disable-sandbox`.

## License

MIT License. Full text: [LICENSE.txt](LICENSE.txt).
