# TRClick

个人自用的 macOS Finder 右键菜单扩展，通过菜单栏应用管理配置。

[下载最新版本](https://github.com/tfcup/TRClick/releases/latest) · [反馈问题](https://github.com/tfcup/TRClick/issues)

## 功能

- 用指定应用打开文件或文件夹，支持应用预设、自定义启动参数和环境变量。
- 分别控制应用在 Finder 工具栏菜单、右键菜单中的可见性。
- 复制绝对路径或文件名。
- 彻底删除文件或文件夹：默认确认，按住 Option 打开菜单可跳过确认。
- 新建 TXT、Markdown、JSON、DOCX、PPTX、XLSX、Pages、Keynote、Numbers 文件。
- 添加自定义文件类型、模板和默认打开应用。
- 调整菜单顺序、分类折叠和应用图标样式。
- 开机启动、手动检查更新，支持中、英、日、西、法五种语言。

## 环境要求

- macOS 15.6 或更新版本。
- GitHub Releases 中的安装包面向 Apple Silicon（arm64）。
- 源码构建需要 Xcode 26 或更新版本，支持 Swift 6.2。

## 安装与首次使用

1. 从本仓库的 Releases 下载 DMG，将 `TRClick.app` 拖入 `/Applications`。
2. 打开应用，在「系统设置 → 通用 → 登录项与扩展」中启用 TRClick Finder 扩展；具体条目名称随 macOS 版本变化，可通过应用「通用」页的按钮进入。
3. 在设置中添加需要的应用、文件类型，并调整菜单显示方式。

自用安装包采用 ad-hoc 签名。若 macOS 因隔离属性阻止启动，确认安装包来自本仓库后，可执行：

```bash
xattr -cr /Applications/TRClick.app
```

应用默认作为菜单栏程序运行。打开设置窗口时显示 Dock 图标，关闭窗口后隐藏；最小化或切换应用时保留图标。关闭设置窗口不会退出程序，退出操作位于菜单栏菜单中。

## 权限与文件操作

- 主应用不启用 App Sandbox；桌面、文稿等受保护位置仍受 macOS 系统权限控制。
- Finder 扩展必须在系统设置中启用。
- 新建文件后自动选中并重命名需要辅助功能权限；未授权时文件仍会创建。
- 「彻底删除」绕过废纸篓，请在确认对话框中核对目标。
- 开机启动需要将应用安装到 `/Applications`。

## 模板与配置

内置 Office 和 iWork 文件类型使用随应用提供的有效模板。自定义模板会复制到应用的数据目录；可以在「新建文件」设置中更换或清除自定义模板。

| 数据 | 位置 |
|---|---|
| 配置数据库 | `~/Library/Application Support/TRClick/TRClickDatabase.sqlite` |
| 自定义模板 | `~/Library/Application Support/TRClick/Templates/` |
| 界面偏好 | `UserDefaults.standard`，应用标识为 `com.tfcup.TRClick` |

## 更新

在「关于」页点击「检查更新」。应用从最新正式版的 `update.json` 附件读取版本信息，不依赖匿名 GitHub REST API 的发布查询额度。

更新时下载完整的 `.app.zip`，解压并校验应用包后，整体替换 `/Applications/TRClick.app`。配置数据库和自定义模板保存在应用包之外，升级会保留这些数据。安装完成后需要重启应用。

检查失败时可打开发布页面手动下载；旧版本若无法检查更新，也可以直接安装本仓库的新版本。

发布新版本时推送 `v*` 标签，GitHub Actions 会构建、签名并生成 DMG、应用 ZIP、校验和及更新清单，附件准备完成后再公开发布。

## 源码构建

```bash
git clone https://github.com/tfcup/TRClick.git
cd TRClick
open TRClick.xcodeproj
```

选择 `TRClick` scheme。命令行构建可使用：

```bash
xcodebuild build \
  -project TRClick.xcodeproj \
  -scheme TRClick \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO
```

上面的命令仅编译，不执行发布流程中的 ad-hoc 签名。直接运行或安装构建产物时，需要完成本地签名及扩展注册。

本地化检查：

```bash
python3 scripts/check-localization.py --languages en zh-Hans ja es fr
```

## 许可

本仓库包含修改后的版本，整理日期为 2026-11-13，按 [GPL-3.0](LICENSE) 发布。

iWork 模板的来源及许可见 [第三方模板许可](TRClick/Resources/iWorkTemplates-LICENSE.txt)。
