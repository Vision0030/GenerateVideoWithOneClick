# 一键成片（GenerateVideoWithOneClick）技术文档

> 阅读对象：接手本工程的 iOS 开发 / 需要改模板或改渲染策略的同学
> 代码基线：`main` 分支首个提交 `7745148`（43 个文件 / 约 3.5k 行）
> 平台：iOS 16.0+（Deployment Target 16.0），Objective-C + Masonry

---

## 1. 项目概览

### 1.1 一句话定位

**选一堆照片 / 视频 → 套一个「节拍模板」→ 自动卡点成片，导出 1080×1920 MP4 存进相册。**

工程是一个"模板驱动"的短视频生成 Demo：模板（纯 JSON）决定节奏（BPM）、每段素材占几拍、转场多长、运镜怎么走、配哪首歌；引擎负责把这些规则翻译成 `AVComposition` 时间轴，用一个自定义 compositor 逐帧画出来，预览和导出共用同一条渲染链路（所见即所得）。

### 1.2 功能清单

| 能力 | 实现 |
| --- | --- |
| 素材导入 | PHPicker 有序多选（照片 + 视频混选，上限 12 个），照片降采样解码，视频拷贝到沙盒 |
| 素材排序 | 缩略图条长按拖动调整顺序（UIKit drag & drop），顺序即时间轴顺序，改动后旧成片自动作废 |
| 模板切换 | 顶部横向 chip 列表，模板来自 bundle 内所有合法模板 JSON，按 `order` 排序 |
| 一键成片 | 素材 + 模板 → `AVComposition` + `AVVideoComposition` + `AVAudioMix` |
| 预览 | `AVPlayer` + 自定义合成器；点画面暂停 / 继续，播完显示「重播」 |
| 导出 | `AVAssetExportSession` → H.264 MP4（1080×1920）→ `PHPhotoLibrary`（仅添加权限）保存 |
| 转场 | 节拍对齐的叠化（dissolve），时长按模板 `transition_beats` 决定 |
| 运镜 | Ken Burns：`zoom_in` / `zoom_out` / `pan_left` / `pan_right`，按段循环 |
| 视频处理 | 两档策略：`slot`（裁到节拍槽位，源偏短慢放补齐）/ `full`（原速完整播放） |
| 测试 | `scripts/run_e2e.sh`：Mac Catalyst 编译命令行程序，端到端校验渲染链路 |

### 1.3 技术栈

| 项 | 说明 |
| --- | --- |
| 语言 | Objective-C（ARC），无 Swift |
| UI | UIKit + Masonry 1.1.0（链式 Auto Layout DSL） |
| 媒体 | AVFoundation（AVComposition / AVVideoComposition / AVAssetExportSession）、CoreImage、CoreVideo |
| 相册 | Photos（`PHAccessLevelAddOnly`）、PhotosUI（PHPicker） |
| 资源 | 模板 JSON + `bgm_*.m4a` 伴奏（脚本生成，见 5.5） |
| 工程 | Xcode 16 的 `fileSystemSynchronizedGroups`：目录内文件自动进 target，新增模板不用改 pbxproj |

### 1.4 代码规模

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `ViewController.m` | 641 | 界面 + 主流程（Masonry 布局） |
| `KBTimelineBuilder.m` | 376 | 素材 + 模板 → 时间轴（核心） |
| `KBVideoCompositor.m` | 261 | 自定义 compositor：运镜 + 叠化 |
| `KBAssetLoader.m` | 142 | PHPicker 导入 |
| `KBTemplate.m` | 131 | 模板 DSL 解析 |
| `KBExporter.m` | 98 | 导出 MP4 + 存相册 |
| `KBMediaAsset.m` | 95 | 统一素材模型 |
| `scripts/e2e_test.m` | 408 | 端到端验证用例 |
| `scripts/make_bgm.py` | 173 | 伴奏合成 |

---

## 2. 目录与文件清单

```
GenerateVideoWithOneClick/
├─ GenerateVideoWithOneClick.xcodeproj        # 工程（含 fileSystemSynchronizedGroups）
├─ GenerateVideoWithOneClick.xcworkspace     # 用这个打开（CocoaPods）
├─ Podfile / Podfile.lock                     # Masonry ~> 1.1，platform :ios, '16.0'
├─ .gitignore                                 # 忽略 Pods/ build/ xcuserdata/ .DS_Store 等
├─ README.md                                  # 快速上手
├─ docs/TECHNICAL.md                          # 本文档
├─ GenerateVideoWithOneClick/
│  ├─ AppDelegate.h/.m  SceneDelegate.h/.m  main.m      # 标准 Scene 生命周期（基本为空实现）
│  ├─ ViewController.h/.m                     # 界面 + 主流程
│  ├─ KBTemplate.h/.m                         # 模板 DSL（JSON → 模型）
│  ├─ KBMediaAsset.h/.m                       # 素材模型（照片 / 视频 + 封面）
│  ├─ KBAssetLoader.h/.m                      # PHPicker 导入
│  ├─ KBTimelineBuilder.h/.m                  # 时间轴构建（引擎核心）
│  ├─ KBVideoCompositor.h/.m                  # 自定义合成器（引擎核心）
│  ├─ KBExporter.h/.m                         # 导出 + 存相册
│  ├─ travel_fast.json / daily_vlog.json / sport_hype.json / story_full.json
│  ├─ bgm_travel_128bpm.m4a / bgm_daily_90bpm.m4a / bgm_sport_150bpm.m4a / bgm_story_96bpm.m4a
│  ├─ Assets.xcassets / Base.lproj / Info.plist
└─ scripts/
   ├─ e2e_test.m      # 渲染链路端到端验证（Mac Catalyst 命令行程序）
   ├─ run_e2e.sh      # 编译 + 跑验证（默认跑全部模板）
   └─ make_bgm.py     # 生成卡点伴奏（纯标准库 + afconvert）
```

---

## 3. 总体架构

### 3.1 分层

```
┌──────────────────────────────────────────────────────────────────────┐
│ 界面层  ViewController（Masonry 布局 / 状态机 / 播放器）              │
└───────────────┬──────────────────────────────────────────────────────┘
                │  用户动作：选素材 / 切模板 / 一键成片 / 导出
┌───────────────▼──────────────────────────────────────────────────────┐
│ 领域层                                                               │
│   KBAssetLoader ──► KBMediaAsset（照片: CIImage / 视频: 本地 URL）    │
│   KBTemplate    ──► 模板参数（BPM / 拍数 / 转场 / 运镜 / video_mode） │
└───────────────┬──────────────────────────────────────────────────────┘
                │  素材数组 + 模板 + BGM URL
┌───────────────▼──────────────────────────────────────────────────────┐
│ 渲染引擎层                                                           │
│   KBTimelineBuilder ──► KBTimeline{ composition, videoComposition,   │
│                                     audioMix, duration }             │
│   KBVideoCompositor ◄── 被 AVFoundation 逐帧调用（预览/导出同一份）   │
│   KBExporter        ──► MP4 文件 + 相册                              │
└───────────────┬──────────────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────────────┐
│ 系统框架  AVFoundation / CoreImage / CoreVideo / Photos / PhotosUI    │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.2 数据流（从选素材到存相册）

```
① 用户点「选择照片 / 视频」
   PHPickerViewController（ordered 多选，filter = images + videos）
        │  PHPickerResult[]
        ▼
   KBAssetLoader.loadMediaFromResults:  ← 并发加载 + 锁保护 + 按下标收敛
        │  NSArray<KBMediaAsset *>（顺序 = 用户点选顺序）
        ▼
   ViewController: 刷新缩略图条 → invalidateTimeline（旧成片作废）

② 用户点「一键成片」
   KBTemplate（当前 chip） + mediaAssets + bgmURL
        ▼
   KBTimelineBuilder（串行队列 com.oneclick.timeline.build）
        ├─ 并发预加载：BGM 音轨 + 每个视频的画面轨（dispatch_group 等待）
        ├─ 排版：durations[] / starts[] / total / T
        ├─ 写 carrier 黑帧视频（270×480@2fps）
        ├─ AVMutableComposition：carrier 轨 + 每视频一条轨 + BGM 循环轨
        └─ AVMutableVideoComposition：一条自定义指令，携带 KBClipSpec[]
        ▼
   KBTimeline  ──► AVPlayerItem（预览，主线程）
               └─► KBExporter（导出：AVAssetExportSession + videoComposition + audioMix）
                        ▼
                   MP4（NSTemporaryDirectory）──► PHPhotoLibrary 保存
