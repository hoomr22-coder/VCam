#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "MediaManager.h"

// ============================================================================
// MARK: - 全局状态
// ============================================================================

static BOOL g_vcamEnabled = NO;
static UIWindow *g_overlayWindow = nil;
static UIButton *g_floatButton = nil;

static AVPlayer *g_player = nil;
static AVPlayerLayer *g_playerLayer = nil;
static NSURL *g_videoURL = nil;
static NSHashTable *g_previewLayers = nil;

static void vcamAttachPreview(AVCaptureVideoPreviewLayer *pl);

// 全局素材：/var/jb/Library/Application Support/VCam/video.mp4
// 打包时塞进 deb，所有注入了插件的 App 打开即用同一段视频，不必逐个选片。
// config.plist 里 "enabled" = false 可全局关掉默认启用。
static NSString *const kVCamGlobalDir = @"/var/jb/Library/Application Support/VCam";

static void vcamLoadGlobalConfig(void) {
    NSString *mp4 = [kVCamGlobalDir stringByAppendingPathComponent:@"video.mp4"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:mp4]) {
        NSLog(@"[VCam] no global video at %@", mp4);
        return;
    }
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:
        [kVCamGlobalDir stringByAppendingPathComponent:@"config.plist"]];
    BOOL enabled = cfg[@"enabled"] ? [cfg[@"enabled"] boolValue] : YES;
    g_videoURL = [NSURL fileURLWithPath:mp4];
    g_vcamEnabled = enabled;
    NSLog(@"[VCam] global video %@ enabled=%d", mp4, enabled);
}


// ---- 拍照 / 录像输出替换 ----
// 预览层只改"看到什么"，拍照/录像走的是另一条路，这里补上：
//   * AVCapturePhoto.fileDataRepresentation —— 拍照产物（JPEG/HEIF 字节）
//   * AVCaptureMovieFileOutput             —— 录像落盘的文件
// 二者都用同一段 g_videoURL：照片抽当前播放位置的一帧，录像整段文件替换。
static const void *kVCamMovieURLKey = &kVCamMovieURLKey;

// 拍照替换必须"零阻塞"：fileDataRepresentation 是在拍照回调链上调用的，
// 在这里同步解码视频/编码大图会把 capture 管线堵住，系统相机表现为预览冻住、
// 对焦反复拉风箱、整机点不动（1.0.8 就是这么挂的）。
// 做法：第一次遇到某种尺寸时先返回真图，同时在后台把这一尺寸的替换图渲染好缓存，
//       之后同一尺寸的照片直接返回缓存字节（纯内存读，微秒级）。
static NSCache *g_photoCache = nil;
static NSMutableSet *g_photoPending = nil;
static dispatch_queue_t g_photoQueue = nil;

static CGImageRef vcamFrameCGImage(void) {
    if (!g_videoURL) return NULL;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:g_videoURL options:nil];
    double dur = CMTimeGetSeconds(asset.duration);
    if (!(dur > 0)) return NULL;
    AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.requestedTimeToleranceBefore = kCMTimeZero;
    gen.requestedTimeToleranceAfter = kCMTimeZero;
    double t = fmod(CACurrentMediaTime(), dur);
    NSError *err = nil;
    CGImageRef cg = [gen copyCGImageAtTime:CMTimeMakeWithSeconds(t, 600) actualTime:NULL error:&err];
    if (!cg) NSLog(@"[VCam] frame grab failed: %@", err);
    return cg;
}

static NSData *vcamEncodeImage(CGImageRef img, BOOL heic) {
    NSMutableData *out = [NSMutableData data];
    CFStringRef uti = heic ? CFSTR("public.heic") : CFSTR("public.jpeg");
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, uti, 1, NULL);
    if (!dest) return nil;
    NSDictionary *opts = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.9};
    CGImageDestinationAddImage(dest, img, (__bridge CFDictionaryRef)opts);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok ? out : nil;
}

