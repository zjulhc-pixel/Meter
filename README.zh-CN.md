<p align="center">
  <a href="README.md">English</a> · <b>简体中文</b>
</p>

<p align="center">
  <img src="docs/icon.png" width="128" alt="Meter 图标">
</p>

<h1 align="center">Meter</h1>

<p align="center">
  <b>一眼看清每个 AI Coding Plan 的余额，不再为额度焦虑。</b><br>
  Claude · Codex · GLM Coding Plan · Kimi Code
</p>

<p align="center">
  <img src="docs/hero.png" alt="Meter 菜单，显示 Claude、Codex、GLM Coding 和 Kimi Code 的用量">
</p>

## 为什么做 Meter

同时订阅了好几个 AI Coding Plan 的人，大概都有过这种感受：Claude、Codex、GLM、Kimi 各有各的计量方式——
5 小时窗口、周限额、MCP 月额度——用量还分散在各自的设置页里。要么一个个打开去看，要么干脆不看，
等到 agent 写到一半突然停下，才发现额度用完了。

最难受的是心里没底：要么舍不得用，总想"留着以后用"；要么放开用，又时刻担心随时撞上限额。

**Meter 把所有套餐的剩余额度放进菜单栏。** 扫一眼就知道哪个还有余量、各个窗口什么时候重置，
挑对工具接着干，不再为额度焦虑。

## 功能

- **一眼看全**：每个套餐一个黑白 logo 加一个数字。数字取最紧的那个窗口，也就是最先会卡住你的限额。
- **只在需要时提醒**：用量到 80% 数字变橙，到 95% 变红。
- **点开看详情**：每个窗口都有进度条、百分比和重置时间。点套餐名打开对应 app，点用量行打开官方用量页。
- **多账号**：GLM Coding Plan 和 Kimi Code 可以添加任意多个 API key。
- **稳定不掉线**：自动刷新 Claude 和 Codex 的登录凭证；请求失败时继续显示上次的数据；出错时自动退避重试；
  电脑唤醒后立即刷新；真的需要重新登录时，菜单里一键重新登录。
- **隐私**：只访问各家官方的用量接口，密钥只存在你的 Mac 上，没有任何统计上报。
- **原生轻量**：Swift + AppKit 编写，零依赖，macOS 26 上是 Liquid Glass 风格菜单。

<p align="center">
  <img src="docs/menubar.png" alt="菜单栏样式：数字与圆环，深色与浅色菜单栏">
</p>

想要更短？在菜单 *Others › Menu Bar Style* 里切换到圆环样式（Rings）。

## 安装

需要 macOS 13 及以上、Apple 芯片。从源码编译，只需几秒钟：

```bash
git clone https://github.com/zjulhc-pixel/Meter.git && cd Meter && ./build.sh install
```

然后接入你的套餐：

| 套餐 | 接入方式 |
|---|---|
| Claude（Pro / Max） | 用 Claude Code 登录一次（运行 `claude`），Meter 直接复用这个登录。 |
| Codex（ChatGPT 套餐） | 登录一次 Codex（Codex 命令行或 ChatGPT app）。 |
| GLM Coding Plan | 菜单 *Others › Accounts › Add GLM Coding Plan Account…*，填入 API key。 |
| Kimi Code | 菜单 *Others › Accounts › Add Kimi Code Account…*，填入以 `sk-kimi-` 开头的 key。 |

Meter 首次运行会自动开启开机自启，可在菜单 *Others* 里关闭。

## 数据来源

| 套餐 | 凭证位置 | 用量接口 |
|---|---|---|
| Claude | Claude Code 的钥匙串项 `Claude Code-credentials`（或 `~/.claude/.credentials.json`） | `api.anthropic.com/api/oauth/usage` |
| Codex | `~/.codex/auth.json`（`$CODEX_HOME`） | `chatgpt.com/backend-api/wham/usage` |
| GLM Coding | `~/Library/Application Support/Meter/accounts.json` 中的 API key | `open.bigmodel.cn/api/monitor/usage/quota/limit` |
| Kimi Code | 同一文件中的 API key | `api.kimi.com/coding/v1/usages` |

Claude 和 Codex 的访问令牌几个小时就会过期。Meter 用和官方命令行工具相同的方式自动刷新，并写回原来的位置，
所以命令行工具也能照常使用。诊断日志（不含任何密钥）在 `~/Library/Logs/Meter.log`，也可以从菜单
*Others › Open Log* 打开。

## 开发

```bash
./build.sh                    # 编译到 build/Meter.app
./build.sh install            # 替换 /Applications/Meter.app 并重新启动
build/Meter.app/Contents/MacOS/Meter --check   # 拉取一次所有套餐的用量并打印结果
build/Meter.app/Contents/MacOS/Meter --demo    # 演示数据，不联网（可加 --rings / --backdrop）
swift Tools/make-icon.swift titanium Resources/AppIcon.icns   # 重新生成图标
swift Tools/make-icon.swift sheet styles.png  # 对比各种图标材质：flat、aluminum、titanium、glass、obsidian
```

Meter 原名 UsageBar；bundle id 仍是 `local.usagebar`，所以原有设置会自动保留。

## 许可证

MIT 许可证，详见 [LICENSE](LICENSE)。Meter 是独立项目，与 Anthropic、OpenAI、智谱 AI、月之暗面均无关联，
产品名称和 logo 归各自所有者所有。
