//
//  KBTimelineBuilder.h
//  GenerateVideoWithOneClick
//
//  时间轴构建：素材（照片+视频混排）+ 模板 → (AVComposition + videoComposition + audioMix)。
//  平台无关（iOS / macOS 同源），预览与导出共用构建结果。
//
//  视频处理策略：
//  - 每个视频素材占一条独立 composition 轨道，插入到其槽位起点；
//  - 模板 video_mode = slot（默认）：裁到节拍槽位，源时长 < 槽位 → scaleTimeRange 慢放补齐；
//  - 模板 video_mode = full：保持源时长、原速完整播放，槽位长度随素材时长伸缩；
//  - 视频原始音轨忽略（成片只保留模板 BGM）；
//  - 旋转元数据（preferredTransform）由 compositor 应用。
//
//  排版模型：第 i 段起点 start[i+1] = start[i] + duration[i] - T（T = 转场时长，
//  按最短段的一半收敛），相邻两段尾部叠化 T，切点落在节拍网格上。
//

#import <AVFoundation/AVFoundation.h>
#import "KBTemplate.h"
#import "KBMediaAsset.h"

NS_ASSUME_NONNULL_BEGIN

@interface KBTimeline : NSObject
@property (nonatomic, strong) AVComposition *composition;
@property (nonatomic, strong) AVMutableVideoComposition *videoComposition;
@property (nonatomic, strong, nullable) AVAudioMix *audioMix;
@property (nonatomic, assign) CMTime duration;

- (AVPlayerItem *)makePlayerItem;
@end

@interface KBTimelineBuilder : NSObject

/// 在后台队列构建时间轴；completion 可能在任意队列回调。
/// assets: 已按播放顺序排列的素材（照片/视频混排）；bgmURL: 传 nil 则无音乐。
+ (void)buildTimelineAsyncWithAssets:(NSArray<KBMediaAsset *> *)assets
                             template:(KBTemplate *)template
                               bgmURL:(nullable NSURL *)bgmURL
                           completion:(void (^)(KBTimeline *_Nullable timeline, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