```

### 3.3 线程模型

| 队列 | 用途 | 注意 |
| --- | --- | --- |
| **主队列** | 所有 UI；`KBAssetLoader` 的 completion；`KBExporter` 的 progress；缩略图回调 | 渲染链路里唯一的出口都回到主队列 |
| `com.oneclick.timeline.build`（串行） | `KBTimelineBuilder` 的全部工作 | 里面会 `dispatch_group_wait` **阻塞**当前线程，所以绝不能放在主线程调用；`buildTimelineAsyncWithAssets:` 负责派发 |
| `com.oneclick.compositor.render`（串行） | 自定义 compositor 的逐帧渲染 | `renderContextChanged:` 会 `dispatch_sync` 到这条队列上写 `renderContext`；`cancelAllAsyncVideoCompositionRequests` 也 `dispatch_sync` 排空，保证没有 in-flight 的回调 |
| AVFoundation 内部队列 | `loadTracksWithMediaType:` 等异步回调 | 回调里写共享状态一律加锁（见 6.1 / 9.3） |

### 3.4 关键设计取舍

1. **为什么不直接用 `AVMutableVideoCompositionInstruction` 做转场？**
   官方指令的转场是「前段 → 后段」的固定形态，很难同时表达"每段不同运镜 + 节拍叠化 + 视频/照片混排"。所以本工程只用一条**自定义指令**承载全部渲染配置（`clips[]`），把时间轴解释权完全交给自己的 compositor，预览与导出的画面必然一致。
2. **为什么要写一条 carrier 黑帧视频？**
   `AVVideoComposition` 的帧节奏由"视频轨"驱动。合成里如果只有照片（没有视频轨），AVFoundation 没有帧源就不会按 `frameDuration` 逐帧回调 compositor。所以引擎固定写一条低成本的 270×480@2fps 黑帧 H.264（画面完全不被使用）当"时间基准"，照片与视频的渲染结果全部由 compositor 输出。
3. **为什么视频素材一条轨一个 track？**
   视频片段要和照片叠化、要按自己的 `preferredTransform` 旋转、还要支持"原速完整播放"，把它们各自放进独立 composition track 再交给 compositor 取帧，比在一条轨上做多段裁剪 + `scaleTimeRange` 更容易控制，也天然支持段与段重叠 T。
4. **为什么模板是 JSON 而不是代码？**
   模板是"时间轴结构 + 节拍 + 运镜 + 音乐"的纯数据描述，产品侧可以下发生成，工程侧零改动（`templatesInBundle:` 扫描 bundle 内所有合法 JSON）。

---

## 4. 数据模型

### 4.1 KBMediaAsset（`KBMediaAsset.h`）

统一素材模型，照片与视频在时间轴上混排时统一消费。

| 属性 | 照片 | 视频 |
| --- | --- | --- |
| `type` | `KBMediaTypePhoto` | `KBMediaTypeVideo` |
| `image` | 解码后的 `CIImage`（方向已烘焙） | `nil` |
| `videoURL` | `nil` | 沙盒里的本地副本 URL |
| `asset` | `nil` | 懒加载 `AVURLAsset` |
| `thumbnail` | 同步生成的小图 | 异步出图，见下 |

要点：

- **照片解码**（`KBMediaAsset.m:28`）：先用 `CGImageSourceCreateThumbnailAtIndex` 取一张最长边 2400 的图当渲染源（避免直接吃 4000 万像素相机的原图），再取一张 `maxPixel`（列表里用 400）的当封面。`kCGImageSourceCreateThumbnailWithTransform = YES` 把 EXIF 方向烘焙进像素，后续渲染不用再管方向。
- **视频 URL 必须拷贝**（`KBAssetLoader.m:53`）：`loadFileRepresentationForTypeIdentifier:` 回调结束后系统会回收源文件，直接留 URL 会拿到失效路径。所以统一 `copyItemAtURL:` 到 `NSTemporaryDirectory()` 下带 UUID 的文件名。
- **封面出图**（`KBMediaAsset.m:64`）：`AVAssetImageGenerator`（`appliesPreferredTrackTransform = YES`，`maximumSize = 400×400`，取 0.3s 处帧），完成后回主队列。三个必须注意的细节：
  1. generator 被属性**强持有**（`thumbnailGenerator`）——AVFoundation 不保证持有它，回调期间对象提前释放会拿到失效数据；
  2. 用自增 `thumbnailRequestID` 作废过期回调——重选素材会重建缩略图条，同一素材可能被重复请求，只认最新一次；
  3. 回调里的 `CGImageRef` 是**非持有**引用（`The generated image is not retained`），**不能 `CGImageRelease`**，否则过度释放 → 黑图 + `CFRelease` 崩溃（详见 11.2）。

### 4.2 KBTemplate（`KBTemplate.h`）

模板 DSL 的模型层。`+templateNamed:inBundle:` 读单个 JSON；`+templatesInBundle:` 扫描 bundle 内所有 JSON，**只收编同时声明了 `id` / `bpm` / `clip_beats` 的文件**（避免把普通配置 JSON 当模板），再按 `order`（相同则按 `name`）排序。

派生量（`KBTemplate.m:97` 起）：

| 方法 | 公式 | 例（travel_fast） |
| --- | --- | --- |
| `beatInterval` | `60 / bpm` | 0.46875 s |
| `clipDuration`（D） | `clip_beats × beatInterval` | 1.40625 s |
| `transitionDuration`（T） | `transition_beats × beatInterval` | 0.234375 s |
| `totalDurationForClipCount:` | `D + (n-1) × max(0.1, D - T) + 0.6` | n=6 → 7.866 s |
| `motionAtIndex:` | `motionCycle[i % count]` | 循环取运镜 |

> `totalDurationForClipCount:` 只是**界面上的估算**（它假设全部是节拍槽位、且不收敛 T），真实时长以 `KBTimeline.duration` 为准，所以 `full` 模板的文案写成「预计成片 ≥ X 秒」。

### 4.3 KBTimeline（`KBTimelineBuilder.h`）

构造产物，预览与导出共用：

```objc
@interface KBTimeline : NSObject
@property (nonatomic, strong) AVComposition *composition;                   // 轨道与时间
@property (nonatomic, strong) AVMutableVideoComposition *videoComposition;  // 帧尺寸/帧率/指令
@property (nonatomic, strong, nullable) AVAudioMix *audioMix;               // BGM 淡入淡出
@property (nonatomic, assign) CMTime duration;                              // = carrier 长度 = total + 0.1
- (AVPlayerItem *)makePlayerItem;                                           // 预览入口
@end
```

### 4.4 KBClipSpec / KBCompositionInstruction（`KBVideoCompositor.h`）

渲染配置的载体，全部挂在指令上随 `AVAsynchronousVideoCompositionRequest` 传递，**不需要任何单例或静态状态**。

| 字段 | 含义 |
| --- | --- |
| `image` | 照片：解码后的 `CIImage` |
| `isVideo` / `videoTrackID` / `videoTransform` | 视频：所在 composition 轨道 ID + 原始 `preferredTransform` |
| `start` / `end` | 该段在成片时间轴上的区间（**含与前段重叠的 T**） |
| `motion` | 该段的 Ken Burns 运镜 |
| `progressAtTime:` | `clamp((t - start) / (end - start), 0, 1)`，运镜进度用 |
| `KBCompositionInstruction.clips` | 全部片段，按时间顺序 |
| `KBCompositionInstruction.transitionDuration` | 叠化长度 T（统一值） |

---

## 5. 模板 DSL

### 5.1 字段表

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
  "motions": ["zoom_in", "pan_right", "zoom_out", "pan_left"],
  "transition": { "type": "dissolve", "align": "beat" }
}
```