// 从原始照片里读出像素尺寸和容器类型，键用于缓存
static NSString *vcamPhotoKey(NSData *data, CGSize *size, BOOL *heic) {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return nil;
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
    CFStringRef type = CGImageSourceGetType(src);
    BOOL isHeic = type && CFStringCompare(type, CFSTR("public.heic"), 0) == kCFCompareEqualTo;
    CFRelease(src);
    if (!props) return nil;
    CGFloat w = [props[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
    CGFloat h = [props[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
    if (w <= 0 || h <= 0) return nil;
    if (size) *size = CGSizeMake(w, h);
    if (heic) *heic = isHeic;
    return [NSString stringWithFormat:@"%.0fx%.0f/%d", w, h, isHeic];
}

static void vcamRenderPhotoAsync(NSString *key, CGSize size, BOOL heic) {
    if (!g_photoQueue) g_photoQueue = dispatch_queue_create("com.vcam.photo", DISPATCH_QUEUE_SERIAL);
    if (!g_photoCache) { g_photoCache = [[NSCache alloc] init]; g_photoCache.countLimit = 6; }
    if (!g_photoPending) g_photoPending = [NSMutableSet set];
    @synchronized (g_photoPending) {
        if ([g_photoPending containsObject:key]) return;
        [g_photoPending addObject:key];
    }
    dispatch_async(g_photoQueue, ^{
        @autoreleasepool {
            CGImageRef src = vcamFrameCGImage();
            if (src) {
                size_t W = (size_t)MAX(size.width, 1), H = (size_t)MAX(size.height, 1);
                CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, 0, cs, kCGImageAlphaNoneSkipLast);
                if (ctx) {
                    CGFloat sw = (CGFloat)CGImageGetWidth(src), sh = (CGFloat)CGImageGetHeight(src);
                    CGFloat scale = MAX(W / sw, H / sh);
                    CGRect r = CGRectMake((W - sw * scale) / 2.0, (H - sh * scale) / 2.0, sw * scale, sh * scale);
                    CGContextDrawImage(ctx, r, src);
                    CGImageRef scaled = CGBitmapContextCreateImage(ctx);
                    if (scaled) {
                        NSData *enc = vcamEncodeImage(scaled, heic);
                        if (enc.length) {
                            [g_photoCache setObject:enc forKey:key];
                            NSLog(@"[VCam] photo cache ready %@ %lu B", key, (unsigned long)enc.length);
                        }
                        CGImageRelease(scaled);
                    }
                    CGContextRelease(ctx);
                }
                CGColorSpaceRelease(cs);
                CGImageRelease(src);
            }
            @synchronized (g_photoPending) { [g_photoPending removeObject:key]; }
        }
    });
}

static BOOL vcamReplaceMovieAtPath(NSString *path) {
    if (!path || !g_videoURL) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:path error:nil];
    NSError *err = nil;
    BOOL ok = [fm copyItemAtURL:g_videoURL toURL:[NSURL fileURLWithPath:path] error:&err];
    NSLog(@"[VCam] movie replaced -> %@ ok=%d err=%@", path.lastPathComponent, ok, err);
    return ok;
}

static void vcamEnsurePlayer(void) {
    if (!g_videoURL) return;
    if (!g_player) {
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:g_videoURL];
        g_player = [AVPlayer playerWithPlayerItem:item];
        g_player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        g_player.muted = YES;
        __weak AVPlayer *weakPlayer = g_player;
        [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
            object:item queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note) {
                [weakPlayer seekToTime:kCMTimeZero];
                [weakPlayer play];
            }];
    }
    if (!g_playerLayer) {
        g_playerLayer = [AVPlayerLayer playerLayerWithPlayer:g_player];
        g_playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        g_playerLayer.backgroundColor = [UIColor blackColor].CGColor;
    }
}

