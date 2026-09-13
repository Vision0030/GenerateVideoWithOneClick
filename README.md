# 一键成片 Demo（GenerateVideoWithOneClick）

选几张照片 / 视频 → 套一个节拍模板 → 自动卡点成片、导出到相册。

## 流程

1. **选择照片 / 视频**：PHPicker 有序多选（图片 + 视频混选，最多 12 个），素材按点选顺序进时间轴
2. **切模板**：顶部 chip 切换模板，BPM / 每段拍数 / 转场拍数 / 运镜全部由模板 JSON 决定
3. **一键成片**：构建时间轴 → AVPlayer 预览（点画面暂停/继续，播完出现重播）
4. **导出并保存到相册**：导出 1080×1920 MP4，自动请求"仅添加"相册权限

## 目录

| 文件 | 职责 |
| --- | --- |
| `GenerateVideoWithOneClick/KBTemplate.*` | 模板 DSL：JSON → 模型（节拍、每段拍数、转场、运镜循环、画幅、BGM） |
| `GenerateVideoWithOneClick/KBAssetLoader.*` | PHPicker 素材导入：图片降采样解码、视频拷贝到沙盒 |
| `GenerateVideoWithOneClick/KBMediaAsset.*` | 统一素材模型：照片（CIImage）/ 视频（本地 URL + 封面） |
| `GenerateVideoWithOneClick/KBTimelineBuilder.*` | 素材 + 模板 → `AVComposition` + `videoComposition` + `audioMix` |
| `GenerateVideoWithOneClick/KBVideoCompositor.*` | 自定义 compositor：Ken Burns 运镜 + 节拍叠化（CoreImage，预览与导出共用） |
| `GenerateVideoWithOneClick/KBExporter.*` | 导出 MP4 + 写入相册 |
| `GenerateVideoWithOneClick/ViewController.m` | 界面与主流程（Masonry 布局） |
| `GenerateVideoWithOneClick/*.json` | 模板：`travel_fast` / `daily_vlog` / `sport_hype` / `story_full` |
| `GenerateVideoWithOneClick/bgm_*.m4a` | 各模板伴奏，BPM 与模板一致（卡点才落在拍上） |
| `scripts/make_bgm.py` | 合成伴奏（纯标准库 + `afconvert` 转 m4a） |
| `scripts/e2e_test.m` | 渲染链路端到端验证 |
| `scripts/run_e2e.sh` | 编译并运行上面的验证（默认跑全部模板） |

## 模板 DSL

```json
{
  "id": "travel_fast",
  "name": "旅行 · 快闪",
  "order": 1,
  "bpm": 128,
  "clip_beats": 3,
  "transition_beats": 0.5,
  "video_mode": "slot",
  "resolution": [1080, 1920],
  "fps": 30,
  "audio": "bgm_travel_128bpm",
  "motions": ["zoom_in", "pan_right", "zoom_out", "pan_left"]
}
```

| 字段 | 说明 |
| --- | --- |
| `id` / `name` / `order` | 标识、展示名、chip 排序 |
| `bpm` | 节拍速度，切镜都对齐到它 |
| `clip_beats` | 每段素材占几拍（3 拍 @128BPM ≈ 1.41s 一切） |
| `transition_beats` | 叠化转场时长（拍），0.5 = 半拍卡点 |
| `video_mode` | 视频素材处理方式：`slot`（默认）裁到节拍槽位；`full` 保持源时长原速完整播放 |
| `resolution` / `fps` | 成片画幅与帧率 |
| `audio` | 伴奏资源名（取 `.m4a`，缺省回退 `.mp3`） |
| `motions` | 运镜循环：`zoom_in` / `zoom_out` / `pan_left` / `pan_right` |

两档视频策略对应的模板：

| 模板 | `video_mode` | 观感 |
| --- | --- | --- |
| `travel_fast` / `daily_vlog` / `sport_hype` | `slot`（默认） | 视频裁到节拍槽位，卡点最紧；源偏短会慢放补齐 |
| `story_full` | `full` | 视频原速完整播完（不裁剪、不变速），槽位长度随素材伸缩 |

`+[KBTemplate templatesInBundle:]` 扫描 bundle 内声明了 `id` / `bpm` / `clip_beats` 的 JSON 并按 `order` 排序，
所以**新增模板 = 往 `GenerateVideoWithOneClick/` 里丢一个 JSON（+ 一条伴奏）**。
工程使用 Xcode 16 的 `fileSystemSynchronizedGroups`，目录内文件自动进 target 资源，无需手改 pbxproj。

## 时间轴模型

- `D = clip_beats × 60 / bpm`：照片段时长；`T = transition_beats × 60 / bpm`：转场时长
- 每段时长 `d[i]`：照片 = `D`；`slot` 模板的视频 = `D`；`full` 模板的视频 = 源时长（源时长异常时退回 `D`）
- `T` 按最短段的一半收敛（`T = min(T, d[i] / 2)`），保证每段都有稳定画面、叠化不盖满整段
- 第 i 段起点 `start[i+1] = start[i] + d[i] − T`，相邻两段尾部叠化 `T` → **照片段的切点仍落在节拍网格上**
- 视频素材：`slot` → 源时长 ≥ 槽位则从头裁剪，源偏短则 `scaleTimeRange` 慢放补齐；
  `full` → 整段源插入 `AVCompositionTrack`（不裁剪、不 `scaleTimeRange`），总时长随素材时长增加
- 成片只保留模板 BGM（循环铺满 + 首尾淡入淡出），视频原声忽略
- carrier 黑帧轨道（270×480@2fps，写进临时目录）：用一条视频轨驱动 AVFoundation
  按 `frameDuration` 逐帧调用自定义 compositor，画面完全由 compositor 决定

## 构建

```bash
pod install                                        # 依赖 Masonry（界面约束 DSL）
open GenerateVideoWithOneClick.xcworkspace         # 之后都用 workspace 打开
```

命令行构建：

```bash
xcodebuild -workspace GenerateVideoWithOneClick.xcworkspace \
           -scheme GenerateVideoWithOneClick -sdk iphonesimulator build
```

界面约束全部写在 `mas_makeConstraints:` 里，例如：

```objc
[self.templateCard mas_makeConstraints:^(MASConstraintMaker *make) {
    make.top.equalTo(self.templateScrollView.mas_bottom).offset(12);
    make.left.right.equalTo(self.contentView);
}];
```

## 验证

```bash
scripts/run_e2e.sh              # 全部模板
scripts/run_e2e.sh travel_fast  # 指定模板
```

脚本用 Mac Catalyst 目标（`-target arm64-apple-ios*-macabi`）把 `scripts/e2e_test.m`
和 App 的引擎源码编成命令行程序。测试素材为 5 张纯色图 + 1 段 0.8s 视频（占第 4 段），
期望值按模板现算（时长表 / 起点表 / 收敛后的 `T`），逐项校验：模板解析、总时长、预览通路、
导出 MP4、分辨率 1080×1920、音视频轨道、节拍点画面切换、转场叠化混合色、
视频处理模式（`slot` 拉伸到槽位 / `full` 保持源时长）、视频封面生成与重复请求、BGM 覆盖全片。

## 待办

- 素材管理：目前只能整体重选，还不能删除单个 / 拖拽排序
- 模板 DSL 的 `beats[]`（离线节拍网格）尚未启用，demo 由 `bpm` 现算
- 转场类型目前固定 dissolve，JSON 里的 `transition.type` 还是占位字段
