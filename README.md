# 📱 DMusic Mobile (Flutter Android App)

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.24%2B-02569B?logo=flutter" alt="Flutter">
  <img src="https://img.shields.io/badge/Dart-3.5%2B-0175C2?logo=dart" alt="Dart">
  <img src="https://img.shields.io/badge/Platform-Android%208.0%2B-green?logo=android" alt="Platform">
  <img src="https://img.shields.io/badge/Architecture-MVVM%20%7C%20Provider-purple" alt="Architecture">
  <img src="https://img.shields.io/badge/License-GPL--3.0-blue?logo=gnu" alt="License">
</p>

**DMusic Mobile** 是一款基于 Flutter 与 Material 3 现代化设计语言打造的高颜值、高性能移动端音乐聚合试听与无损下载应用。支持全网跨平台多源秒级聚合、同名版本聚合折叠、沉浸式同步滚动歌词、本地离线媒体库及后台常驻播放。

---

## ✨ 核心特性

- 🔍 **跨源流式聚合检索**：一键并行聚合检索各大主流音源平台，智能去重，自动优选最高音质规格（FLAC / Hi-Res / 320k）。
- ⚏ **同名异版折叠聚合（方案 A）**：
  - 智能收拢原版、Live 现场版、伴奏、翻唱及 DJ 混音版；
  - **动态提升主卡片**：在折叠列表点击任意子版本试听时，该子版本动态提升为该曲目卡片的主视图进行播放；
  - 折叠后主卡片始终保持当前选中的版本与播放状态；子版本支持独立播放与下载。
- 🌪️ **多维条件联动筛选与排序**：
  - 音源平台标签多选联动；
  - 音质规格快速筛选（无损 / 320k / 标准）；
  - **歌手作者自适应固定记忆**：动态识别当前搜索词的高频歌手。若本次搜索包含上次选中的歌手则继续保持选中固定，若不包含则平滑回退为全部；
  - 歌曲时长筛选与综合排序。
- 🎤 **沉浸式同步滚动歌词**：三级歌词匹配引擎（音源自带 / 本地 LRC / 联网在线智能检索匹配），支持时间轴毫秒级平滑滚动居中高亮，点击歌词行随意快进定位。
- ⚡ **本地已有下载状态感知与秒播通道**：自动比对本地曲库与下载记录，明确标注 `已下载` 状态；试听本地已下载曲目时直接秒开，0 流量消耗且支持原生任意拖拽定位。
- 🎨 **Material 3 磨砂质感界面**：沉浸式底栏迷你播放条、旋转黑胶唱片微动画、手势交互抽屉与桌面小组件支持。
- 🔄 **离线曲库与格式转换**：内置本地媒体库扫描、本地音频转码与歌单解析功能。

---

## 🚀 编译与构建

### 1. 环境要求

- **Flutter SDK**: `>= 3.24.0`
- **Dart SDK**: `>= 3.5.0`
- **Android Studio / Android SDK**: API 34+
- **JDK**: 17+

### 2. 本地开发与调试

```bash
# 1. 进入项目根目录
cd dmusic_app

# 2. 获取 Flutter 依赖包
flutter pub get

# 3. 运行静态代码语法检查
flutter analyze

# 4. 连接真机或模拟器启动调试
flutter run
```

### 3. 打包发布 APK

通过 Flutter 标准命令行构建 Release 安装包：
```bash
flutter build apk --release
```
构建产物将输出在 `build/app/outputs/flutter-apk/app-release.apk`。

---

## 🏗️ 项目架构

```
lib/
├── models/                     # 数据模型层
│   ├── song.dart               # 核心歌曲实体与音质元数据
│   ├── lyric.dart              # 同步时间轴歌词模型
│   ├── playlist.dart           # 歌单实体
│   └── search_preferences.dart # 筛选条件与偏好记忆模型
├── services/                   # 核心业务服务层 (Provider)
│   ├── music_api.dart          # 跨平台音源并发聚合接口
│   ├── player_service.dart     # 音频播放核心控制器 (just_audio / audio_service)
│   ├── download_service.dart   # 后台断点续传下载引擎
│   ├── database_service.dart   # SQLite 本地曲库与历史归档持久化
│   ├── audio_converter_service.dart # 音频转码服务
│   ├── playback_cache_service.dart  # 预加载与离线缓存
│   └── widget_service.dart     # 桌面微件状态联动
├── views/                      # UI 视图与交互组件
│   ├── player_bottom_sheet.dart# 沉浸式大屏播放器与同步歌词页
│   ├── download_sheet.dart     # 下载选项与音质选择底栏
│   ├── converter_tab.dart      # 格式转换中心
│   ├── library_tab.dart        # 本地媒体库视图
│   ├── playlist_dialogs.dart   # 歌单创建与导入弹窗
│   └── song_options_sheet.dart # 歌曲快捷操作菜单
└── main.dart                   # 应用主入口与全局主题配置
```

---

## 📄 开源许可证

本项目基于 [GNU General Public License v3.0 (GPL-3.0)](LICENSE) 协议开源。
仅供个人学习研究与 Flutter 跨平台音频技术交流使用。
