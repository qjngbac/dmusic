# DMusic Mobile

<p align="center">
  <img src="https://img.shields.io/badge/Release-v1.2.23-blue?logo=android" alt="Release">
  <img src="https://img.shields.io/badge/Flutter-3.44%2B-02569B?logo=flutter" alt="Flutter">
  <img src="https://img.shields.io/badge/Dart-3.12.2%2B-0175C2?logo=dart" alt="Dart">
  <img src="https://img.shields.io/badge/Platform-Android%208.0%2B-green?logo=android" alt="Platform">
  <img src="https://img.shields.io/badge/Architecture-ARM64%20(arm64--v8a)-teal" alt="Architecture">
  <img src="https://img.shields.io/badge/Size-~19.0MiB-orange" alt="Size">
  <img src="https://img.shields.io/badge/License-GPL--3.0-blue?logo=gnu" alt="License">
</p>

DMusic Mobile 是一款基于 Flutter 的 Android 音乐聚合试听与无损下载应用。支持多源聚合检索、同名版本折叠、同步滚动歌词、自建歌单拖拽排序、4x2 黑胶桌面小组件、本地媒体库、后台播放以及系统媒体控制。

当前版本：**1.2.23+39**（versionName 1.2.23，versionCode 39），仅提供 **ARM64** 安装包。

## 下载与安装

安装包通过 GitHub Releases 发布，不放入源码仓库：

- Releases：<https://github.com/qjngbac/dmusic/releases>
- 文件名：`dmusic-v1.2.23.apk`
- 适用架构：`arm64-v8a`（Android 8.0 及以上）

```bash
adb install -r dmusic-v1.2.23.apk
```

同一签名版本可直接覆盖安装并保留本地数据；从其他签名版本切换时需要先卸载。

## 核心特性

- **多源聚合检索**：并行检索多个公开音源，去重并优先选择可用音质。
- **同名异版折叠**：原版、Live、伴奏、翻唱等版本聚合展示，支持单独试听与下载。
- **筛选与排序**：音源平台、音质、歌手、时长等条件组合筛选。
- **同步滚动歌词**：音源自带歌词、本地 LRC 与联网检索三级匹配，支持点击歌词跳转。
- **本地曲库与下载**：SQLite 管理本地歌曲、自建歌单和下载记录，支持断点续传与音频完整性检测。
- **歌单管理**：长按拖拽排序、置顶、规则排序，以及歌单顺序连播。
- **后台播放与系统媒体中心**：基于 `audio_service` 管理播放引擎与 MediaSession，通知栏、锁屏和蓝牙控制与播放器状态一致。
- **4x2 黑胶桌面小组件**：播放/暂停、切歌、播放模式、收藏、进度显示与点击打开播放器。

## 技术栈

- Flutter / Dart，Material 3
- `audioplayers`：音频解码与播放
- `audio_service`：后台音频服务、MediaSession 与系统媒体控制
- `sqflite`：本地曲库、歌单与偏好持久化
- Kotlin：原生媒体会话观察、桌面小组件、音频焦点与 FlutterEngine 桥接
- 本地插件 `packages/dmusic_runtime_bridge`：在有界面与无界面引擎中安装原生桥接

## 编译与构建

### 环境要求

- Flutter SDK：`>= 3.44.0`（当前使用 3.44.9）
- Dart SDK：`>= 3.12.2`（与 `pubspec.yaml` 一致）
- Android SDK：compileSdk 36，最低运行 Android 8.0（API 24）
- JDK：17+
- 目标安装架构：`arm64-v8a`

### 本地运行

```bash
flutter pub get
flutter analyze
flutter run
```

### 构建 Release APK

仅构建 ARM64，避免默认全架构导致体积明显增大：

```bash
flutter build apk --release --target-platform android-arm64
```

产物路径：

```text
build/app/outputs/flutter-apk/app-release.apk
```

### 测试

Flutter 针对性测试：

```bash
flutter test test/widget_service_test.dart test/background_audio_handler_test.dart
```

Android 原生测试：

```bash
cd android
./gradlew :app:testDebugUnitTest -Ptarget-platform=android-arm64
```

## 项目结构

```text
lib/
├── models/                         # 歌曲、歌词、歌单、筛选偏好
├── services/
│   ├── music_api.dart              # 多源聚合检索
│   ├── player_service.dart         # 播放、队列、断点与状态管理
│   ├── background_audio_handler.dart # audio_service 与 MediaSession 适配
│   ├── widget_service.dart         # 桌面小组件与原生通道桥接
│   ├── download_service.dart       # 下载、校验与断点续传
│   ├── playback_cache_service.dart # 预加载与缓存
│   ├── audio_converter_service.dart# 音频转码
│   └── database_service.dart       # SQLite 持久化
├── views/                          # 播放器、搜索、曲库、下载、转换等界面
└── main.dart                       # 应用入口与主题

android/app/src/main/kotlin/com/dmusic/app/dmusic_app/
├── MainActivity.kt                 # 共享引擎的界面入口
├── DMusicApplication.kt            # 安装原生桥接插件工厂
├── DMusicEngineBridge.kt           # FlutterEngine 与原生通道
├── DMusicMediaSessionObserver.kt   # MediaSession 观察与小组件状态
├── DMusicAudioFocusManager.kt      # 音频焦点与耳机拔出
├── DMusicWidgetPlaybackState.kt    # 组件状态、租约与系统核验
├── WidgetPlaybackLease.kt          # 进程/会话/心跳有效期
└── DMusicAppWidgetProvider.kt      # 4x2 桌面小组件

packages/dmusic_runtime_bridge/      # 本地 Flutter 插件：引擎级原生桥接
```

## 数据与隐私

- 应用不需要账号，不包含广告 SDK 或统计 SDK。
- 歌曲、歌单、播放进度、下载记录和设置保存在本机；卸载应用会清除这些数据。
- 检索、试听、下载和歌词匹配会访问第三方公开网络接口，具体可用性取决于对应服务。
- 本项目不会上传用户的本地媒体文件。

## 已知限制

- 第三方音源可能失效、限流或变更接口，应用会在可用源之间尝试切换，但不能保证所有歌曲始终可播放。
- 部分定制 Android 系统对后台服务、任务清理和桌面组件的限制较严格，小组件复位时间可能受系统调度影响。
- 本项目为个人学习与技术交流项目，未针对所有机型、所有 ROM 做完整兼容性验证。

## 许可证

本项目基于 [GNU General Public License v3.0](LICENSE) 开源。

音乐、封面、歌词等内容的版权归原作者及对应平台所有。本项目仅供个人学习研究与技术交流，请勿用于商业用途或侵犯他人权益的场景。