| 字段 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `id` | ✅ | — | 模板标识（`templatesInBundle:` 用它判断是否为模板） |
| `name` | | `未命名模板` | chip 与卡片上的展示名 |
| `order` | | `999` | chip 排序；未声明排最后 |
| `bpm` | ✅ | `120`（缺失/≤0） | 节拍速度，所有切点对齐它 |
| `clip_beats` | ✅ | `1`（下限） | 每段素材占几拍 → D |
| `transition_beats` | | `0.5` | 叠化时长（拍）→ T；0.5 = 半拍卡点 |
| `video_mode` | | `slot` | `slot` 裁到槽位 / `full` 原速完整播放（见 5.3） |
| `resolution` | | `[1080, 1920]` | 成片画幅 |
| `fps` | | `30` | 帧率（`videoComposition.frameDuration`） |
| `audio` | | `""`（无 BGM） | 资源名，优先 `.m4a`，回退 `.mp3` |
| `motions` | | `["zoom_in"]` | 运镜循环，按段取模 |
| `transition` | | — | 目前仅占位（类型固定 dissolve），`align` 表达"对齐节拍"的设计意图 |

### 5.2 内置模板与实际时序

| 模板 | name | bpm | beat | clip_beats | **D** | transition_beats | **T** | video_mode | BGM（时长） |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `travel_fast` | 旅行 · 快闪 | 128 | 0.46875 s | 3 | **1.4063 s** | 0.5 | **0.2344 s** | slot | `bgm_travel_128bpm`（30.4 s） |
| `daily_vlog` | 日常 · 慢剪 | 90 | 0.6667 s | 4 | **2.6667 s** | 1 | **0.6667 s** | slot | `bgm_daily_90bpm`（43.1 s） |
| `sport_hype` | 运动 · 高能 | 150 | 0.4 s | 2 | **0.8 s** | 0.25 | **0.1 s** | slot | `bgm_sport_150bpm`（32.4 s） |
| `story_full` | 故事 · 原速完整 | 96 | 0.625 s | 3 | **1.875 s** | 1 | **0.625 s** | **full** | `bgm_story_96bpm`（40.4 s） |

> 表中 T 是"模板声明值"；真实使用的 T 会被"最短段一半"收敛（见 6.2），例如 `story_full` 遇到 0.8 s 的视频时 T 会降到 0.4 s。

### 5.3 `video_mode` 的语义差异

这是两档完全不同的视频处理策略，也是"切镜卡点"和"完整表达"的分水岭：

| | `slot`（默认，旅行/日常/运动） | `full`（故事 · 原速完整） |
| --- | --- | --- |
| 段时长 | = 节拍槽位 D | = 视频源时长 V |
| 源比槽位长 | 从头裁到 D | 不裁，整段播完 |
| 源比槽位短 | `scaleTimeRange` **慢放**补满 D | 不拉伸，段就短 |
| 成片总时长 | 只由模板决定（可预估） | 随素材时长变化（界面显示 ≥） |
| 卡点 | 所有切点都在拍网格上 | 视频段切点会偏离拍网格（照片段仍在网格上） |
| 适用 | 快闪、混剪、音乐卡点 | vlog / 口播 / 需要完整表达的长镜头 |

`full` 模式在排版时会先读视频源时长，异常（<0.1 s 或拿不到轨道）时退回节拍槽位，保证不生成 0 长度片段。

### 5.4 新增一个模板

1. 在 `GenerateVideoWithOneClick/` 下扔一个 JSON（字段见 5.1，`id` / `bpm` / `clip_beats` 必填）。
2. 生成对应伴奏（BPM 必须与模板一致，否则卡点会飘）：

```bash
python3 scripts/make_bgm.py --bpm 100 --style calm \
        --out /tmp/bgm.wav \
        --m4a GenerateVideoWithOneClick/bgm_xxx_100bpm.m4a
```

3. 重新编译即可：工程用 `fileSystemSynchronizedGroups`，目录里的 JSON / m4a 自动进 bundle，**不需要改 pbxproj**。
4. 验证：`bash scripts/run_e2e.sh xxx`（脚本会自动发现新模板）。

### 5.5 伴奏是怎么来的

`scripts/make_bgm.py`：纯标准库合成 16bit 立体声 WAV（`44100 Hz`），再用 macOS 自带 `afconvert -f m4af -d aac -b 192000` 转 m4a。

- 织体：`kick / snare / hat / bass / arpeggio / pad`，和弦走向 `Am → F → C → G`（每小节一个和弦循环）。
- 三种风格：`fast`（四踩 kick，织体密）、`calm`（kick 在 1/3 拍，织体疏）、`hype`（4 分音符 hat / 琶音，最密）。
- 结构：`--bars` 小节数（默认 16 小节 + 0.4 s 尾巴），因此时长 ≈ `bars × 4 × 60 / bpm + 0.4`。
- 结尾做了峰值归一化（`0.89 / peak`）+ 20 ms 淡入 / 0.5 s 淡出；左右声道差 0.4 ms 制造宽度。

---

## 6. 时间轴构建（引擎核心）

入口：`KBTimelineBuilder.m:33`（异步封装）与 `KBTimelineBuilder.m:44`（真正的装配函数）。

```objc
+ (void)buildTimelineAsyncWithAssets:(NSArray<KBMediaAsset *> *)assets
                             template:(KBTemplate *)template
                               bgmURL:(nullable NSURL *)bgmURL
                           completion:(void (^)(KBTimeline *, NSError *))completion;
```

### 6.1 步骤 1：轨道预加载（`KBTimelineBuilder.m:53`）

因为 `full` 模式的排版需要**视频源时长**，所以在排版前必须先把轨道元数据拿到：

- 对 BGM：`loadTracksWithMediaType:AVMediaTypeAudio` 拿第一条音轨。
- 对每个视频素材：`loadTracksWithMediaType:AVMediaTypeVideo` 拿第一条画面轨（视频原声一律忽略）。
- 并发发起，用 `dispatch_group` 汇合，用 `NSLock` 保护共享写入，结果按下标存进 `NSMutableDictionary<NSNumber *, AVAssetTrack *>`（**不能存数组**——回调完成顺序不确定，原因见 11.1）。
- 任何一条轨道缺失或加载报错：整体失败返回（错误码 -7 / -8）。

### 6.2 步骤 2：排版模型（`KBTimelineBuilder.m:97`）

设素材数 `n`，模板槽位时长 `D`，转场 `T`：

**① 每段时长 `d[i]`**

```
照片：              d[i] = D
视频 & slot：       d[i] = D
视频 & full：       d[i] = V（源时长，< 0.1 s 时退回 D）
末段（仅 slot）：    d[n-1] += 0.6      // 片尾定格
```

**② 转场收敛**

```
T = min(模板 T, min(d[i]) / 2)
```

物理含义：一段素材里「被前一段叠化占掉的部分」+「被后一段叠化占掉的部分」不能超过它自己的长度，留出至少一半的稳定画面。否则短片段会被叠化完全盖住（画面永远在半透明状态）。`story_full` 插入 0.8 s 视频时 T 会从 0.625 s 收敛到 0.4 s，就是这个机制。

**③ 起点与总时长**

```
start[0] = 0
start[i] = Σ_{j<i} (d[j] - T)          // 相邻两段尾部重叠 T
total    = Σ d[i] - (n-1) × T
```

时间轴示意图（slot 模式，n = 3，T < D/2）：

```
              start[1]=D-T            start[2]=2(D-T)
 段0  |===========================|
 段1                   |===========================|
 段2                                  |===========================|
                       ^^^^T^^^        ^^^^T^^^
                      段0/1 叠化区     段1/2 叠化区

 完全切换时刻 = start[i] + T
 例 travel_fast：D=1.4063s, T=0.2344s ⇒ 切换出现在 0.5、3、5.5、8… 拍（半拍网格）
```

> 卡点原理：`D - T = (clip_beats - transition_beats) × beatInterval`，是拍长的整数/半整数倍，所以每段"完全接管画面"的时刻 `start[i] + T` 必然落在拍网格上（travel_fast 落在半拍网格，sport_hype 落在 1/4 拍网格）。

### 6.3 步骤 3：carrier 承载视频（`KBTimelineBuilder.m:287`）

```objc
+ (nullable NSURL *)writeCarrierVideoWithDuration:(NSTimeInterval)duration error:(NSError **)error;
```

| 参数 | 值 | 原因 |
| --- | --- | --- |
| 分辨率 | 270×480 | 越低成本越好，它只是"节拍器" |
| 帧率 | 2 fps | 只要能驱动 `frameDuration`，编码压力越小越好 |
| 编码 | H.264 / MP4 / 32BGRA | 兼容性最好的组合 |
| 帧数 | `ceil(duration × 2) + 2` | 多写 2 帧留余量 |
| 落地 | `NSTemporaryDirectory()/carrier_<UUID>.mp4` | 每次构建独立文件，避免并发写同一个文件 |

