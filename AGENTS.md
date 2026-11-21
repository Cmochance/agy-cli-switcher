# agy-cli-switcher

本仓库只做 Antigravity CLI（`agy`）在这台 Mac 上的账号切换。后续实现不要偏离下面的约束。

## 语言和界面

- 实现只用 Swift。新文件、新目标、依赖都放在 Swift 里。
- 不要改成 Rust、Python、shell、Tauri 或网页。
- 界面是 macOS 菜单栏工具：SwiftUI + AppKit，部署目标 macOS 13。点开列出已保存邮箱，再点一项完成切换。不要做独立大窗口，也不要做浏览器页面。
- 工程形态用 Swift Package 的单个可执行文件，对齐本机 `mouse-switch` 的 `Package.swift`。
- 钥匙串那一项的读、写、删都通过 `/usr/bin/security`，和 `agy` 自己的做法一致。路径写绝对路径，不从 `PATH` 里找。读用 `find-generic-password -w`，删用 `delete-generic-password`。写用 `security -i`，把 `add-generic-password -U … -w <内容>` 从标准输入送进去，token 不出现在任何进程的参数里。
- 不要用 Security.framework 的 `SecItem*` 或 Python 读写这一项的内容。这一项只信任 `/usr/bin/security`，分区名单里只有 `apple-tool:`。在本进程里读，每读一次弹两个钥匙串密码窗口。在本进程里写，分区名单会被换成本程序的 `cdhash:`，之后 `agy` 自己读取也会弹窗。只数这一项有几条、不取内容时，可以用 `SecItemCopyMatching`。
- `security -i` 的一行连换行超过 4096 个字节时，前 4095 个字节会被当成一条指令执行，剩下的被当成下一条指令。写入前检查内容只有 `go-keyring-base64:` 加 base64 字符，并且整行不超过 4095 个字节。新增账号在移开钥匙串那一项之前先做同样的检查，写不回去的登录不动它。

## 登录数据

- 当前登录只有钥匙串里这一条 generic password：service `gemini`，account `antigravity`。
- 值是 `go-keyring-base64:` 加上标准 base64。解码后的 JSON 含 `token.refresh_token`、`token.access_token`、`token.expiry`、`id_token_email`、`auth_method`。
- 已保存账号放在 `~/.gemini/antigravity-cli/accounts/`。目录权限 `700`，文件权限 `600`。仓库里不放这些副本。
- 不要把 token、refresh token 或钥匙串原文写进仓库、日志、提交说明或这份规则。
- `.gitignore` 忽略 `*.token` 和 `accounts/`。不要放宽。

## 行为

