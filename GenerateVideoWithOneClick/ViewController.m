//
//  ViewController.m
//  GenerateVideoWithOneClick
//
//  一键成片 Demo 主流程：
//  选择素材(PHPicker) → 模板解析 → 时间轴合成 → AVPlayer 预览 → 导出保存相册
//

#import "ViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <Masonry/Masonry.h>
#import "KBTemplate.h"
#import "KBAssetLoader.h"
#import "KBMediaAsset.h"
#import "KBTimelineBuilder.h"
#import "KBExporter.h"

static const NSInteger kMaxMediaCount = 12;
static NSString *const kKBThumbCellID = @"KBThumbnailCell";

#pragma mark - 播放器容器（AVPlayerLayer 承载视图）

@interface KBPlayerView : UIView
+ (Class)layerClass;
@end

@implementation KBPlayerView
+ (Class)layerClass {
    return [AVPlayerLayer class];
}
- (AVPlayerLayer *)playerLayer {
    return (AVPlayerLayer *)self.layer;
}
@end

#pragma mark - 素材缩略图 cell

// 素材缩略图条用的 cell：一张封面 + 视频角标。cell 会被复用，所以异步出图回调
// 必须校验"当前显示的还是不是同一个素材"，否则会把旧素材的封面写到新 cell 上。
@interface KBThumbnailCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *thumbView;
@property (nonatomic, strong) UILabel *videoBadge;
@property (nonatomic, strong) UILabel *orderLabel;
@property (nonatomic, weak, nullable) KBMediaAsset *representedAsset;
- (void)configureWithAsset:(KBMediaAsset *)asset order:(NSUInteger)order;
@end

@implementation KBThumbnailCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.contentView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    self.contentView.layer.cornerRadius = 8;
    self.contentView.clipsToBounds = YES;

    _thumbView = [[UIImageView alloc] init];
    _thumbView.contentMode = UIViewContentModeScaleAspectFill;
    _thumbView.clipsToBounds = YES;
    [self.contentView addSubview:_thumbView];

    _videoBadge = [[UILabel alloc] init];
    _videoBadge.text = @"视频";
    _videoBadge.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
    _videoBadge.textColor = UIColor.whiteColor;
    _videoBadge.backgroundColor = [UIColor systemIndigoColor];
    _videoBadge.layer.cornerRadius = 4;
    _videoBadge.clipsToBounds = YES;
    _videoBadge.textAlignment = NSTextAlignmentCenter;
    [self.contentView addSubview:_videoBadge];

    // 左上角序号：素材顺序即成片顺序，标出来用户才知道拖完是第几段
    _orderLabel = [[UILabel alloc] init];
    _orderLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightBold];
    _orderLabel.textColor = UIColor.whiteColor;
    _orderLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _orderLabel.textAlignment = NSTextAlignmentCenter;
    _orderLabel.layer.cornerRadius = 8;
    _orderLabel.clipsToBounds = YES;
    [self.contentView addSubview:_orderLabel];

    [_thumbView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self.contentView);
    }];
    [_videoBadge mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.equalTo(self.contentView).offset(4);
        make.bottom.equalTo(self.contentView).offset(-4);
        make.width.mas_equalTo(30);
        make.height.mas_equalTo(14);
    }];
    [_orderLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.top.equalTo(self.contentView).offset(4);
        make.width.height.mas_equalTo(16);
    }];
    return self;
}

// cell 会被复用：换素材前先清干净，避免出现"上一个素材的封面残影"。
- (void)prepareForReuse {
    [super prepareForReuse];
    self.representedAsset = nil;
    self.thumbView.image = nil;
}

- (void)configureWithAsset:(KBMediaAsset *)asset order:(NSUInteger)order {
    self.representedAsset = asset;
    self.videoBadge.hidden = (asset.type != KBMediaTypeVideo);
    self.orderLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)order];
    self.thumbView.image = asset.thumbnail;

    if (asset.type == KBMediaTypeVideo && !asset.thumbnail) {
        __weak typeof(self) weakSelf = self;
        [asset loadThumbnailWithCompletion:^(UIImage *_Nullable thumb) {
            if (!thumb || weakSelf.representedAsset != asset) return; // cell 已被复用给别人
            weakSelf.thumbView.image = thumb;
        }];
    }
}

@end

