# agy-cli-switcher

本仓库只做 Antigravity CLI（`agy`）在这台 Mac 上的账号切换。后续实现不要偏离下面的约束。

## 语言和界面

- 实现只用 Swift。新文件、新目标、依赖都放在 Swift 里。
- 不要改成 Rust、Python、shell、Tauri 或网页。
- 界面是 macOS 菜单栏工具：SwiftUI + AppKit，部署目标 macOS 13。点开列出已保存邮箱，再点一项完成切换。不要做独立大窗口，也不要做浏览器页面。
- 工程形态用 Swift Package 的单个可执行文件，对齐本机 `mouse-switch` 的 `Package.swift`。
- 这一个可执行文件两用。`Sources/agy-cs/main.swift` 用 `launchMode` 判断：没有参数、父进程是 launchd（`getppid() == 1`）、环境里有 `AGY_CS_MENU_BAR=1`，三样都对上才进菜单栏，其余情况都是命令行。这个标记只写在 `Packaging/Info.plist` 的 `LSEnvironment` 里，被系统打开（Finder、Dock、`open`）时才有（实测）。进菜单栏之后立刻 `unsetenv`，不传给之后启动的进程。不要另加一个 app 专用的可执行文件：切换后查额度的进程是重新执行自己，新增账号也是让终端执行包里的这同一个文件。
- 目标分三个。`AgyAccount` 是全部逻辑。`AgyMenuBar` 是界面：菜单栏图标是 `NSStatusItem`，点开的面板是 `NSPopover`，里面的内容用 SwiftUI 写，由 `NSHostingController` 按内容的大小报给面板。不要改回 SwiftUI 的 `MenuBarExtra` 窗口样式：它显示过几行提示之后窗口不再变矮，内容上下各空出一条（实测窗口 358 高，内容约 281 高）。`agy-cs` 只剩 `main.swift`。面板不自己实现任何账号操作，每个动作都经 `AccountBoard.perform` 在本进程里执行一条 `agy-cs` 指令，说的话收集起来显示。面板要的新能力先做成指令，再接到面板上。
- 面板里的操作：点一行等于 `switch -- <名字>`；“刷新额度”等于 `refresh quota`；每行的 `…` 里是 `rename` 和 `rm`，当前记录只剩这一份副本时再问一次，确认了才带 `--force`；齿轮里是 `save`、`language` 和退出。输入名字和确认删除都在面板里完成，不弹别的窗口。
- 菜单栏图标左键开关面板；右键，或者按住 control 的左键，弹出一个只有“退出”的菜单，面板点不开的时候也能退出。图标的按钮同时收左键和右键的松开，在动作里看当前事件分开。菜单只在这一次点击里挂到 `NSStatusItem.menu` 上，弹完就摘掉；一直挂着的话左键也会变成打开菜单，面板就点不开了。退出（右键菜单和齿轮里的都是 `PanelModel.quit`）遇到有指令正在执行时先等它做完再退：切换是先换钥匙串、再记当前账号，中途退出会只做了一半。
- 同一时间只运行一个菜单栏工具。启动时在 `~/.agy-cs/app.lock` 上拿 `flock`（`AccountBoard.lockApp`），拿不到说明已经有一个在运行，新启动的这个直接退出，不出图标。锁跟着进程走，退出或崩溃都会自动放开，不用清理文件。锁文件带 `O_CLOEXEC` 打开，不传给之后启动的查额度进程。命令行不拿这把锁。
- 面板上每行只显示邮箱，行和行之间有分隔线。名字是给命令行选账号用的，面板上不显示；只有同一个邮箱存了几个名字时，这几行才在邮箱后面带上名字，不然分不出来。改名和删除的提示里仍然写名字。
- 账号的顺序记在 `~/.agy-cs/order`，一行一个名字。`agy-cs move <名字> <位置>` 把一个账号移到第几位，只改这个文件，不读钥匙串。`list`、不带名字的 `switch`、`next` 和面板都按这个顺序。还没有这个文件时全部按字母顺序。有了之后，新存的名字接在最后，先存的在前；同一个名字再存一次不挪位置。改名留在原位，从没排过顺序时改名也一样，这时会把当时的顺序记下来。删掉的名字从顺序里去掉。文件里写着不存在的名字不碍事，读的时候只留现有的名字。
- 面板上按住一行上下拖就是执行 `move`：这一行跟着鼠标走，别的行让开，松手的那一下面板先换好，再把顺序记下来。行上的点击和拖动是同一个手势，松手时看鼠标走了多远，上下走出 6 个点算拖动，几乎没动算点击。不要把行换回按钮：按钮会把按下的鼠标吃掉，行就拖不动了。行底下另有一个看不见、不接鼠标的按钮，只给键盘用。位置怎么算在 `RowDrag` 里，不依赖界面，有单测。每一行的位置要在 `offset` 之后量，量到的才是不带拖动偏移的位置；带着偏移量的话，把一行拖到列表尽头松手之后，下一次拖动会按旧位置算（测试里撞到过）。
- `switch -- <名字>` 和 `switch <名字>` 一样，只是名字正好是 `add` 的旧记录也能切过去，不会被当成新增账号。打勾的行也能点：同一个登录存了几个名字时，每一行都打勾，点另一个名字把它记成当前项，不改钥匙串。
- `save <名字>` 在名字下面已经存着另一个登录时不替换，因为那一份保存的登录换掉就找不回来；带 `--force` 才替换。同一个登录重新存一次不算替换。命令行和面板都是这条规则。
- 面板上看到的一行可能已经过时，所以它确认之后发出的指令带 `--expect <邮箱>`，指令在动手之前核对这个名字下面实际存的是谁。`rm <名字> --expect <邮箱>`：存的不是这个邮箱就不删，带 `--force` 也一样。`save <名字> --force --expect <邮箱>`：只替换这个邮箱存的那一份。面板先不带 `--force` 存一次，被拒绝了就把占着名字的邮箱拿来问“替换？”，确认之后才带着 `--force` 和那个邮箱再存。`--expect` 和 `switch --` 只给面板用，不写进 help。
- 四个语言文件用 `Package.swift` 的 `.embedInCode` 编进二进制，`StringCatalog` 读 `PackageResources`。不要改回 `.copy` 加 `Bundle.module`：经符号链接运行时 `Bundle.main` 指向链接所在的目录（实测），按位置找资源包会找不到，放进 app 包之后也一样。
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
- 命令名是 `agy-cs`。本机 `~/.local/bin/agy-cs` 指向仓库 `build/agy-cs`。改完后执行 `make install`。`build/agy-cs` 是单个文件，旁边不需要别的东西。安装时先删掉旧的 `build/agy-cs` 再复制，然后执行 `codesign --force --sign - build/agy-cs`。直接 `cp -f` 覆盖旧文件时，内核会沿用旧的代码签名缓存，打开第一页就发 SIGKILL，zsh 显示 `killed`。
- `make app` 生成 `build/Agy Switcher.app`。`Contents/MacOS/agy-cs` 就是上面那个二进制，另有 `Packaging/Info.plist` 和 `Packaging/AppIcon.icns`，整个包 ad-hoc 签名。同样先 `rm -rf` 旧的包再拷。图标由 `Packaging/AppIcon.swift` 画出来，换图标时改它，再重新生成 icns。
- `make dist` 编译 arm64 加 x86_64 的通用二进制，生成 `dist/Agy-Switcher-v<版本号>-macOS-universal.dmg`、`dist/agy-cs-v<版本号>-macOS-universal.tar.gz`，每个文件旁边各有一个同名加 `.sha256` 的校验文件。两个架构分开编译，再用 `lipo -create` 合并。不要改成一次传两个 `--arch`：Xcode 26.6 的 SwiftPM 这时换用另一套构建系统，不生成 `.embedInCode` 的 `PackageResources`，编译不过（CI 实测）。每个架构编完就把二进制拷走，因为本机这版 SwiftPM 两次编译用同一个输出目录。dmg 用 `hdiutil create` 打，里面是 `Agy Switcher.app` 和一个指向 `/Applications` 的链接，打开就能拖进去。包名带版本号和平台，和本机其他项目的发布页一致；继续出通用包，不按架构拆，因为每个包不到 1 MB。不出 `.sig` 和 `latest.json`，它们是给自动更新用的，本项目没有。版本号只写在 `Packaging/Info.plist`，`Makefile` 从那里读；README 里的下载链接和文件名带着版本号，每次升版本要跟着改，测试会核对，CHANGELOG 也一样。
- 发布：推 `v` 加版本号的 tag，`release.yml` 跑测试、执行 `make dist`，然后建 draft release。它只建 draft，不要在 workflow 里加发正式版的步骤。签名是 ad-hoc，没有公证，因为没有 Developer ID 证书；浏览器下载的 app 第一次打开要到“系统设置 → 隐私与安全性”里放行。以后有证书时用 `make dist SIGN_IDENTITY=…`，公证另加。
- 非密钥名单在 `~/.agy-cs/`，目录权限 `700`，文件权限 `600`。这里不放 token。首次运行如果还没有账号记录，会读取一次钥匙串，用邮箱 `@` 前面的字符保存当前登录，并写入 `~/.agy-cs/initialized`。已经有账号记录时只补这个标记，不再读钥匙串。菜单栏工具启动时走的是同一步。
- 初始化之后，`current`、`list`、`rm`、`rename`、`language`、`help` 只读 `~/.agy-cs/`。`save`、`switch`、`next` 才读写钥匙串。密钥副本仍在 `~/.gemini/antigravity-cli/accounts/`。面板打开时和打开期间每两秒的重读，读的是 `list` 那一份记录，同样不读钥匙串、不联网。重读可能正好撞上别的进程在改名或删除：列出名字之后、读它之前就没了的那条记录跳过，不当成整份名单读不出来（CI 上实测撞到过）。
- 联网只发生在 `agy-cs refresh quota` 里：用每个保存副本里的 refresh token 向 `oauth2.googleapis.com` 换一个临时 access token，再请求 `daily-cloudcode-pa.googleapis.com` 的 `loadCodeAssist`（套餐）、`retrieveUserQuotaSummary`（额度）和 `fetchAvailableModels`（模型列表），结果写到 `~/.agy-cs/usage/<名字>.json`。临时 token 只留在内存里，不回写任何文件，也不读钥匙串。从开始到最后一个回答合计最多等 10 秒。`list` 不联网，只读这些记录。记录里带着邮箱；同一个名字后来存成了另一个登录时，旧记录不再显示。
- 额度查询和切换互不干涉。`switch`、`next` 和新增账号成功之后不在本进程里查，而是另起进程执行 `agy-cs refresh quota`，不等它结束，它失败也不影响切换；切换失败时不会启动它。启动分两步：先启动 `agy-cs refresh quota --detach` 并等它退出，它再启动真正查询的进程（自成会话，标准输入输出接 `/dev/null`）然后立刻退出。这样查询进程没有父进程，菜单里随后换成 `agy` 的那个进程下面不会留下僵尸进程。`--detach` 只给这一步用，不写进 help。
- 后台那次查询没有终端可以报错，所以每次查询都把没查到的账号写进 `~/.agy-cs/usage-status.json`，`list` 发现有就在 stderr 提示。`~/.agy-cs/usage.lock` 上的 `flock` 保证同一时间只有一个进程在查询和写记录。锁被占着时最多等 10 秒：等到了说明另一个进程刚查完，它查过的账号直接用它记下的结果，只补查它没见过的账号，等锁和补查合计仍不超过 10 秒；等不到就报忙，不写任何记录。保存的副本读不出来的账号也算没查到。本次查询的退出码用本次内存里的结果，`usage-status.json` 写不下来时直接报错。写记录前再核对一次这个名字现在的邮箱，查询期间被删掉或改存成别的登录的名字不写。
- `list` 的每一行是：套餐、`5h`（`gemini-5h`）、`7d`（`gemini-weekly`）、`Argon`（id 里带 `argon` 的那一项）。每项显示剩余百分比和本机时区的重置时间。剩余 100% 时不显示重置时间。当前时间过了重置时间就按 100% 显示。账号没有这一项时显示 `—`。不显示套餐到期时间，这两个接口里没有这个字段。
- 套餐同样是 `g1-pro-tier`，Google 只给付费订阅开放 Gemini 4 的 Neon、Hydrogen、Argon。`loadCodeAssist` 分不出这两种账号（实测两个账号的回答逐字段相同），区别只在 `fetchAvailableModels`：没开放的账号，列表里是 `gemini-4-argon-disabled` 这样带 `disabled: true` 的占位项。记录里用 `argon_locked` 记下来。套餐不是 `free-tier` 而 Argon 锁着时，`list` 在套餐名后面标“非付费”。模型列表取不到不算这个账号失败，沿用上次记下的结果。这三个请求都不消耗额度（实测各连发 3 次，剩余比例七位小数不变）。
- 一次查询要尽量短。所有账号同时换 token；`agy` 没变时直接读 `agy-client.json` 里记着的那个位置上的 secret，不扫描整个文件，它被拒绝了才重新找。换 token 的同时先把到 Cloud Code 的连接建好。套餐、额度、模型列表三个请求同时发：额度请求要带的 project 记在额度记录里，和这次套餐回答里的一致就直接用提前发出的回答，不一致再按新的问一次。免费账号的额度请求不带 project 会返回 403（实测），所以不能省掉它。
- 这几个接口是 `agy` 自己用的，没有公开文档。请求的 User-Agent 必须是 `antigravity/cli/<版本号>`，版本号取自 `agy --version`。标识不对时接口返回 403，版本太旧时回答里的组不全（实测 1.3.0 起是完整的三组，1.2.0 只有两组，1.1.0 只剩 Claude/GPT 一组）。
- `agy --version` 只在 `~/.agy-cs/agy-client.json` 里记的大小或修改时间和现在的 `agy` 对不上时才执行，执行前先核对代码签名是 Google 的 Developer ID（团队 `EQHXZ8M8AV`）。`PATH` 上签名对不上的 `agy` 不会被执行。`switch <名字>` 和 `next` 原本不启动 `agy`，不能因为查额度而去执行一个来路不明的文件。
- 换 token 用的 OAuth client secret 不写进仓库。运行时从 `agy` 二进制里找 `GOCSPX-` 加 28 个字符，二进制里有几个候选，逐个试。`~/.agy-cs/agy-client.json` 只记 `agy` 的位置、大小、修改时间、版本号和可用那个候选的位置，不记 secret 本身。
- 读 secret 和版本号用的 `agy` 这样找：先 `PATH`，再 `agy-client.json` 里记着的位置，最后 `~/.local/bin`、`/opt/homebrew/bin`、`/usr/local/bin`。被系统打开的菜单栏进程，`PATH` 只有 `/usr/bin:/bin:/usr/sbin:/sbin`（实测），只靠 `PATH` 找不到。启动 `agy` 让用户登录的那一步（`agyExecutable`）仍然只认 `PATH`，不走这个回退。
- 面板的“新增账号…”不在面板里登录，`agy` 的登录界面要一个终端。它把 `~/.agy-cs/add-account.command`（权限 `700`）写成两行：`#!/bin/sh` 和 `exec '<本程序的路径>' switch add`，再用 `NSWorkspace` 打开，由系统默认的终端程序执行。实测默认是 Terminal.app，脚本里 stdin 是终端、进程在前台、`PATH` 里有 `agy`。路径用单引号括起来，路径里的单引号写成 `'\''`。这是仓库里唯一一处 shell，只负责把终端打开；登录和回滚仍是 `switch add` 那一套，不要往这个文件里加别的指令。面板自己没有终端，`switch` 和 `switch add` 在面板进程里按“需要终端”报错，不动钥匙串。
- `agy-cs switch` 不带名字时在终端里选择：第 1 项是当前账号，不能选；第 2 项新增账号；从第 3 项起是已有账号。选已有账号完成切换后，在当前终端启动 `agy`。`agy-cs switch add` 跳过选择，直接新增账号。新增账号会先保存当前登录，临时移开钥匙串那一项，再启动 `agy` 让用户登录；登录写入新邮箱后按 `@` 前的字符保存，然后重新启动 `agy`。登录没有完成就退出时，把原来的钥匙串登录写回去。`agy-cs switch <名字>` 只切换，不启动 `agy`。`add` 不是账号名：`save`、`rename` 的新名字和按邮箱自动取名都拒绝它；以前留下的 `add` 记录仍能在菜单里选，也能 `rename`、`rm`。
- 把终端交给 `agy` 之前，要求本进程是终端的前台进程组（`tcgetpgrp` 等于 `getpgrp`）。`agy-cs switch &` 这样放到后台时直接报错，不删除也不改写钥匙串那一项。首次运行的那一次读取照常发生，和其他指令一样。交出前台那一步不忽略 `SIGTTOU`，只在交出之后、收回终端期间忽略 `SIGTTOU` / `SIGTTIN`。
- `rename <新名字>` 改当前账号的名字。`rename <旧名字> <新名字>` 改指定账号的名字。只改保存的副本和 `~/.agy-cs/` 记录，不读钥匙串。
- 界面语言默认跟随系统。`agy-cs language` 可改成 `zh-Hans`、`zh-Hant`、`en`、`ja`。
- 界面句子放在 `Sources/AgyAccount/i18n/`。四种语言各一个文件：`zh-Hans.txt`、`zh-Hant.txt`、`en.txt`、`ja.txt`。改文案只改这些文件，格式见同目录 `README.md`。新增句子时，`TextKey` 和四个文件使用同一个键名。

