#import <dlfcn.h>
#import "Tweak.h"

NSBundle *tweakBundle;
NSUserDefaults *tweakDefaults;
TWAdBlockAssetResourceLoaderDelegate *assetResourceLoaderDelegate;

// 1. BLOCK UPDATE PROMPTS
%hook TWAppUpdatePrompt
+ (void)startMonitoringSavantSettingsToShowPromptIfNeeded {}
%end

// 2. NETWORK INTERCEPTION
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"]) return %orig;
  if (![request isKindOfClass:NSMutableURLRequest.class]) request = request.mutableCopy;
  ((NSMutableURLRequest *)request).HTTPBody = [request.HTTPBody twab_requestDataForRequest:request];
  if (![tweakDefaults boolForKey:@"TWAdBlockProxyEnabled"]) return %orig;
  NSString *proxy = [tweakDefaults boolForKey:@"TWAdBlockCustomProxyEnabled"] ? [tweakDefaults stringForKey:@"TWAdBlockProxy"] : PROXY_ADDR;
  if (![request.URL.host isEqualToString:@"usher.ttvnw.net"]) return %orig;
  NSURL *proxyURL = [NSURL URLWithString:proxy];
  if ([proxyURL.scheme hasPrefix:@"http"])
    ((NSMutableURLRequest *)request).URL = [request.URL twab_URLWithProxyURL:proxyURL];
  else
    return &%orig([self twab_proxySessionWithAddress:proxy], _cmd, request);
  return %orig;
}
%end

// 3. BYPASS AMAZON IVS SDK
%hook IVSPlayer
- (void)setPath:(NSURL *)path {
    if ([tweakDefaults boolForKey:@"TWAdBlockVODUnlockEnabled"] && path && [path.host isEqualToString:@"usher.ttvnw.net"]) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:path resolvingAgainstBaseURL:YES];
        components.scheme = @"twab";
        %orig(components.URL);
        return;
    }
    %orig;
}
%end

%hook _TtC6Twitch21PlayerCoreVideoPlayer
- (void)player:(id)arg1 didFailWithError:(id)arg2 {
    if ([tweakDefaults boolForKey:@"TWAdBlockVODUnlockEnabled"]) return;
    %orig;
}
%end

// 4. ASSET RESOURCE LOADER HOOK
%hook AVURLAsset
- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
  if ([URL.scheme isEqualToString:@"twab"]) {
      if ((self = %orig)) {
          [self.resourceLoader setDelegate:assetResourceLoaderDelegate queue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)];
      }
      return self;
  }
  if ([tweakDefaults boolForKey:@"TWAdBlockVODUnlockEnabled"] && [URL.host isEqualToString:@"usher.ttvnw.net"]) {
      NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:YES];
      components.scheme = @"twab";
      URL = components.URL;
      if ((self = %orig)) {
          [self.resourceLoader setDelegate:assetResourceLoaderDelegate queue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)];
      }
      return self;
  }
  return %orig;
}
%end

// 5. PLAYER AUTO-PLAY FORCE
%hook AVPlayer
- (instancetype)init {
  if ((self = %orig)) {
    [self addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:NULL];
    [self addObserver:self forKeyPath:@"rate" options:NSKeyValueObservingOptionNew context:NULL];
  }
  return self;
}
%new
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
  if ([self status] == AVPlayerStatusReadyToPlay) [self play];
}
%end

// 6. LOW-LEVEL DATA MODEL BYPASS
@interface _TtC9TwitchKit5Video : NSObject
- (BOOL)currentUserIsRestricted;
@end
%hook _TtC9TwitchKit5Video
- (BOOL)currentUserIsRestricted { return NO; }
%end

// 7. BRUTAL UI REMOVAL
static void hideIfRestricted(UIView *view) {
    if (!view) return;
    @try {
        if ([view isKindOfClass:[UILabel class]]) {
            NSString *text = [((UILabel *)view).text lowercaseString];
            if (text && ([text containsString:@"réservé"] || [text containsString:@"abonné"] || [text containsString:@"sub"] || [text containsString:@"restricted"])) {
                view.superview.hidden = YES;
                return;
            }
        }
        for (UIView *subview in view.subviews) hideIfRestricted(subview);
    } @catch (id e) {}
}

@interface _TtC6Twitch30TheaterRequestErrorOverlayView : UIView
@end
%hook _TtC6Twitch30TheaterRequestErrorOverlayView
- (void)didMoveToWindow { %orig; self.hidden = YES; }
- (void)setHidden:(BOOL)hidden { %orig(YES); }
%end

%hook _TtC6Twitch21TheaterViewController
- (void)viewDidAppear:(BOOL)animated { %orig; hideIfRestricted(self.view); }
- (void)viewWillAppear:(BOOL)animated { %orig; hideIfRestricted(self.view); }
%end

// 8. CTOR & SYMBOLS
static void (*orig_PlaybackAccessTokenParams_init)(void *, void *, void *, void *, void *, void *, void *, void *);
static void hook_PlaybackAccessTokenParams_init(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    // 2 = some(false) in Swift Nullable<Bool>
    orig_PlaybackAccessTokenParams_init(a, (void *)2, c, d, e, f, g, h);
}

%ctor {
  rebind_symbols((struct rebinding[]){
      {"_$s13TwitchGraphQL25PlaybackAccessTokenParamsV12disableHTTPS10hasAdblock8platform13playerBackend0M4TypeAC9ApolloAPI0B10QLNullableOySbG_ALSSAKySSGSStcfC", (void *)hook_PlaybackAccessTokenParams_init, (void **)&orig_PlaybackAccessTokenParams_init},
  }, 1);

  tweakDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.level3tjg.twitchadblock"];
  if (![tweakDefaults objectForKey:@"TWAdBlockEnabled"]) [tweakDefaults setBool:YES forKey:@"TWAdBlockEnabled"];
  if (![tweakDefaults objectForKey:@"TWAdBlockVODUnlockEnabled"]) [tweakDefaults setBool:YES forKey:@"TWAdBlockVODUnlockEnabled"];
  if (![tweakDefaults objectForKey:@"TWAdBlockRestrictionRemoverEnabled"]) [tweakDefaults setBool:YES forKey:@"TWAdBlockRestrictionRemoverEnabled"];

  assetResourceLoaderDelegate = [[TWAdBlockAssetResourceLoaderDelegate alloc] init];
}