写帧流程：`AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`，复用**同一块黑帧 buffer**（`memset` 一次），逐帧 `appendPixelBuffer:withPresentationTime:`，`readyForMoreMediaData` 不满足时自旋等待（带 10 s 超时保护），最后 `finishWritingWithCompletionHandler:` 用信号量同步等待。失败一律删除临时文件并返回错误（-3 ~ -6）。

### 6.4 步骤 4：composition 组装（`KBTimelineBuilder.m:162`）

```
AVMutableComposition
├─ 视频轨 1：carrier 黑帧，插入 [0, total + 0.1)   ← 长度比内容多 0.1s，保证末帧覆盖
├─ 视频轨 2..k+1：每个视频素材一条轨
│    ├─ slot 模式：take = min(源时长, 槽位时长)，插到槽位起点；
│    │              take < 槽位 ⇒ scaleTimeRange:toDuration: 慢放铺满
│    └─ full 模式：整段源 srcTrack.timeRange 插到槽位起点，不裁剪、不变速
└─ 音频轨 1（有 BGM 时）：按 BGM 长度分块循环插入，铺满整个 [0, total)
```

音频的淡入淡出通过 `AVMutableAudioMix` 实现：

```objc
[params setVolumeRampFromStartVolume:0 toEndVolume:1 timeRange:[0, 0.3s]];             // 淡入
[params setVolumeRampFromStartVolume:1 toEndVolume:0 timeRange:[total - 1.0s, 1.0s]];  // 淡出
```

### 6.5 步骤 5：videoComposition 与指令（`KBTimelineBuilder.m:260`）

```objc
videoComposition.renderSize    = tpl.renderSize;              // 1080×1920
videoComposition.frameDuration = CMTimeMake(1, tpl.fps);      // 1/30
videoComposition.customVideoCompositorClass = [KBVideoCompositor class];
videoComposition.instructions   = @[instruction];             // 一条覆盖全片
```

指令字段：

| 字段 | 值 | 说明 |
| --- | --- | --- |
| `timeRange` | `[0, carrierLength)` | 覆盖全片 |
| `clips` | 全部 `KBClipSpec` | 渲染配置来源 |
| `renderSize` | 模板画幅 | compositor 用它算 aspect-fill |
| `transitionDuration` | T | 叠化进度分母 |
| `requiredSourceTrackIDs` | carrier + 全部视频轨 ID | 声明依赖；carrier 本身不被读帧 |
| `containsTweening` | `YES` | 有叠化插值 → 关闭帧缓存复用，避免复用到转场中间帧 |
| `enablePostProcessing` | `NO` | 不需要系统后处理 |

最终 `timeline.duration = carrierLength = total + 0.1`。

### 6.6 步骤 6：错误码表（`kKBTimelineErrorDomain`）

| code | 含义 |
| --- | --- |
| -1 | 未选择素材 |
| -2 | carrier 轨道缺失 |
| -3 ~ -6 | carrier 视频写入失败（startWriting / buffer 创建 / 写帧 / finishWriting） |
| -7 | 视频画面轨缺失（预加载阶段） |
| -8 | 视频画面轨缺失（组装阶段，含素材序号） |

### 6.7 必须保持的不变量（改代码前先读这段）

1. `clips[i].start` 与 composition 里该素材的插入时间**必须一致**，否则画面与裁切对不上。
2. `start[i+1] - start[i] = d[i] - T`，且 `T ≤ min(d)/2`：前者保证叠化区长度统一，后者保证每段都有稳定画面。
3. `clips` 必须按时间**升序**排列（compositor 取"前两个可见片段"就 break）。
4. carrier 长度 ≥ `total`（当前 `+0.1 s`），否则末尾黑帧。
5. `timeline.duration == carrierLength`，e2e 的时长断言据此计算（`total + 0.1`）。
6. 视频素材的 `preferredTransform` 必须随 `KBClipSpec` 传下去，compositor 才会做旋转校正。

---

## 7. 自定义合成器（KBVideoCompositor）

`KBVideoCompositor` 实现 `AVVideoCompositing`，由 AVFoundation 在播放/导出时实例化，**预览与导出共用同一份代码**，这是"所见即所得"的根本原因。

### 7.1 协议实现清单

| 成员 | 作用 |
| --- | --- |
| `sourcePixelBufferAttributes` | 输入要求：32BGRA |
| `requiredPixelBufferAttributesForRenderContext` | 输出要求：32BGRA |
| `renderContextChanged:` | 缓存 `renderContext`（**系统只在回调期间持有，不能跨回调长期持有**）；写之前 `dispatch_sync` 到渲染队列 |
| `startVideoCompositionRequest:` | 每帧入口：异步到渲染队列 → 画图 → `finishWithComposedVideoFrame:` |
| `cancelAllAsyncVideoCompositionRequests` | `_cancelled = YES` 并 `dispatch_sync` 排空渲染队列，保证返回后不再有 in-flight 完成回调 |
| `dealloc` | `dispatch_sync` 排空渲染队列 + 释放色彩空间 |

### 7.2 一帧的渲染流程

```
startVideoCompositionRequest(request)
  ├─ 取消过？（_cancelled） → finishCancelledRequest，退出
  ├─ 有 renderContext？ → 否则 finishWithError(AVErrorNoImageAtTime)
  ├─ outputBuffer = [context newPixelBuffer]
  ├─ frame = [self frameForRequest:request]
  │     ├─ 取 instruction（含 clips / renderSize / transitionDuration）
  │     ├─ 找出可见片段（start ≤ t < end，最多 2 个）
  │     ├─ 渲染 current = renderedImageForClip(visible[0])
  │     ├─ 若 2 个可见：q = clamp((t - visible[1].start) / T, 0, 1)
  │     │              current = CIDissolveTransition(current, next, q)
  │     └─ 无可见片段 → 返回全黑图
  ├─ [ciContext render:frame toCVPixelBuffer:bounds:colorSpace:]
  └─ finishWithComposedVideoFrame /（取消）finishCancelledRequest + CVBufferRelease
```

### 7.3 可见片段与叠化（`KBVideoCompositor.m:166`）

```objc
for (KBClipSpec *clip in instruction.clips) {
    if (t >= clip.start && t < clip.end) [visible addObject:clip];
    if (visible.count == 2) break;      // 至多两段重叠 —— 依赖 clips 时间升序
}
```

- 恰好 1 段：直接画它。
- 恰好 2 段（重叠区长度 = T）：`q` 从 0 线性走到 1，`CIDissolveTransition` 按 `inputTime = q` 混合两张图。
- 0 段：全黑（正常时间轴不会出现，属于兜底）。
- **进度用绝对时间计算**（`(t - visible[1].start) / T`），而不是用段内百分比，所以两段各自的运镜进度互不干扰，叠化看起来"跨镜头连续"。

### 7.4 Ken Burns 运镜数学（`KBVideoCompositor.m:205`）

设画布 `S = (W, H)`（1080×1920），图源尺寸 `(iw, ih)`，段内进度 `p ∈ [0,1]`：

```
fill  = max(W/iw, H/ih)                       // aspect-fill，保证铺满不留黑边

zoom_in    : scale = fill × (1 + 0.22 p)
zoom_out   : scale = fill × (1.22 − 0.22 p)
pan_left   : scale = fill × 1.15              // 预留放大余量
pan_right  : scale = fill × 1.15
             maxX  = max(0, (iw × scale − W) / 2)
             dx    = dir × maxX × (2p − 1)    // pan_left: dir = +1，pan_right: dir = −1

transform = Scale( Translate((W − iw×scale)/2 + dx, (H − ih×scale)/2), scale )
```

要点：

- 变换顺序是"先缩放（相对图像原点）再平移到居中位置"，写法是 `CGAffineTransformScale(CGAffineTransformMakeTranslation(tx, ty), scale, scale)`。
- 缩放幅度 ±22%、平移预留 1.15 倍，是为了让运镜"看得出来"又不露黑边：`zoom_out` 在 p=1 时正好 `scale = fill`（贴边不裁），`pan` 全程 `scale ≥ fill`。
- 运镜类型每段由 `motionAtIndex:i` 循环取，段与段的运镜切换发生在叠化区里，观感更自然。

