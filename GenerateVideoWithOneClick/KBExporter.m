//
//  KBExporter.m
//  GenerateVideoWithOneClick
//

#import "KBExporter.h"

#if TARGET_OS_IPHONE
#import <Photos/Photos.h>
#endif

@implementation KBExporter

+ (void)exportTimeline:(KBTimeline *)timeline
            completion:(void (^)(NSURL *_Nullable, NSError *_Nullable))completion
              progress:(nullable void (^)(float))progress {
    NSString *name = [NSString stringWithFormat:@"oneclick_%@.mp4", [NSUUID UUID].UUIDString];
    NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

    AVAssetExportSession *session =
        [[AVAssetExportSession alloc] initWithAsset:timeline.composition
                                          presetName:AVAssetExportPresetHighestQuality];
    if (!session) {
        completion(nil, [NSError errorWithDomain:@"KBExporter" code:-1
                                        userInfo:@{NSLocalizedDescriptionKey : @"创建导出会话失败"}]);
        return;
    }
    session.outputURL = outputURL;
    session.outputFileType = AVFileTypeMPEG4;
    session.videoComposition = timeline.videoComposition;
    session.audioMix = timeline.audioMix;
    session.shouldOptimizeForNetworkUse = YES;

    NSTimer *progressTimer = nil;
    if (progress) {
        __weak AVAssetExportSession *weakSession = session;
        progressTimer = [NSTimer timerWithTimeInterval:0.1
                                                 repeats:YES
                                               block:^(NSTimer *timer) {
            dispatch_async(dispatch_get_main_queue(), ^{
                progress(weakSession.progress);
            });
        }];
        [[NSRunLoop currentRunLoop] addTimer:progressTimer forMode:NSRunLoopCommonModes];
    }

    [session exportAsynchronouslyWithCompletionHandler:^{
        if (progressTimer) {
            [progressTimer invalidate];
            dispatch_async(dispatch_get_main_queue(), ^{
                progress(1.0f);
            });
        }
        switch (session.status) {
            case AVAssetExportSessionStatusCompleted:
                completion(outputURL, nil);
                break;
            default:
                completion(nil, session.error ?: [NSError errorWithDomain:@"KBExporter" code:-2
                                                                 userInfo:@{NSLocalizedDescriptionKey : @"导出失败"}]);
                break;
        }
    }];
}

#if TARGET_OS_IPHONE
+ (void)saveToPhotoLibrary:(NSURL *)fileURL
                completion:(void (^)(BOOL, NSError *_Nullable))completion {
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                         handler:^(PHAuthorizationStatus status) {
        if (status != PHAuthorizationStatusAuthorized &&
            status != PHAuthorizationStatusLimited) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, [NSError errorWithDomain:@"KBExporter" code:-3
                                            userInfo:@{NSLocalizedDescriptionKey : @"未获得相册写入权限"}]);
            });
            return;
        }
        [PHPhotoLibrary.sharedPhotoLibrary
            performChanges:^{
                PHAssetChangeRequest *request = [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
                if (!request) {
                    @throw [NSException exceptionWithName:@"KBExportSaveFailed"
                                                   reason:@"无法从视频文件创建相册资产"
                                                 userInfo:nil];
                }
            }
            completionHandler:^(BOOL success, NSError *_Nullable error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(success, error);
                });
            }];
    }];
}
#endif

@end