static void vcamAttachPreview(AVCaptureVideoPreviewLayer *pl) {
    if (!pl) return;
    if (!g_vcamEnabled) {
        if (g_playerLayer && g_playerLayer.superlayer == (CALayer *)pl) {
            [g_playerLayer removeFromSuperlayer];
        }
        return;
    }
    vcamEnsurePlayer();
    if (!g_playerLayer) return;
    if (g_playerLayer.superlayer != (CALayer *)pl) {
        // 换挂载点时把 player 重新绑定一次：否则图层搬过去后可能停在旧画面上
        [g_playerLayer removeFromSuperlayer];
        g_playerLayer.player = nil;
        g_playerLayer.player = g_player;
        [(CALayer *)pl addSublayer:g_playerLayer];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    g_playerLayer.frame = [(CALayer *)pl bounds];
    [CATransaction commit];
    [g_player play];
    NSLog(@"[VCam] overlay attached: %@ %.0fx%.0f", pl, [(CALayer *)pl bounds].size.width, [(CALayer *)pl bounds].size.height);
}

static void vcamRefreshPreviews(void) {
    if (!g_previewLayers) return;
    for (AVCaptureVideoPreviewLayer *pl in g_previewLayers.allObjects) {
        vcamAttachPreview(pl);
    }
}

// 播放看门狗：拍照/查看照片/切前后台之后，AVPlayer 很容易被系统停住，
// 或者已经在结尾停下，表现就是"虚拟画面卡住不动"（1.0.9 反馈）。
// 每秒自检：播到结尾就回头、没在播就续播、item 失败就重建。
static BOOL g_watchdogStarted = NO;

static int g_stallTicks = 0;
static int g_diagTicks = 0;

// 把 item 整个换掉并从头播：比 seek 更狠，能解开 "rate=1 但一帧不动" 的僵死
static void vcamHardRestart(void) {
    if (!g_videoURL || !g_player) return;
    AVPlayerItem *fresh = [AVPlayerItem playerItemWithURL:g_videoURL];
    __weak AVPlayer *weakPlayer = g_player;
    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
        object:fresh queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            [weakPlayer seekToTime:kCMTimeZero];
            [weakPlayer play];
        }];
    [g_player replaceCurrentItemWithPlayerItem:fresh];
    if (g_playerLayer) {
        g_playerLayer.player = nil;
        g_playerLayer.player = g_player;
    }
    [g_player play];
    NSLog(@"[VCam] hard restart");
}

static void vcamResumePlayback(void) {
    if (!g_vcamEnabled || !g_videoURL) return;
    vcamEnsurePlayer();
    if (!g_player) return;
    AVPlayerItem *item = g_player.currentItem;
    if (!item || item.status == AVPlayerItemStatusFailed) {
        NSLog(@"[VCam] player item failed -> rebuild");
        vcamHardRestart();
        item = g_player.currentItem;
    }
    double dur = CMTimeGetSeconds(item.duration);
    double cur = CMTimeGetSeconds(g_player.currentTime);
    if (dur > 0 && cur >= dur - 0.15) {
        [g_player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
    if (g_player.rate == 0.0 && g_player.status != AVPlayerStatusFailed) {
        [g_player play];
    }
    // 僵死判定：前台却连续 2 秒不是 playing（rate=1 但 timeControlStatus 卡在 waiting 也算），
    // 直接换 item 重播。
    BOOL active = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
    if (active && g_player.timeControlStatus != AVPlayerTimeControlStatusPlaying) {
        if (++g_stallTicks >= 2) {
            g_stallTicks = 0;
            vcamHardRestart();
        }
    } else {
        g_stallTicks = 0;
    }
    if (++g_diagTicks % 5 == 0) {
        NSLog(@"[VCam] state tc=%ld rate=%.1f t=%.2f/%.2f item=%ld super=%d",
              (long)g_player.timeControlStatus, g_player.rate, cur, dur,
              (long)item.status, g_playerLayer.superlayer != nil);
    }
}

static void vcamStartWatchdog(void) {
    if (g_watchdogStarted) return;
    g_watchdogStarted = YES;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              (uint64_t)(1.0 * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, ^{ vcamResumePlayback(); });
    dispatch_resume(t);
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            vcamResumePlayback();
            vcamRefreshPreviews();
        }];
    NSLog(@"[VCam] playback watchdog started");
}

// ============================================================================
// MARK: - 悬浮按钮 UI
// ============================================================================

@interface VCamFloatButton : UIButton
@property (nonatomic, assign) CGPoint initialCenter;
@end

@implementation VCamFloatButton
@end

// 透明悬浮窗：只在按钮区域吃掉触摸，其余位置一律透传给宿主 App。
// 1.0.2 用过裸 UIWindow（全屏 + hidden=NO），会抢 key window 并吃掉整屏触摸，
// 在系统相机里表现为界面点不动 / 预览卡住。
@interface VCamOverlayWindow : UIWindow
@end

@implementation VCamOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == nil) return nil;
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeFocused { return NO; }

@end


static void setupFloatButton(void);
static void handlePanGesture(UIPanGestureRecognizer *gesture);
static void handleTapGesture(UITapGestureRecognizer *gesture);

