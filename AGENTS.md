# OpenPhotoFrame - Codex Developer & Context Guide

This file serves as the permanent knowledge base for Codex agents working on this project. It is automatically loaded at the start of every session to ensure context continuity.

## 📌 Project Overview
OpenPhotoFrame is an Android digital photo frame application built with Flutter.

## 🛠 Recent Milestones & Architectural Changes (July 2026)

### 1. Video Playback Support
- **Core Feature**: Added video slide selection and playback.
- **Timer Mechanics**: Slide transitions originally used a periodic timer (`Timer.periodic`) which cut off videos prematurely. This was refactored to use **single-shot timers**. 
  - For image slides, a new timer is scheduled for the slide duration.
  - For video slides, no timer is created; instead, slide transition is triggered via the `onPlaybackCompleted` callback of the `VideoSlide` widget.
- **Key-Preservation**: Fixed a video restart bug during transition animations by moving the `ValueKey` from the inner `VideoSlide` to the **direct child of the Stack** (the Transition widget), preventing Flutter element state loss.

### 2. AMap Geocoding & GPS Location Fallback
- **Feature**: Integrated AMap (高德地图) reverse geocoding to resolve photo GPS coordinates into human-readable locations.
- **UI & Config**: Handled geocoding fallback when offline or when key is missing. Removed API key inputs from the settings screen in favor of secure built-in keys. Bumped version to `1.12.1+18` (Commit: `b27d33d`).

### 3. CI/CD Release Builds
- **GitHub Actions**: Configured `.github/workflows` to build and upload unsigned release APKs as artifacts. This allows running highly optimized, obfuscated production builds on actual hardware without manual signing (Commit: `1d23b1b`).

### 4. SMB Source & On-Demand LRU Cache
- **Feature**: Integrated SMB network media source using `jcifs-ng` to recursively fetch images and videos.
- **Caching Mechanism**: Implemented **LRU (Least Recently Used) On-Demand Cache** with a customizable cap (default 500MB). 
  - On synchronization, the app recursively scans directories on the SMB server and stores file metadata (path, size, modification time) in the local database, creating a virtual playlist instantly.
  - Media files are downloaded on-demand and buffered 3-5 slides ahead.
  - If downloading causes the cache folder to exceed the limit, the oldest or least-recently-accessed files are deleted.
- **R8 / Proguard Rules**: Configured Proguard rules for `jcifs-ng`, `slf4j`, and `BouncyCastle` to prevent R8 from stripping the MD4 security algorithm and dynamic reflection bindings during release builds.

## 💡 Developer Guidelines
- Ensure that any UI updates respect layout boundaries (specifically, config tiles in the settings panel should not truncate text or wrap incorrectly).
- Keep obfuscation rules in `android/app/proguard-rules.pro` updated for any new native/Java-based packages.
