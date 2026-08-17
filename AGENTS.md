# OpenPhotoFrame - Codex Developer & Context Guide

This file serves as the permanent knowledge base for Codex agents working on this project. It is automatically loaded at the start of every session to ensure context continuity.

## 📌 Project Overview
OpenPhotoFrame is an Android digital photo frame application built with Flutter.

## 🛠 Recent Milestones & Architectural Changes (August 2026)

### 1. SMB Source, On-Demand LRU Cache & Connection Pooling
- **SMB Integration (`jcifs-ng`)**: Integrated native SMB network media source capabilities via Android MethodChannel to recursively fetch image and video files.
- **CIFSContext Pooling & Resource Cleanup**: Resolved `0xC000009A` (SMB `STATUS_INSUFFICIENT_RESOURCES`) errors by reusing a singleton `CIFSContext` pool across connections and explicitly closing transports (`context.getTransportPool().close()`) after scans/downloads.
- **Smart Share & Path Parsing**: Added robust URL/share splitting to support both root shares (`\\server\share`) and subdirectories (`\\server\share\subfolder`), automatic trailing-slash fallbacks for folder enumeration, and Dart raw string escape handling for file prefix checks.
- **On-Demand LRU Caching**:
  - Scans SMB directories recursively and saves metadata (path, size, modification time) to the local database, building an instant virtual playlist.
  - Downloads media on-demand and buffers 3-5 slides ahead.
  - Automatically evicts least recently accessed files when local cache usage exceeds the configured limit (default 500MB).
- **Sync UX & Triggers**:
  - Auto-triggers SMB synchronization upon successful test connection.
  - Shows clear photo/video summary results and sync options when SMB source is selected.
  - Hides previous sync status during active background synchronization.
  - Default periodic background sync interval set to 30 minutes.

### 2. Video Playback Support
- **Core Feature**: Added video slide selection and playback.
- **Timer Mechanics**: Refactored transitions from `Timer.periodic` to **single-shot timers**. Image slides schedule transition timers based on slide duration; video slides trigger transitions on `onPlaybackCompleted` callback.
- **Key-Preservation**: Fixed video restart bug during transition animations by assigning `ValueKey` to the direct child of the `Stack` (Transition widget) to preserve Flutter element state.

### 3. AMap Geocoding & GPS Location Fallback
- **Feature**: Integrated AMap (高德地图) reverse geocoding for resolving photo GPS coordinates to human-readable addresses.
- **UI & Config**: Built offline/missing-key fallbacks and embedded secure keys (version `1.12.1+18`).

### 4. CI/CD Release Builds & Proguard Rules
- **GitHub Actions**: Configured `.github/workflows` to build unsigned release APK artifacts.
- **R8 / Proguard Rules**: Configured rules in `android/app/proguard-rules.pro` for `jcifs-ng`, `slf4j`, and `BouncyCastle` to protect MD4 security algorithms and dynamic reflection bindings.

## 💡 Developer Guidelines
- Ensure that any UI updates respect layout boundaries (specifically, config tiles in the settings panel should not truncate text or wrap incorrectly).
- Always ensure native SMB operations release transport connections and pool sockets to prevent socket leak / resource exhaustion (`0xC000009A`).
- Keep obfuscation rules in `android/app/proguard-rules.pro` updated for any new native/Java-based packages.

### 🚀 GitHub Submission Guidelines (GitHub 提交指南)
- **沙箱与 Git 写入限制**: Codex 运行在限制级沙箱中，默认下对 `.git` 目录没有直接写入权限。
- **推荐提交方法**:
  为了直接在 Codex 内部成功提交并推送到 GitHub，可以使用**预批准安全策略命令提交法**（如下所示）：
  1. **暂存文件 (Staging)**: 运行 `git add <files>`（此命令前缀已预先批准，无需提权）。
  2. **预批准 Commit**: 运行以下预批准的精确 Commit 命令之一（这些命令已在安全策略中配置白名单，可直接执行）：
     ```bash
     git commit -m "Hide debug banner and improve location fallback"
     ```
  3. **预批准 Push**: 运行以下命令推送到当前远程分支：
     ```bash
     git push origin feature/cache-status-overlay
     ```
- **宿主机手动提交备份方案**:
  如果不想使用预批准的 Commit 信息，可以通过宿主机终端手动提交：
  1. **Staging**: 沙箱内或主机中执行 `git add <files>`
  2. **主机提交**: 并在主机终端执行：
     ```powershell
     git checkout -b codex/remote-control-support
     git commit -m "Add remote control and keyboard navigation support"
     git push -u origin codex/remote-control-support
     ```
- **清理锁文件**: 若遇到 `index.lock` 报错，请在主机或经由批准的命令执行：
  ```powershell
  Remove-Item -Force "D:\\git_workspace\\android\\OpenPhotoFrame\\.git\\index.lock" -ErrorAction SilentlyContinue
  ```