#pragma mark - 主控制器

@interface ViewController () <PHPickerViewControllerDelegate, UIGestureRecognizerDelegate,
                              UICollectionViewDataSource, UICollectionViewDragDelegate,
                              UICollectionViewDropDelegate>
@property (nonatomic, copy) NSArray<KBTemplate *> *templates;
@property (nonatomic, strong, nullable) KBTemplate *template;
@property (nonatomic, copy) NSArray<KBMediaAsset *> *mediaAssets;
@property (nonatomic, strong, nullable) KBTimeline *timeline;

@property (nonatomic, strong, nullable) AVPlayer *player;
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) KBPlayerView *playerView;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *templateCard;
@property (nonatomic, strong) UIScrollView *templateScrollView;
@property (nonatomic, strong) UIStackView *templateStack;
@property (nonatomic, strong) NSMutableArray<UIButton *> *templateButtons;
@property (nonatomic, strong) UILabel *templateNameLabel;
@property (nonatomic, strong) UILabel *templateDetailLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) UICollectionView *thumbCollectionView;
@property (nonatomic, strong) UIButton *pickButton;
@property (nonatomic, strong) UIButton *generateButton;
@property (nonatomic, strong) UIButton *exportButton;
@property (nonatomic, strong) UIButton *replayButton;
@property (nonatomic, strong) MASConstraint *playerHeightConstraint;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIProgressView *progressView;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.055 green:0.075 blue:0.102 alpha:1];
    self.templates = [KBTemplate templatesInBundle:[NSBundle mainBundle]];
    self.template = self.templates.firstObject;
    [self buildUI];
    [self refreshState];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CAGradientLayer *bg = (CAGradientLayer *)self.view.layer.sublayers.firstObject;
    if ([bg isKindOfClass:[CAGradientLayer class]]) {
        bg.frame = self.view.bounds;
    }
}

#pragma mark - UI