- 切换只替换上面那一条钥匙串项。换到另一个邮箱时删除 `~/.gemini/antigravity-cli/.quota_cache.json`。
- 不移动、不删除 `~/.gemini/antigravity-cli/conversations`。
- 命令名是 `agy-cs`。本机 `~/.local/bin/agy-cs` 指向仓库 `build/agy-cs`。改完后执行 `make install`。它会把 release 二进制和旁边的 `agy-cs_AgyAccount.bundle` 一起放到 `build/`。只复制二进制的话，运行时找不到语言包，会在 `resource_bundle_accessor.swift` 里崩溃。安装时先删掉旧的 `build/agy-cs` 再复制，然后执行 `codesign --force --sign - build/agy-cs`。直接 `cp -f` 覆盖旧文件时，内核会沿用旧的代码签名缓存，打开第一页就发 SIGKILL，zsh 显示 `killed`。
- 非密钥名单在 `~/.agy-cs/`，目录权限 `700`，文件权限 `600`。这里不放 token。首次运行如果还没有账号记录，会读取一次钥匙串，用邮箱 `@` 前面的字符保存当前登录，并写入 `~/.agy-cs/initialized`。已经有账号记录时只补这个标记，不再读钥匙串。
- 初始化之后，`current`、`list`、`rm`、`rename`、`language`、`help` 只读 `~/.agy-cs/`。`save`、`switch`、`next` 才读写钥匙串。密钥副本仍在 `~/.gemini/antigravity-cli/accounts/`。
- 联网只发生在 `agy-cs refresh quota` 里：用每个保存副本里的 refresh token 向 `oauth2.googleapis.com` 换一个临时 access token，再请求 `daily-cloudcode-pa.googleapis.com` 的 `loadCodeAssist`（套餐）和 `retrieveUserQuotaSummary`（额度），结果写到 `~/.agy-cs/usage/<名字>.json`。临时 token 只留在内存里，不回写任何文件，也不读钥匙串。从开始到最后一个回答合计最多等 10 秒。`list` 不联网，只读这些记录。记录里带着邮箱；同一个名字后来存成了另一个登录时，旧记录不再显示。
- 额度查询和切换互不干涉。`switch`、`next` 和新增账号成功之后不在本进程里查，而是另起进程执行 `agy-cs refresh quota`，不等它结束，它失败也不影响切换；切换失败时不会启动它。启动分两步：先启动 `agy-cs refresh quota --detach` 并等它退出，它再启动真正查询的进程（自成会话，标准输入输出接 `/dev/null`）然后立刻退出。这样查询进程没有父进程，菜单里随后换成 `agy` 的那个进程下面不会留下僵尸进程。`--detach` 只给这一步用，不写进 help。
- 后台那次查询没有终端可以报错，所以每次查询都把没查到的账号写进 `~/.agy-cs/usage-status.json`，`list` 发现有就在 stderr 提示。`~/.agy-cs/usage.lock` 上的 `flock` 保证同一时间只有一个进程在查询和写记录。锁被占着时最多等 10 秒：等到了说明另一个进程刚查完，它查过的账号直接用它记下的结果，只补查它没见过的账号，等锁和补查合计仍不超过 10 秒；等不到就报忙，不写任何记录。保存的副本读不出来的账号也算没查到。本次查询的退出码用本次内存里的结果，`usage-status.json` 写不下来时直接报错。写记录前再核对一次这个名字现在的邮箱，查询期间被删掉或改存成别的登录的名字不写。
- `list` 的每一行是：套餐、`5h`（`gemini-5h`）、`7d`（`gemini-weekly`）、`Argon`（id 里带 `argon` 的那一项）。每项显示剩余百分比和本机时区的重置时间。剩余 100% 时不显示重置时间。当前时间过了重置时间就按 100% 显示。账号没有这一项时显示 `—`。不显示套餐到期时间，这两个接口里没有这个字段。
- 这两个接口是 `agy` 自己用的，没有公开文档。请求的 User-Agent 必须是 `antigravity/cli/<版本号>`，版本号取自 `agy --version`。标识不对时接口返回 403，版本太旧时回答里的组不全（实测 1.3.0 起是完整的三组，1.2.0 只有两组，1.1.0 只剩 Claude/GPT 一组）。
- `agy --version` 只在 `~/.agy-cs/agy-client.json` 里记的大小或修改时间和现在的 `agy` 对不上时才执行，执行前先核对代码签名是 Google 的 Developer ID（团队 `EQHXZ8M8AV`）。`PATH` 上签名对不上的 `agy` 不会被执行。`switch <名字>` 和 `next` 原本不启动 `agy`，不能因为查额度而去执行一个来路不明的文件。
- 换 token 用的 OAuth client secret 不写进仓库。运行时从 `PATH` 上的 `agy` 二进制里找 `GOCSPX-` 加 28 个字符，二进制里有几个候选，逐个试。`~/.agy-cs/agy-client.json` 只记 `agy` 的大小、修改时间、版本号和可用那个候选的位置，不记 secret 本身。
- `agy-cs switch` 不带名字时在终端里选择：第 1 项是当前账号，不能选；第 2 项新增账号；从第 3 项起是已有账号。选已有账号完成切换后，在当前终端启动 `agy`。`agy-cs switch add` 跳过选择，直接新增账号。新增账号会先保存当前登录，临时移开钥匙串那一项，再启动 `agy` 让用户登录；登录写入新邮箱后按 `@` 前的字符保存，然后重新启动 `agy`。登录没有完成就退出时，把原来的钥匙串登录写回去。`agy-cs switch <名字>` 只切换，不启动 `agy`。`add` 不是账号名：`save`、`rename` 的新名字和按邮箱自动取名都拒绝它；以前留下的 `add` 记录仍能在菜单里选，也能 `rename`、`rm`。
- 把终端交给 `agy` 之前，要求本进程是终端的前台进程组（`tcgetpgrp` 等于 `getpgrp`）。`agy-cs switch &` 这样放到后台时直接报错，不删除也不改写钥匙串那一项。首次运行的那一次读取照常发生，和其他指令一样。交出前台那一步不忽略 `SIGTTOU`，只在交出之后、收回终端期间忽略 `SIGTTOU` / `SIGTTIN`。
- `rename <新名字>` 改当前账号的名字。`rename <旧名字> <新名字>` 改指定账号的名字。只改保存的副本和 `~/.agy-cs/` 记录，不读钥匙串。
- 界面语言默认跟随系统。`agy-cs language` 可改成 `zh-Hans`、`zh-Hant`、`en`、`ja`。
- 界面句子放在 `Sources/AgyAccount/i18n/`。四种语言各一个文件：`zh-Hans.txt`、`zh-Hant.txt`、`en.txt`、`ja.txt`。改文案只改这些文件，格式见同目录 `README.md`。新增句子时，`TextKey` 和四个文件使用同一个键名。

## 验证

- 说完成之前核对：`~/.local/bin/agy-cs` 的符号链接目标、钥匙串的 service 和 account 没变、当前邮箱仍能读出。
- 输出里不打印 token。
- 改了钥匙串读写之后，用临时项跑一遍真实往返：`AGY_ACCOUNT_PROBE=1 swift test --disable-sandbox --filter testSecurityToolRoundTripOnAProbeItemWhenEnabled`。它只动 service 为 `agy-cs-test-probe` 的临时项，结束时删掉。
- 改了套餐和额度的抓取之后，跑一遍真实请求：`AGY_USAGE_LIVE=1 swift test --disable-sandbox --filter testLiveUsageFetchWhenEnabled`。它用本机保存的每个账号各查一次，只打印套餐和额度项的 id。

## 合并之后

- 合并 PR 仍要用户当条消息明确说合并。合并完成后，下面几步默认接着做，不用再问：
  1. 先确认本地分支和合并后的 `main` 内容一致（`git diff --quiet main <分支>`）。不一致就停下来报告，不删。
  2. `git switch main`，`git pull --ff-only`。
  3. 删除本地分支（squash 合并后要用 `git branch -D`）和远端分支（`git push origin --delete <分支>`），再 `git fetch --prune`。
  4. 用 `git branch -a` 核对两个分支都已消失。
- 只删刚合并的那个 PR 的分支，其他分支不动。