static void setupFloatButton() {
    if (g_floatButton) return;
    
    CGFloat btnSize = 50;
    CGRect screen = [UIScreen mainScreen].bounds;
    
    g_floatButton = [VCamFloatButton buttonWithType:UIButtonTypeSystem];
    g_floatButton.frame = CGRectMake(screen.size.width - btnSize - 15, 100, btnSize, btnSize);
    g_floatButton.layer.cornerRadius = btnSize / 2.0;
    g_floatButton.layer.shadowColor = [UIColor blackColor].CGColor;
    g_floatButton.layer.shadowOffset = CGSizeMake(0, 2);
    g_floatButton.layer.shadowOpacity = 0.3;
    g_floatButton.layer.shadowRadius = 4;
    g_floatButton.backgroundColor = g_vcamEnabled 
        ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
        : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
    
    [g_floatButton setTitle:@"📷" forState:UIControlStateNormal];
    g_floatButton.titleLabel.font = [UIFont systemFontOfSize:24];
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] 
        initWithTarget:g_floatButton action:@selector(handlePan:)];
    [g_floatButton addGestureRecognizer:pan];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] 
        initWithTarget:g_floatButton action:@selector(handleTap:)];
    [g_floatButton addGestureRecognizer:tap];
    
    g_overlayWindow = [[VCamOverlayWindow alloc] initWithFrame:screen];
    g_overlayWindow.windowLevel = UIWindowLevelAlert + 100;
    g_overlayWindow.hidden = NO;
    g_overlayWindow.backgroundColor = [UIColor clearColor];
    
    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    [rootVC.view addSubview:g_floatButton];
    g_overlayWindow.rootViewController = rootVC;
    
    // Register selectors on the button class
    class_addMethod([g_floatButton class], @selector(handlePan:), 
                    (IMP)handlePanGesture, "v@:@");
    class_addMethod([g_floatButton class], @selector(handleTap:), 
                    (IMP)handleTapGesture, "v@:@");
}

static void handlePanGesture(UIPanGestureRecognizer *gesture) {
    UIView *btn = gesture.view;
    CGPoint translation = [gesture translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:btn.superview];
    
    if (gesture.state == UIGestureRecognizerStateEnded) {
        CGRect screen = [UIScreen mainScreen].bounds;
        CGFloat x = btn.center.x < screen.size.width / 2 ? 35 : screen.size.width - 35;
        [UIView animateWithDuration:0.2 animations:^{
            btn.center = CGPointMake(x, btn.center.y);
        }];
    }
}

static UIViewController *findTopViewController(void) {
    UIViewController *topVC = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.isKeyWindow) {
                    topVC = w.rootViewController;
                    break;
                }
            }
        }
    }
    while (topVC && topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    return topVC;
}

@interface VCamImagePickerControllerDelegate : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

