# Meter

Menu bar app showing plan usage for Claude, Codex, GLM Coding Plan and Kimi Code.
(Formerly UsageBar; the bundle id is still `local.usagebar` so settings carry over.)

```bash
./build.sh            # build into build/UsageBar.app
./build.sh install    # replace /Applications/Meter.app and relaunch
/Applications/Meter.app/Contents/MacOS/Meter --check   # fetch everything once, print results
swift Tools/make-icon.swift titanium Resources/AppIcon.icns   # regenerate the app icon (styles: flat, aluminum, titanium, glass, obsidian; `sheet out.png` compares them)
```

## Where the data comes from

| Provider | Credentials | Usage endpoint |
|---|---|---|
| Claude | Claude Code's keychain item `Claude Code-credentials` (or `~/.claude/.credentials.json`) | `api.anthropic.com/api/oauth/usage` |
| Codex | `~/.codex/auth.json` (`$CODEX_HOME`) | `chatgpt.com/backend-api/wham/usage` |
| GLM Coding | API key in `~/Library/Application Support/Meter/accounts.json` (`zcoder`) | `open.bigmodel.cn/api/monitor/usage/quota/limit` |
| Kimi Code | API key in the same file (`kimi`) | `api.kimi.com/coding/v1/usages` |

## Why Claude/Codex used to go blank, and what changed

Their OAuth access tokens expire after a few hours, and v1 only *read* them — they were refreshed
only when the `claude` / `codex` CLI happened to run. v2 refreshes them itself (same endpoint,
client id and storage format as the CLIs) and writes the new tokens back, so the CLIs keep working:
the Claude CLI re-reads the keychain under a lock before refreshing and adopts a newer token.

Other robustness bits: last good numbers are cached (`cache.json`) and shown dimmed when stale
instead of disappearing; retries back off on errors / 429; everything refreshes ~8 s after wake;
a rejected refresh token is never retried; when a real re-login is needed the menu offers
"Sign In Again", which opens Terminal with `claude auth login` / `codex login`.

Diagnostics (no secrets): `~/Library/Logs/Meter.log`, or menu › Others › Open Log.

## License

MIT — see [LICENSE](LICENSE). Meter is an independent project and is not affiliated with
Anthropic, OpenAI, Zhipu AI or Moonshot AI; product names and logos belong to their owners.
