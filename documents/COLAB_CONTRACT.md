# Google Colab CLI Contract Baseline

This document records the verified upstream behavior of `googlecolab/google-colab-cli` that `agy-cli-switcher`'s Colab provider relies on, so local tests and CI drift checks can spot breaking changes early.

- `baseline_repo`: `googlecolab/google-colab-cli`
- `baseline_version`: `0.8.0`
- `baseline_tag`: `v0.8.0`
- `baseline_commit`: `0abf82d`
- `verified_at`: `2026-11-22`

## Keychain contract

- **Service**: `google-colab-cli`
- **Account**: `oauth_token`
- **Payload**: Single-line UTF-8 JSON storing `token`, `refresh_token`, `token_uri`, `client_id`, `client_secret`, `scopes`, `universe_domain` (`googleapis.com`), and `expiry` (`account` is empty `""`). `expiry` is UTC `yyyy-MM-dd'T'HH:mm:ssZ` with no fractional seconds.
- **macOS ACL / partition contract**: `google-colab-cli` reads and writes this item through the Python `keyring` package installed alongside `colab`. Reads, writes, and deletes from `agy-cs` spawn that same `#!` Python interpreter and exchange `op`/`service`/`account`/`value` JSON over stdin/stdout so no macOS keychain authorization prompt is triggered and the partition list stays unchanged.

## Local state files (`~/.config/colab-cli/`)

| Path | Role in `agy-cs` |
|---|---|
| `sessions.json` | Backed up to `<name>.sessions.json` and swapped when switching between different emails; cleared to `{}` if the target account has no backup. |
| `sessions.attached.json` | Isolated alongside `sessions.json` as `<name>.sessions.attached.json` (anticipating upstream PR #230). |
| `settings.json` | Account-scoped capability flags `public_api_supported` and `tunnel_api_supported` are reset to `null` on email switch (per upstream #238 / PR #266). |
| `accounts/` | Managed by `agy-cs` (dir `700`, files `600`): `<name>.token`, `<name>.meta.json`, `<name>.sessions.json`, `<name>.sessions.attached.json`, `.add-rollback`, `active`. |
| `history/`, `colab.log` | Never moved, edited, or deleted by `agy-cs`. |

## Network & OAuth endpoints

- **Token refresh**: `POST https://oauth2.googleapis.com/token` (`application/x-www-form-urlencoded`) sending `client_id`, `client_secret`, `refresh_token`, `grant_type=refresh_token`. `scope` is intentionally omitted to stay compatible with partial OAuth grants (upstream #235).
- **Email resolution**: Prefers matching `refresh_token` offline against saved `accounts/*.token` + `.meta.json`. For newly seen logins, resolves email from `id_token` JWT or `GET https://oauth2.googleapis.com/tokeninfo?access_token=...`.
- **Compute units & active assignments**: `GET https://colab.research.google.com/tun/m/ccu-info?authuser=0` with `Authorization: Bearer <access_token>`, `Accept: application/json`, and `X-Colab-Client-Agent: colab-cli`; strips leading XSSI `)]}'` line and reads `currentBalance`, `consumptionRateHourly`, and `assignmentsCount`.

## Sign-in

`agy-cs colab switch add` performs the authorization-code grant itself. It does not run `colab whoami` for this login.

- **Authorization endpoint**: `https://accounts.google.com/o/oauth2/auth`
- **Token endpoint**: `https://oauth2.googleapis.com/token`
- **PKCE**: S256. Scopes are `openid`, `https://www.googleapis.com/auth/userinfo.profile`, `https://www.googleapis.com/auth/userinfo.email`, `https://www.googleapis.com/auth/cloud-platform`, `https://www.googleapis.com/auth/colaboratory`, and `https://www.googleapis.com/auth/drive.file`, plus `access_type=offline` and `prompt=consent`.
- **Loopback redirect**: exactly `http://127.0.0.1:<port>/`, where the kernel chooses the port. That request does not send `token_usage`. The listener accepts one successful callback, rejects a mismatched `state`, and treats a matching-state `error` such as `access_denied` as cancellation. It closes when sign-in finishes, is cancelled, or times out after 10 minutes.
- **Remote fallback**: redirect `https://sdk.cloud.google.com/applicationdefaultauthcode.html` and `token_usage=remote`. The authorization code is read from stdin, never from argv.
- **Client credentials**: read at run time from `oauth_config.json` in the virtualenv of the shebang interpreter (`<venv>/lib/python*/site-packages/colab_cli/oauth_config.json`), not from the base install when `bin/python` is a symlink. `auth_uri` must use host `accounts.google.com` and `token_uri` must use host `oauth2.googleapis.com`. They are not stored in this repository or under `~/.agy-cs/`.

## Non-secret switcher metadata (`~/.agy-cs/colab/`)

- Shares `~/.agy-cs/provider` (active provider toggle: `antigravity` or `colab`) and `~/.agy-cs/language`.
- Stores Colab-specific `accounts/*.json`, `usage/*.json`, `usage-status.json`, `usage.lock`, `state.lock`, `order`, `active`, `initialized`, `not-saved` under `~/.agy-cs/colab/`, and caches the located `colab` path in `~/.agy-cs/colab-client.json`.

## Updating after an upstream Colab release

1. Compare upstream commits from `baseline_commit` to the new release, focusing on `auth.py`, `consumption.py`, `client.py`, `state.py`, and `commands/usage.py` / `session.py`.
2. Update `ColabKeychain.swift`, `ColabUsage.swift`, `ColabSession.swift`, or `AccountFiles.swift` if any contract field changed.
3. Update `baseline_version`, `baseline_tag`, `baseline_commit`, and `verified_at` above, then run `make test` and live opt-in checks.