### 7.5 视频取帧与旋转

```objc
CVPixelBufferRef buffer = [request sourceFrameByTrackID:clip.videoTrackID];
CIImage *image = [CIImage imageWithCVImageBuffer:buffer];
image = [image imageByApplyingTransform:clip.videoTransform];   // 校正竖拍视频的旋转元数据
if (image.extent.origin.x != 0 || image.extent.origin.y != 0) { // 旋转后原点可能为负，平移到 0
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-x, -y)];
}
```

AVFoundation 已经按 composition 时间把源帧映射好，所以 compositor 拿到的就是"该时刻应该显示的那一帧"，不需要自己做时间换算。

### 7.6 生命周期与取消的三个注意点

1. **不能长期持有 `renderContext`**：系统只在 `renderContextChanged:` 与渲染回调期间保证其有效，本类只在渲染回调里临时取用（`unsafe_unretained` + 队列同步）。
2. **`_cancelled` 一旦置位不会复位**：`KBVideoCompositor` 实例是 per-playerItem / per-export-session 的，所以这符合预期；但如果把 compositor 改成单例复用，必须在 `startVideoCompositionRequest:` 里复位。
3. **`dealloc` 里 `dispatch_sync` 排空**：避免析构时还有 in-flight 帧回调访问已释放的 ivar。

### 7.7 渲染性能

- `CIContext` 懒加载：优先 Metal（`MTLCreateSystemDefaultDevice`），没有 Metal 时退回 CPU context。
- 输出像素格式固定 32BGRA，避免每帧做像素格式转换。
- `instruction.containsTweening = YES` 会关掉 AVFoundation 的帧缓存复用——这是**故意**的：叠化期间每帧画面都不同，复用会串帧。
- 真正的瓶颈是"每帧合成两张 1080×1920 的 CIImage"。要提速优先考虑：降低导出分辨率、减少同时可见片段数、或把 Ken Burns 换成 Metal 自定义 kernel。

---

## 8. 导出与相册（KBExporter）

```objc
+ (void)exportTimeline:(KBTimeline *)timeline
            completion:(void (^)(NSURL *, NSError *))completion
              progress:(void (^)(float))progress;
+ (void)saveToPhotoLibrary:(NSURL *)fileURL
                completion:(void (^)(BOOL, NSError *))completion;   // 仅 iOS
```

| 项 | 值 / 说明 |
| --- | --- |
| 输出路径 | `NSTemporaryDirectory()/oneclick_<UUID>.mp4` |
| preset | `AVAssetExportPresetHighestQuality`（重编码，保证 compositor 效果） |
| 文件类型 | `AVFileTypeMPEG4` |
| 必须挂载 | `session.videoComposition`（否则运镜/转场全丢）、`session.audioMix`（否则 BGM 淡入淡出失效） |
| 进度 | `NSTimer` 每 0.1 s 读 `session.progress` 回主队列；结束时补一个 1.0 |
| 失败 | 状态非 `Completed` 时透出 `session.error`（错误码 -1 / -2） |
| 存相册 | `PHAccessLevelAddOnly` 授权 → `PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:`；权限不足返回 -3 |
| 权限文案 | `Info.plist` 的 `NSPhotoLibraryAddUsageDescription` |

注意：`AVAssetExportSession` 是一次性对象，不能在导出中复用；导出期间不能删除输出目录，由 `ViewController` 的 timeline 生命周期保证。

---

## 9. 素材导入（KBAssetLoader）

### 9.1 Picker 配置（`KBAssetLoader.m:20`）

```objc
config.filter    = [PHPickerFilter anyFilterMatchingSubfilters:@[imagesFilter, videosFilter]];
config.selectionLimit = 12;
config.selection = PHPickerConfigurationSelectionOrdered;   // 保持用户点选顺序（iOS 15+）
```

顺序很重要：时间轴按数组顺序吃素材，用户点选顺序就是成片顺序。

### 9.2 单条素材的加载策略

```
itemProvider 声明了 image 类型？
  ├─ 是 → loadFileRepresentationForTypeIdentifier:UTTypeImage
  │        └─ 解码失败（例如只注册了视频表示）→ 自动降级走视频分支
  └─ 否 → loadFileRepresentationForTypeIdentifier:UTTypeMovie
           └─ 拷贝到 NSTemporaryDirectory()/pick_<UUID>.<ext> → KBMediaAsset
```

失败时收集第一个错误（`KBLoadErrorBox`），"部分成功"也能出成片（`ViewController` 会在状态栏提示"部分素材读取失败"）。

### 9.3 并发收敛（`KBAssetLoader.m:102`）

```objc
NSMutableDictionary<NSNumber *, KBMediaAsset *> *loaded;   // key = 用户点选下标
NSLock *lock;
for (每个 result) { dispatch_group_enter(group); [self loadOneResult:... index:index ...]; }
dispatch_group_notify(group, 全局队列, ^{
    for (i in 0..<count) if (loaded[@(i)]) [collected addObject:loaded[@(i)]];  // 按下标收敛
    dispatch_async(主队列, ^{ completion(ordered, error); });
});
```

**为什么必须用字典而不是数组**：`NSMutableArray` 按下标赋值只在 `index == count` 时等价于追加；回调完成顺序不确定，`index 1` 先于 `index 0` 到达时会直接抛越界异常（真实崩溃，见 11.1）。

---

## 10. 界面与交互（ViewController）

### 10.1 视图层级

```
UIView（渐变背景 CAGradientLayer）
└─ UIScrollView（纵向）
   └─ contentView（Masonry 约束撑开滚动区）
      ├─ 标题 / 副标题
      ├─ UIScrollView（横向）→ UIStackView → 模板 chip（UIButton）
      ├─ 模板卡片（名称 / 参数 / 视频策略 / 时长估算）
      ├─ 素材缩略图条（UICollectionView 横向 flow layout → KBThumbnailCell[封面 + 序号 + 「视频」角标]）
      ├─ KBPlayerView（AVPlayerLayer 承载）→ 重播按钮
      ├─ 选择素材 / 一键成片 / 导出并保存到相册
      ├─ UIProgressView（导出进度）
      └─ 状态 Label
```

`KBPlayerView` 通过重写 `+layerClass` 让 view 的 backing layer 直接就是 `AVPlayerLayer`，省掉手动同步 frame 的代码。

### 10.2 Masonry 约束要点

整屏纵向滚动：

```objc
[self.scrollView mas_makeConstraints:^(MASConstraintMaker *make) {
    make.top.equalTo(self.view.mas_safeAreaLayoutGuideTop);
    make.left.right.bottom.equalTo(self.view);
}];
[self.contentView mas_makeConstraints:^(MASConstraintMaker *make) {
    make.top.equalTo(self.scrollView).offset(20);
    make.left.equalTo(self.scrollView).offset(20);
    make.right.equalTo(self.scrollView).offset(-20);
    make.bottom.equalTo(self.scrollView).offset(-24);
    make.width.equalTo(self.scrollView).offset(-40);   // 关键：锁定内容宽度 = 屏宽 − 40
}];
```

横向滚动区（模板 chip / 缩略图条）：

```objc
[self.templateStack mas_makeConstraints:^(MASConstraintMaker *make) {
    make.top.bottom.left.equalTo(self.templateScrollView);
    make.right.equalTo(self.templateScrollView).offset(-8);  // ★ 右边也必须钉住
    make.height.mas_equalTo(36);
}];
```

**★ 是本工程踩过的坑**：横向滚动区只钉左边（或只钉 `top/bottom/left`）时，滚动区算不出内容宽度（实测 `contentSize.width = 0`，而 stack 实际有 624 pt 宽），表现是 chip 被裁掉且怎么拖都不动。Masonry 1.1.0 **不支持 layout guide**，写 `equalTo(self.scrollView.contentLayoutGuide)` 会直接断言崩溃（`attempting to add unsupported attribute: _UIScrollViewLayoutGuide`），所以用"左右都钉住"的写法：右边钉住等于把内容宽度交给 stack 自身（chip 固有宽度）决定。

其他约定：

- 视图高度用常量约束 + `MASConstraint` 持有，运行时改值：

```objc
self.playerHeightConstraint = make.height.mas_equalTo(0);   // 未出成片时收起，避免大块空白
...
[self.playerHeightConstraint setOffset:391];                // 220 × 16/9 ≈ 391
```

