//
//  KBVideoCompositor.m
//  GenerateVideoWithOneClick
//

#import "KBVideoCompositor.h"
#import <Metal/Metal.h>

@implementation KBClipSpec

+ (instancetype)specWithImage:(CIImage *)image start:(CMTime)start end:(CMTime)end motion:(KBMotionType)motion {
    KBClipSpec *spec = [[KBClipSpec alloc] init];
    spec.image = image;
    spec.isVideo = NO;
    spec.videoTrackID = kCMPersistentTrackID_Invalid;
    spec.videoTransform = CGAffineTransformIdentity;
    spec.start = start;
    spec.end = end;
    spec.motion = motion;
    return spec;
}

+ (instancetype)specWithVideoTrackID:(CMPersistentTrackID)trackID
                          transform:(CGAffineTransform)transform
                              start:(CMTime)start
                                end:(CMTime)end
                             motion:(KBMotionType)motion {
    KBClipSpec *spec = [[KBClipSpec alloc] init];
    spec.image = nil;
    spec.isVideo = YES;
    spec.videoTrackID = trackID;
    spec.videoTransform = transform;
    spec.start = start;
    spec.end = end;
    spec.motion = motion;
    return spec;
}

- (double)progressAtTime:(CMTime)t {
    double dur = CMTimeGetSeconds(CMTimeSubtract(self.end, self.start));
    if (dur <= 0) return 0;
    double p = CMTimeGetSeconds(CMTimeSubtract(t, self.start)) / dur;
    return MIN(1.0, MAX(0.0, p));
}

@end

@implementation KBCompositionInstruction

- (CMPersistentTrackID)passthroughTrackID {
    return kCMPersistentTrackID_Invalid; // 非直通指令
}

@end

@interface KBVideoCompositor ()
@property (nonatomic, strong, nullable) dispatch_queue_t renderQueue;
@property (nonatomic, assign, unsafe_unretained) AVVideoCompositionRenderContext *renderContext; // 系统持有，仅回调期间有效
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, strong, nullable) CIContext *ciContext;
@property (nonatomic, assign, nullable) CGColorSpaceRef outputColorSpace;
@end

@implementation KBVideoCompositor

- (void)dealloc {
    if (_renderQueue) {
        dispatch_sync(_renderQueue, ^{});
    }
    if (_outputColorSpace) {
        CGColorSpaceRelease(_outputColorSpace);
    }
}

#pragma mark - AVVideoCompositing

- (void)renderContextChanged:(AVVideoCompositionRenderContext *)newRenderContext {
    // 在串行队列上同步，避免与进行中的渲染竞争
    if (self.renderQueue) {
        dispatch_sync(self.renderQueue, ^{
            self->_renderContext = newRenderContext;
        });
    } else {
        _renderContext = newRenderContext;
    }
}

- (void)startVideoCompositionRequest:(AVAsynchronousVideoCompositionRequest *)request {
    if (!self.renderQueue) {
        self.renderQueue = dispatch_queue_create("com.oneclick.compositor.render", DISPATCH_QUEUE_SERIAL);
    }
    dispatch_async(self.renderQueue, ^{
        if (self->_cancelled) {
            [request finishCancelledRequest];
            return;
        }
        AVVideoCompositionRenderContext *context = self->_renderContext;
        if (!context) {
            [request finishWithError:[NSError errorWithDomain:AVFoundationErrorDomain
                                                          code:AVErrorNoImageAtTime
                                                      userInfo:nil]];
            return;
        }
        CVPixelBufferRef outputBuffer = [context newPixelBuffer];
        if (!outputBuffer) {
            [request finishWithError:[NSError errorWithDomain:@"KBCompositor" code:-1
                                                      userInfo:@{NSLocalizedDescriptionKey : @"分配输出帧失败"}]];
            return;
        }

        CIImage *frame = [self frameForRequest:request];
        [self.ciContext render:frame
                toCVPixelBuffer:outputBuffer
                         bounds:CGRectMake(0, 0, CVPixelBufferGetWidth(outputBuffer), CVPixelBufferGetHeight(outputBuffer))
                    colorSpace:self.outputColorSpace];

        if (self->_cancelled) {
            CVBufferRelease(outputBuffer);
            [request finishCancelledRequest];
            return;
        }
        [request finishWithComposedVideoFrame:outputBuffer];
        CVBufferRelease(outputBuffer);
    });
}

- (void)cancelAllAsyncVideoCompositionRequests {
    _cancelled = YES;
    if (_renderQueue) {
        // 排空渲染队列后返回，保证不再有 in-flight 的 finish 调用
        dispatch_sync(_renderQueue, ^{});
    }
}

#pragma mark - 渲染

- (CIContext *)ciContext {
    if (!_ciContext) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device) {
            _ciContext = [CIContext contextWithMTLDevice:device];
        } else {
            _ciContext = [[CIContext alloc] init];
        }
    }
    return _ciContext;
}