- (void)buildUI {
    // 背景渐变
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[(id)[UIColor colorWithRed:0.055 green:0.075 blue:0.102 alpha:1].CGColor,
                        (id)[UIColor colorWithRed:0.10 green:0.13 blue:0.19 alpha:1].CGColor];
    gradient.frame = self.view.bounds;
    [self.view.layer insertSublayer:gradient atIndex:0];

    // 纵向滚动容器：contentView 撑开滚动区域，宽度跟随屏幕
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];

    self.contentView = [[UIView alloc] init];
    [self.scrollView addSubview:self.contentView];

    UILabel *titleLabel = [self labelWithText:@"一键成片"
                                        font:[UIFont systemFontOfSize:30 weight:UIFontWeightBold]
                                       color:UIColor.whiteColor];
    UILabel *subtitleLabel = [self labelWithText:@"节拍卡点 · Ken Burns 运镜 · 叠化转场"
                                            font:[UIFont systemFontOfSize:14 weight:UIFontWeightMedium]
                                           color:[UIColor colorWithWhite:1 alpha:0.55]];

    // 模板选择（横向 chip 列表，来自 bundle 内所有模板 JSON）
    self.templateScrollView = [[UIScrollView alloc] init];
    self.templateScrollView.showsHorizontalScrollIndicator = NO;
    self.templateScrollView.hidden = (self.templates.count <= 1);

    self.templateStack = [[UIStackView alloc] init];
    self.templateStack.axis = UILayoutConstraintAxisHorizontal;
    self.templateStack.spacing = 8;
    [self.templateScrollView addSubview:self.templateStack];

    // 模板卡片
    self.templateCard = [[UIView alloc] init];
    self.templateCard.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    self.templateCard.layer.cornerRadius = 16;
    self.templateCard.layer.borderWidth = 1;
    self.templateCard.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.08].CGColor;

    self.templateNameLabel = [self labelWithText:@""
                                           font:[UIFont systemFontOfSize:19 weight:UIFontWeightSemibold]
                                          color:UIColor.whiteColor];
    self.templateDetailLabel = [self labelWithText:@""
                                              font:[UIFont systemFontOfSize:13]
                                             color:[UIColor colorWithWhite:1 alpha:0.5]];
    self.durationLabel = [self labelWithText:@"未选择素材"
                                        font:[UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium]
                                       color:[UIColor systemIndigoColor]];

    [self.templateCard addSubview:self.templateNameLabel];
    [self.templateCard addSubview:self.templateDetailLabel];
    [self.templateCard addSubview:self.durationLabel];
    [self buildTemplateChips];
    [self updateTemplateCard];

    // 素材缩略图横条
    // 素材缩略图条：横向 collection view，长按拖动即可调整顺序
    UICollectionViewFlowLayout *thumbLayout = [[UICollectionViewFlowLayout alloc] init];
    thumbLayout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    thumbLayout.itemSize = CGSizeMake(64, 72);
    thumbLayout.minimumLineSpacing = 8;
    thumbLayout.sectionInset = UIEdgeInsetsMake(8, 8, 8, 8);

    self.thumbCollectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:thumbLayout];
    self.thumbCollectionView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
    self.thumbCollectionView.layer.cornerRadius = 14;
    self.thumbCollectionView.showsHorizontalScrollIndicator = NO;
    self.thumbCollectionView.alwaysBounceHorizontal = YES;
    self.thumbCollectionView.dragInteractionEnabled = YES; // iPhone 上默认关闭，必须显式打开才能长按拖动
    self.thumbCollectionView.dataSource = self;
    self.thumbCollectionView.dragDelegate = self;
    self.thumbCollectionView.dropDelegate = self;
    [self.thumbCollectionView registerClass:[KBThumbnailCell class] forCellWithReuseIdentifier:kKBThumbCellID];
    self.thumbCollectionView.hidden = YES;

    // 播放器（9:16）
    self.playerView = [[KBPlayerView alloc] init];
    self.playerView.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    self.playerView.backgroundColor = [UIColor blackColor];
    self.playerView.layer.cornerRadius = 16;
    self.playerView.clipsToBounds = YES;
    self.playerView.hidden = YES;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePlay)];
    tap.delegate = self; // 点"重播"按钮时不再触发暂停/继续手势
    [self.playerView addGestureRecognizer:tap];

    self.replayButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *symConfig = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIFontWeightSemibold];
    [self.replayButton setImage:[UIImage systemImageNamed:@"arrow.counterclockwise.circle.fill"
                                    withConfiguration:symConfig]
                       forState:UIControlStateNormal];
    [self.replayButton setTitle:@"  重播" forState:UIControlStateNormal];
    self.replayButton.tintColor = UIColor.whiteColor;
    self.replayButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.replayButton.hidden = YES;
    [self.replayButton addTarget:self action:@selector(replayTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.playerView addSubview:self.replayButton];

    // 按钮
    self.pickButton = [self buttonWithTitle:[NSString stringWithFormat:@"选择照片 / 视频（最多 %ld 个）", (long)kMaxMediaCount]
                                     filled:NO
                                     action:@selector(pickTapped)];
    self.generateButton = [self buttonWithTitle:@"一键成片"
                                         filled:YES
                                         action:@selector(generateTapped)];
    self.exportButton = [self buttonWithTitle:@"导出并保存到相册"
                                       filled:NO
                                       action:@selector(exportTapped)];

    // 状态区
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = [UIColor colorWithWhite:1 alpha:0.7];
    self.spinner.hidesWhenStopped = YES;

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.progressTintColor = [UIColor systemIndigoColor];
    self.progressView.hidden = YES;

    for (UIView *view in @[titleLabel, subtitleLabel, self.templateScrollView, self.templateCard,
                           self.thumbCollectionView, self.playerView, self.pickButton, self.generateButton,
                           self.exportButton, self.progressView, self.statusLabel]) {
        [self.contentView addSubview:view];
    }

    // 布局（Masonry）
    [self.scrollView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.view.mas_safeAreaLayoutGuideTop);
        make.left.right.bottom.equalTo(self.view);
    }];
    [self.contentView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.scrollView).offset(20);
        make.left.equalTo(self.scrollView).offset(20);
        make.right.equalTo(self.scrollView).offset(-20);
        make.bottom.equalTo(self.scrollView).offset(-24);
        make.width.equalTo(self.scrollView).offset(-40);
    }];
    [titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.left.equalTo(self.contentView);
    }];
    [subtitleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(titleLabel.mas_bottom).offset(4);
        make.left.equalTo(self.contentView);
    }];
    [self.templateScrollView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(subtitleLabel.mas_bottom).offset(16);
        make.left.right.equalTo(self.contentView);
        make.height.mas_equalTo(36);
    }];
    [self.templateStack mas_makeConstraints:^(MASConstraintMaker *make) {
        // 横向滚动区必须「左右都钉住」才能算出内容宽度：只钉左边时 contentSize.width = 0，
        // chip 会被裁掉且滑不动；右边钉住等于把内容宽度交给 stack 自身（chip 的固有宽度）决定。
        make.top.bottom.left.equalTo(self.templateScrollView);
        make.right.equalTo(self.templateScrollView).offset(-8); // 滑到底留一点边距
        make.height.mas_equalTo(36);
    }];
    [self.templateCard mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.templateScrollView.mas_bottom).offset(12);
        make.left.right.equalTo(self.contentView);
    }];
    [self.templateNameLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.templateCard).offset(14);
        make.left.equalTo(self.templateCard).offset(16);
    }];
    [self.templateDetailLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.templateNameLabel.mas_bottom).offset(4);
        make.left.equalTo(self.templateNameLabel);
    }];
    [self.durationLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.templateDetailLabel.mas_bottom).offset(8);
        make.left.equalTo(self.templateNameLabel);
        make.bottom.equalTo(self.templateCard).offset(-14);
    }];
    [self.thumbCollectionView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.templateCard.mas_bottom).offset(14);
        make.left.right.equalTo(self.contentView);
        make.height.mas_equalTo(88);
    }];
    [self.playerView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.thumbCollectionView.mas_bottom).offset(14);
        make.centerX.equalTo(self.contentView);
        make.width.mas_equalTo(220);
        self.playerHeightConstraint = make.height.mas_equalTo(0); // 未生成成片时收起
    }];
    [self.replayButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerX.equalTo(self.playerView);
        make.bottom.equalTo(self.playerView).offset(-14);
    }];
    [self.pickButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.playerView.mas_bottom).offset(16);
        make.left.right.equalTo(self.contentView);
        make.height.mas_equalTo(48);
    }];
    [self.generateButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.pickButton.mas_bottom).offset(12);
        make.left.right.equalTo(self.contentView);
        make.height.mas_equalTo(52);
    }];
    [self.exportButton mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.generateButton.mas_bottom).offset(12);
        make.left.right.equalTo(self.contentView);
        make.height.mas_equalTo(48);
    }];
    [self.progressView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.exportButton.mas_bottom).offset(14);
        make.left.right.equalTo(self.contentView);
    }];
    [self.statusLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.progressView.mas_bottom).offset(10);
        make.left.right.equalTo(self.contentView);
        make.bottom.equalTo(self.contentView);
    }];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playbackFinished:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 模板