- **不要再混用 `NSLayoutConstraint` 和 Masonry**：Masonry 安装约束时会把 `translatesAutoresizingMaskIntoConstraints` 置 `NO`；手工创建的自定义 view 若自己加约束又漏掉这一句，就会出现约束打架、视图塌成 0 尺寸（早期按钮就是这个原因，见 11.4）。
- 渐变背景的 `frame` 在 `viewDidLayoutSubviews` 里跟随 `self.view.bounds`（`CAGradientLayer` 不参与 Auto Layout）。

### 10.3 状态机

| 状态 | 判据 | 界面 |
| --- | --- | --- |
| 未选素材 | `mediaAssets.count == 0` | 时长标签「未选择素材」，两按钮禁用 |
| 已选素材 | `count > 0 && template` | 「已选 N 个素材 · 预计成片 X 秒」；`count ≥ 2` 时「一键成片」可用 |
| 已生成成片 | `timeline != nil` | 预览播放，「导出并保存到相册」可用 |
| 导出中 | 导出回调未返回 | 进度条显示，导出按钮禁用，状态栏「正在导出 MP4…」 |

失效规则（`invalidateTimeline`，`ViewController.m:585`）：**换素材或换模板都会作废上一版成片**——停播、清 player、收起预览、进度归零，避免把旧版本导出给用户。

### 10.4 播放器交互

- 点画面暂停/继续（`UITapGestureRecognizer` + `togglePlay`）。
- 播完订阅 `AVPlayerItemDidPlayToEndTimeNotification` 显示「重播」，并**比对 `notification.object` 与当前 item**，忽略已被替换的旧条目。
- `gestureRecognizer:shouldReceiveTouch:` 保证点「重播」按钮不会同时触发暂停手势。

### 10.5 素材缩略图条：长按拖动排序

缩略图条是一个横向 `UICollectionView`（`itemSize 64×72`、`spacing 8`、`sectionInset 8`、行高 88），
顺序即时间轴顺序，也是成片顺序。实现走 UIKit 的 **drag & drop** 两条 delegate（`ViewController.m:531` 起）：

| 步骤 | 方法 | 关键点 |
| --- | --- | --- |
| 允许拖动 | `collectionView:canMoveItemAtIndexPath:` | 只有 ≥2 个素材才允许排序 |
| 拎起素材 | `collectionView:itemsForBeginningDragSession:atIndexPath:` | `UIDragItem.localObject` 挂 `KBMediaAsset`，只做本地重排，不需要真数据 |
| 拖动反馈 | `collectionView:dropSessionDidUpdate:withDestinationIndexPath:` | 本地会话返回 `UIDropOperationMove` + `UICollectionViewDropIntentInsertAtDestinationIndexPath`；外部拖入返回 `UIDropOperationCancel` |
| 松手落位 | `collectionView:performDropWithCoordinator:` | 取 `sourceIndexPath` + `destinationIndexPath`，改模型后 `performBatchUpdates:moveItemAtIndexPath:`，再调 `[coordinator dropItem:toItemAtIndexPath:]` |
| 模型重排 | `moveAssetAtIndex:toIndex:`（`ViewController.m:590`） | `removeObjectAtIndex:` + `insertObject:atIndex:`，返回最终下标；位置没变返回 `nil` |

设计要点：

- **模型与动画必须是同一个下标**。`moveAssetAtIndex:toIndex:` 里模型做
  `remove` + `insert:(to)`、collection view 做 `moveItemAtIndexPath:from → to`，
  两者语义一致（移动后元素落在 `to`），所以"屏幕上的顺序"和"数组里的顺序"永远一致。
  想改动这里时，务必先确认动画结果和数组结果仍然一致，否则成片顺序会和用户看到的对不上。
- **拖到空白处**：`destinationIndexPath` 为 `nil`，按"移到末尾"处理，再由 `moveAssetAtIndex:` 夹到 `0..count-1`。
- **`dragInteractionEnabled` 在 iPhone 上默认是 `NO`**，必须显式置 `YES`（`ViewController.m:246`），否则长按毫无反应。
- **松手要通知 coordinator**：不调用 `dropItem:toItemAtIndexPath:` 时，拖起来的快照会飞回**原位**，
  看起来像"没换成功"，即使 layout 已经移动了。
- **必须有拖拽落位后的副作用**：顺序变化后立即 `invalidateTimeline`（旧成片作废）+ `refreshState`，
  状态栏提示「已调整素材顺序 · 重新一键成片生效」，避免用户导出上一个顺序的成片。
- **cell 复用校验**：`KBThumbnailCell.representedAsset` 与 `prepareForReuse` 双重保险，
  防止异步出图把上一个素材的封面写进被复用的 cell。

---

## 11. 崩溃与疑难复盘

### 11.1 素材加载时 NSMutableArray 并发按索引写入越界

**现象**：选完素材、正在读素材时闪退，堆栈停在 `- [__NSArrayM setObject:atIndexedSubscript:]` 的越界断言（`index 1 beyond bounds for empty array`）。

**根因**：`KBAssetLoader` 早期实现用 `NSMutableArray` 存加载结果并按下标赋值：

```objc
results[index] = asset;   // 只有 index == count 时才是"追加"
```

`PHPickerResult` 的加载回调是**并发**的（图片走 `loadFileRepresentationForTypeIdentifier:`，视频还要拷贝文件），完成顺序不确定。下标 1 的回调先到时数组还是空的 → 越界。

**修复**：`NSMutableDictionary` + `NSLock`，`dispatch_group` 汇合后按下标收敛成有序数组（`KBAssetLoader.m:102-140`）。

**通用教训**：任何"多回调写共享容器"的场景，先问"回调完成顺序确定吗"——不确定就别用下标写数组。

### 11.2 视频封面全黑 + CFRelease 崩溃（CGImageRef 被过度释放）

**现象**：导入视频后缩略图是**纯黑**，紧接着进程 `Trace/BPT trap` 崩溃，堆栈停在 `CoreFoundation CFRelease`。

**根因**：`generateCGImageAsynchronouslyForTime:completionHandler:` 的文档明确写着 *"The generated image is not retained. Clients should retain the image if they wish it to persist after the completion handler returns."* —— 回调里的 `CGImageRef` 是**非持有**引用，代码里却调了 `CGImageRelease(image)`：

```objc
UIImage *thumb = image ? [UIImage imageWithCGImage:image] : nil;
if (image) CGImageRelease(image);   // 过度释放 → 黑图 + 后续 CFRelease 崩
```

**修复**（`KBMediaAsset.m:64`）：删掉 `CGImageRelease`（`UIImage` 会自己 retain），并强持有 generator、用 `thumbnailRequestID` 作废过期回调。

**通用教训**：CF 对象出现在"回调参数"位置时，先确认所有权（`CF_RETURNS_NOT_RETAINED` / 文档里的 not retained），不确定就别 release。

### 11.3 缩略图回写依赖 subviews.firstObject

```objc
__weak UIView *weakCell = cell;
[asset loadThumbnailWithCompletion:^(UIImage *thumb) {
    UIImageView *ivInCell = [weakCell.subviews firstObject];   // 依赖"第一个子视图正好是图片"
    if ([ivInCell isKindOfClass:[UIImageView class]]) ivInCell.image = thumb;
}];
```

后续在 cell 上加了「视频」角标、Masonry 约束之后，子视图顺序就不再保证"图片永远是第一个"，回写会静默失效（封面一直空）甚至写到角标上。

**修复**：直接弱引用 `UIImageView` 本身（`ViewController.m:478`）：

```objc
__weak UIImageView *weakImageView = iv;
[asset loadThumbnailWithCompletion:^(UIImage *thumb) { weakImageView.image = thumb; }];
```

### 11.4 布局塌陷（autoresizing mask 与 Masonry 打架）

**现象**：按钮/控件看不见、尺寸塌成 0。

**根因**：早期用 `NSLayoutConstraint` 手写约束时，自建的按钮没有设 `translatesAutoresizingMaskIntoConstraints = NO`，它自带的 autoresizing mask 会生成与手动约束冲突的隐式约束。

**修复**：布局全部改为 Masonry（`mas_makeConstraints:`）后自然消除；Masonry 安装约束时会自动把该属性置 `NO`。若后续新增自建控件，注意不要在同一个视图上混用两种约束写法。

