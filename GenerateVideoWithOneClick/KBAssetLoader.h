//
//  KBAssetLoader.h
//  GenerateVideoWithOneClick
//
//  素材导入：PHPicker 多选（有序、图片+视频混选）+ 图片降采样解码。
//

#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import "KBMediaAsset.h"

NS_ASSUME_NONNULL_BEGIN

@interface KBAssetLoader : NSObject

+ (PHPickerConfiguration *)pickerConfigurationWithLimit:(NSInteger)limit;
/// 按选择顺序加载图片/视频素材；completion 在主线程回调。
+ (void)loadMediaFromResults:(NSArray<PHPickerResult *> *)results
                  completion:(void (^)(NSArray<KBMediaAsset *> *_Nullable assets,
                                       NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