- (void)buildTemplateChips {
    self.templateButtons = [NSMutableArray arrayWithCapacity:self.templates.count];
    for (NSUInteger i = 0; i < self.templates.count; i++) {
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
        chip.tag = (NSInteger)i;
        [chip addTarget:self action:@selector(templateChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [chip mas_makeConstraints:^(MASConstraintMaker *make) {
            make.height.mas_equalTo(36);
            make.width.mas_greaterThanOrEqualTo(78);
        }];
        [self.templateStack addArrangedSubview:chip];
        [self.templateButtons addObject:chip];
    }
    [self updateTemplateSelection];
}

- (void)templateChipTapped:(UIButton *)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)self.templates.count) return;
    KBTemplate *tpl = self.templates[(NSUInteger)sender.tag];
    if (tpl == self.template) return;

    self.template = tpl;
    [self invalidateTimeline]; // 模板换了，上一版成片作废
    [self updateTemplateSelection];
    [self updateTemplateCard];
    [self refreshState];
    [self setStatus:[NSString stringWithFormat:@"已切到「%@」，重新一键成片即可", tpl.name] busy:NO];
}

- (void)updateTemplateSelection {
    for (UIButton *chip in self.templateButtons) {
        KBTemplate *tpl = self.templates[(NSUInteger)chip.tag];
        BOOL selected = (tpl == self.template);
        UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
        config.title = tpl.name;
        config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        config.contentInsets = NSDirectionalEdgeInsetsMake(8, 16, 8, 16);
        config.baseBackgroundColor = selected ? [UIColor systemIndigoColor] : [UIColor colorWithWhite:1 alpha:0.10];
        config.baseForegroundColor = selected ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.75];
        chip.configuration = config;
    }
}