### 11.5 横向 chip 行"只有两个半且滑不动"

详见 10.2 的 ★ 段：`contentSize.width = 0`，必须左右都钉住。同类问题也出现在素材缩略图条上（素材超过 4 个就滑不动），一并修掉。

### 11.6 拖拽排序：编译期与运行期两个坑

**编译期**：`UICollectionViewDropItem` 是**协议**不是类，写
`UICollectionViewDropItem *item = coordinator.items.firstObject;` 会报
`unknown type name 'UICollectionViewDropItem'`。正确写法是
`id<UICollectionViewDropItem> item = coordinator.items.firstObject;`。

**枚举名别猜**：drop 提案用的是 `UIDropOperationCancel` / `UIDropOperationMove`（`UIDropOperation` 枚举），
并不存在 `UICollectionViewDropOperation*` 这种名字；`intent` 才是 `UICollectionViewDropIntent*`。

**运行期**：`dragInteractionEnabled` 在 iPhone 上默认 `NO`，不打开的话 `itemsForBeginningDragSession:` 根本不会被调用，
表现是"长按没反应"。另外别忘了在 `performDropWithCoordinator:` 里调 `[coordinator dropItem:toItemAtIndexPath:]`，
否则快照飞回原位。

---

## 12. 测试与验证（scripts/）

### 12.1 为什么要用 Mac Catalyst 编译命令行程序

引擎类依赖 UIKit（`UIImage` / `CIImage`），所以 `run_e2e.sh` 用 **Mac Catalyst 目标**把它们编成一个 macOS 命令行程序，直接跑真实的 `KBTimelineBuilder + KBVideoCompositor + KBExporter`，不需要模拟器 UI：

```bash
clang -fobjc-arc -fmodules -fmodules-cache-path=build/e2e/ModuleCache -O1 -g \
  -target $(uname -m)-apple-ios<SDK版本>-macabi -isysroot $(xcrun --sdk macosx --show-sdk-path) \
  -I GenerateVideoWithOneClick \
  scripts/e2e_test.m \
  GenerateVideoWithOneClick/{KBTemplate,KBMediaAsset,KBTimelineBuilder,KBVideoCompositor,KBExporter}.m \
  -framework Foundation -framework AVFoundation -framework CoreImage -framework CoreMedia \
  -framework CoreGraphics -framework CoreVideo -framework ImageIO -framework Metal \
  -framework Photos -framework UIKit \
  -o build/e2e/e2e_test
```

### 12.2 用法

```bash
bash scripts/run_e2e.sh                 # 跑 bundle 内全部模板（脚本自动发现 JSON）
bash scripts/run_e2e.sh story_full      # 只跑指定模板
E2E_REPEAT=10 bash scripts/run_e2e.sh travel_fast   # 重复跑，排查偶发问题
```

> 脚本里注意 `"${tpl}（...）"` 必须写花括号：bash 3.2（macOS 自带）会把中文括号当成变量名的一部分。

### 12.3 测试素材与期望值推导

脚本现场生成素材，**不依赖任何外部文件**：

| 素材 | 规格 |
| --- | --- |
| 5 张照片 | 1200×1600 纯色 PNG（手工挑选的高区分度配色，任意两色通道差之和 > 150） |
| 1 段视频 | 720×1280 @30fps，0.8 s 纯色 teal（H.264），放在第 4 个槽位（`kVideoSlot = 3`） |

期望值**按模板现算**（不是硬编码），与 6.2 的排版模型一一对应：

```
D = clipDuration；full 模板下视频段 d = 0.8（源时长），其余段 d = D
slot 模板：末段 +0.6（片尾定格）
T = min(transitionDuration, min(d)/2)
start[i] = Σ_{j<i}(d[j] − T)，total = start[n-1] + d[n-1]
```

### 12.4 校验项清单

| # | 校验 | 判定方式 |
| --- | --- | --- |
| 1 | 模板解析 / 节拍间隔 | `bpm` 与 `beatInterval == 60/bpm` |
| 2 | 时间轴构建 | 非空且无错误 |
| 3 | 总时长 | 与现算期望差 < 0.2 s（注意 `timeline.duration = total + 0.1`） |
| 4 | 预览通路 | `makePlayerItem` 且挂了 `videoComposition` |
| 5 | 导出 MP4 | 文件存在且无错误 |
| 6 | 输出规格 | 单视频轨、1080×1920、单音轨、时长吻合 |
| 7 | 节拍点画面切换 | 6 段各取**段中点**帧，任意两段颜色差 > 60 → 卡点切镜生效 |
| 8 | 视频槽位画面 | 该段中点颜色 ≈ teal（容差 90） |
| 9 | 视频处理模式 | composition 里素材轨的**结束时间** = 槽位起点 +（slot: 槽位时长 / full: 源时长） |
| 10 | 转场取帧 + 叠化混合色 | 转场中点颜色 ≈ 两段底色的平均（容差 120） |
| 11 | 照片→视频叠化 | 视频槽位起点的转场中点 ≈ 照片与视频的混合 |
| 12 | BGM 覆盖全片 | 音频轨时长 > 成片时长 − 1.5 s |
| 13 | 视频封面 | 异步出图 + 主队列回调；取色 ≈ teal；重复请求 3 次不崩不悬挂 |

取帧用 `AVAssetImageGenerator`（关闭 `appliesPreferredTrackTransform`，直接看像素），16×16 降采样后取左上角 4×4 区域平均色——**测试图因此做成整图纯色**：运镜缩放/平移不影响取色（早期测试图中央有白块，pan 到边缘时会漂进采样区，导致取色不稳、偶发误判）。

### 12.5 两个容易踩的测试细节

1. **composition track 的 `timeRange` 从 0 起算**：`AVMutableCompositionTrack.timeRange.duration` 等于"最后一段编辑的结束时间"，不是该素材自己的时长。slot 模式下 0.8 s 视频插在 3.5 s 处、慢放补到槽位后读出来是 **4.92 s（结束时间）**，断言必须用 `start[kVideoSlot] + 期望时长` 去比。
2. **CLI 程序没有 run loop**：`loadThumbnailWithCompletion:` 的回调派到主队列，命令行程序要自己驱动 run loop（`[[NSRunLoop currentRunLoop] runMode:beforeDate:]`）才能等到回调。

### 12.6 覆盖不到的（需要人工验证）

- UI 交互本身（PHPicker 选择、chip 滑动、点画面暂停、重播）。
- 真机相册写入与权限弹窗（模拟器只能验证到"调用成功"）。
- 性能与内存的真实表现（模拟器 / Mac 与真机差异大）。

---

## 13. 构建、运行与调试

### 13.1 首次准备

```bash
cd GenerateVideoWithOneClick
pod install                                   # 装 Masonry（Pods/ 不入库，必须执行）
open GenerateVideoWithOneClick.xcworkspace    # 之后一律用 workspace 打开
```

### 13.2 命令行构建 / 安装到模拟器

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodebuild -workspace GenerateVideoWithOneClick.xcworkspace \
           -scheme GenerateVideoWithOneClick \
           -sdk iphonesimulator -configuration Debug \
           -derivedDataPath ./build CODE_SIGNING_ALLOWED=NO build

