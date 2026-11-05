#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <netdb.h>
#import <unistd.h>
#import <substrate.h>
#import "MediaManager.h"

// ============================================================================
// MARK: - 全局状态
// ============================================================================

static BOOL g_vcamEnabled = NO;
static UIWindow *g_overlayWindow = nil;
static UIButton *g_floatButton = nil;

// ---- 1.0.15: 无图标交互（音量键唤起，悬浮球默认隐藏） ----
// 音量键走两条互不依赖的通道，任一条收到就够：
//   A. AVSystemController 的音量变化通知（进程内、可靠；方向靠比对前后音量）
//   B. UIApplication sendEvent 里的 GSEvent（type 12/13 直接给方向；不同 iOS 版本可能变）
// 两条都只观察不拦截：音量照常变化，"上一格 → 下一格"一个来回净变化为 0。
static BOOL g_showButton = NO;        // config.plist 的 showButton，默认隐藏
static BOOL g_volumeHooked = NO;
static int  g_volNotif = 0;
static int  g_volUp = 0;
static int  g_volDown = 0;
static int  g_lastGsType = -1;
static float g_lastVolume = -1.0f;
static BOOL g_volUpPending = NO;
static double g_volUpTime = 0;

static AVPlayer *g_player = nil;
static AVPlayerLayer *g_playerLayer = nil;
static NSURL *g_videoURL = nil;
static NSHashTable *g_previewLayers = nil;

// 实时微动（照片 + Core Animation 变换）的全局状态，声明放前面：config 读取要用
static BOOL  g_liveEnabled = NO;
static CALayer *g_liveLayer = nil;
static CADisplayLink *g_liveLink = nil;
static NSObject *g_liveDriver = nil;
static double g_liveT0 = 0;
static int    g_liveFrames = 0;
static double g_liveFPS = 0;
static double g_liveFPSAt = 0;
static CGImageRef g_livePhoto = NULL;
static CGSize g_livePhotoSize = {0, 0};
static int g_restarts = 0;
static NSString *g_pullURL = nil;

static void vcamAttachPreview(AVCaptureVideoPreviewLayer *pl);
static void vcamLiveAttach(CALayer *host);
static void vcamLiveStop(void);
static BOOL vcamLiveIsOn(void);
static CGImageRef vcamLiveFrameCGImage(void);

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
    g_showButton = cfg[@"showButton"] ? [cfg[@"showButton"] boolValue] : NO;
    g_liveEnabled = cfg[@"live"] ? [cfg[@"live"] boolValue] : NO;
    g_pullURL = [cfg[@"sourceURL"] isKindOfClass:[NSString class]] ? cfg[@"sourceURL"] : nil;
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
    if (vcamLiveIsOn()) {
        CGImageRef live = vcamLiveFrameCGImage();
        if (live) return live;      // 实时微动：拍照取当前这一帧的形变状态
    }
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
        vcamLiveStop();
        return;
    }
    if (vcamLiveIsOn()) {
        vcamLiveAttach((CALayer *)pl);
        if (g_playerLayer && g_playerLayer.superlayer == (CALayer *)pl) {
            [g_playerLayer removeFromSuperlayer];
        }
        [g_player pause];
        return;
    }
    vcamLiveStop();
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