- (void)updateTemplateCard {
    KBTemplate *tpl = self.template;
    self.templateNameLabel.text = tpl.name ?: @"未找到模板";
    if (!tpl) {
        self.templateDetailLabel.text = @"bundle 内缺少模板 JSON";
        return;
    }
    NSString *detail = [NSString stringWithFormat:@"%g BPM · 每 %lu 拍切镜 · 转场 %g 拍 · %.0f×%.0f @%ldfps",
                        tpl.bpm, (unsigned long)tpl.clipBeats, tpl.transitionBeats,
                        tpl.renderSize.width, tpl.renderSize.height, (long)tpl.fps];
    self.templateDetailLabel.text = tpl.playsVideoInFull
        ? [detail stringByAppendingString:@"\n视频按原速完整播放（不裁剪/不变速）"]
        : [detail stringByAppendingString:@"\n视频裁到节拍槽位，短片段慢放补齐"];
}

#pragma mark - UI 辅助

- (UILabel *)labelWithText:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (UIButton *)buttonWithTitle:(NSString *)title filled:(BOOL)filled action:(SEL)action {
    UIButtonConfiguration *config = filled ? [UIButtonConfiguration filledButtonConfiguration]
                                           : [UIButtonConfiguration tintedButtonConfiguration];
    config.title = title;
    config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    config.baseBackgroundColor = [UIColor systemIndigoColor];
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)setStatus:(NSString *)text busy:(BOOL)busy {
    self.statusLabel.text = text;
    if (busy) {
        [self.spinner startAnimating];
        if (!self.spinner.superview) {
            [self.contentView addSubview:self.spinner];
            [self.spinner mas_makeConstraints:^(MASConstraintMaker *make) {
                make.centerY.equalTo(self.statusLabel);
                make.right.equalTo(self.statusLabel.mas_centerX).offset(-60);
            }];
        }
    } else {
        [self.spinner stopAnimating];
    }
}

- (void)refreshState {
    NSUInteger n = self.mediaAssets.count;
    NSString *reorderHint = (n >= 2) ? @" · 长按缩略图可拖动排序" : @"";
    if (n > 0 && self.template) {
        NSTimeInterval total = [self.template totalDurationForClipCount:n];
        if (self.template.playsVideoInFull) {
            self.durationLabel.text = [NSString stringWithFormat:@"已选 %lu 个素材 · 预计成片 ≥ %.1f 秒（视频按原速完整播放）%@",
                                       (unsigned long)n, total, reorderHint];
        } else {
            self.durationLabel.text = [NSString stringWithFormat:@"已选 %lu 个素材（照片+视频） · 预计成片 %.1f 秒%@",
                                       (unsigned long)n, total, reorderHint];
        }
    } else if (n > 0) {
        self.durationLabel.text = [NSString stringWithFormat:@"已选 %lu 个素材 · 缺少模板", (unsigned long)n];
    } else {
        self.durationLabel.text = @"未选择素材";
    }
    self.generateButton.enabled = (n >= 2) && (self.template != nil);
    self.exportButton.enabled = (self.timeline != nil);
}

- (void)showThumbnails {
    [self.thumbCollectionView reloadData];
    self.thumbCollectionView.hidden = (self.mediaAssets.count == 0);
}

#pragma mark - 缩略图条：长按拖动排序

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.mediaAssets.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                           cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    KBThumbnailCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kKBThumbCellID
                                                                     forIndexPath:indexPath];
    if (indexPath.item < (NSInteger)self.mediaAssets.count) {
        [cell configureWithAsset:self.mediaAssets[indexPath.item] order:(NSUInteger)indexPath.item + 1];
    }
    return cell;
}

- (BOOL)collectionView:(UICollectionView *)collectionView canMoveItemAtIndexPath:(NSIndexPath *)indexPath {
    return self.mediaAssets.count > 1; // 只有一个素材时没有排序的意义
}

- (NSArray<UIDragItem *> *)collectionView:(UICollectionView *)collectionView
            itemsForBeginningDragSession:(id<UIDragSession>)session
                             atIndexPath:(NSIndexPath *)indexPath {
    if (self.mediaAssets.count < 2 || indexPath.item >= (NSInteger)self.mediaAssets.count) return @[];
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:[[NSItemProvider alloc] init]];
    item.localObject = self.mediaAssets[indexPath.item];
    return @[item];
}

