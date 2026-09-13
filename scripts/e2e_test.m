//
//  e2e_test.m — macOS 命令行端到端验证（照片+视频混剪版）
//  5 张测试图 + 1 个短测试视频（0.8s，占第 4 槽位）
//  → KBTimelineBuilder → KBVideoCompositor 渲染 → AVAssetExportSession 导出
//  校验：时长、音视频轨道、节拍点画面切换（含视频槽位）、转场叠化、视频处理模式
//  （slot 模板拉伸到槽位 / full 模板保持源时长）、封面生成
//
//  用法：e2e_test <资源目录> [模板名]      模板名默认 travel_fast
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import "KBTemplate.h"
#import "KBMediaAsset.h"
#import "KBTimelineBuilder.h"
#import "KBExporter.h"

static int g_failures = 0;

#define CHECK(cond, name, ...) do { \
    BOOL c_ = !!(cond); \
    NSString *d_ = [NSString stringWithFormat:__VA_ARGS__]; \
    printf("%s %s %s\n", c_ ? "PASS" : "FAIL", (name).UTF8String, d_.UTF8String); \
    if (!c_) g_failures++; \
} while (0)

// 测试视频占第 4 槽位
static const NSUInteger kVideoSlot = 3;
static const uint8_t kVideoR = 26, kVideoG = 156, kVideoB = 140; // teal

// 6 张测试图的手工配色：任意两色通道差之和 > 150，且都与测试视频的 teal 拉开距离。
// 整图纯色 → 采样点落在画面任何位置都能取到准确底色（运镜缩放/平移不影响取色）。
static const uint8_t kPhotoPalette[6][3] = {
    {220, 50, 50},   // 红
    {230, 180, 40},  // 黄
    {60, 190, 90},   // 绿
    {50, 90, 230},   // 蓝
    {170, 70, 210},  // 紫
    {250, 120, 180}, // 粉
};

// 生成纯色测试图（各不相同，便于按帧判别）并写为 PNG
static NSURL *writeTestImage(NSUInteger index, CGFloat w, CGFloat h) {
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, rgb, kCGImageAlphaPremultipliedLast);
    const uint8_t *c = kPhotoPalette[index % 6];
    CGContextSetRGBFillColor(ctx, c[0] / 255.0, c[1] / 255.0, c[2] / 255.0, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGImageRef cg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"testimg_%lu.png", (unsigned long)index]];
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((CFURLRef)url, (CFStringRef)@"public.png", 1, NULL);
    CGImageDestinationAddImage(dest, cg, NULL);
    CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(cg);
    CGColorSpaceRelease(rgb);
    return url;
}

// 生成 0.8s teal 纯色测试视频（720x1280@30，短于槽位时长 → 触发慢放补齐）
static NSURL *writeTestVideo(NSError **error) {
    const size_t w = 720, h = 1280;
    const int32_t fps = 30;
    const double dur = 0.8;
    int64_t frameCount = (int64_t)(dur * fps);

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"testvideo.mov"];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSURL *url = [NSURL fileURLWithPath:path];

    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeQuickTimeMovie error:error];
    if (!writer) return nil;
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                   outputSettings:@{
        AVVideoCodecKey : AVVideoCodecTypeH264,
        AVVideoWidthKey : @(w), AVVideoHeightKey : @(h),
    }];
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                                           sourcePixelBufferAttributes:@{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey : @(w), (NSString *)kCVPixelBufferHeightKey : @(h),
    }];
    [writer addInput:input];
    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];

    CVPixelBufferRef buf = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, NULL, &buf);
    CVPixelBufferLockBaseAddress(buf, 0);
    uint8_t *px = (uint8_t *)CVPixelBufferGetBaseAddress(buf);
    size_t bpr = CVPixelBufferGetBytesPerRow(buf);
    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            uint8_t *p = px + y * bpr + x * 4;
            p[0] = kVideoB; p[1] = kVideoG; p[2] = kVideoR; p[3] = 255; // BGRA
        }
    }
    CVPixelBufferUnlockBaseAddress(buf, 0);

    for (int64_t i = 0; i < frameCount; i++) {
        while (!input.readyForMoreMediaData) usleep(5000);
        [adaptor appendPixelBuffer:buf withPresentationTime:CMTimeMake(i, fps)];
    }
    CVBufferRelease(buf);
    [input markAsFinished];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        if (error) *error = writer.error;
        return nil;
    }
    return url;
}

