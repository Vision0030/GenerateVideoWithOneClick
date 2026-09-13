//
//  KBExporter.h
//  GenerateVideoWithOneClick
//
//  导出：KBTimeline → MP4（1080×1920 HEVC/H.264）→ 保存到相册。
//

#import <Foundation/Foundation.h>
#import "KBTimelineBuilder.h"

NS_ASSUME_NONNULL_BEGIN

@interface KBExporter : NSObject

/// 导出 MP4；progress 回调在主线程，completion 可能在任意队列。
+ (void)exportTimeline:(KBTimeline *)timeline
            completion:(void (^)(NSURL *_Nullable fileURL, NSError *_Nullable error))completion
              progress:(nullable void (^)(float progress))progress;

#if TARGET_OS_IPHONE
/// 保存视频到相册（仅 iOS）；自动请求"仅添加"权限。
+ (void)saveToPhotoLibrary:(NSURL *)fileURL
                completion:(void (^)(BOOL success, NSError *_Nullable error))completion;
#endif

@end

NS_ASSUME_NONNULL_END