// ============================================================================
// MARK: - 实时微动（照片 + Core Animation 变换，无神经网络、无解码）
// ============================================================================
// 8899 的 idle 本来就是「静止照片 + 合成运动轨迹」（呼吸/漂移/手抖/微摆），
// 这里把同一套轨迹直接打在 CALayer 上，由 GPU 合成，不产生像素拷贝。
// 局限：纯仿射，没有 3D 视角合成 —— 做不了明显转头，那是 LivePortrait 的活。
static CGImageRef vcamLivePhotoImage(void) {
    if (g_livePhoto) return g_livePhoto;
    NSString *p = [kVCamGlobalDir stringByAppendingPathComponent:@"photo.jpg"];
    UIImage *img = [UIImage imageWithContentsOfFile:p];
    if (!img) img = [UIImage imageWithContentsOfFile:[kVCamGlobalDir stringByAppendingPathComponent:@"photo.png"]];
    if (img.CGImage) {
        g_livePhoto = CGImageRetain(img.CGImage);
        g_livePhotoSize = CGSizeMake(CGImageGetWidth(g_livePhoto), CGImageGetHeight(g_livePhoto));
        NSLog(@"[VCam] live photo %@ %.0fx%.0f", p.lastPathComponent, g_livePhotoSize.width, g_livePhotoSize.height);
        return g_livePhoto;
    }
    // 没有 photo.jpg 就退回视频首帧，保证开箱能看
    if (g_videoURL) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:g_videoURL options:nil];
        AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
        gen.appliesPreferredTrackTransform = YES;
        gen.requestedTimeToleranceBefore = kCMTimeZero;
        gen.requestedTimeToleranceAfter = kCMTimeZero;
        CGImageRef cg = [gen copyCGImageAtTime:kCMTimeZero actualTime:NULL error:NULL];
        if (cg) {
            g_livePhoto = cg;
            g_livePhotoSize = CGSizeMake(CGImageGetWidth(cg), CGImageGetHeight(cg));
            NSLog(@"[VCam] live photo = video first frame %.0fx%.0f", g_livePhotoSize.width, g_livePhotoSize.height);
            return g_livePhoto;
        }
    }
    return NULL;
}

// 当前时刻的运动参数（与 studio.py 的 idle 同构：4s 呼吸、8s 漂移、56 周期手抖）
typedef struct { double sx, sy, rot, scale; } VCamMotion;
static VCamMotion vcamMotionAt(double t) {
    const double tw = 2.0 * M_PI;
    VCamMotion m;
    m.scale = 1.0 + 0.006 * sin(tw * t / 4.0);
    m.sx = 2.4 * sin(tw * t / 8.0) + 1.1 * sin(tw * 2.0 * t / 8.0)
         + 0.45 * sin(tw * 56.0 * t / 8.0);
    m.sy = 1.6 * sin(tw * t / 6.0 + 1.2) + 0.35 * sin(tw * 47.0 * t / 8.0);
    m.rot = 0.25 * sin(tw * t / 9.0);
    return m;
}

