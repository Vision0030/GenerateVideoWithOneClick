//
//  KBTemplate.h
//  GenerateVideoWithOneClick
//
//  模板 DSL：一份模板就是"时间轴结构 + 节拍 + 运镜 + 音乐"的纯数据描述。
//  渲染引擎吃「模板 + 用户素材」输出成片。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, KBMotionType) {
    KBMotionZoomIn   = 0,
    KBMotionPanRight = 1,
    KBMotionZoomOut  = 2,
    KBMotionPanLeft  = 3,
};

// 视频素材的处理方式
typedef NS_ENUM(NSUInteger, KBVideoClipMode) {
    KBVideoClipModeSlot = 0,   // 默认：裁到模板节拍槽位（源偏短则慢放补齐）
    KBVideoClipModeFull = 1,   // full：保持源时长原速完整播放，槽位长度随素材时长伸缩
};

@interface KBTemplate : NSObject

@property (nonatomic, copy, readonly) NSString *templateID;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *audioFileName;
@property (nonatomic, assign, readonly) CGFloat bpm;
@property (nonatomic, assign, readonly) NSUInteger clipBeats;       // 每段素材占的节拍数
@property (nonatomic, assign, readonly) CGFloat transitionBeats;    // 转场时长（0.5 = 半拍卡点）
@property (nonatomic, assign, readonly) CGSize renderSize;
@property (nonatomic, assign, readonly) NSInteger fps;
@property (nonatomic, assign, readonly) NSInteger order;        // 模板列表展示顺序（未声明排最后）
@property (nonatomic, strong, readonly) NSArray<NSNumber *> *motionCycle;
@property (nonatomic, assign, readonly) KBVideoClipMode videoMode; // 视频：按槽位裁剪 or 原速完整

// demo 由 bpm 现算节拍点；产品级模板应在制模阶段离线分析（如 librosa）写入 beats[]
- (NSTimeInterval)beatInterval;
- (NSTimeInterval)clipDuration;
- (NSTimeInterval)transitionDuration;
- (NSTimeInterval)totalDurationForClipCount:(NSUInteger)count;
- (KBMotionType)motionAtIndex:(NSUInteger)index;
- (BOOL)playsVideoInFull;
- (nullable NSURL *)audioURLInBundle:(NSBundle *)bundle;

+ (nullable instancetype)templateNamed:(NSString *)name inBundle:(NSBundle *)bundle;
/// 扫描 bundle 内所有模板 JSON（需声明 id / bpm / clip_beats），按 order 排序返回。
+ (NSArray<KBTemplate *> *)templatesInBundle:(NSBundle *)bundle;
- (nullable instancetype)initWithDictionary:(NSDictionary *)dict;

@end

NS_ASSUME_NONNULL_END
