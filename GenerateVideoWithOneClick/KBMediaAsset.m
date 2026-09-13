//
//  KBMediaAsset.m
//  GenerateVideoWithOneClick
//

#import "KBMediaAsset.h"
#import <ImageIO/ImageIO.h>

static CGImageRef _Nullable KBCreateThumbnail(CGImageSourceRef source, size_t maxPixel) {
    NSDictionary *options = @{
        (NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (NSString *)kCGImageSourceCreateThumbnailWithTransform    : @YES,
        (NSString *)kCGImageSourceThumbnailMaxPixelSize          : @(maxPixel),
    };
    return CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
}

@interface KBMediaAsset ()
@property (nonatomic, strong, readwrite, nullable) AVURLAsset *asset;
@property (nonatomic, strong, readwrite, nullable) UIImage *thumbnail;
// 异步出图期间必须自己持有 generator（AVFoundation 不保证持有），否则回调可能拿到失效数据
@property (nonatomic, strong, nullable) AVAssetImageGenerator *thumbnailGenerator;
@property (nonatomic, assign) NSUInteger thumbnailRequestID;
@end

@implementation KBMediaAsset

+ (nullable instancetype)photoAssetWithFileURL:(NSURL *)fileURL thumbnailMaxPixel:(size_t)maxPixel {
    CGImageSourceRef source = CGImageSourceCreateWithURL((CFURLRef)fileURL, NULL);
    if (!source) return nil;
    CGImageRef full = KBCreateThumbnail(source, 2400);
    CGImageRef thumb = full ? KBCreateThumbnail(source, maxPixel) : NULL;
    CFRelease(source);
    if (!full) return nil;

    KBMediaAsset *asset = [[KBMediaAsset alloc] init];
    asset->_type = KBMediaTypePhoto;
    asset->_image = [CIImage imageWithCGImage:full];
    asset->_thumbnail = thumb ? [UIImage imageWithCGImage:thumb scale:1.0 orientation:UIImageOrientationUp]
                              : [UIImage imageWithCGImage:full scale:6.0 orientation:UIImageOrientationUp];
    CGImageRelease(full);
    if (thumb) CGImageRelease(thumb);
    return asset;
}

+ (nullable instancetype)videoAssetWithFileURL:(NSURL *)fileURL {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:fileURL options:nil];
    if (!asset) return nil;
    // 占位校验：确认是可读的视频文件（轨道在构建时间轴时再异步加载）
    KBMediaAsset *media = [[KBMediaAsset alloc] init];
    media->_type = KBMediaTypeVideo;
    media->_videoURL = fileURL;
    media->_asset = asset;
    return media;
}

- (AVURLAsset *)asset {
    if (_type == KBMediaTypeVideo && !_asset) {
        _asset = [AVURLAsset URLAssetWithURL:_videoURL options:nil];
    }
    return _asset;
}

- (void)loadThumbnailWithCompletion:(void (^)(UIImage *_Nullable))completion {
    if (self.type == KBMediaTypePhoto || self.thumbnail) {
        completion(self.thumbnail);
        return;
    }

    // 重选素材会重建缩略图条，同一素材可能被重复请求：作废上一次，只认最新一次回调
    [self.thumbnailGenerator cancelAllCGImageGeneration];
    self.thumbnailRequestID += 1;
    NSUInteger requestID = self.thumbnailRequestID;

    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:[self asset]];
    generator.appliesPreferredTrackTransform = YES; // 封面按显示方向出图
    generator.maximumSize = CGSizeMake(400, 400);
    self.thumbnailGenerator = generator;

    __weak AVAssetImageGenerator *weakGenerator = generator;
    [generator generateCGImageAsynchronouslyForTime:CMTimeMake(300, 1000)
                                  completionHandler:^(CGImageRef _Nullable image, CMTime actualTime, NSError *_Nullable error) {
        // 回调里的 CGImage 不归调用方所有（文档：the generated image is not retained），
        // 不能 CFRelease，否则过度释放 → 后续 CFRelease 崩溃；UIImage 会自己 retain 一份。
        UIImage *thumb = image ? [UIImage imageWithCGImage:image] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (requestID != self.thumbnailRequestID) return; // 已被更新的请求取代
            if (thumb) self.thumbnail = thumb;
            if (self.thumbnailGenerator == weakGenerator) self.thumbnailGenerator = nil;
            completion(thumb ?: self.thumbnail);
        });
    }];
}

@end