## 验证

- 说完成之前核对：`~/.local/bin/agy-cs` 的符号链接目标、钥匙串的 service 和 account 没变、当前邮箱仍能读出。
- 输出里不打印 token。
- 改了钥匙串读写之后，用临时项跑一遍真实往返：`AGY_ACCOUNT_PROBE=1 make test FILTER=testSecurityToolRoundTripOnAProbeItemWhenEnabled`。它只动 service 为 `agy-cs-test-probe` 的临时项，结束时删掉。
- 改了套餐和额度的抓取之后，跑一遍真实请求：`AGY_USAGE_LIVE=1 make test FILTER=testLiveUsageFetchWhenEnabled`。它用本机保存的每个账号各查一次，只打印套餐和额度项的 id。
- 改了面板之后，把它画成图片看一眼：`AGY_PANEL_SNAPSHOT=/tmp/agy-panel make test FILTER=testPanelPicturesWhenEnabled`。图片写在那个目录里，用的是临时目录里的假账号。
- 改了行上的点击或拖动之后，把真的鼠标事件送进面板跑一遍：`AGY_PANEL_GESTURES=1 make test FILTER=testPanelGesturesWhenEnabled`。它会在屏幕左下角开一个两秒钟的小窗口，用的是临时目录里的假账号。
- 改了打包或启动方式之后执行 `make app`，核对三件事：`codesign --verify --strict "build/Agy Switcher.app"` 通过；在终端里运行 `"build/Agy Switcher.app/Contents/MacOS/agy-cs" ls` 仍然是命令行；`open "build/Agy Switcher.app"` 之后进程留着、菜单栏出现图标。

