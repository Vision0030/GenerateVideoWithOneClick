//
//  KBMediaAsset.h
//  GenerateVideoWithOneClick
//
//  统一素材模型：照片（已解码 CIImage）或视频（本地文件 URL）。
//  模板时间轴按槽位顺序消费，两类素材在同一时间轴上混排。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, KBMediaType) {
    KBMediaTypePhoto = 0,
    KBMediaTypeVideo = 1,
};

@interface KBMediaAsset : NSObject

@property (nonatomic, assign, readonly) KBMediaType type;
@property (nonatomic, strong, readonly, nullable) CIImage *image;    // 照片：全图（方向已烘焙）
@property (nonatomic, strong, readonly, nullable) NSURL *videoURL;   // 视频：本地副本 URL（PHPicker 的 URL 回调结束后即失效，必须拷贝）
@property (nonatomic, strong, readonly, nullable) AVURLAsset *asset; // 视频：懒加载的资产对象
@property (nonatomic, strong, readonly, nullable) UIImage *thumbnail;

+ (nullable instancetype)photoAssetWithFileURL:(NSURL *)fileURL thumbnailMaxPixel:(size_t)maxPixel;
+ (nullable instancetype)videoAssetWithFileURL:(NSURL *)fileURL;

/// 视频封面（异步，主线程回调）；照片或已缓存封面时同步返回。同一个素材重复调用只认最新一次请求。
- (void)loadThumbnailWithCompletion:(void (^)(UIImage *_Nullable thumbnail))completion;

@end

NS_ASSUME_NONNULL_END
