[简体中文](README.md)

# agy-cli-switcher

Switch Antigravity CLI (`agy`) logins on macOS. The command is `agy-cs`.

Requires macOS 13 and Swift from Xcode or the Command Line Tools.

## Install

```sh
git clone https://github.com/Cmochance/agy-cli-switcher.git
cd agy-cli-switcher
make install
```

`make install` builds the release binary and points `~/.local/bin/agy-cs` at `build/agy-cs` in this checkout. The terminal needs that directory on `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## Commands

| Command | What it does |
| --- | --- |
| `agy-cs` | List saved accounts |
| `current` | Show the recorded email |
| `list` | List saved accounts. `ls` is the same |
| `save <name>` | Save the current login under a name |
| `switch` | Choose in the terminal. Item 1 is the current account and cannot be selected. Item 2 adds an account. Later items are saved accounts. `agy` then starts in this terminal |
| `switch <name>` | Switch to a saved account without starting `agy` |
| `next` | Switch to the next saved account |
| `rename <new>` | Rename the current account |
| `rename <old> <new>` | Rename one saved account |
| `rm <name>` | Delete a saved copy. The current login stays |
| `language` | Show or change the interface language. `lg` is the same |
| `help` | Show every command |

With no language chosen, `agy-cs` follows the system language. Codes: `zh-Hans`, `zh-Hant`, `en`, `ja`.

On the first run, when no account is recorded yet, `agy-cs` reads the current login once and saves it under the characters before `@`. Later runs do not read the login just to list accounts.

Switching to another email deletes `~/.gemini/antigravity-cli/.quota_cache.json`. `~/.gemini/antigravity-cli/conversations` is left in place.

## Where data lives

| Location | Contents |
| --- | --- |
| `~/.agy-cs/` | Names, emails, the active record, and the language. No login secrets |
| `~/.gemini/antigravity-cli/accounts/` | `agy`'s own login copies |
| One generic password in the login keychain, service `gemini`, account `antigravity` | The current login. A switch replaces only this item |

Directories are mode `700`. Files are mode `600`.

## Edit the interface text

The four languages live in [`Sources/AgyAccount/i18n`](Sources/AgyAccount/i18n). Edit the txt file directly. The format is in that directory's `README.md`. Then run `make install`.

## Tests

```sh
make test
```

`make test` runs `swift test --disable-sandbox`.

History is in [documents/CHANGELOG.md](documents/CHANGELOG.md). License: [MIT](LICENSE.txt).