// 从导出视频中取帧，返回左上角背景区平均颜色
static BOOL extractCornerColor(NSURL *url, CMTime at, uint8_t *r, uint8_t *g, uint8_t *b) {
    AVAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    gen.appliesPreferredTrackTransform = NO;
    gen.requestedTimeToleranceBefore = kCMTimeZero;
    gen.requestedTimeToleranceAfter = CMTimeMake(1, 600);
    CGImageRef frame = [gen copyCGImageAtTime:at actualTime:nil error:nil];
    if (!frame) return NO;

    size_t sw = 16, sh = 16;
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, sw, sh, 8, sw * 4, rgb, kCGImageAlphaPremultipliedLast);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, sw, sh), frame);
    uint8_t *px = (uint8_t *)CGBitmapContextGetData(ctx);
    long sr = 0, sg = 0, sb = 0, n = 0;
    for (size_t y = 1; y < 5; y++) {
        for (size_t x = 1; x < 5; x++) {
            uint8_t *p = px + (y * sw + x) * 4;
            sr += p[0]; sg += p[1]; sb += p[2]; n++;
        }
    }
    *r = (uint8_t)(sr / n); *g = (uint8_t)(sg / n); *b = (uint8_t)(sb / n);
    CGContextRelease(ctx);
    CGColorSpaceRelease(rgb);
    CGImageRelease(frame);
    return YES;
}

