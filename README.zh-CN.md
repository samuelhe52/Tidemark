<div align="center">
  <h1>Tidemark</h1>

  <p>栖息在屏幕边缘、显示编程智能体额度的macOS伴侣。</p>

  <p>
    <img src="https://img.shields.io/badge/platform-macOS-34C759" alt="macOS app" />
    <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License" />
  </p>

  <p><a href="README.md">English</a></p>
</div>

---

Tidemark平时只是屏幕边缘的一道微光。鼠标悬停时，一个带动画的球体浮现并显示摘要；停留片刻或点击，就会展开面板，显示Claude Code和Codex的剩余额度与重置时间。它读取这些工具已经写在本地的额度记录。

Tidemark仍在早期开发中。首个实现包含原生伴侣窗口、保存屏幕边缘位置，以及从Claude Code缓存（或已有的状态栏采集文件）和Codex会话日志被动读取额度。旧记录会显示采集时间；过期或陈旧的额度显示为未知。

点击球体可固定或取消固定面板，拖动球体可移动位置。可通过Tidemark菜单中的 **Show Companion** 或 **Reset Position** 找回伴侣。球体外观为临时版本；CC Switch历史用量、实时额度请求、多账户管理和自定义皮肤尚待实现。

## 系统要求

- macOS 15或更高版本

## 构建

```sh
make build   # 构建应用
make run     # 构建并重新启动
make test    # 运行引擎和数据测试
make help    # 列出所有目标
```

## 许可证

MIT，详见[LICENSE](LICENSE)。
