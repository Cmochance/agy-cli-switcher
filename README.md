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

**agy-cli-switcher** 在 macOS 上切换 Antigravity CLI（`agy`）的登录。有两种形式：终端里的命令 `agy-cs`，和菜单栏工具 Agy Switcher。两者是同一个程序，用同一份数据，可以只装一种，也可以都装。

当前版本 **v0.2.0**（详见 [Changelog](documents/CHANGELOG.md)）。

## 能做什么

- 在多个 `agy` 登录之间切换，并记下名字、邮箱和当前项
- Agy Switcher 在菜单栏里列出已保存的账号和额度，点一项完成切换
- `agy-cs ls` 显示每个账号的套餐，以及 Gemini 5 小时、7 天和 Argon 额度的剩余量与重置时间
- `agy-cs switch` 在终端里选择：第 1 项是当前账号，不能选；第 2 项新增账号；之后是已保存账号。完成后在当前终端启动 `agy`
- `agy-cs switch add` 直接新增账号，不进入选择。先保住当前登录，再打开 `agy`
- `agy-cs switch <名字>` 只切换，不启动 `agy`
- 第一次运行、并且还没有账号记录时，读取一次当前登录，用邮箱 `@` 前面的字符保存
- 换到另一个邮箱时删除 `~/.gemini/antigravity-cli/.quota_cache.json`。`~/.gemini/antigravity-cli/conversations` 保持不动
- 界面语言默认跟随系统，可选 `zh-Hans`、`zh-Hant`、`en`、`ja`

## 安装

需要 macOS 13 或更新的系统，Apple 芯片和 Intel 都可以。下面两种形式任选。

### 菜单栏工具 Agy Switcher