## 本地开发用 worktree

- 主目录 `~/alysechen/github/agy-cli-switcher` 只停在 `main`，不在这里建分支、改跟踪的文件、commit。它只做这几件事：读规则、`git pull --ff-only`、`make install`、放不进仓库的本地文件。
- 每个开发分支各用一个 worktree，放在 `~/alysechen/github/agy-cli-switcher-worktree/agy-cli-switcher-<分支后缀>`。分支后缀是分支名把 `/` 换成 `-`，比如 `feat/status-item-menu` 对应 `agy-cli-switcher-feat-status-item-menu`。几个 worktree 可以同时开发，互不影响。
- 建 worktree：在主目录先 `git pull --ff-only`，再执行 `git worktree add -b <分支> <worktree 路径> main`。不要用 `cp` 拷文件夹。worktree 里的 `.git` 只是一个指回主目录 `.git/worktrees/<名字>` 的文件，仓库本身始终在主目录（实测），之后再建 worktree、commit、push 都不受影响。同一个分支不能同时在两个文件夹里检出，所以主目录不离开 `main`。
- 会话的工作目录保持主目录，这样读到的始终是主目录的 `AGENTS.md`。读写文件一律用 worktree 的绝对路径；`make`、`git` 用 worktree 路径作为执行目录。不要用主目录的路径改跟踪的文件。
- 规则以主目录的 `AGENTS.md` 为准。要改规则时改 worktree 里的那一份，合并之后主目录 pull 下来才生效。
- 编译缓存只有一份，是主目录的 `.build/`。`Makefile` 用 `git rev-parse --git-common-dir` 找到主目录，把它的 `.build` 用 `--scratch-path` 传给每一条 `swift build` 和 `swift test`；worktree 里不会另外生成 `.build/`（实测）。换一个文件夹编译时本项目的代码会重编一遍，约 8 秒（实测）。
- 编译和测试一律用 `make build`、`make test`、`make app`、`make dist`，不直接执行 `swift build` 或 `swift test`。只跑一部分测试用 `make test FILTER=<测试名>`，环境变量照常写在 `make` 前面。直接执行 `swift` 会在 worktree 里另存一份缓存，也绕过了下面的排队。
- 同一时间只有一个文件夹在编译。`build`、`test`、`dist` 三个目标先用 `/usr/bin/lockf` 拿主目录 `.build/agy-cs-make.lock` 上的锁，再做事；锁被占着时说一声，然后等前一个做完。锁要把“编译”和“把二进制拷到自己的 `build/`”一起包住：几个 worktree 编出来的文件在同一个位置，只锁编译的话，这边还没拷走，那边就换成了另一个分支的。实测两个文件夹同时 `make build`，后一个等前一个，各自拿到的是自己的二进制。
- worktree 里不执行 `make install`：它会把 `~/.local/bin/agy-cs` 指到 worktree 的 `build/agy-cs`，worktree 删掉之后命令行就坏了。要手测就 `open "<worktree 路径>/build/Agy Switcher.app"`；已经有一个 Agy Switcher 在运行时先退出它，不然新开的这个拿不到 `app.lock`，会直接退出。
- 不进仓库的本地文件只放主目录，不放 worktree。只在本机用的，把路径写进主目录的 `.git/info/exclude`，它对所有 worktree 生效，不用开 PR。忽略规则要进仓库时才开 worktree 改 `.gitignore`。主目录里未跟踪的文件不影响 `git pull`，除非远端新增了同一个路径的文件。worktree 里要用这些文件时按主目录的绝对路径读，不拷贝。