- (UICollectionViewDropProposal *)collectionView:(UICollectionView *)collectionView
                                  dropSessionDidUpdate:(id<UIDropSession>)session
                              withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    // 只接受本 App 内部的拖动（外面拖进来的内容直接取消）
    if (!session.localDragSession) {
        return [[UICollectionViewDropProposal alloc] initWithDropOperation:UIDropOperationCancel];
    }
    return [[UICollectionViewDropProposal alloc] initWithDropOperation:UIDropOperationMove
                                                                intent:UICollectionViewDropIntentInsertAtDestinationIndexPath];
}

- (void)collectionView:(UICollectionView *)collectionView
   performDropWithCoordinator:(id<UICollectionViewDropCoordinator>)coordinator {
    // 注意：UICollectionViewDropItem 是协议不是类，必须写成 id<...>，否则编译不过
    id<UICollectionViewDropItem> item = coordinator.items.firstObject;
    NSIndexPath *source = item.sourceIndexPath;
    if (!source) return;
    // 拖到空白处时 destinationIndexPath 为 nil → 视为移到末尾，再夹到合法下标
    NSInteger to = coordinator.destinationIndexPath ? coordinator.destinationIndexPath.item
                                                   : (NSInteger)self.mediaAssets.count;
    NSIndexPath *finalIndexPath = [self moveAssetAtIndex:source.item toIndex:to];
    // 把拖起来的那张快照落到新位置；不调用的话快照会飞回原位，看起来像没换成功
    if (finalIndexPath) {
        [coordinator dropItem:item.dragItem toItemAtIndexPath:finalIndexPath];
    }
}

// 把第 from 个素材挪到第 to 个位置：模型与 collection view 动画用同一个目标下标，
// 保证"屏幕上的顺序"和"数组里的顺序"永远一致（顺序即成片顺序）。
// 返回移动后的最终位置；位置没变（或下标非法）时返回 nil。
- (nullable NSIndexPath *)moveAssetAtIndex:(NSInteger)from toIndex:(NSInteger)to {
    NSInteger count = (NSInteger)self.mediaAssets.count;
    if (count < 2 || from < 0 || from >= count) return nil;
    to = MIN(MAX(to, 0), count - 1);       // 夹到合法范围（拖到空白处 = 末尾）
    if (to == from) return nil;            // 位置没变，不做无谓的重建

    NSMutableArray<KBMediaAsset *> *assets = [self.mediaAssets mutableCopy];
    KBMediaAsset *moved = assets[(NSUInteger)from];
    [assets removeObjectAtIndex:(NSUInteger)from];
    [assets insertObject:moved atIndex:(NSUInteger)to];
    self.mediaAssets = assets;

    NSIndexPath *source = [NSIndexPath indexPathForItem:from inSection:0];
    NSIndexPath *destination = [NSIndexPath indexPathForItem:to inSection:0];
    [self.thumbCollectionView performBatchUpdates:^{
        [self.thumbCollectionView moveItemAtIndexPath:source toIndexPath:destination];
    } completion:nil];

    [self invalidateTimeline]; // 顺序变了，上一版成片作废
    [self refreshState];
    [self setStatus:@"已调整素材顺序 · 重新一键成片生效" busy:NO];
    return destination;
}

#pragma mark - 流程：选择素材

- (void)pickTapped {
    PHPickerViewController *picker =
        [[PHPickerViewController alloc] initWithConfiguration:[KBAssetLoader pickerConfigurationWithLimit:kMaxMediaCount]];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    [self setStatus:@"读取素材中…" busy:YES];
    [KBAssetLoader loadMediaFromResults:results
                             completion:^(NSArray<KBMediaAsset *> *_Nullable assets, NSError *_Nullable error) {
        if (error) {
            [self setStatus:[NSString stringWithFormat:@"部分素材读取失败：%@", error.localizedDescription] busy:NO];
        }
        if (assets.count < 2) {
            self.mediaAssets = assets ?: @[];
            [self invalidateTimeline];
            [self showThumbnails];
            [self refreshState];
            if (!error) [self setStatus:@"至少选择 2 个素材（照片或视频）" busy:NO];
            return;
        }
        self.mediaAssets = assets;
        [self invalidateTimeline];
        [self showThumbnails];
        [self refreshState];
        [self setStatus:[NSString stringWithFormat:@"已加载 %lu 个素材 · 长按缩略图可拖动排序，然后一键成片", (unsigned long)assets.count] busy:NO];
    }];
}

