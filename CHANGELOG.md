# Changelog

TRClick 的版本记录。项目 fork 自 [wflixu/RClick](https://github.com/wflixu/RClick)（GPL-3.0）。

## [0.1.0] - 2026-11-11

首个自用版本。

### 功能

- Finder 右键新建 TXT / Markdown / JSON / DOCX / PPTX / XLSX / Pages / Keynote / Numbers，支持自定义类型
- 复制绝对路径、复制文件名
- 用指定 App 打开选中的文件或文件夹，应用列表可手动添加
- 彻底删除（绕过废纸篓，默认带确认，按住 Option 跳过）
- 基于 GitHub Releases 的自动更新

### 架构

- 移除 App Group 与主 App 沙盒，改用 ad-hoc 签名，无需 Apple 开发者账号
- 数据存放于 `~/Library/Application Support/TRClick/`
- Finder 扩展保持沙盒，只负责菜单渲染与事件转发；配置经 IPC 传递

### 移除

- 常用目录、AirDrop、隐藏 / 取消隐藏、书签权限体系
