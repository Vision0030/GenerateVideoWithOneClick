//
//  KBTimelineBuilder.m
//  GenerateVideoWithOneClick
//

#import "KBTimelineBuilder.h"
#import "KBVideoCompositor.h"

static NSString *const kKBTimelineErrorDomain = @"KBTimelineErrorDomain";

@implementation KBTimeline

- (AVPlayerItem *)makePlayerItem {
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:self.composition];
    item.videoComposition = self.videoComposition;
    item.audioMix = self.audioMix;
    return item;
}

@end

@implementation KBTimelineBuilder

+ (dispatch_queue_t)buildQueue {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.oneclick.timeline.build", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

+ (void)buildTimelineAsyncWithAssets:(NSArray<KBMediaAsset *> *)assets
                             template:(KBTemplate *)template
                               bgmURL:(nullable NSURL *)bgmURL
                           completion:(void (^)(KBTimeline *_Nullable, NSError *_Nullable))completion {
    dispatch_async(self.buildQueue, ^{
        NSError *error = nil;
        KBTimeline *timeline = [self assembleTimelineWithAssets:assets template:template bgmURL:bgmURL error:&error];
        completion(timeline, error);
    });
}

+ (nullable KBTimeline *)assembleTimelineWithAssets:(NSArray<KBMediaAsset *> *)assets
                                           template:(KBTemplate *)tpl
                                             bgmURL:(nullable NSURL *)bgmURL
                                                error:(NSError **)error {
    if (assets.count == 0) {
        if (error) *error = [NSError errorWithDomain:kKBTimelineErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey : @"未选择素材"}];
        return nil;
    }

    // 1. 先异步加载轨道：full 模式下视频的真实时长要参与排版，BGM 一起拿
    dispatch_group_t loadGroup = dispatch_group_create();
    NSLock *loadLock = [[NSLock alloc] init]; // 多个加载回调并发写共享状态
    __block AVAssetTrack *bgmTrack = nil;
    __block NSError *loadError = nil;
    // 以素材下标为 key：KBMediaAsset 未实现 NSCopying，不能直接做字典 key
    __block NSMutableDictionary<NSNumber *, AVAssetTrack *> *videoTracks = [NSMutableDictionary dictionary];

    AVURLAsset *bgmAsset = bgmURL ? [AVURLAsset URLAssetWithURL:bgmURL options:nil] : nil;
    if (bgmAsset) {
        dispatch_group_enter(loadGroup);
        [bgmAsset loadTracksWithMediaType:AVMediaTypeAudio
                        completionHandler:^(NSArray<AVAssetTrack *> *_Nullable tracks, NSError *_Nullable e) {
            [loadLock lock];
            bgmTrack = tracks.firstObject;
            loadError = loadError ?: e;
            [loadLock unlock];
            dispatch_group_leave(loadGroup);
        }];
    }
    for (NSUInteger i = 0; i < assets.count; i++) {
        KBMediaAsset *asset = assets[i];
        if (asset.type == KBMediaTypeVideo) {
            dispatch_group_enter(loadGroup);
            [[asset asset] loadTracksWithMediaType:AVMediaTypeVideo
                                 completionHandler:^(NSArray<AVAssetTrack *> *_Nullable tracks, NSError *_Nullable e) {
                [loadLock lock];
                if (tracks.firstObject) {
                    videoTracks[@(i)] = tracks.firstObject;
                } else {
                    loadError = loadError ?: e ?: [NSError errorWithDomain:kKBTimelineErrorDomain code:-7
                                                                  userInfo:@{NSLocalizedDescriptionKey : @"视频轨道缺失"}];
                }
                [loadLock unlock];
                dispatch_group_leave(loadGroup);
            }];
        }
    }
    dispatch_group_wait(loadGroup, DISPATCH_TIME_FOREVER);
    if (loadError) {
        if (error) *error = loadError;
        return nil;
    }

    // 2. 排版：每段时长 + 起点。照片按节拍时长；视频看模板 video_mode：
    //    slot = 裁到节拍槽位（源偏短则慢放补齐）；full = 保持源时长、原速完整播放
    NSTimeInterval D = tpl.clipDuration;
    BOOL fullVideo = tpl.playsVideoInFull;
    NSUInteger count = assets.count;

    NSMutableArray<NSNumber *> *durations = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        KBMediaAsset *asset = assets[i];
        NSTimeInterval duration = D;
        if (asset.type == KBMediaTypeVideo && fullVideo) {
            AVAssetTrack *srcTrack = videoTracks[@(i)];
            if (!srcTrack) {
                if (error) *error = [NSError errorWithDomain:kKBTimelineErrorDomain code:-8
                                                    userInfo:@{NSLocalizedDescriptionKey :
                                                               [NSString stringWithFormat:@"第 %lu 个视频无画面轨道", (unsigned long)i + 1]}];
                return nil;
            }
            duration = CMTimeGetSeconds(srcTrack.timeRange.duration);
            if (duration < 0.1) duration = D; // 源时长异常（过短/未知）时退回节拍槽位
        }
        [durations addObject:@(duration)];
    }
    if (!fullVideo) {
        durations[count - 1] = @([durations[count - 1] doubleValue] + 0.6); // 片尾多留一点
    }

    // 转场时长按最短段收敛：保证每段都留有稳定画面，叠化不会盖满整段
    NSTimeInterval T = tpl.transitionDuration;
    for (NSNumber *duration in durations) {
        T = MIN(T, duration.doubleValue * 0.5);
    }
    T = MAX(0.0, T);

    NSMutableArray<NSNumber *> *starts = [NSMutableArray arrayWithCapacity:count];
    NSTimeInterval cursor = 0;
    for (NSUInteger i = 0; i < count; i++) {
        [starts addObject:@(cursor)];
        cursor += durations[i].doubleValue - T; // 与下一段重叠 T：切点落在节拍网格上 = 卡点
    }
    NSTimeInterval total = cursor + T; // 末段末尾（上面循环多减了一次 T）

    // 3. 生成 carrier 轨道：用一条低码率黑帧视频轨驱动 AVFoundation 按
    //    frameDuration 逐帧调用合成器（合成器不使用 carrier 的画面）。
    NSURL *carrierURL = [self writeCarrierVideoWithDuration:total + 0.1 error:error];
    if (!carrierURL) return nil;
    AVURLAsset *carrierAsset = [AVURLAsset URLAssetWithURL:carrierURL options:nil];

    dispatch_group_t carrierGroup = dispatch_group_create();
    __block AVAssetTrack *carrierTrack = nil;
    __block NSError *carrierError = nil;
    dispatch_group_enter(carrierGroup);
    [carrierAsset loadTracksWithMediaType:AVMediaTypeVideo
                        completionHandler:^(NSArray<AVAssetTrack *> *_Nullable tracks, NSError *_Nullable e) {
        carrierTrack = tracks.firstObject;
        carrierError = e;
        dispatch_group_leave(carrierGroup);
    }];
    dispatch_group_wait(carrierGroup, DISPATCH_TIME_FOREVER);
    if (!carrierTrack) {
        if (error) *error = carrierError ?: [NSError errorWithDomain:kKBTimelineErrorDomain code:-2
                                                           userInfo:@{NSLocalizedDescriptionKey : @"carrier 轨道缺失"}];
        return nil;
    }

    // 4. 组装 composition：视频 = carrier + 每个视频素材一条轨道；音频 = BGM 循环铺满
    AVMutableComposition *composition = [AVMutableComposition composition];
    NSError *insertError = nil;

    AVMutableCompositionTrack *carrierCompTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                               preferredTrackID:kCMPersistentTrackID_Invalid];
    CMTime carrierLength = CMTimeMakeWithSeconds(total + 0.1, 600);
    if (![carrierCompTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, carrierLength)
                                   ofTrack:carrierTrack
                                    atTime:kCMTimeZero
                                     error:&insertError]) {
        if (error) *error = insertError;
        return nil;
    }

    NSMutableArray<KBClipSpec *> *clips = [NSMutableArray array];
    NSMutableArray<NSNumber *> *sourceTrackIDs = [NSMutableArray arrayWithObject:@(carrierCompTrack.trackID)];

    for (NSUInteger i = 0; i < count; i++) {
        KBMediaAsset *asset = assets[i];
        CMTimeRange slot = CMTimeRangeMake(CMTimeMakeWithSeconds(starts[i].doubleValue, 600),
                                           CMTimeMakeWithSeconds(durations[i].doubleValue, 600));
        KBMotionType motion = [tpl motionAtIndex:i];

        if (asset.type == KBMediaTypeVideo) {
            AVAssetTrack *srcTrack = videoTracks[@(i)];
            if (!srcTrack) {
                if (error) *error = [NSError errorWithDomain:kKBTimelineErrorDomain code:-8
                                                    userInfo:@{NSLocalizedDescriptionKey :
                                                               [NSString stringWithFormat:@"第 %lu 个视频无画面轨道", (unsigned long)i + 1]}];
                return nil;
            }
            AVMutableCompositionTrack *compTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                        preferredTrackID:kCMPersistentTrackID_Invalid];
            if (fullVideo) {
                // 原速完整播放：整段源插入，不裁剪、不变速
                if (![compTrack insertTimeRange:srcTrack.timeRange
                                        ofTrack:srcTrack
                                         atTime:slot.start
                                          error:&insertError]) {
                    if (error) *error = insertError;
                    return nil;
                }
            } else {
                CMTime need = slot.duration;
                CMTimeRange take = CMTimeRangeMake(srcTrack.timeRange.start,
                                                   CMTimeMinimum(srcTrack.timeRange.duration, need));
                if (![compTrack insertTimeRange:take ofTrack:srcTrack atTime:slot.start error:&insertError]) {
                    if (error) *error = insertError;
                    return nil;
                }
                if (CMTimeCompare(take.duration, need) < 0) {
                    // 源片段偏短：慢放补满槽位
                    [compTrack scaleTimeRange:CMTimeRangeMake(slot.start, take.duration)
                                   toDuration:slot.duration];
                }
            }
            [sourceTrackIDs addObject:@(compTrack.trackID)];
            [clips addObject:[KBClipSpec specWithVideoTrackID:compTrack.trackID
                                                   transform:srcTrack.preferredTransform
                                                       start:slot.start
                                                         end:CMTimeRangeGetEnd(slot)
                                                      motion:motion]];
        } else {
            [clips addObject:[KBClipSpec specWithImage:asset.image
                                                 start:slot.start
                                                   end:CMTimeRangeGetEnd(slot)
                                                motion:motion]];
        }
    }

    AVMutableAudioMix *audioMix = nil;
    if (bgmTrack) {
        AVMutableCompositionTrack *audioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                            preferredTrackID:kCMPersistentTrackID_Invalid];
        CMTime cursor = kCMTimeZero;
        CMTime remaining = CMTimeMakeWithSeconds(total, 600);
        CMTime bgmLength = bgmTrack.timeRange.duration;
        while (CMTimeCompare(remaining, kCMTimeZero) > 0) {
            CMTime chunk = CMTimeMinimum(remaining, bgmLength);
            if (![audioTrack insertTimeRange:CMTimeRangeMake(bgmTrack.timeRange.start, chunk)
                                     ofTrack:bgmTrack
                                      atTime:cursor
                                         error:&insertError]) {
                if (error) *error = insertError;
                return nil;
            }
            cursor = CMTimeAdd(cursor, chunk);
            remaining = CMTimeSubtract(remaining, chunk);
        }

        audioMix = [AVMutableAudioMix audioMix];
        AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:audioTrack];
        [params setVolumeRampFromStartVolume:0.0 toEndVolume:1.0 timeRange:CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(0.3, 600))];
        [params setVolumeRampFromStartVolume:1.0 toEndVolume:0.0 timeRange:CMTimeRangeMake(CMTimeMakeWithSeconds(MAX(0, total - 1.0), 600), CMTimeMakeWithSeconds(1.0, 600))];
        audioMix.inputParameters = @[params];
    }

    // 5. videoComposition：一条覆盖全片的自定义指令，携带全部渲染配置
    KBCompositionInstruction *instruction = [[KBCompositionInstruction alloc] init];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, carrierLength);
    instruction.requiredSourceTrackIDs = sourceTrackIDs;
    instruction.containsTweening = YES; // 存在叠化插值，禁止帧缓存复用
    instruction.enablePostProcessing = NO;
    instruction.clips = clips;
    instruction.renderSize = tpl.renderSize;
    instruction.transitionDuration = CMTimeMakeWithSeconds(T, 600);

    AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
    videoComposition.renderSize = tpl.renderSize;
    videoComposition.frameDuration = CMTimeMake(1, (int32_t)tpl.fps);
    videoComposition.customVideoCompositorClass = [KBVideoCompositor class];
    videoComposition.instructions = @[instruction];

    KBTimeline *timeline = [[KBTimeline alloc] init];
    timeline.composition = composition;
    timeline.videoComposition = videoComposition;
    timeline.audioMix = audioMix;
    timeline.duration = carrierLength;
    return timeline;
}

