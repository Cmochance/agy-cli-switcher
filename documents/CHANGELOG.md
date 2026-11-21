# Changelog

## 0.1.0

### 简体中文

- 命令行工具 `agy-cs`，在多个 `agy` 登录之间切换。
- 命令：`current`、`list`、`save`、`switch`、`next`、`rename`、`rm`、`language`、`help`。
- 不带名字的 `switch` 在终端里选择账号或登录新账号，完成后启动 `agy`。带名字的 `switch` 只切换。
- 首次运行会把当前登录记到 `~/.agy-cs/`。界面语言为 `zh-Hans`、`zh-Hant`、`en`、`ja`。
- 界面句子放在 `Sources/AgyAccount/i18n`，可以直接改。

### English

- Command-line tool `agy-cs` switches between `agy` logins.
- Commands: `current`, `list`, `save`, `switch`, `next`, `rename`, `rm`, `language`, `help`.
- `switch` with no name chooses an account, or signs in to a new one, and then starts `agy`. `switch` with a name only switches.
- The first run records the current login in `~/.agy-cs/`. Interface languages: `zh-Hans`, `zh-Hant`, `en`, `ja`.
- Interface text lives in `Sources/AgyAccount/i18n` and can be edited by hand.