// 把当前运动状态烘成一张 CGImage，供拍照替换使用（背景队列调用，+1 引用）
static CGImageRef vcamLiveFrameCGImage(void) {
    CGImageRef photo = vcamLivePhotoImage();
    if (!photo) return NULL;
    double t = g_liveT0 > 0 ? CACurrentMediaTime() - g_liveT0 : 0;
    VCamMotion m = vcamMotionAt(t);
    size_t W = (size_t)g_livePhotoSize.width, H = (size_t)g_livePhotoSize.height;
    if (W == 0 || H == 0) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, 0, cs, kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextTranslateCTM(ctx, W / 2.0 + m.sx, H / 2.0 + m.sy);
    CGContextRotateCTM(ctx, m.rot * M_PI / 180.0);
    CGContextScaleCTM(ctx, m.scale, m.scale);
    CGContextDrawImage(ctx, CGRectMake(-W / 2.0, -H / 2.0, W, H), photo);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

static void vcamLiveTick(void) {
    if (!g_liveEnabled || !g_liveLayer || !g_liveLayer.superlayer) return;
    double now = CACurrentMediaTime();
    if (g_liveT0 <= 0) g_liveT0 = now;
    VCamMotion m = vcamMotionAt(now - g_liveT0);
    CGFloat rad = (CGFloat)(m.rot * M_PI / 180.0);
    CATransform3D tr = CATransform3DMakeScale((CGFloat)m.scale, (CGFloat)m.scale, 1.0);
    tr = CATransform3DRotate(tr, rad, 0, 0, 1);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    g_liveLayer.transform = tr;
    g_liveLayer.position = CGPointMake(g_liveLayer.superlayer.bounds.size.width / 2.0 + m.sx,
                                       g_liveLayer.superlayer.bounds.size.height / 2.0 + m.sy);
    [CATransaction commit];
    g_liveFrames++;
    if (g_liveFPSAt <= 0) g_liveFPSAt = now;
    if (now - g_liveFPSAt >= 1.0) {
        g_liveFPS = g_liveFrames / (now - g_liveFPSAt);
        g_liveFrames = 0;
        g_liveFPSAt = now;
    }
}

@interface VCamLiveDriver : NSObject
@end

@implementation VCamLiveDriver
- (void)tick:(CADisplayLink *)link { vcamLiveTick(); }
@end

static void vcamLiveAttach(CALayer *host) {
    if (!host) return;
    CGImageRef photo = vcamLivePhotoImage();
    if (!photo) return;
    if (!g_liveLayer) {
        g_liveLayer = [CALayer layer];
        g_liveLayer.contentsGravity = kCAGravityResizeAspectFill;
        g_liveLayer.masksToBounds = YES;
        g_liveLayer.contents = (__bridge id)photo;
    }
    // 放大 8%，保证旋转/平移时不会露出边缘
    CGRect b = host.bounds;
    CGFloat w = b.size.width * 1.08, h = b.size.height * 1.08;
    g_liveLayer.bounds = CGRectMake(0, 0, w, h);
    g_liveLayer.position = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    if (g_liveLayer.superlayer != host) {
        [g_liveLayer removeFromSuperlayer];
        [host addSublayer:g_liveLayer];
    }
    if (!g_liveLink) {
        if (!g_liveDriver) g_liveDriver = [[VCamLiveDriver alloc] init];
        g_liveLink = [CADisplayLink displayLinkWithTarget:g_liveDriver selector:@selector(tick:)];
        g_liveLink.preferredFramesPerSecond = 30;
        [g_liveLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        g_liveT0 = CACurrentMediaTime();
        NSLog(@"[VCam] live warp started (photo %.0fx%.0f)", g_livePhotoSize.width, g_livePhotoSize.height);
    }
}

static void vcamLiveStop(void) {
    if (g_liveLink) {
        [g_liveLink invalidate];
        g_liveLink = nil;
    }
    if (g_liveLayer) [g_liveLayer removeFromSuperlayer];
    g_liveFPS = 0;
}

static BOOL vcamLiveIsOn(void) { return g_liveEnabled; }

static void vcamLiveSetEnabled(BOOL on) {
    g_liveEnabled = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"VCamLive"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (!on) vcamLiveStop();
    vcamRefreshPreviews();
    NSLog(@"[VCam] live=%d", on);
}

// ============================================================================
// MARK: - 从 PC 拉素材（8899/8898 → 手机）
// ============================================================================
// 自建 socket 发 HTTP/1.1 GET：不走 NSURLSession，宿主 App 的 ATS 管不到这里。
// 文件写进 App 自己的 tmp（沙箱可写），再交给播放器 —— 不用 root、不用改 /var/jb
// 权限，也不需要 PC 端开监听。
static int g_pullOK = 0;
static int g_pullFail = 0;
static double g_pullBytes = 0;
static void vcamResumePlayback(void);
static UIViewController *findTopViewController(void);
static BOOL vcamUseLocalClip(BOOL force);
static void vcamToast(NSString *msg);

static NSData *vcamDechunk(NSData *body) {
    NSMutableData *out = [NSMutableData data];
    const uint8_t *p = (const uint8_t *)body.bytes, *end = p + body.length;
    while (p < end) {
        const uint8_t *nl = (const uint8_t *)memchr(p, 0x0A, (size_t)(end - p));
        if (!nl) break;
        long len = strtol((const char *)p, NULL, 16);
        p = nl + 1;
        if (len <= 0 || p + len > end) break;
        [out appendBytes:p length:(NSUInteger)len];
        p += len + 2;               // 跳过 chunk 后的 CRLF
    }
    return out.length ? out : nil;
}

static NSData *vcamHTTPGet(NSString *urlString, NSUInteger maxBytes) {
    NSURLComponents *c = [NSURLComponents componentsWithString:urlString];
    if (!c.host) return nil;
    NSString *host = c.host;
    NSString *port = c.port ? c.port.stringValue : @"80";
    NSString *path = c.percentEncodedPath.length ? c.percentEncodedPath : @"/";
    if (c.percentEncodedQuery) path = [path stringByAppendingFormat:@"?%@", c.percentEncodedQuery];

    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host.UTF8String, port.UTF8String, &hints, &res) != 0 || !res) return nil;
    int fd = socket(res->ai_family, res->ai_socktype, 0);
    if (fd < 0) { freeaddrinfo(res); return nil; }
    struct timeval tv = {8, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
        close(fd); freeaddrinfo(res); return nil;
    }
    freeaddrinfo(res);

    NSString *req = [NSString stringWithFormat:
        @"GET %@ HTTP/1.1\r\nHost: %@\r\nUser-Agent: VCam\r\nConnection: close\r\n\r\n", path, host];
    const char *rq = req.UTF8String;
    send(fd, rq, strlen(rq), 0);

    NSMutableData *resp = [NSMutableData data];
    char buf[64 * 1024];
    ssize_t n;
    while ((n = recv(fd, buf, sizeof(buf), 0)) > 0) {
        [resp appendBytes:buf length:(NSUInteger)n];
        if (resp.length > maxBytes) { close(fd); return nil; }
    }
    close(fd);
    if (resp.length < 32) return nil;

    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange r = [resp rangeOfData:sep options:0 range:NSMakeRange(0, MIN(resp.length, 8192))];
    if (r.location == NSNotFound) return nil;
    NSString *head = [[NSString alloc] initWithData:[resp subdataWithRange:NSMakeRange(0, r.location)]
                                           encoding:NSASCIIStringEncoding];
    if (!head || [head rangeOfString:@" 200 "].location == NSNotFound) {
        NSLog(@"[VCam] pull head: %@", [head componentsSeparatedByString:@"\r\n"].firstObject);
        return nil;
    }
    NSData *body = [resp subdataWithRange:NSMakeRange(NSMaxRange(r), resp.length - NSMaxRange(r))];
    if ([head.lowercaseString containsString:@"transfer-encoding: chunked"]) body = vcamDechunk(body);
    return body.length ? body : nil;
}

