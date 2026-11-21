[English](README.en.md)

# agy-cli-switcher

在 macOS 上切换 Antigravity CLI（`agy`）的登录。命令名是 `agy-cs`。在终端里选择已保存的账号，或登录一个新账号。

需要 macOS 13，以及 Xcode 或 Command Line Tools 里的 Swift。

## 安装

```sh
git clone https://github.com/Cmochance/agy-cli-switcher.git
cd agy-cli-switcher
make install
```

`make install` 会编译 release，并把 `~/.local/bin/agy-cs` 指到仓库里的 `build/agy-cs`。终端要能找到这个目录：

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## 命令

| 命令 | 作用 |
| --- | --- |
| `agy-cs` | 列出已保存的账号 |
| `current` | 显示已记录的当前邮箱 |
| `list` | 列出已保存的账号。`ls` 相同 |
| `save <名字>` | 把当前登录存成一个名字 |
| `switch` | 在终端里选择。第 1 项是当前账号，不能选；第 2 项新增账号；之后是已保存账号。完成后在当前终端启动 `agy` |
| `switch <名字>` | 切换到已保存的账号，不启动 `agy` |
| `next` | 切换到下一个已保存的账号 |
| `rename <新名字>` | 把当前账号改名 |
| `rename <旧名字> <新名字>` | 把指定账号改名 |
| `rm <名字>` | 删除一个已保存的副本，不改当前登录 |
| `language` | 显示或切换界面语言。`lg` 相同 |
| `help` | 显示全部指令 |

没指定语言时跟随系统。可选 `zh-Hans`、`zh-Hant`、`en`、`ja`。

第一次运行、并且还没有账号记录时，会读取一次当前登录，用邮箱 `@` 前面的字符保存。已经有记录时不再读登录。

换到另一个邮箱时，会删除 `~/.gemini/antigravity-cli/.quota_cache.json`。`~/.gemini/antigravity-cli/conversations` 保持不动。

## 数据放在哪

| 位置 | 内容 |
| --- | --- |
| `~/.agy-cs/` | 名字、邮箱、当前项和语言。不含登录密钥 |
| `~/.gemini/antigravity-cli/accounts/` | `agy` 自己的登录副本 |
| 登录钥匙串里的一条 generic password，service 是 `gemini`，account 是 `antigravity` | 当前登录。切换时只替换这一条 |

目录权限是 `700`，文件权限是 `600`。

## 改界面文字

四种语言的句子在 [`Sources/AgyAccount/i18n`](Sources/AgyAccount/i18n)。直接改对应的 txt，说明在该目录的 `README.md`。改完执行 `make install`。

## 测试

```sh
make test
```

`make test` 执行 `swift test --disable-sandbox`。

版本记录见 [documents/CHANGELOG.md](documents/CHANGELOG.md)。许可是 [MIT](LICENSE.txt)。