1. 在 [Releases](https://github.com/Cmochance/agy-cli-switcher/releases/latest) 下载 `Agy-Switcher.zip`，解开后把 `Agy Switcher.app` 拖进“应用程序”
2. 第一次打开时系统会拦住它，因为它没有经过 Apple 公证。到“系统设置 → 隐私与安全性”里点“仍要打开”

也可以在终端里下载。这样下载的文件不带 `com.apple.quarantine` 标记，不用去系统设置里放行：

```bash
tmp="$(mktemp -d)" && \
  curl -fL -o "$tmp/Agy-Switcher.zip" https://github.com/Cmochance/agy-cli-switcher/releases/latest/download/Agy-Switcher.zip && \
  ditto -x -k "$tmp/Agy-Switcher.zip" /Applications && \
  open "/Applications/Agy Switcher.app"
```

`mktemp -d` 建的目录只有你自己能进，前一步没成功后面就不执行。

更新时先退出 Agy Switcher 并删掉旧的 `Agy Switcher.app`，再装新的。

### 命令 `agy-cs`

预编译的是单个文件：

```bash
mkdir -p ~/.local/bin
curl -fL https://github.com/Cmochance/agy-cli-switcher/releases/latest/download/agy-cs-macos-universal.tar.gz | tar -xz -C ~/.local/bin
```

已经装了 Agy Switcher 的话不用再下载，包里就是同一个程序：

```bash
mkdir -p ~/.local/bin
ln -s "/Applications/Agy Switcher.app/Contents/MacOS/agy-cs" ~/.local/bin/agy-cs
```

也可以从源码编译，需要 Xcode 或 Command Line Tools 里的 Swift：

```bash
git clone https://github.com/Cmochance/agy-cli-switcher.git
cd agy-cli-switcher
make install
```

`make install` 会编译 release，并把 `~/.local/bin/agy-cs` 指到仓库里的 `build/agy-cs`。

终端要能找到 `~/.local/bin`：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

下载的两个文件可以用同一页上的 `SHA256SUMS.txt` 核对：`shasum -a 256 -c SHA256SUMS.txt`。

## 快速开始

1. 执行 `agy-cs` 查看已保存的账号
2. 执行 `agy-cs switch` 选择账号，或登录一个新账号
3. 执行 `agy-cs help` 查看全部指令

## 菜单栏工具

点菜单栏上的图标打开面板。

- 每行是一个已保存的账号：名字、邮箱、套餐，以及 5h、7d、Argon 额度。打勾的是当前账号；同一个登录存了几个名字时，这几行都打勾
- 点一行就切换过去，和 `agy-cs switch <名字>` 一样，只切换，不启动 `agy`
- 保存当前登录时，名字下面已经存着别的账号的话，会先问要不要替换
- “刷新额度”和 `agy-cs refresh quota` 一样
- “新增账号…”打开终端执行 `agy-cs switch add`，在那里登录。登录完再点开面板就能看到新账号
- 每行右边的 `…` 里可以改名、删除。齿轮里可以保存当前登录、换语言、退出
- 打开面板只读记下来的结果，不联网，也不读钥匙串

## 命令

| 命令 | 作用 |
|---|---|
| `agy-cs` | 列出已保存的账号 |
| `current` | 显示已记录的当前邮箱 |
| `list` | 列出已保存的账号，以及最近一次记下的套餐和额度。`ls` 相同 |
| `save <名字>` | 把当前登录存成一个名字。名字下面已经存着另一个登录时不替换 |
| `save <名字> --force` | 名字下面已经存着另一个登录时，替换它 |
| `switch` | 在终端里选择。第 1 项是当前账号，不能选；第 2 项新增账号；之后是已保存账号。完成后在当前终端启动 `agy` |
| `switch add` | 直接新增账号，不进入选择。先保住当前登录，再打开 `agy` |
| `switch <名字>` | 切换到已保存的账号，不启动 `agy` |
| `next` | 切换到下一个已保存的账号 |
| `refresh quota` | 重新查询所有已保存账号的套餐和额度，然后列出来 |
| `rename <新名字>` | 把当前账号改名 |
| `rename <旧名字> <新名字>` | 把指定账号改名 |
| `rm <名字>` | 删除一个已保存的副本，不改当前登录 |
| `language` | 显示或切换界面语言。`lg` 相同 |
| `help` | 显示全部指令 |

## 套餐和额度

```
* alice  alice@example.com  Pro   5h 62% 11-21 23:35  7d 100%             Argon 100%
  bob    bob@example.com    Free  5h —                7d 99% 11-28 18:23  Argon —
```

- 每一项是剩余的百分比，后面是重置时间（本机时区）。剩余 100% 时不显示重置时间
- 过了重置时间的项按 100% 显示
- `—` 表示这个账号没有这一项。免费账号没有 5 小时额度，Argon 只有部分账号有
- `Pro（非付费）` 表示套餐是 Pro，但 Google 没有把它算作付费订阅。这样的账号用不了 Gemini 4 的 Neon、Hydrogen 和 Argon，也没有 Argon 额度
- `ls` 只读记下来的结果，不联网
- `agy-cs refresh quota` 立刻把所有账号查一遍并列出来
- `switch`、`next` 和新增账号成功之后，会另起一个后台进程去查。切换不等它，也不受它影响；通常几秒后 `ls` 就是新的。后台那次有账号没查到时，下一次 `ls` 会提示
- 查询用的是 `agy` 自己使用的接口。Google 没有公开这些接口，`agy` 升级后可能失效

## 数据放在哪

| 位置 | 内容 |
|---|---|
| `~/.agy-cs/` | 名字、邮箱、当前项、语言，以及套餐和额度记录。不含登录密钥。“新增账号…”用的 `add-account.command` 也在这里，里面只有一行启动 `agy-cs switch add` 的指令 |
| `~/.gemini/antigravity-cli/accounts/` | `agy` 自己的登录副本 |
| 登录钥匙串里的一条 generic password，service 是 `gemini`，account 是 `antigravity` | 当前登录。切换时只替换这一条 |

目录权限是 `700`，文件权限是 `600`。

## 界面文字

四种语言的句子在 [`Sources/AgyAccount/i18n`](Sources/AgyAccount/i18n)。直接改对应的 txt，说明在该目录的 `README.md`。改完执行 `make install`。

## 本地开发

```bash
make test       # swift test --disable-sandbox
make install    # 重新编译并更新 ~/.local/bin/agy-cs
make app        # 生成 build/Agy Switcher.app，用 open "build/Agy Switcher.app" 打开
make dist       # 生成 dist/ 里的两个发布包和 SHA256SUMS.txt
```

`make test` 执行 `swift test --disable-sandbox`。

推一个 `v` 开头的 tag 会触发发布流程：跑测试、执行 `make dist`，然后建一个 draft release。tag 要和 `Packaging/Info.plist` 里的版本号一致。

## 许可证

MIT License。完整文本见 [LICENSE.txt](LICENSE.txt)。