// 换片：重建 AVPlayer 和图层绑定。只改 g_videoURL 不动播放器 = 画面不变，
// 1.0.20 的「拉取没变化」就是这个坑。
static void vcamSwapVideo(NSURL *url) {
    if (!url) return;
    g_videoURL = url;
    g_vcamEnabled = YES;
    AVPlayer *p = [AVPlayer playerWithURL:url];
    p.muted = YES;
    p.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    __weak AVPlayer *wp = p;
    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
        object:p.currentItem queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            [wp seekToTime:kCMTimeZero];
            [wp playImmediatelyAtRate:1.0];
        }];
    g_player = p;
    if (!g_playerLayer) {
        g_playerLayer = [AVPlayerLayer playerLayerWithPlayer:p];
        g_playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        g_playerLayer.backgroundColor = [UIColor blackColor].CGColor;
    } else {
        g_playerLayer.player = p;
    }
    [p playImmediatelyAtRate:1.0];
    g_restarts++;
    [[MediaManager sharedManager] loadMediaFromURL:url];
    vcamRefreshPreviews();
    NSLog(@"[VCam] swapped to %@", url.lastPathComponent);
}

static void vcamFetchFromPC(void) {
    if (g_pullURL.length == 0) {
        NSLog(@"[VCam] pull: sourceURL 未配置");
        return;
    }
    NSString *url = [g_pullURL copy];
    NSLog(@"[VCam] pull %@", url);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *data = vcamHTTPGet(url, 400u * 1024u * 1024u);
        if (data.length < 1024) {
            g_pullFail++;
            NSLog(@"[VCam] pull failed (%lu B)", (unsigned long)data.length);
            BOOL local = vcamUseLocalClip(YES);      // 网络不通就走 DCIM 通道
            vcamToast(local ? @"从 PC 拉取失败，已改用 DCIM 里的片段"
                            : @"从 PC 拉取失败，DCIM 里也没有片段");
            return;
        }
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_pull.mp4"];
        BOOL ok = [data writeToFile:tmp atomically:YES];
        NSLog(@"[VCam] pull got %.1f MB ok=%d", data.length / 1048576.0, ok);
        if (!ok) { g_pullFail++; return; }
        g_pullOK++;
        g_pullBytes = data.length / 1048576.0;
        vcamToast([NSString stringWithFormat:@"已从 PC 拉取 %.0f KB", data.length / 1024.0]);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (vcamLiveIsOn()) vcamLiveSetEnabled(NO);   // 拉到文件就切回视频模式
            vcamSwapVideo([NSURL fileURLWithPath:tmp]);
        });
    });
}