#pragma mark - Carrier 视频

// 生成低分辨率黑帧视频（270x480 @2fps H.264），仅用于承载视频轨道
+ (nullable NSURL *)writeCarrierVideoWithDuration:(NSTimeInterval)duration error:(NSError **)error {
    const size_t w = 270, h = 480;
    const int32_t fps = 2;
    int64_t frameCount = (int64_t)ceil(duration * fps) + 2;

    NSString *name = [NSString stringWithFormat:@"carrier_%@.mp4", [NSUUID UUID].UUIDString];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];

    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:error];
    if (!writer) return nil;

    NSDictionary *videoSettings = @{
        AVVideoCodecKey : AVVideoCodecTypeH264,
        AVVideoWidthKey  : @(w),
        AVVideoHeightKey : @(h),
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                   outputSettings:videoSettings];
    NSDictionary *bufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey           : @(w),
        (NSString *)kCVPixelBufferHeightKey          : @(h),
        (NSString *)kCVPixelBufferCGImageCompatibilityKey : @YES,
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                                           sourcePixelBufferAttributes:bufferAttributes];
    [writer addInput:input];
    writer.shouldOptimizeForNetworkUse = YES;

    if (![writer startWriting]) {
        if (error) *error = writer.error ?: [NSError errorWithDomain:kKBTimelineErrorDomain code:-3 userInfo:@{NSLocalizedDescriptionKey : @"carrier startWriting 失败"}];
        return nil;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    // 复用同一块黑帧 buffer
    CVPixelBufferRef blackBuffer = NULL;
    CVReturn cvr = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                       (__bridge CFDictionaryRef)bufferAttributes, &blackBuffer);
    if (cvr != kCVReturnSuccess || !blackBuffer) {
        if (error) *error = [NSError errorWithDomain:kKBTimelineErrorDomain code:-4 userInfo:@{NSLocalizedDescriptionKey : @"黑帧 buffer 创建失败"}];
        return nil;
    }
    CVPixelBufferLockBaseAddress(blackBuffer, 0);
    memset(CVPixelBufferGetBaseAddress(blackBuffer), 0,
           CVPixelBufferGetBytesPerRow(blackBuffer) * CVPixelBufferGetHeight(blackBuffer));
    CVPixelBufferUnlockBaseAddress(blackBuffer, 0);

    BOOL appendFailed = NO;
    for (int64_t i = 0; i < frameCount; i++) {
        NSInteger waitAttempts = 0;
        while (!input.readyForMoreMediaData) {
            if (writer.status == AVAssetWriterStatusFailed) { appendFailed = YES; break; }
            if (++waitAttempts > 2000) { appendFailed = YES; break; } // ~10s 超时
            usleep(5000);
        }
        if (appendFailed) break;
        if (![adaptor appendPixelBuffer:blackBuffer withPresentationTime:CMTimeMake(i, fps)]) {
            appendFailed = YES;
            break;
        }
    }
    CVBufferRelease(blackBuffer);
    [input markAsFinished];

    if (appendFailed || writer.status == AVAssetWriterStatusFailed) {
        [writer cancelWriting];
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        if (error) *error = writer.error ?: [NSError errorWithDomain:kKBTimelineErrorDomain code:-5 userInfo:@{NSLocalizedDescriptionKey : @"carrier 写帧失败"}];
        return nil;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL finishOK = NO;
    [writer finishWritingWithCompletionHandler:^{
        finishOK = (writer.status == AVAssetWriterStatusCompleted);
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (!finishOK) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        if (error) *error = writer.error ?: [NSError errorWithDomain:kKBTimelineErrorDomain code:-6 userInfo:@{NSLocalizedDescriptionKey : @"carrier finishWriting 失败"}];
        return nil;
    }
    return url;
}

@end
