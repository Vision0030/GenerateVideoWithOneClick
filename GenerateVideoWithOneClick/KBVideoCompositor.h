//
//  KBVideoCompositor.h
//  GenerateVideoWithOneClick
//
//  自定义视频合成器：Ken Burns 运镜 + 节拍点叠化转场，CoreImage 渲染。
//  预览（AVPlayer）与导出（AVAssetExportSession）共用本类，保证所见即所得。
//
//  设计要点：渲染配置（素材排布、运镜、转场时长）全部挂在自定义
//  KBCompositionInstruction 上。AVFoundation 在播放/导出时自行实例化
//  compositor，每个 AVAsynchronousVideoCompositionRequest 都携带当前
//  instruction，因此无需任何全局单例或静态状态交换。
//

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import "KBTemplate.h"

NS_ASSUME_NONNULL_BEGIN

// 一个素材片段在成片时间轴上的排布
@interface KBClipSpec : NSObject
@property (nonatomic, strong, nullable) CIImage *image;             // 照片：已解码全图
@property (nonatomic, assign) BOOL isVideo;                         // 视频：从轨道实时取帧
@property (nonatomic, assign) CMPersistentTrackID videoTrackID;     // 视频所在的 composition 轨道
@property (nonatomic, assign) CGAffineTransform videoTransform;     // 视频 preferredTransform（旋转元数据）
@property (nonatomic, assign) CMTime start;         // 成片时间轴起点（含与前段的重叠区）
@property (nonatomic, assign) CMTime end;           // 终点
@property (nonatomic, assign) KBMotionType motion;  // 运镜类型
- (double)progressAtTime:(CMTime)t;                 // 段内进度 0..1
+ (instancetype)specWithImage:(CIImage *)image
                       start:(CMTime)start
                         end:(CMTime)end
                       motion:(KBMotionType)motion;
+ (instancetype)specWithVideoTrackID:(CMPersistentTrackID)trackID
                          transform:(CGAffineTransform)transform
                              start:(CMTime)start
                                end:(CMTime)end
                             motion:(KBMotionType)motion;
@end

// 携带渲染配置的自定义指令
@interface KBCompositionInstruction : NSObject <AVVideoCompositionInstruction>
@property (nonatomic, assign) CMTimeRange timeRange;
@property (nonatomic, strong, nullable) NSArray<NSValue *> *requiredSourceTrackIDs;
@property (nonatomic, assign) BOOL containsTweening;
@property (nonatomic, assign) BOOL enablePostProcessing;
// —— 渲染配置 ——
@property (nonatomic, copy) NSArray<KBClipSpec *> *clips;
@property (nonatomic, assign) CGSize renderSize;
@property (nonatomic, assign) CMTime transitionDuration;
@end

@interface KBVideoCompositor : NSObject <AVVideoCompositing>
@end

NS_ASSUME_NONNULL_END