// ============================================================================
// MARK: - 本地片段（DCIM）——不需要网络的通道
// ============================================================================
// Camera.app 的沙箱允许读写 /var/mobile/Media/DCIM（它自己就把照片存那儿），
// 所以 PC 用 AFC 把片段推进 DCIM 后，进程里直接读得到 —— 不依赖局域网、
// 不依赖 App 有没有网络权限（后者恰恰是系统相机最可能没有的）。
static double g_videoMTime = 0;

static void vcamToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = findTopViewController();
        if (!top) { NSLog(@"[VCam] toast(no vc): %@", msg); return; }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"VCam"
                                                                  message:msg
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
    });
}

static NSString *vcamNewestDCIMClip(double *mtimeOut) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/mobile/Media/DCIM";
    NSString *best = nil;
    double bestT = 0;
    NSMutableArray *dirs = [NSMutableArray array];
    for (NSString *d in [fm contentsOfDirectoryAtPath:root error:NULL]) {
        [dirs addObject:[root stringByAppendingPathComponent:d]];
    }
    NSMutableArray *files = [NSMutableArray arrayWithArray:dirs];
    for (NSString *d in dirs) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:d isDirectory:&isDir] && isDir) {
            for (NSString *f in [fm contentsOfDirectoryAtPath:d error:NULL]) {
                [files addObject:[d stringByAppendingPathComponent:f]];
            }
        }
    }
    for (NSString *p in files) {
        NSString *ext = p.pathExtension.lowercaseString;
        if (!([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"])) continue;
        NSDictionary *a = [fm attributesOfItemAtPath:p error:NULL];
        double t = [a[NSFileModificationDate] timeIntervalSince1970];
        if (t > bestT) { bestT = t; best = p; }
    }
    if (mtimeOut) *mtimeOut = bestT;
    return best;
}

// 有比当前更新的片段就换上去。force=YES 时无论新旧都载入。
static BOOL vcamUseLocalClip(BOOL force) {
    double t = 0;
    NSString *p = vcamNewestDCIMClip(&t);
    if (!p) return NO;
    if (!force && t <= g_videoMTime) return NO;
    g_videoMTime = t;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (vcamLiveIsOn()) vcamLiveSetEnabled(NO);
        vcamSwapVideo([NSURL fileURLWithPath:p]);
        NSLog(@"[VCam] local clip %@", p.lastPathComponent);
    });
    return YES;
}

// 播放看门狗：拍照/查看照片/切前后台之后，AVPlayer 很容易被系统停住，
// 或者已经在结尾停下，表现就是"虚拟画面卡住不动"（1.0.9 反馈）。
// 每秒自检：播到结尾就回头、没在播就续播、item 失败就重建。
static BOOL g_watchdogStarted = NO;
// ARC 下 dispatch_source_t 是对象：只放局部变量，函数返回即释放 = 定时器当场被取消。
// 这就是 1.0.10~1.0.13 看门狗一次都没跑过（wd 恒 0）的原因，必须存全局强引用。
static dispatch_source_t g_watchdogTimer = nil;

static int g_stallTicks = 0;
static int g_diagTicks = 0;
static int g_wdTicks = 0;

