# Changelog

## 0.2.1

### 简体中文

- 右键点 Agy Switcher 的菜单栏图标可以直接退出，按住 control 点左键也一样。原来退出只在面板的齿轮里。
- 有操作正在进行时点退出，会等它做完再退，不会停在切换到一半的地方。
- 同一时间只运行一个 Agy Switcher。已经有一个在运行时，再打开另一份会直接退出。

### English

- Right-clicking the Agy Switcher menu bar icon now lets you quit directly. Control-clicking does the same. Quit used to be only in the panel's gear menu.
- Quitting while an operation is in progress waits for it to finish, so a switch is never left half done.
- Only one Agy Switcher runs at a time. Opening another copy while one is running exits immediately.

## 0.2.0

### 简体中文

- 新增菜单栏工具 Agy Switcher。点开列出已保存的账号、套餐和额度，点一项完成切换；还可以刷新额度、新增账号、保存当前登录、改名、删除、换语言。
- Agy Switcher 和 `agy-cs` 是同一个程序：在终端里运行是命令，被系统打开时是菜单栏工具。两种形式用同一份数据。
- 发布页提供两个包：`Agy-Switcher.zip` 和单个文件的 `agy-cs-macos-universal.tar.gz`，都同时支持 Apple 芯片和 Intel。
- 语言文件编进了二进制。`agy-cs` 现在是单个文件，旁边不再需要资源包。
- `agy-cs switch add` 直接新增账号。
- `agy-cs save <名字>` 在名字下面已经存着另一个登录时不再直接覆盖，带 `--force` 才替换。
- `agy-cs move <名字> <位置>` 调整账号的顺序。在 Agy Switcher 里按住一行上下拖是同一件事。
- `agy-cs ls` 显示每个账号的套餐，以及 Gemini 5 小时、7 天和 Argon 额度的剩余量与重置时间；套餐是 Pro 但不算付费订阅的账号标“非付费”。
- `agy-cs refresh quota` 重新查询所有账号的套餐和额度。切换之后另起后台进程去查，不耽误切换。
- 钥匙串读写改走 `/usr/bin/security`，不再弹密码窗口。

### English

- New menu bar tool, Agy Switcher. It lists the saved accounts with their plan and quota, and a click switches. It can also refresh the quota, add an account, save the current login, rename, delete, and change the language.
- Agy Switcher and `agy-cs` are the same program: a command when run in a terminal, a menu bar tool when opened by the system. Both forms use the same data.
- The release page has two packages: `Agy-Switcher.zip` and the single-file `agy-cs-macos-universal.tar.gz`. Both run on Apple silicon and Intel.
- The language files are compiled into the binary. `agy-cs` is now a single file and needs no resource bundle next to it.
- `agy-cs switch add` adds an account directly.
- `agy-cs save <name>` no longer overwrites another login that is already saved under that name. `--force` replaces it.
- `agy-cs move <name> <position>` changes the order of the accounts. Dragging a row up or down in Agy Switcher does the same.
- `agy-cs ls` shows each account's plan, and how much of the Gemini 5-hour, 7-day and Argon quota is left and when it resets. An account whose plan is Pro but does not count as a paid subscription is marked "non-paid".
- `agy-cs refresh quota` looks up the plan and quota of every account again. After a switch, a separate background process does the lookup, so the switch does not wait.
- The keychain item is read and written through `/usr/bin/security`, so no password window appears.

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