@implementation VCamImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker 
        didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    
    NSURL *url = info[UIImagePickerControllerMediaURL];
    if (!url) return;
    
    NSURL *tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() 
        stringByAppendingPathComponent:@"vcam_input.mp4"]];
    [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
    [[NSFileManager defaultManager] copyItemAtURL:url toURL:tempURL error:nil];
    
    [[MediaManager sharedManager] loadMediaFromURL:tempURL];
    g_videoURL = tempURL;
    vcamRefreshPreviews();
    g_vcamEnabled = YES;
    [[MediaManager sharedManager] start];
    vcamResumePlayback();
    if (g_floatButton) {
        g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end

static VCamImagePickerControllerDelegate *g_pickerDelegate = nil;

static void handleTapGesture(UITapGestureRecognizer *gesture) {
    UIViewController *topVC = findTopViewController();
    if (!topVC) return;
    
    UIAlertController *alert = [UIAlertController 
        alertControllerWithTitle:@"VCam" 
        message:g_vcamEnabled ? @"虚拟相机已启用" : @"虚拟相机已关闭"
        preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"选择视频" 
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        
        if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeSavedPhotosAlbum]) {
            return;
        }
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypeSavedPhotosAlbum;
        picker.mediaTypes = @[@"public.movie"];
        picker.delegate = g_pickerDelegate;
        [topVC presentViewController:picker animated:YES completion:nil];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:g_vcamEnabled ? @"关闭虚拟相机" : @"开启虚拟相机" 
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        g_vcamEnabled = !g_vcamEnabled;
        vcamRefreshPreviews();
        if (g_floatButton) {
            g_floatButton.backgroundColor = g_vcamEnabled 
                ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
                : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
        }
        if (g_vcamEnabled) {
            [[MediaManager sharedManager] start];
        } else {
            [[MediaManager sharedManager] stop];
        }
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = gesture.view;
        alert.popoverPresentationController.sourceRect = gesture.view.bounds;
    }
    
    [topVC presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// MARK: - Hook AVCaptureSession / Video Output
// ============================================================================

%group VCamHooks

// Replace the live preview picture with a looping video layer.
%hook AVCaptureVideoPreviewLayer

- (id)initWithSession:(AVCaptureSession *)session {
    self = %orig;
    if (self) {
        if (!g_previewLayers) g_previewLayers = [NSHashTable weakObjectsHashTable];
        [g_previewLayers addObject:self];
        vcamAttachPreview(self);
    }
    return self;
}

- (void)setSession:(AVCaptureSession *)session {
    %orig;
    if (!g_previewLayers) g_previewLayers = [NSHashTable weakObjectsHashTable];
    [g_previewLayers addObject:self];
    vcamAttachPreview(self);
}

- (void)layoutSublayers {
    %orig;
    if (g_playerLayer && g_playerLayer.superlayer == (CALayer *)self) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        g_playerLayer.frame = [(CALayer *)self bounds];
        [CATransaction commit];
    }
}

%end

%end // VCamHooks group

// ============================================================================
// MARK: - 拍照 / 录像 输出 hook
// ============================================================================

%group VCamCaptureHooks

// 拍照：任何拿 AVCapturePhoto 字节的 App（相机、微信、抖音、网页上传）都走这里
%hook AVCapturePhoto

- (NSData *)fileDataRepresentation {
    NSData *orig = %orig;
    if (!g_vcamEnabled || !g_videoURL || orig.length < 32) return orig;
    CGSize size = CGSizeZero;
    BOOL heic = NO;
    NSString *key = vcamPhotoKey(orig, &size, &heic);
    if (!key) return orig;
    NSData *hit = [g_photoCache objectForKey:key];
    if (hit.length > 0) {
        NSLog(@"[VCam] photo replaced %@ %lu B", key, (unsigned long)hit.length);
        return hit;                       // 纯内存返回，不碰 capture 管线
    }
    vcamRenderPhotoAsync(key, size, heic); // 这一张先给真图，后台把该尺寸渲染好
    return orig;
}

%end

// 录像：AVCaptureMovieFileOutput 落盘后把文件换成我们的视频
%hook AVCaptureMovieFileOutput

- (void)startRecordingToOutputFileURL:(NSURL *)url recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    if (g_vcamEnabled && url.isFileURL) {
        objc_setAssociatedObject(self, kVCamMovieURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[VCam] recording -> %@", url.lastPathComponent);
    }
    %orig;
}

- (void)stopRecording {
    %orig;
    if (!g_vcamEnabled) return;
    NSURL *url = objc_getAssociatedObject(self, kVCamMovieURLKey);
    if (!url.isFileURL) return;
    NSString *path = url.path;
    // 落盘收尾有时间差：0.4s / 1.0s / 2.0s 各试一次（幂等，后一次覆盖前一次）
    for (NSNumber *delay in @[@0.4, @1.0, @2.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            vcamReplaceMovieAtPath(path);
        });
    }
}

%end

%end // VCamCaptureHooks group

// ============================================================================
// MARK: - Constructor
// ============================================================================

%ctor {
    @autoreleasepool {
        g_pickerDelegate = [[VCamImagePickerControllerDelegate alloc] init];
        
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        
        // 只跳过 SpringBoard：桌面不需要悬浮按钮，注进去只会添乱。
        // 其余 App（含系统相机 / FaceTime / 信息 / Safari）全部注入 = 系统级替换。
        if ([bundleID isEqualToString:@"com.apple.springboard"]) {
            NSLog(@"[VCam] skipped in %@", bundleID);
            return;
        }
        
        %init(VCamHooks);
        %init(VCamCaptureHooks);
        vcamLoadGlobalConfig();
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), 
            dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    setupFloatButton();
                    vcamStartWatchdog();
                }
            });
    }
}