// 屏幕上的自检信息（点 📷 → 状态），不依赖 syslog
static NSString *vcamDiagString(void) {
    AVPlayerItem *it = g_player.currentItem;   // 实时微动模式下 player 可能没建起来
    return [NSString stringWithFormat:
        @"enabled=%d app=%ld\ntimeControl=%ld rate=%.2f\nplayerStatus=%ld itemStatus=%ld\nt=%.2f / %.2f layer=%d\nwd=%d restarts=%d\nvol: gs=%d n=%d up=%d dn=%d btn=%d\nlive=%d fps=%.1f pull=%d/%d %.1fMB\nvideo=%@",
        g_vcamEnabled, (long)[UIApplication sharedApplication].applicationState,
        (long)g_player.timeControlStatus, g_player.rate,
        (long)g_player.status, (long)it.status,
        CMTimeGetSeconds(g_player.currentTime), CMTimeGetSeconds(it.duration),
        g_playerLayer.superlayer != nil, g_wdTicks, g_restarts,
        g_lastGsType, g_volNotif, g_volUp, g_volDown,
        (g_overlayWindow && !g_overlayWindow.hidden),
        g_liveEnabled, g_liveFPS, g_pullOK, g_pullFail, g_pullBytes,
        g_videoURL.lastPathComponent ?: @"(none)"];
}

// 整条播放器重建：只换 item 解决不了"玩家本身卡死"（status=failed、或被系统按住 rate 恒 0）。
static void vcamRebuildPlayer(void) {
    if (!g_videoURL) return;
    static CFTimeInterval lastRebuild = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastRebuild < 5.0) return;   // 防抖：5 秒内最多重建一次，避免画面反复跳
    lastRebuild = now;
    AVPlayer *p = [AVPlayer playerWithURL:g_videoURL];
    p.muted = YES;
    p.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    __weak AVPlayer *wp = p;
    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
        object:p.currentItem queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            [wp seekToTime:kCMTimeZero];
            [wp playImmediatelyAtRate:1.0];
        }];
    g_player = p;
    if (!g_playerLayer) {
        g_playerLayer = [AVPlayerLayer playerLayerWithPlayer:p];
        g_playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        g_playerLayer.backgroundColor = [UIColor blackColor].CGColor;
    } else {
        g_playerLayer.player = p;
    }
    [p playImmediatelyAtRate:1.0];
    g_restarts++;
    NSLog(@"[VCam] player rebuilt (#%d)", g_restarts);
}

