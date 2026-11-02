<div align="center">
  <h1>Tidemark</h1>

  <p>A macOS companion that lives at the screen's edge and shows your coding agents' quotas.</p>

  <p>
    <img src="https://img.shields.io/badge/platform-macOS-34C759" alt="macOS app" />
    <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License" />
  </p>

  <p><a href="README.zh-CN.md">简体中文</a></p>
</div>

---

Tidemark rests as a thin glow at the edge of your screen. Hover over it and an animated orb emerges with a summary; linger or click and it opens a panel with the quota left and the reset time for Claude Code and Codex. It reads quota observations those tools already write locally.

Tidemark is in early development. The first implementation includes the native companion, saved edge placement, and passive quota reads from Claude Code's cache (or an existing statusline tap) and Codex session logs. Old observations show their age; stale or expired quotas show as unknown.

Click the orb to pin or unpin the dashboard, and drag it to move. Use **Show Companion** or **Reset Position** in the Tidemark menu to recover it. The orb artwork is provisional. CC Switch history, live quota requests, account management, and custom skins are planned.

## Requirements

- macOS 15 or later

## Building

```sh
make build   # build the app
make run     # build and relaunch
make test    # run engine and data tests
make help    # list all targets
```

## License

MIT. See [LICENSE](LICENSE).
