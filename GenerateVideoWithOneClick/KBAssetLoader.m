//
//  KBAssetLoader.m
//  GenerateVideoWithOneClick
//

#import "KBAssetLoader.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// 收集首个错误：多个加载回调并发写入，写入统一在 lock 保护下进行。
// 用对象持有而不是 NSError ** 出参，避免 block 捕获 __autoreleasing 临时指针。
@interface KBLoadErrorBox : NSObject
@property (nonatomic, strong, nullable) NSError *error;
@end

@implementation KBLoadErrorBox
@end

@implementation KBAssetLoader

+ (PHPickerConfiguration *)pickerConfigurationWithLimit:(NSInteger)limit {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[[PHPickerFilter imagesFilter],
                                                                 [PHPickerFilter videosFilter]]];
    config.selectionLimit = limit;
    config.selection = PHPickerConfigurationSelectionOrdered; // 保持用户点选顺序（iOS 15+）
    return config;
}

#pragma mark - 单个结果加载

// 图片路径：直接解码；读不出来（例如 provider 只注册了视频表示）则退回视频路径
+ (void)loadImageResult:(PHPickerResult *)result
                  index:(NSUInteger)index
                   lock:(NSLock *)lock
                 loaded:(NSMutableDictionary<NSNumber *, KBMediaAsset *> *)loaded
               errorBox:(KBLoadErrorBox *)errorBox
                  group:(dispatch_group_t)group {
    [result.itemProvider loadFileRepresentationForTypeIdentifier:UTTypeImage.identifier
                                               completionHandler:^(NSURL *_Nullable url, NSError *_Nullable error) {
        KBMediaAsset *asset = url ? [KBMediaAsset photoAssetWithFileURL:url thumbnailMaxPixel:400] : nil;
        if (!asset) {
            [self loadVideoResult:result index:index lock:lock loaded:loaded errorBox:errorBox group:group];
            return;
        }
        [lock lock];
        loaded[@(index)] = asset;
        [lock unlock];
        dispatch_group_leave(group);
    }];
}

// 视频路径：拷贝到自有临时目录（itemProvider 回调结束后源 URL 即被回收）
+ (void)loadVideoResult:(PHPickerResult *)result
                  index:(NSUInteger)index
                   lock:(NSLock *)lock
                 loaded:(NSMutableDictionary<NSNumber *, KBMediaAsset *> *)loaded
               errorBox:(KBLoadErrorBox *)errorBox
                  group:(dispatch_group_t)group {
    [result.itemProvider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier
                                               completionHandler:^(NSURL *_Nullable url, NSError *_Nullable error) {
        KBMediaAsset *asset = nil;
        NSError *loadError = error;
        if (!loadError && url) {
            NSURL *copyURL = [NSURL fileURLWithPath:
                [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"pick_%@.%@",
                        [NSUUID UUID].UUIDString, url.pathExtension ?: @"mov"]]];
            NSError *copyError = nil;
            if ([[NSFileManager defaultManager] copyItemAtURL:url toURL:copyURL error:&copyError]) {
                asset = [KBMediaAsset videoAssetWithFileURL:copyURL];
            } else {
                loadError = copyError;
            }
        }
        if (!asset && !loadError) {
            loadError = [NSError errorWithDomain:@"KBAssetLoader" code:-2
                                        userInfo:@{NSLocalizedDescriptionKey :
                                                   [NSString stringWithFormat:@"第 %lu 个素材读取失败", (unsigned long)index + 1]}];
        }
        [lock lock];
        if (asset) loaded[@(index)] = asset;
        if (loadError && !errorBox.error) errorBox.error = loadError;
        [lock unlock];
        dispatch_group_leave(group);
    }];
}

// 按 itemProvider 声明的类型选主路径：图片优先（实况照片取静帧），否则按视频处理
+ (void)loadOneResult:(PHPickerResult *)result
                index:(NSUInteger)index
                 lock:(NSLock *)lock
               loaded:(NSMutableDictionary<NSNumber *, KBMediaAsset *> *)loaded
             errorBox:(KBLoadErrorBox *)errorBox
                group:(dispatch_group_t)group {
    if ([result.itemProvider hasItemConformingToTypeIdentifier:UTTypeImage.identifier]) {
        [self loadImageResult:result index:index lock:lock loaded:loaded errorBox:errorBox group:group];
    } else {
        [self loadVideoResult:result index:index lock:lock loaded:loaded errorBox:errorBox group:group];
    }
}

+ (void)loadMediaFromResults:(NSArray<PHPickerResult *> *)results
                  completion:(void (^)(NSArray<KBMediaAsset *> *_Nullable, NSError *_Nullable))completion {
    if (results.count == 0) {
        completion(nil, nil);
        return;
    }

    NSUInteger count = results.count;
    // 加载回调是并发的、完成顺序不定，所以按下标写字典而不是写数组
    // （NSMutableArray 的下标赋值只在 index == count 时等价 append，乱序写会越界崩溃）
    // 全部回调结束后再按 index 收敛成数组，顺序即用户点选顺序
    NSMutableDictionary<NSNumber *, KBMediaAsset *> *loaded = [NSMutableDictionary dictionaryWithCapacity:count];
    NSLock *lock = [[NSLock alloc] init];
    KBLoadErrorBox *errorBox = [[KBLoadErrorBox alloc] init];
    dispatch_group_t group = dispatch_group_create();

    for (NSUInteger index = 0; index < count; index++) {
        PHPickerResult *result = results[index];
        dispatch_group_enter(group);
        [self loadOneResult:result index:index lock:lock loaded:loaded errorBox:errorBox group:group];
    }

    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<KBMediaAsset *> *ordered = nil;
        [lock lock];
        NSMutableArray<KBMediaAsset *> *collected = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; i++) {
            KBMediaAsset *asset = loaded[@(i)];
            if (asset) [collected addObject:asset];
        }
        NSError *error = errorBox.error;
        [lock unlock];
        if (collected.count) ordered = collected;

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(ordered, error);
        });
    });
}

@end