static void vcamResumePlayback(void) {
    if (!g_vcamEnabled || !g_videoURL) return;
    if (vcamLiveIsOn()) { g_wdTicks++; return; }   // 实时微动不播文件，不需要看门狗
    g_wdTicks++;
    vcamEnsurePlayer();
    if (!g_player || g_player.status == AVPlayerStatusFailed) { vcamRebuildPlayer(); return; }
    AVPlayerItem *item = g_player.currentItem;
    if (!item || item.status == AVPlayerItemStatusFailed) { vcamRebuildPlayer(); return; }
    double dur = CMTimeGetSeconds(item.duration);
    double cur = CMTimeGetSeconds(g_player.currentTime);
    if (dur > 0 && cur >= dur - 0.15) {
        [g_player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
    if (g_player.rate == 0.0) {
        [g_player playImmediatelyAtRate:1.0];   // 比 play() 硬：不等缓冲直接推
    }
    BOOL active = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
    if (active && g_player.timeControlStatus != AVPlayerTimeControlStatusPlaying) {
        if (++g_stallTicks >= 2) {
            g_stallTicks = 0;
            vcamRebuildPlayer();
        }
    } else {
        g_stallTicks = 0;
    }
    if (++g_diagTicks % 5 == 0) {
        NSLog(@"[VCam] state tc=%ld rate=%.1f t=%.2f/%.2f item=%ld player=%ld wd=%d restarts=%d super=%d",
              (long)g_player.timeControlStatus, g_player.rate, cur, dur, (long)item.status,
              (long)g_player.status, g_wdTicks, g_restarts, g_playerLayer.superlayer != nil);
    }
}

static void vcamStartWatchdog(void) {
    if (g_watchdogStarted) return;
    g_watchdogStarted = YES;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    g_watchdogTimer = t;   // 保住强引用，否则定时器立刻失效
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
static void handlePanGesture(id target, SEL cmd, UIPanGestureRecognizer *gesture);
static void handleTapGesture(id target, SEL cmd, UITapGestureRecognizer *gesture);

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

// 注意签名：class_addMethod 装上来的 IMP 是按 (id self, SEL _cmd, id arg) 调用的。
// 只写一个参数 = 把 self(按钮) 当成手势对象，随后给 UIButton 发 -view 直接
// unrecognized selector 崩溃（1.0.16 自带相机点图标闪退就是这么来的）。
static void handlePanGesture(id target, SEL cmd, UIPanGestureRecognizer *gesture) {
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

// 悬浮球默认隐藏；偏好优先读 NSUserDefaults（沙箱内可写，按 App 记忆），
// 没有记录时退回 deb 里 config.plist 的 showButton。
static BOOL vcamButtonPref(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"VCamShowButton"];
    if (v) return [v boolValue];
    return g_showButton;
}

static void vcamSetButtonVisible(BOOL show) {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:@"VCamShowButton"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (show) {
        setupFloatButton();
        g_overlayWindow.hidden = NO;
    } else if (g_overlayWindow) {
        g_overlayWindow.hidden = YES;
    }
    NSLog(@"[VCam] button visible=%d", show);
}

static void vcamShowMenu(UIView *sourceView) {
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
    
    [alert addAction:[UIAlertAction actionWithTitle:@"状态（诊断）"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIAlertController *d = [UIAlertController alertControllerWithTitle:@"VCam 状态"
            message:vcamDiagString() preferredStyle:UIAlertControllerStyleAlert];
        [d addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *top = findTopViewController();
        [top presentViewController:d animated:YES completion:nil];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"从 PC 拉取素材"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        vcamFetchFromPC();
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"载入 DCIM 最新片段"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (!vcamUseLocalClip(YES)) vcamToast(@"DCIM 里没有 mp4/mov");
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:g_liveEnabled ? @"实时微动：开（照片）" : @"实时微动：关（视频）"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        vcamLiveSetEnabled(!g_liveEnabled);
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:(g_overlayWindow && !g_overlayWindow.hidden) ? @"隐藏悬浮球" : @"显示悬浮球"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        vcamSetButtonVisible(!(g_overlayWindow && !g_overlayWindow.hidden));
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    if (alert.popoverPresentationController) {
        UIView *src = sourceView ?: topVC.view;
        alert.popoverPresentationController.sourceView = src;
        alert.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(src.bounds), CGRectGetMidY(src.bounds), 1, 1);
    }
    
    [topVC presentViewController:alert animated:YES completion:nil];
}

static void handleTapGesture(id target, SEL cmd, UITapGestureRecognizer *gesture) {
    vcamShowMenu(gesture.view);
}

// ---- 音量键：上一格 → 下一格（1 秒内）唤出菜单 ----

static void vcamVolumeEvent(BOOL up) {
    // 关掉虚拟相机后仍然要能唤出菜单，否则「无按钮 + 音量键不响应」= 再也打不开
    double now = CACurrentMediaTime();
    if (up) {
        g_volUp++;
        g_volUpTime = now;
        g_volUpPending = YES;
        return;
    }
    g_volDown++;
    if (!g_volUpPending || now - g_volUpTime > 1.0) return;
    g_volUpPending = NO;
    NSLog(@"[VCam] volume trigger (up->down)");
    dispatch_async(dispatch_get_main_queue(), ^{
        vcamShowMenu(nil);
    });
}

// GSEventGetType 是 GraphicsServices 的私有符号，用 dlsym 取，避免链私有 framework
typedef uint32_t (*VCamGSEventGetTypeFn)(void *);
static uint32_t vcamGSEventType(void *gs) {
    static VCamGSEventGetTypeFn fn = NULL;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        fn = (VCamGSEventGetTypeFn)dlsym(RTLD_DEFAULT, "GSEventGetType");
    }
    return fn ? fn(gs) : 0xFFFFFFFFu;
}

@interface VCamAVSystemController : NSObject
+ (instancetype)sharedAVSystemController;
- (BOOL)setAttribute:(id)attribute forKey:(NSString *)key error:(NSError **)error;
- (BOOL)getActiveCategoryVolume:(float *)volume andName:(NSString **)name;
@end

static void vcamStartVolumeMonitor(void) {
    if (g_volumeHooked) return;
    g_volumeHooked = YES;
    Class cls = NSClassFromString(@"AVSystemController");
    if (!cls) {
        NSLog(@"[VCam] volume: no AVSystemController");
        return;
    }
    id sys = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedAVSystemController));
    float v = 0;
    NSString *name = nil;
    if (((BOOL (*)(id, SEL, float *, NSString **))objc_msgSend)(
            sys, @selector(getActiveCategoryVolume:andName:), &v, &name)) {
        g_lastVolume = v;
    }
    ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(
        sys, @selector(setAttribute:forKey:error:),
        @"On", @"AVSystemController_SystemVolumeDidChangeNotification", NULL);
    [[NSNotificationCenter defaultCenter] addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        g_volNotif++;
        NSDictionary *info = note.userInfo;
        NSString *reason = info[@"AVSystemController_AudioVolumeChangeReasonNotificationParameter"];
        if (reason && ![reason isEqualToString:@"ExplicitVolumeChange"]) return;
        float nv = [info[@"AVSystemController_AudioVolumeNotificationParameter"] floatValue];
        if (g_lastVolume >= 0) {
            if (nv > g_lastVolume + 0.001f) vcamVolumeEvent(YES);
            else if (nv < g_lastVolume - 0.001f) vcamVolumeEvent(NO);
        }
        g_lastVolume = nv;
    }];
    NSLog(@"[VCam] volume monitor started (vol=%.2f)", g_lastVolume);
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
// MARK: - 音量键 hook
// ============================================================================

%group VCamVolumeHooks

%hook UIApplication

// 音量键按下会作为 GSEvent 走 sendEvent。只读不拦，type 12=上 / 13=下。
- (void)sendEvent:(UIEvent *)event {
    %orig;
    SEL gsSel = NSSelectorFromString(@"_gsEvent");
    if (![event respondsToSelector:gsSel]) return;
    void *gs = ((void *(*)(id, SEL))objc_msgSend)(event, gsSel);
    if (!gs) return;
    uint32_t t = vcamGSEventType(gs);
    if (t == 0xFFFFFFFFu) return;
    g_lastGsType = (int)t;
    if (t == 12) vcamVolumeEvent(YES);
    else if (t == 13) vcamVolumeEvent(NO);
}

%end

%end // VCamVolumeHooks group

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
        %init(VCamVolumeHooks);
        vcamLoadGlobalConfig();
        // 用户的开关优先于 deb 里的默认值（按 App 记忆）
        id livePref = [[NSUserDefaults standardUserDefaults] objectForKey:@"VCamLive"];
        if (livePref) g_liveEnabled = [livePref boolValue];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), 
            dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    if (vcamButtonPref()) setupFloatButton();
                    vcamStartVolumeMonitor();
                    vcamStartWatchdog();
                    vcamUseLocalClip(NO);      // PC 推进 DCIM 的片段优先于内置 video.mp4
                }
            });
        
        // 兜底：两条音量通道都没反应（机型/系统改了事件路径）时把悬浮球放出来，
        // 否则"无图标 + 音量键失效"会把唯一入口弄丢。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    if (g_volNotif == 0 && g_volUp == 0 && g_volDown == 0) {
                        NSLog(@"[VCam] volume trigger silent -> fallback button");
                        setupFloatButton();
                        g_overlayWindow.hidden = NO;
                    }
                }
            });

        // 配了 sourceURL 就在启动 3 秒后自动拉一次（8899/8898 -> 手机）
        if (g_pullURL.length > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    @autoreleasepool { vcamFetchFromPC(); }
                });
        }
    }
}
