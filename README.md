<p align="center">
  <b>English</b> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/icon.png" width="128" alt="Meter icon">
</p>

<h1 align="center">Meter</h1>

<p align="center">
  <b>Every AI coding plan's balance — one glance in your menu bar.</b><br>
  Claude · Codex · GLM Coding Plan · Kimi Code
</p>

<p align="center">
  <img src="docs/hero.png" alt="Meter menu showing Claude, Codex, GLM Coding and Kimi Code usage">
</p>

## Why Meter

If you pay for more than one AI coding plan, you know the feeling. Claude, Codex, GLM and Kimi
each meter you differently — 5-hour windows, weekly caps, monthly MCP quotas — and each hides the
numbers in a different settings page. So you either check four dashboards, or you don't, and find
out you're out of quota when the agent stops halfway through a refactor.

The uncertainty is the worst part: you either ration ("better save it for later") or burn through
it and keep worrying about hitting the wall.

**Meter puts every plan's remaining headroom in your menu bar.** One glance tells you which plan has
room right now and when each window resets — so you pick the right tool and get back to work.

## Features

- **All plans at a glance** — a monochrome logo and one number per plan. The number is the
  tightest window, i.e. the limit that will stop you first.
- **Colour only when it matters** — numbers turn orange at 80% and red at 95%.
- **Details on click** — every window with a progress bar, percentage and reset time. Click a plan's
  name to open its app; click a row to open its official usage page.
- **Multiple accounts** — add as many GLM Coding Plan / Kimi Code API keys as you like.
- **Keeps working** — Meter refreshes the Claude and Codex sign-ins by itself, keeps showing the last
  known numbers when a request fails, backs off politely on errors, refreshes after your Mac wakes,
  and offers one-click "Sign In Again" when a real re-login is needed.
- **Private** — talks only to each provider's own usage endpoint. Keys stay on your Mac. No analytics.
- **Native and tiny** — Swift + AppKit, no dependencies, Liquid Glass menu on macOS 26.

<p align="center">
  <img src="docs/menubar.png" alt="Menu bar styles: numbers and rings, on dark and light menu bars">
</p>

Prefer something even smaller? Switch to **Rings** in *Others › Menu Bar Style*.

## Install

Requires macOS 13 or later on Apple silicon. Build from source (takes a few seconds):

```bash
git clone https://github.com/zjulhc-pixel/Meter.git && cd Meter && ./build.sh install
```

Then connect your plans:

| Plan | How to connect |
|---|---|
| Claude (Pro / Max) | Sign in to Claude Code once (`claude`). Meter reuses that sign-in. |
| Codex (ChatGPT plans) | Sign in to Codex once (Codex CLI or the ChatGPT app). |
| GLM Coding Plan | *Others › Accounts › Add GLM Coding Plan Account…* with your API key. |
| Kimi Code | *Others › Accounts › Add Kimi Code Account…* with your `sk-kimi-…` key. |

Meter turns on *Launch at Login* the first time it runs; toggle it under *Others*.

## Where the data comes from

| Plan | Credentials | Usage endpoint |
|---|---|---|
| Claude | Claude Code's keychain item `Claude Code-credentials` (or `~/.claude/.credentials.json`) | `api.anthropic.com/api/oauth/usage` |
| Codex | `~/.codex/auth.json` (`$CODEX_HOME`) | `chatgpt.com/backend-api/wham/usage` |
| GLM Coding | API key in `~/Library/Application Support/Meter/accounts.json` | `open.bigmodel.cn/api/monitor/usage/quota/limit` |
| Kimi Code | API key in the same file | `api.kimi.com/coding/v1/usages` |

Claude and Codex access tokens expire after a few hours. Meter refreshes them the same way the
official CLIs do and writes the new tokens back to the same place, so the CLIs keep working too.
Diagnostics (never containing secrets) go to `~/Library/Logs/Meter.log` (*Others › Open Log*).

## Development

```bash
./build.sh                    # build into build/Meter.app
./build.sh install            # replace /Applications/Meter.app and relaunch
build/Meter.app/Contents/MacOS/Meter --check   # fetch every plan once and print the results
build/Meter.app/Contents/MacOS/Meter --demo    # sample data, no network (add --rings / --backdrop)
swift Tools/make-icon.swift titanium Resources/AppIcon.icns   # regenerate the icon
swift Tools/make-icon.swift sheet styles.png  # compare icon materials: flat, aluminum, titanium, glass, obsidian
```

Formerly called UsageBar; the bundle id is still `local.usagebar` so existing settings carry over.

## License

MIT — see [LICENSE](LICENSE). Meter is an independent project and is not affiliated with Anthropic,
OpenAI, Zhipu AI or Moonshot AI; product names and logos belong to their owners.