APP=build/Build/Products/Debug-iphonesimulator/GenerateVideoWithOneClick.app
xcrun simctl boot "iPhone 17 Pro"
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.xuhan.GenerateVideoWithOneClick
xcrun simctl io booted screenshot /tmp/shot.png
```

调试小技巧：

- `xcrun simctl launch --console-pty booted <bundleid>` 抓 App 的 stdout/stderr。
- 回看已启动 App 的日志：`xcrun simctl spawn booted log show --last 2m --predicate 'process == "GenerateVideoWithOneClick"' --style compact`（`NSLog` 都在里面）。

### 13.3 排错清单

| 症状 | 原因 / 处理 |
| --- | --- |
| `'Masonry/Masonry.h' file not found` | 忘了 `pod install`，或没用 `.xcworkspace` 打开 |
| 模板不显示 | JSON 缺 `id` / `bpm` / `clip_beats` 之一（`templatesInBundle:` 会跳过它） |
| BGM 放不出来 | `audio` 名字与 bundle 内文件名不一致（先找 `.m4a` 再退 `.mp3`） |
| 卡点不准 | 模板 BPM 与实际伴奏不符；用 `make_bgm.py` 重新按同一 BPM 生成 |
| 成片没声音 | 模板没配 `audio`；视频原声是**故意忽略**的 |
| 视频画面是黑的 | 视频缺画面轨（错误码 -7 / -8）；或被 `duration < 0.1 s` 判定异常 |
| 导出很慢 | `HighestQuality` + 1080×1920 重编码；素材多 / 视频长时正常 |
| 相册没保存成功 | 权限是"仅添加"，用户拒绝时返回 -3 |

---

## 14. 性能数据（本机实测，Apple Silicon + iOS 26 模拟器）

| 场景 | 耗时 |
| --- | --- |
| 6 个素材（5 图 + 1 段 0.8 s 视频）构建时间轴 + 导出约 8 s 成片 | 约 1.7 s |
| `scripts/run_e2e.sh` 全量（编译 + 4 个模板端到端） | 约 7.4 s |
| carrier 写盘（8 s 成片 → 约 20 帧 270×480） | 毫秒级，可忽略 |

主要成本在两处：导出时逐帧的 `CIDissolveTransition` 合成（转场区每帧 2 张 1080×1920），以及 `AVAssetExportSession` 的重编码。

---

## 15. 已知限制与风险

| 项 | 说明 | 影响 |
| --- | --- | --- |
| 节拍靠 `bpm` 现算 | 没有离线节拍分析（`beats[]`） | 模板 BGM 必须用脚本生成，或保证 BPM 精确 |
| `transition.type` 只是占位 | 目前只有 dissolve | 想加推/擦/缩放转场要在 compositor 里扩展 |
| 视频原声被忽略 | 只保留模板 BGM | 口播类视频需要扩展（多音轨 + 音量包络） |
| `full` 模式没有时长上限 | 选一段 3 分钟视频 → 成片 3 分钟以上 | 可加 `video_max_seconds` 截断或变速压缩 |
| 每条视频一条轨道 | 12 个素材 = 最多 12 条视频轨 | 轨道数上升会略微增加构建与解码开销 |
| 无缓存 | 换模板 / 换素材都要重建时间轴、重新导出 | 可加"低清预览 + 高清导出"两级策略 |
| 相册只有"仅添加"权限 | 不回读相册 | 需要续编 / 素材预览时要扩展 |
| 播放中断未处理 | 来电 / 后台回来不自动续播 | 可订阅 `AVPlayerItemFailedToPlayToEndTime` 等通知 |
| 引擎测试 ≠ 真机测试 | e2e 在 macOS 上跑，模拟器 / 真机表现可能有差异 | 上架前要补真机回归 |
| `KBVideoCompositor._cancelled` 不复位 | 依赖"实例 per playback"这一前提 | 若改成复用实例必须复位 |

---

## 16. 扩展指南

### 16.1 新增运镜

1. `KBTemplate.h` 的 `KBMotionType` 加枚举值；
2. `KBTemplate.m` 的 `motionMap` 加 JSON 名映射；
3. `KBVideoCompositor.m:205` 的 `switch` 里加变换分支（保证"缩放 ≥ fill、不露黑边"）。

### 16.2 新增转场

1. `KBTemplate` 解析 `transition.type`（当前被忽略）；
2. `KBClipSpec` 或指令上带转场类型；
3. `KBVideoCompositor.m:166` 的叠化分支改成按类型分发（`CIZoomBlur` / `CISwipeTransition` / 自定义 Metal kernel）；
4. 注意 `containsTweening` 仍应为 `YES`（关帧缓存）。

### 16.3 支持视频原声

1. `KBTimelineBuilder` 里给每个视频素材加一条音频轨（时间与画面轨一致，slot 模式同样要 `scaleTimeRange`）；
2. `AVMutableAudioMix` 里给视频音轨加音量参数（例如原声 0.3、BGM 0.7），叠化区做交叉淡变；
3. 模板加字段（如 `"keep_original_audio": true`）。

### 16.4 长视频压缩（配合 `full` 模式）

模板加 `video_max_seconds`：插入前比较源时长与上限，超限时用 `scaleTimeRange` 提速（`> 1x` 即快放）或裁掉中段，保持"内容完整但不冗长"。

### 16.5 产品化方向

- **离线节拍分析**：制模阶段用 librosa 等工具分析真实音乐，把 `beats[]` 写进模板，`bpm` 只作兜底；
- **模板下发**：模板 JSON + BGM 从服务端拉取并缓存（把 `templatesInBundle:` 换成"bundle + 缓存目录"两处扫描即可）；
- **模板封面**：模板自带一张预览图，chip / 卡片直接展示风格；
- **流水线并行**：预览开始时就并行跑导出，减少等待。

---

## 17. 术语表

| 术语 | 含义 |
| --- | --- |
| 槽位（slot） | 一段素材在时间轴上占用的时长（默认 = `clip_beats × beat`） |
| D | `clipDuration`，模板定义的照片段时长 |
| T | `transitionDuration`，相邻两段的叠化重叠长度（会按最短段收敛） |
| 收敛 | `T = min(模板 T, min(d[i])/2)`，保证每段都有稳定画面 |
| 片尾定格 | slot 模式给末段多留 0.6 s，收尾更自然 |
| carrier | 驱动 compositor 逐帧回调的低成本黑帧视频轨 |
| 稳定期 | 一段素材"独占画面"的区间，即 `[start[i] + T, start[i+1])` |
| `video_mode` | `slot` = 裁到节拍槽位；`full` = 原速完整播放 |

---

## 附录 A：公式速查

```
beatInterval        = 60 / bpm
D                   = clip_beats × beatInterval
T_declared          = transition_beats × beatInterval
T                   = min(T_declared, min(d[i]) / 2)
d[i]                = D                      （照片；或 slot 模式的视频）
                    = V                      （full 模式的视频，V = 源时长）
d[n-1]             += 0.6                    （slot 模式片尾定格）
start[i]            = Σ_{j<i} (d[j] − T)
total               = Σ d[i] − (n−1) × T
timeline.duration   = total + 0.1            （carrier 长度）
完全切换时刻         = start[i] + T           （落在拍网格上 = 卡点）
段内进度 p(t)        = clamp((t − start) / (end − start), 0, 1)
叠化进度 q(t)        = clamp((t − visible[1].start) / T, 0, 1)
Ken Burns fill       = max(W/iw, H/ih)
zoom_in  scale       = fill × (1 + 0.22p)
zoom_out scale       = fill × (1.22 − 0.22p)
pan      scale       = fill × 1.15，dx = dir × maxX × (2p − 1)
```

## 附录 B：仓库信息

| 项 | 值 |
| --- | --- |
| 远端 | `git@github.com:Vision0030/GenerateVideoWithOneClick.git` |
| 主分支 | `main` |
| `.gitignore` | 忽略 `Pods/`、`build/`、`DerivedData/`、`xcuserdata/`、`*.xcuserstate`、`*.xcscmblueprint`、`*.xccheckout`、`*.hmap`、`*.ipa`、`*.dSYM`、`.DS_Store`；**保留 `Podfile.lock`**（保证依赖版本一致） |
| 克隆后第一步 | `pod install`，然后打开 `.xcworkspace` |

## 附录 C：需求变更记录（本次迭代）

| 变更 | 涉及文件 |
| --- | --- |
| 新增 `video_mode`：`slot` / `full` 两档视频策略 | `KBTemplate.h/.m`、`KBTimelineBuilder.m` |
| 新增模板「故事 · 原速完整」+ 伴奏 | `story_full.json`、`bgm_story_96bpm.m4a` |
| 排版模型重写：按段时长排版 + 转场收敛 + 片尾定格 | `KBTimelineBuilder.m:97` 起 |
| 修崩溃：素材并发加载越界 | `KBAssetLoader.m:102` |
| 修崩溃：封面 CGImageRef 过度释放 / 全黑 | `KBMediaAsset.m:64` |
| 修崩溃隐患：缩略图回写用弱引用 imageView | `ViewController.m:478` |
| 修交互：横向 chip / 缩略图条滑不动 | `ViewController.m:236`、`:265` |
| 新增：素材缩略图条长按拖动排序（UICollectionView + Drag/Drop delegate + 序号角标） | `ViewController.m:531` 起 |
| 文档：本文件 | `docs/TECHNICAL.md` |
| 测试：期望值按模板现算 + 视频策略断言 | `scripts/e2e_test.m` |
