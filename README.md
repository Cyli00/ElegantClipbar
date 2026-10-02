# ElegantClipbar

[English](README_EN.md) | 中文

用于 macOS 的菜单栏剪贴板工具。界面和窗口交互参照 ClashBar：360 pt 宽的原生面板固定在菜单栏图标下方，外观跟随系统明暗模式。

应用使用 Swift、SwiftUI 和少量 AppKit，数据保存在本机。支持 macOS 13 及以上、Apple Silicon 和 Intel；Swift 包远程依赖为 **0**。

## 日常使用

- 按 **⌥⌘V（Option + Command + V）**，或点击菜单栏图标，打开剪贴板历史。
- 搜索、预览和置顶常用内容。支持文本、链接、HTML/RTF 富文本、图片及文件。
- 点击记录或按回车，关闭面板并返回原应用粘贴。自动粘贴需要在「系统设置 → 隐私与安全性 → 辅助功能」中授权；未授权时仍会复制到系统剪贴板，可自行按 ⌘V。
- 文件只保存路径。原文件移动或删除后，记录会提示文件不可用。
- 内容及格式完全相同的记录会去重并移到最新位置；文字相同、格式不同的记录分别保留。

普通历史默认最多保留 **1,000 条、30 天**，超过任一限制就清理；可在设置中调整。置顶记录不参与自动清理。

设置包括开机启动、来源应用识别、排除指定应用、本地备份导入导出，以及「记录成功」和「执行粘贴」两个独立音效开关。两个音效默认关闭，支持试听。

Swift 版从空历史开始，备份仅适用于新的原生数据格式。翻译、WebDAV 同步、自定义主题、分组、独立收藏和工具栏定制不在本次原生版本范围内。仓库已迁移为原生工程，旧版实现可从 Git 历史查阅。

## 构建与运行

需要 macOS 和 Swift 6.0 或更新版本的 Xcode 工具链。应用最低运行版本为 macOS 13。

```sh
make check       # 编译检查
make test        # 运行 Swift 测试
make build       # 为当前 Mac 构建 release 应用
make universal   # 构建 Apple Silicon + Intel 通用应用
make run         # 构建并打开 debug 应用
```

测试使用 Swift Testing：`make test` 执行 `swift test --disable-xctest --enable-swift-testing`，可直接使用 Xcode Command Line Tools 运行。

构建产物：

| 命令 | 输出 |
| --- | --- |
| `make build` / `make run` | `build/ElegantClipbar.app` |
| `make universal` | `build/universal/ElegantClipbar.app` |

构建脚本使用临时签名（ad-hoc），适合本地运行。分发给其他 Mac 前还需要开发者签名和公证。重复打包会把旧 `.app` 移到系统临时目录，并输出可恢复的路径。

版本号默认 `0.1.0`，可在打包时设置：

```sh
APP_VERSION=0.1.0 BUILD_NUMBER=1 ./scripts/package-app.sh --universal
```

GitHub Actions 的 CI 执行编译、测试和双架构打包。推送与 `Resources/Info.plist` 版本一致的 `v*` 标签（例如 `v0.1.0`）会自动运行 `Build macOS release`：测试、双架构打包、验证签名，再创建 GitHub Release，附上通用 `.app` 的 ZIP 和 SHA-256 校验文件。也可对已有版本标签手动运行工作流。

## 项目结构

- `Sources/ElegantClipbar/`：Swift 应用、SwiftUI 界面及系统交互。
- `Sources/CSQLite/`：macOS 自带 SQLite 的模块声明。
- `Tests/ElegantClipbarTests/`：原生数据与行为测试。
- `Resources/Info.plist`：应用身份和 macOS 最低版本。
- `scripts/package-app.sh`：编译、组装并签名 `.app`。

[MIT License](LICENSE)