#pragma mark - 流程：一键成片

- (void)generateTapped {
    if (self.mediaAssets.count < 2 || !self.template) return;

    [self setStatus:@"正在合成时间轴…" busy:YES];
    self.generateButton.enabled = NO;
    self.exportButton.enabled = NO;

    NSURL *bgmURL = [self.template audioURLInBundle:[NSBundle mainBundle]];
    [KBTimelineBuilder buildTimelineAsyncWithAssets:self.mediaAssets
                                            template:self.template
                                              bgmURL:bgmURL
                                          completion:^(KBTimeline *_Nullable timeline, NSError *_Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!timeline || error) {
                [self setStatus:[NSString stringWithFormat:@"合成失败：%@", error.localizedDescription ?: @"未知错误"] busy:NO];
                [self refreshState];
                return;
            }
            self.timeline = timeline;
            [self startPreview];
            [self setStatus:@"预览播放中 · 点画面可暂停/继续" busy:NO];
            [self refreshState];
        });
    }];
}

- (void)startPreview {
    [self.player pause];
    self.player = [[AVPlayer alloc] initWithPlayerItem:[self.timeline makePlayerItem]];
    self.playerView.playerLayer.player = self.player;
    self.playerView.hidden = NO;
    [self.playerHeightConstraint setOffset:391]; // 隐藏期间收起为 0，避免空白占位
    self.replayButton.hidden = YES;
    [self.player play];
}

- (void)togglePlay {
    if (!self.player) return;
    if (self.player.rate == 0) {
        [self.player play];
    } else {
        [self.player pause];
    }
}

- (void)replayTapped {
    [self.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    [self.player play];
    self.replayButton.hidden = YES;
}

- (void)playbackFinished:(NSNotification *)notification {
    if (notification.object != self.player.currentItem) return; // 忽略已被替换的旧条目
    self.replayButton.hidden = NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return self.replayButton.hidden || ![touch.view isDescendantOfView:self.replayButton];
}

// 素材或模板变化后旧成片即失效：停播、收起预览，避免导出上一个版本
- (void)invalidateTimeline {
    [self.player pause];
    self.player = nil;
    self.playerView.playerLayer.player = nil;
    self.playerView.hidden = YES;
    [self.playerHeightConstraint setOffset:0];
    self.replayButton.hidden = YES;
    self.progressView.hidden = YES;
    self.progressView.progress = 0;
    self.timeline = nil;
}

#pragma mark - 流程：导出

- (void)exportTapped {
    if (!self.timeline) return;
    self.progressView.hidden = NO;
    self.progressView.progress = 0;
    [self setStatus:@"正在导出 MP4…" busy:YES];
    self.exportButton.enabled = NO;

    __weak typeof(self) weakSelf = self;
    [KBExporter exportTimeline:self.timeline
                    completion:^(NSURL *_Nullable fileURL, NSError *_Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!fileURL || error) {
            [strongSelf setStatus:[NSString stringWithFormat:@"导出失败：%@", error.localizedDescription ?: @"未知错误"] busy:NO];
            [strongSelf refreshState];
            return;
        }
        [strongSelf setStatus:@"导出完成，正在保存到相册…" busy:YES];
        [KBExporter saveToPhotoLibrary:fileURL
                            completion:^(BOOL success, NSError *_Nullable saveError) {
            __strong typeof(weakSelf) s2 = weakSelf;
            if (!s2) return;
            NSString *message = success
                ? [NSString stringWithFormat:@"已保存到相册 ✓  %@", fileURL.lastPathComponent]
                : [NSString stringWithFormat:@"保存失败：%@", saveError.localizedDescription ?: @"未知错误"];
            [s2 setStatus:message busy:NO];
            [s2 refreshState];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:success ? @"完成" : @"保存失败"
                                                                             message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [s2 presentViewController:alert animated:YES completion:nil];
        }];
    }
                      progress:^(float progress) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf.progressView setProgress:progress animated:YES];
        }
    }];
}

@end