// 输出/输入像素格式：32BGRA
- (NSDictionary<NSString *, id> *)requiredPixelBufferAttributesForRenderContext {
    return @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
}

- (NSDictionary<NSString *, id> *)sourcePixelBufferAttributes {
    return @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
}

- (CGColorSpaceRef)outputColorSpace {
    if (!_outputColorSpace) {
        _outputColorSpace = CGColorSpaceCreateDeviceRGB();
    }
    return _outputColorSpace;
}

// 计算某一时刻的完整画面：找到 1~2 个可见片段，各自按运镜渲染，重叠期做叠化
- (CIImage *)frameForRequest:(AVAsynchronousVideoCompositionRequest *)request {
    KBCompositionInstruction *instruction = (KBCompositionInstruction *)request.videoCompositionInstruction;
    CMTime t = request.compositionTime;
    CGSize size = instruction.renderSize;

    NSMutableArray<KBClipSpec *> *visible = [NSMutableArray array];
    for (KBClipSpec *clip in instruction.clips) {
        if (CMTimeCompare(t, clip.start) >= 0 && CMTimeCompare(t, clip.end) < 0) {
            [visible addObject:clip];
        }
        if (visible.count == 2) break; // 最多两段重叠
    }

    if (visible.count == 0) {
        return [self blackImageOfSize:size];
    }

    CIImage *current = [self renderedImageForClip:visible[0] atTime:t size:size request:request];

    if (visible.count == 2) {
        // 叠化进度：后段起点 → 转场结束
        double transitionSeconds = CMTimeGetSeconds(instruction.transitionDuration);
        double q = transitionSeconds > 0
            ? CMTimeGetSeconds(CMTimeSubtract(t, visible[1].start)) / transitionSeconds
            : 1.0;
        q = MIN(1.0, MAX(0.0, q));
        CIImage *next = [self renderedImageForClip:visible[1] atTime:t size:size request:request];
        CIFilter *dissolve = [CIFilter filterWithName:@"CIDissolveTransition"];
        [dissolve setValue:current forKey:kCIInputImageKey];
        [dissolve setValue:next forKey:kCIInputTargetImageKey];
        [dissolve setValue:@(q) forKey:kCIInputTimeKey]; // CIDissolveTransition 用 inputTime 表示 0..1 进度
        current = dissolve.outputImage ?: current;
    }
    return current ?: [self blackImageOfSize:size];
}

// Ken Burns：aspect-fill 铺满画幅后，按段内进度做缩放/平移。
// 照片：解码好的 CIImage；视频：从 composition 轨道实时取帧（AVFoundation 已按
// composition 时间映射提供正确的源帧），先应用 preferredTransform 校正旋转。
- (CIImage *)renderedImageForClip:(KBClipSpec *)clip atTime:(CMTime)t size:(CGSize)size
                         request:(AVAsynchronousVideoCompositionRequest *)request {
    CIImage *image = nil;
    if (clip.isVideo) {
        CVPixelBufferRef buffer = [request sourceFrameByTrackID:clip.videoTrackID];
        if (buffer) {
            image = [CIImage imageWithCVImageBuffer:buffer];
            image = [image imageByApplyingTransform:clip.videoTransform];
            CGRect ext = image.extent;
            if (ext.origin.x != 0 || ext.origin.y != 0) {
                image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-ext.origin.x, -ext.origin.y)];
            }
        }
    } else {
        image = clip.image;
    }
    if (!image || image.extent.size.width < 1 || image.extent.size.height < 1) {
        return [self blackImageOfSize:size];
    }
    CGFloat iw = image.extent.size.width;
    CGFloat ih = image.extent.size.height;
    CGFloat fit = MAX(size.width / iw, size.height / ih);
    double p = [clip progressAtTime:t];

    CGFloat scale = fit;
    CGFloat dx = 0.0;
    switch (clip.motion) {
        case KBMotionZoomIn:
            scale = fit * (1.0 + 0.22 * p);
            break;
        case KBMotionZoomOut:
            scale = fit * (1.22 - 0.22 * p);
            break;
        case KBMotionPanLeft:
        case KBMotionPanRight: {
            scale = fit * 1.15; // 平移需要预留放大余量，避免露出黑边
            CGFloat maxX = MAX(0.0, (iw * scale - size.width) * 0.5);
            CGFloat dir = (clip.motion == KBMotionPanLeft) ? 1.0 : -1.0;
            dx = dir * maxX * (p - 0.5) * 2.0;
            break;
        }
    }

    // 先缩放（关于图像原点）再平移到居中位置
    CGAffineTransform transform =
        CGAffineTransformScale(CGAffineTransformMakeTranslation((size.width - iw * scale) / 2.0 + dx,
                                                                 (size.height - ih * scale) / 2.0),
                               scale, scale);
    return [image imageByApplyingTransform:transform];
}

- (CIImage *)blackImageOfSize:(CGSize)size {
    CIImage *color = [CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0]];
    return [color imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];
}

@end
