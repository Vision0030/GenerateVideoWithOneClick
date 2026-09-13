//
//  KBTemplate.m
//  GenerateVideoWithOneClick
//

#import "KBTemplate.h"

@interface KBTemplate ()
@property (nonatomic, copy, readwrite) NSString *templateID;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *audioFileName;
@property (nonatomic, assign, readwrite) CGFloat bpm;
@property (nonatomic, assign, readwrite) NSUInteger clipBeats;
@property (nonatomic, assign, readwrite) CGFloat transitionBeats;
@property (nonatomic, assign, readwrite) CGSize renderSize;
@property (nonatomic, assign, readwrite) NSInteger fps;
@property (nonatomic, assign, readwrite) NSInteger order;
@property (nonatomic, strong, readwrite) NSArray<NSNumber *> *motionCycle;
@property (nonatomic, assign, readwrite) KBVideoClipMode videoMode;
@end

@implementation KBTemplate

+ (nullable instancetype)templateNamed:(NSString *)name inBundle:(NSBundle *)bundle {
    NSURL *url = [bundle URLForResource:name withExtension:@"json"];
    if (!url) return nil;
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return nil;
    NSError *error = nil;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![dict isKindOfClass:[NSDictionary class]]) return nil;
    return [[KBTemplate alloc] initWithDictionary:dict];
}

- (nullable instancetype)initWithDictionary:(NSDictionary *)dict {
    self = [super init];
    if (!self) return nil;

    _templateID = dict[@"id"] ?: @"unknown";
    _name = dict[@"name"] ?: @"未命名模板";
    _audioFileName = dict[@"audio"] ?: @"";
    _bpm = [dict[@"bpm"] doubleValue] > 0 ? [dict[@"bpm"] doubleValue] : 120.0;
    _clipBeats = MAX(1, [dict[@"clip_beats"] unsignedIntegerValue]);
    _transitionBeats = [dict[@"transition_beats"] doubleValue] > 0 ? [dict[@"transition_beats"] doubleValue] : 0.5;
    _fps = [dict[@"fps"] integerValue] > 0 ? [dict[@"fps"] integerValue] : 30;
    _order = dict[@"order"] ? [dict[@"order"] integerValue] : 999;
    _videoMode = [[dict[@"video_mode"] lowercaseString] isEqualToString:@"full"] ? KBVideoClipModeFull
                                                                                 : KBVideoClipModeSlot;

    NSArray *res = dict[@"resolution"];
    CGFloat w = (res.count >= 1) ? [res[0] doubleValue] : 1080.0;
    CGFloat h = (res.count >= 2) ? [res[1] doubleValue] : 1920.0;
    _renderSize = CGSizeMake(w, h);

    static NSDictionary *motionMap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        motionMap = @{
            @"zoom_in"  : @(KBMotionZoomIn),
            @"zoom_out" : @(KBMotionZoomOut),
            @"pan_left" : @(KBMotionPanLeft),
            @"pan_right": @(KBMotionPanRight),
        };
    });
    NSMutableArray *motions = [NSMutableArray array];
    for (NSString *s in dict[@"motions"] ?: @[]) {
        NSNumber *n = motionMap[[s lowercaseString]];
        if (n) [motions addObject:n];
    }
    if (motions.count == 0) [motions addObject:@(KBMotionZoomIn)];
    _motionCycle = motions;

    return self;
}

+ (NSArray<KBTemplate *> *)templatesInBundle:(NSBundle *)bundle {
    NSMutableArray<KBTemplate *> *templates = [NSMutableArray array];
    NSArray<NSString *> *paths = [[bundle pathsForResourcesOfType:@"json" inDirectory:nil]
                                  sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *path in paths) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) continue;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        // 只收编模板 DSL：必须声明 id / bpm / clip_beats，避免把普通配置文件当模板
        if (!dict[@"id"] || !dict[@"bpm"] || !dict[@"clip_beats"]) continue;
        KBTemplate *tpl = [[KBTemplate alloc] initWithDictionary:dict];
        if (tpl) [templates addObject:tpl];
    }
    [templates sortUsingComparator:^NSComparisonResult(KBTemplate *a, KBTemplate *b) {
        if (a.order != b.order) return a.order < b.order ? NSOrderedAscending : NSOrderedDescending;
        return [a.name compare:b.name];
    }];
    return templates;
}

- (NSTimeInterval)beatInterval {
    return 60.0 / self.bpm;
}

- (NSTimeInterval)clipDuration {
    return self.clipBeats * self.beatInterval;
}

- (NSTimeInterval)transitionDuration {
    return self.transitionBeats * self.beatInterval;
}

// 首段完整播放，其后每段与前一段尾部叠化：total = D + (n-1) * (D - T) + 片尾定格
- (NSTimeInterval)totalDurationForClipCount:(NSUInteger)count {
    NSTimeInterval D = self.clipDuration;
    NSTimeInterval T = self.transitionDuration;
    NSTimeInterval total = D + MAX(0, (NSTimeInterval)count - 1) * MAX(0.1, D - T);
    return total + 0.6; // 片尾定格
}

- (KBMotionType)motionAtIndex:(NSUInteger)index {
    return self.motionCycle[index % self.motionCycle.count].unsignedIntegerValue;
}

- (BOOL)playsVideoInFull {
    return self.videoMode == KBVideoClipModeFull;
}

- (nullable NSURL *)audioURLInBundle:(NSBundle *)bundle {
    if (self.audioFileName.length == 0) return nil;
    return [bundle URLForResource:self.audioFileName withExtension:@"m4a"]
        ?: [bundle URLForResource:self.audioFileName withExtension:@"mp3"];
}

@end
