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
