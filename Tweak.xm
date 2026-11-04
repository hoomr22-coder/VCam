#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
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
        vcamLoadGlobalConfig();
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), 
            dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    setupFloatButton();
                }
            });
    }
}