// 取 UIImage 中心区域平均颜色（BGRA 上下文，p[0]=R）
static BOOL sampleImageColor(UIImage *image, uint8_t *r, uint8_t *g, uint8_t *b) {
    CGImageRef cg = image.CGImage;
    if (!cg) return NO;
    const size_t sw = 8, sh = 8;
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, sw, sh, 8, sw * 4, rgb, kCGImageAlphaPremultipliedLast);
    if (!ctx) {
        CGColorSpaceRelease(rgb);
        return NO;
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, sw, sh), cg);
    uint8_t *px = (uint8_t *)CGBitmapContextGetData(ctx);
    long sr = 0, sg = 0, sb = 0, n = 0;
    for (size_t y = 2; y < 6; y++) {
        for (size_t x = 2; x < 6; x++) {
            uint8_t *p = px + (y * sw + x) * 4;
            sr += p[0]; sg += p[1]; sb += p[2]; n++;
        }
    }
    *r = (uint8_t)(sr / n); *g = (uint8_t)(sg / n); *b = (uint8_t)(sb / n);
    CGContextRelease(ctx);
    CGColorSpaceRelease(rgb);
    return YES;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *resDir = argc > 1 ? @(argv[1]) : @".";
        NSString *tplName = argc > 2 ? @(argv[2]) : @"travel_fast";
        printf("=== 一键成片 渲染链路端到端验证（照片+视频混剪）· 模板 %s ===\n", tplName.UTF8String);
        NSBundle *resBundle = [NSBundle bundleWithPath:resDir];

        KBTemplate *tpl = [KBTemplate templateNamed:tplName inBundle:resBundle];
        CHECK(tpl != nil, @"模板解析", @"%@.json", tplName);
        if (!tpl) return 1;
        CHECK(tpl.bpm > 0 && fabs(tpl.beatInterval - 60.0 / tpl.bpm) < 1e-9, @"节拍间隔",
              @"bpm=%g → %.6fs", tpl.bpm, tpl.beatInterval);

        // 1. 混排素材：photo photo photo [video] photo photo
        NSMutableArray<KBMediaAsset *> *assets = [NSMutableArray array];
        for (NSUInteger i = 0; i < 6; i++) {
            if (i == kVideoSlot) {
                NSError *verr = nil;
                NSURL *vURL = writeTestVideo(&verr);
                CHECK(vURL != nil, @"测试视频生成", @"%@", verr.localizedDescription ?: @"0.8s teal 720x1280");
                if (!vURL) return 1;
                KBMediaAsset *va = [KBMediaAsset videoAssetWithFileURL:vURL];
                [assets addObject:va];
            } else {
                NSURL *iURL = writeTestImage(i, 1200, 1600);
                KBMediaAsset *ia = [KBMediaAsset photoAssetWithFileURL:iURL thumbnailMaxPixel:400];
                CHECK(ia != nil, @"测试图生成", @"slot %lu", (unsigned long)i);
                [assets addObject:ia];
            }
        }

        // 2. 构建时间轴
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block KBTimeline *timeline = nil;
        __block NSError *buildError = nil;
        NSURL *bgm = [tpl audioURLInBundle:resBundle];
        CHECK(bgm != nil, @"BGM 资源", @"%@", bgm.absoluteString ?: @"(nil)");
        [KBTimelineBuilder buildTimelineAsyncWithAssets:assets template:tpl bgmURL:bgm
                                             completion:^(KBTimeline *t, NSError *e) {
            timeline = t; buildError = e;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        CHECK(timeline != nil && !buildError, @"时间轴构建", @"%@", buildError.localizedDescription ?: @"OK");
        if (!timeline) return 1;

        double total = CMTimeGetSeconds(timeline.duration);

        // 排版期望：照片 = 节拍槽位 D；full 模板的视频槽位 = 源时长（原速完整播放）。
        // 转场 T 按最短段的一半收敛，starts[i+1] = starts[i] + durations[i] - T。
        double D = tpl.clipDuration;
        BOOL fullVideo = tpl.playsVideoInFull;
        const double kTestVideoDuration = 0.8;
        double durations[6];
        for (NSUInteger i = 0; i < 6; i++) {
            durations[i] = (i == kVideoSlot && fullVideo) ? kTestVideoDuration : D;
        }
        if (!fullVideo) durations[5] += 0.6; // 片尾定格
        double T = tpl.transitionDuration;
        for (NSUInteger i = 0; i < 6; i++) T = MIN(T, durations[i] * 0.5);
        double starts[6];
        double cursor = 0;
        for (NSUInteger i = 0; i < 6; i++) {
            starts[i] = cursor;
            cursor += durations[i] - T;
        }
        double expect = cursor + T;
        CHECK(fabs(total - expect) < 0.2, @"总时长", @"%.3fs (期望 %.3fs)", total, expect);

        // 3. 预览通路
        AVPlayerItem *item = [timeline makePlayerItem];
        CHECK(item != nil && item.videoComposition != nil, @"预览 PlayerItem", @"videoComposition 已挂载");

        // 4. 导出
        __block NSURL *outURL = nil;
        __block NSError *exportError = nil;
        [KBExporter exportTimeline:timeline completion:^(NSURL *u, NSError *e) {
            outURL = u; exportError = e;
            dispatch_semaphore_signal(sem);
        } progress:nil];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        CHECK(outURL != nil && !exportError, @"导出 MP4", @"%@",
              exportError.localizedDescription ?: outURL.lastPathComponent);
        if (!outURL) return 1;

        // 5. 输出资产校验
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:outURL options:nil];
        dispatch_group_t g = dispatch_group_create();
        __block NSArray<AVAssetTrack *> *vTracks = nil, *aTracks = nil;
        dispatch_group_enter(g);
        [asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> *t, NSError *e) { vTracks = t; dispatch_group_leave(g); }];
        dispatch_group_enter(g);
        [asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> *t, NSError *e) { aTracks = t; dispatch_group_leave(g); }];
        dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
        CHECK(vTracks.count == 1, @"视频轨道合并", @"count=%lu %.0fx%.0f@%.3fs",
              (unsigned long)vTracks.count,
              vTracks.firstObject.naturalSize.width, vTracks.firstObject.naturalSize.height,
              CMTimeGetSeconds(vTracks.firstObject.timeRange.duration));
        CGSize ns = vTracks.firstObject.naturalSize;
        CHECK(fabs(ns.width - 1080) < 2 && fabs(ns.height - 1920) < 2, @"输出分辨率 1080x1920", @"%.0fx%.0f", ns.width, ns.height);
        CHECK(aTracks.count == 1, @"音频轨道(BGM)", @"count=%lu dur=%.3fs",
              (unsigned long)aTracks.count, CMTimeGetSeconds(aTracks.firstObject.timeRange.duration));

        // 6. 节拍点画面校验（含视频槽位）：T ≤ 段长一半 ⇒ 段中点必在稳定期（首尾转场之间）
        uint8_t r[6], gg[6], b[6];
        BOOL allExtracted = YES;
        for (NSUInteger i = 0; i < 6; i++) {
            double center = starts[i] + durations[i] * 0.5;
            if (!extractCornerColor(outURL, CMTimeMakeWithSeconds(center, 600), &r[i], &gg[i], &b[i])) allExtracted = NO;
        }
        CHECK(allExtracted, @"取帧", @"6 个节拍段中心帧全部提取");
        BOOL distinct = YES;
        for (NSUInteger i = 0; i < 6 && distinct; i++) {
            for (NSUInteger j = i + 1; j < 6; j++) {
                int dr = abs(r[i]-r[j]) + abs(gg[i]-gg[j]) + abs(b[i]-b[j]);
                if (dr < 60) { distinct = NO; printf("  段 %lu vs %lu 颜色过近: (%d,%d,%d) vs (%d,%d,%d) d=%d\n",
                    (unsigned long)i, (unsigned long)j, r[i],gg[i],b[i], r[j],gg[j],b[j], dr); }
            }
        }
        CHECK(distinct, @"节拍点画面切换", @"6 段画面在各自稳定期颜色互异 = 卡点切镜生效");
        printf("  段中心色: #%02x%02x%02x #%02x%02x%02x #%02x%02x%02x #%02x%02x%02x #%02x%02x%02x #%02x%02x%02x\n",
               r[0],gg[0],b[0], r[1],gg[1],b[1], r[2],gg[2],b[2], r[3],gg[3],b[3], r[4],gg[4],b[4], r[5],gg[5],b[5]);

        // 7. 视频槽位画面 = 测试视频的 teal 色
        //    slot 模板：0.8s 源慢放铺满槽位；full 模板：原速完整播放
        uint8_t er = (uint8_t)kVideoR, eg = (uint8_t)kVideoG, eb = (uint8_t)kVideoB;
        int dv = abs(r[kVideoSlot]-er) + abs(gg[kVideoSlot]-eg) + abs(b[kVideoSlot]-eb);
        CHECK(dv < 90, fullVideo ? @"视频原速完整播放" : @"视频槽位渲染(慢放补齐)",
              @"帧(%d,%d,%d) vs 源(%d,%d,%d) d=%d",
              r[kVideoSlot], gg[kVideoSlot], b[kVideoSlot], er, eg, eb, dv);

        // 7b. 视频素材在 composition 轨道里的结束时间（轨道 timeRange 从 0 起算到末段末尾）：
        //     slot = 槽位起点 + 槽位时长（被拉伸铺满），full = 槽位起点 + 源时长（原速未拉伸）
        double expectedVideoTrack = fullVideo ? kTestVideoDuration : durations[kVideoSlot];
        double videoTrackDuration = -1;
        for (AVMutableCompositionTrack *t in timeline.composition.tracks) {
            if (![t.mediaType isEqualToString:AVMediaTypeVideo]) continue;
            double td = CMTimeGetSeconds(t.timeRange.duration);
            if (fabs(td - (total + 0.1)) < 0.3) continue; // carrier 承载轨
            videoTrackDuration = td;
        }
        double expectedVideoTrackEnd = starts[kVideoSlot] + expectedVideoTrack;
        CHECK(videoTrackDuration > 0 && fabs(videoTrackDuration - expectedVideoTrackEnd) < 0.15,
              fullVideo ? @"视频轨道保持源时长" : @"视频轨道拉伸到槽位",
              @"素材轨结束 %.3fs (期望 %.3fs)", videoTrackDuration, expectedVideoTrackEnd);

        // 8. 转场叠化校验：转场中点帧应为段0与段1底色的混合（dissolve q≈0.5）
        double transStart = starts[1];
        double transMid = transStart + T / 2;
        uint8_t r0, g0, b0, rm, gm, bm;
        BOOL okA = extractCornerColor(outURL, CMTimeMakeWithSeconds(transStart - 0.05, 600), &r0, &g0, &b0);
        BOOL okB = extractCornerColor(outURL, CMTimeMakeWithSeconds(transMid, 600), &rm, &gm, &bm);
        CHECK(okA && okB, @"转场取帧", @"%.3fs / %.3fs", transStart - 0.05, transMid);
        if (okA && okB) {
            uint8_t e0 = (uint8_t)((r[0] + r[1]) / 2), e1 = (uint8_t)((gg[0] + gg[1]) / 2), e2 = (uint8_t)((b[0] + b[1]) / 2);
            int d = abs(rm - e0) + abs(gm - e1) + abs(bm - e2);
            CHECK(d < 120, @"叠化混合色", @"转场中点(%d,%d,%d) vs 期望混合(%d,%d,%d) d=%d",
                  rm, gm, bm, e0, e1, e2, d);
        }

        // 9. 照片→视频转场校验：视频槽位起点后的转场中点应为 photo[2] 与 video 的混合
        double vTransMid = starts[kVideoSlot] + T / 2;
        uint8_t rv, gv, bv;
        BOOL okV = extractCornerColor(outURL, CMTimeMakeWithSeconds(vTransMid, 600), &rv, &gv, &bv);
        CHECK(okV, @"照片→视频转场取帧", @"%.3fs", vTransMid);
        if (okV) {
            uint8_t e0 = (uint8_t)((r[2] + er) / 2), e1 = (uint8_t)((gg[2] + eg) / 2), e2 = (uint8_t)((b[2] + eb) / 2);
            int d = abs(rv - e0) + abs(gv - e1) + abs(bv - e2);
            CHECK(d < 120, @"照片→视频叠化", @"中点(%d,%d,%d) vs 期望(%d,%d,%d) d=%d",
                  rv, gv, bv, e0, e1, e2, d);
        }

        // 10. 音频覆盖
        CHECK(CMTimeGetSeconds(aTracks.firstObject.timeRange.duration) > total - 1.5, @"BGM 覆盖全片",
              @"audio=%.2fs video=%.2fs", CMTimeGetSeconds(aTracks.firstObject.timeRange.duration), total);

        // 11. 视频封面（缩略图条用）：异步出图 + 主队列回调
        KBMediaAsset *videoMedia = assets[kVideoSlot];
        __block UIImage *cover = nil;
        dispatch_semaphore_t coverSem = dispatch_semaphore_create(0);
        [videoMedia loadThumbnailWithCompletion:^(UIImage *_Nullable thumb) {
            cover = thumb;
            dispatch_semaphore_signal(coverSem);
        }];
        // 回调派到主队列，命令行程序要自己驱动 runloop
        while (dispatch_semaphore_wait(coverSem, DISPATCH_TIME_NOW) != 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        CHECK(cover != nil && cover.size.width > 0 && cover.size.height > 0, @"视频封面生成",
              @"%@", cover ? NSStringFromCGSize(cover.size) : @"(nil)");
        if (cover) {
            uint8_t cr = 0, cgv = 0, cb = 0;
            BOOL sampled = sampleImageColor(cover, &cr, &cgv, &cb);
            int dc = abs(cr - (int)kVideoR) + abs(cgv - (int)kVideoG) + abs(cb - (int)kVideoB);
            CHECK(sampled && dc < 90, @"视频封面颜色", @"(%d,%d,%d) vs 源(%d,%d,%d) d=%d",
                  cr, cgv, cb, kVideoR, kVideoG, kVideoB, dc);
        }

        // 12. 重复请求封面（重选素材会重建缩略图条）：不崩溃、不悬挂，仍能拿到图
        __block UIImage *coverAgain = nil;
        __block NSUInteger coverCallbacks = 0;
        dispatch_semaphore_t coverSem2 = dispatch_semaphore_create(0);
        for (NSUInteger i = 0; i < 3; i++) {
            [videoMedia loadThumbnailWithCompletion:^(UIImage *_Nullable thumb) {
                if (thumb) coverAgain = thumb;
                coverCallbacks++;
                dispatch_semaphore_signal(coverSem2);
            }];
        }
        NSDate *coverDeadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
        BOOL coverReplied = NO;
        while (!coverReplied && coverDeadline.timeIntervalSinceNow > 0) {
            if (dispatch_semaphore_wait(coverSem2, DISPATCH_TIME_NOW) == 0) {
                coverReplied = YES;
            } else {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
        }
        while (dispatch_semaphore_wait(coverSem2, DISPATCH_TIME_NOW) == 0) {} // 抽干剩余回调
        CHECK(coverReplied && coverAgain != nil, @"重复请求封面", @"回调 %lu 次",
              (unsigned long)coverCallbacks);

        printf("\n=== %s：%d 项失败 ===\n", g_failures == 0 ? "全部通过 ✓" : "存在失败 ✗", g_failures);
        return g_failures == 0 ? 0 : 1;
    }
}
