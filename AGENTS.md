# agy-cli-switcher

本仓库只做 Antigravity CLI（`agy`）在这台 Mac 上的账号切换。后续实现不要偏离下面的约束。

## 语言和界面

- 实现只用 Swift。新文件、新目标、依赖都放在 Swift 里。
- 不要改成 Rust、Python、shell、Tauri 或网页。
- 界面是 macOS 菜单栏工具：SwiftUI + AppKit，部署目标 macOS 13。点开列出已保存邮箱，再点一项完成切换。不要做独立大窗口，也不要做浏览器页面。
- 工程形态用 Swift Package 的单个可执行文件，对齐本机 `mouse-switch` 的 `Package.swift`。
- 钥匙串用 Security.framework 在进程内读写。不要再启动 `security` 或 Python 去读写登录。

## 登录数据

- 当前登录只有钥匙串里这一条 generic password：service `gemini`，account `antigravity`。
- 值是 `go-keyring-base64:` 加上标准 base64。解码后的 JSON 含 `token.refresh_token`、`token.access_token`、`token.expiry`、`id_token_email`、`auth_method`。
- 已保存账号放在 `~/.gemini/antigravity-cli/accounts/`。目录权限 `700`，文件权限 `600`。仓库里不放这些副本。
- 不要把 token、refresh token 或钥匙串原文写进仓库、日志、提交说明或这份规则。
- `.gitignore` 忽略 `*.token` 和 `accounts/`。不要放宽。

## 行为

- 切换只替换上面那一条钥匙串项。换到另一个邮箱时删除 `~/.gemini/antigravity-cli/.quota_cache.json`。
- 不移动、不删除 `~/.gemini/antigravity-cli/conversations`。
- 命令名是 `agy-cs`。本机 `~/.local/bin/agy-cs` 指向仓库 `build/agy-cs`。改完后用 `swift build -c release` 构建，再把产物复制到 `build/agy-cs`。
- 非密钥名单在 `~/.agy-cs/`，目录权限 `700`，文件权限 `600`。这里不放 token。首次运行如果还没有账号记录，会读取一次钥匙串，用邮箱 `@` 前面的字符保存当前登录，并写入 `~/.agy-cs/initialized`。已经有账号记录时只补这个标记，不再读钥匙串。
- 初始化之后，`current`、`list`、`rm`、`rename`、`language`、`help` 只读 `~/.agy-cs/`。`save`、`switch`、`next` 才读写钥匙串。密钥副本仍在 `~/.gemini/antigravity-cli/accounts/`。
- `agy-cs switch` 不带名字时在终端里选择：第 1 项是当前账号，不能选；第 2 项新增账号；从第 3 项起是已有账号。选已有账号完成切换后，在当前终端启动 `agy`。新增账号会先保存当前登录，临时移开钥匙串那一项，再启动 `agy` 让用户登录；登录写入新邮箱后按 `@` 前的字符保存，然后重新启动 `agy`。登录没有完成就退出时，把原来的钥匙串登录写回去。`agy-cs switch <名字>` 只切换，不启动 `agy`。
- `rename <新名字>` 改当前账号的名字。`rename <旧名字> <新名字>` 改指定账号的名字。只改保存的副本和 `~/.agy-cs/` 记录，不读钥匙串。
- 界面语言默认跟随系统。`agy-cs language` 可改成 `zh-Hans`、`zh-Hant`、`en`、`ja`。
- 界面句子放在 `Sources/AgyAccount/i18n/`。四种语言各一个文件：`zh-Hans.txt`、`zh-Hant.txt`、`en.txt`、`ja.txt`。改文案只改这些文件，格式见同目录 `README.md`。新增句子时，`TextKey` 和四个文件使用同一个键名。

## 验证

- 说完成之前核对：`~/.local/bin/agy-cs` 的符号链接目标、钥匙串的 service 和 account 没变、当前邮箱仍能读出。
- 输出里不打印 token。