## 合并之后

- 合并 PR 仍要用户当条消息明确说合并。合并完成后，下面几步默认接着做，不用再问：
  1. 确认 worktree 的分支和合并后的 `main` 内容一致（先 `git fetch`，再 `git diff --quiet origin/main <分支>`）。不一致就停下来报告，不删。
  2. 在 worktree 里执行 `git status --short --ignored`。有未提交的改动就停下来报告。列出的未跟踪和被忽略的文件，除了 `build/` 和 `dist/`，逐个确认可以丢；要留的先搬到主目录。`git worktree remove` 遇到未跟踪的文件会拒绝，被忽略的文件却会不加提示地一起删掉（实测）。
  3. 主目录 `git pull --ff-only`，再 `make install`。
  4. `git worktree remove <worktree 路径>`。不带 `--force`；它拒绝就回到第 2 步。
  5. 删除本地分支（squash 合并后要用 `git branch -D`）和远端分支（`git push origin --delete <分支>`），再 `git fetch --prune`。
  6. 用 `git worktree list` 和 `git branch -a` 核对 worktree 和两个分支都已消失。
- 只删刚合并的那个 PR 的 worktree 和分支，其他的不动。

## 清理残留

- 用户说清理构建和测试残留时，删这些：`build/Agy Switcher.app`、`dist/`、`/tmp` 下本项目留下的文件、系统临时目录里测试用的假 home。删之前核对内容确实是本项目产生的。
- 不删主目录的 `.build/`。它是所有 worktree 共用的编译缓存，删掉之后下次要从头编译。
- 不删 `build/agy-cs` 和 `~/.agy-cs/`。前者是 `~/.local/bin/agy-cs` 指向的文件，后者是用户的账号记录。
