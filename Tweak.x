#import <dlfcn.h>
#import "Tweak.h"

NSBundle *tweakBundle;
NSUserDefaults *tweakDefaults;
TWAdBlockAssetResourceLoaderDelegate *assetResourceLoaderDelegate;

// Server-side video ad blocking

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"]) return %orig;
  if (![request isKindOfClass:NSMutableURLRequest.class]) request = request.mutableCopy;
  ((NSMutableURLRequest *)request).HTTPBody = [request.HTTPBody twab_requestDataForRequest:request];
  if (![tweakDefaults boolForKey:@"TWAdBlockProxyEnabled"]) return %orig;
  NSString *proxy = [tweakDefaults boolForKey:@"TWAdBlockCustomProxyEnabled"]
                        ? [tweakDefaults stringForKey:@"TWAdBlockProxy"]
                        : PROXY_ADDR;
  if (![request.URL.host isEqualToString:@"usher.ttvnw.net"]) return %orig;
  NSURL *proxyURL = [NSURL URLWithString:proxy];
  if ([proxyURL.scheme hasPrefix:@"http"])
    ((NSMutableURLRequest *)request).URL = [request.URL twab_URLWithProxyURL:proxyURL];
  else
    return &%orig([self twab_proxySessionWithAddress:proxy], _cmd, request);
  return %orig;
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData {
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"]) return %orig;
  if (![request isKindOfClass:NSMutableURLRequest.class]) request = request.mutableCopy;
  bodyData = [bodyData twab_requestDataForRequest:request];
  if (![tweakDefaults boolForKey:@"TWAdBlockProxyEnabled"]) return %orig;
  NSString *proxy = [tweakDefaults boolForKey:@"TWAdBlockCustomProxyEnabled"]
                        ? [tweakDefaults stringForKey:@"TWAdBlockProxy"]
                        : PROXY_ADDR;
  if (![request.URL.host isEqualToString:@"usher.ttvnw.net"]) return %orig;
  NSURL *proxyURL = [NSURL URLWithString:proxy];
  if ([proxyURL.scheme hasPrefix:@"http"])
    ((NSMutableURLRequest *)request).URL = [request.URL twab_URLWithProxyURL:proxyURL];
  else
    return &%orig([self twab_proxySessionWithAddress:proxy], _cmd, request, bodyData);
  return %orig;
}
%end

%hook AVURLAsset
- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
  BOOL adBlockEnabled = [tweakDefaults boolForKey:@"TWAdBlockEnabled"];
  BOOL proxyEnabled = [tweakDefaults boolForKey:@"TWAdBlockProxyEnabled"];
  BOOL vodUnlockEnabled = [tweakDefaults boolForKey:@"TWAdBlockVODUnlockEnabled"];

  if (!adBlockEnabled || (!proxyEnabled && !vodUnlockEnabled) ||
      ![URL.scheme isEqualToString:@"https"] || ![URL.host isEqualToString:@"usher.ttvnw.net"])
    return %orig;
  
  if (proxyEnabled) {
      NSURL *proxyURL = [NSURL URLWithString:[tweakDefaults boolForKey:@"TWAdBlockCustomProxyEnabled"]
                                                 ? [tweakDefaults stringForKey:@"TWAdBlockProxy"]
                                                 : PROXY_ADDR];
      if ([proxyURL.scheme hasPrefix:@"http"])
        return %orig([URL twab_URLWithProxyURL:proxyURL], options);
  }

  NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:YES];
  components.scheme = @"twab";
  URL = components.URL;
  if ((self = %orig)) {
    [self.resourceLoader setDelegate:assetResourceLoaderDelegate
                               queue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)];
  }
  return self;
}
%end

%hook AVPlayer
- (instancetype)init {
  if ((self = %orig)) {
    [self addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:NULL];
    [self addObserver:self forKeyPath:@"rate" options:NSKeyValueObservingOptionNew context:NULL];
  }
  return self;
}
%new
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
  if ([keyPath isEqualToString:@"status"]) {
      if ([change[NSKeyValueChangeNewKey] integerValue] == AVPlayerStatusReadyToPlay) {
          [self play];
      }
  } else if ([keyPath isEqualToString:@"rate"]) {
      if ([change[NSKeyValueChangeNewKey] floatValue] == 0.0 && [self status] == AVPlayerStatusReadyToPlay) {
          [self play];
      }
  }
}
%end

// Client-side video ad blocking

static void removeAdControllers(void *ptr) {
  if (((uintptr_t)ptr & 0xFFFF800000000000) != 0) return;
  id obj = (__bridge id)ptr;
  Ivar theaterAdControllerIvar =
      class_getInstanceVariable(object_getClass(obj), "theaterAdController");
  if (!theaterAdControllerIvar) return;
  id theaterAdController = object_getIvar(obj, theaterAdControllerIvar);
  const char *ivars[] = {"displayAdController", "streamDisplayAdStateManager", "vastAdController"};
  for (int i = 0; i < sizeof(ivars) / sizeof(ivars[0]); i++) {
    Ivar adControllerIvar =
        class_getInstanceVariable(object_getClass(theaterAdController), ivars[i]);
    if (adControllerIvar) object_setIvar(theaterAdController, adControllerIvar, nil);
  }
}

static void *(*orig_swift_unknownObjectWeakAssign)(void *, void *);
static void *hook_swift_unknownObjectWeakAssign(void *ref, void *value) {
  void *result = orig_swift_unknownObjectWeakAssign(ref, value);
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"]) return result;
  removeAdControllers(value);
  return result;
}

static void *(*orig_swift_unknownObjectWeakLoadStrong)(void *);
static void *hook_swift_unknownObjectWeakLoadStrong(void *ref) {
  void *result = orig_swift_unknownObjectWeakLoadStrong(ref);
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"]) return result;
  removeAdControllers(result);
  return result;
}

// Block ads in feed tab

%hook _TtC9TwitchKit18TKURLSessionClient
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"]) return %orig;
  %orig(session, dataTask, [data twab_responseDataForRequest:dataTask.currentRequest]);
}
%end

// Block ads in following tab

%hook _TtC6Twitch23FollowingViewController
- (instancetype)initWithGraphQL:(_TtC9TwitchKit9TKGraphQL *)graphQL
                   themeManager:(_TtC12TwitchCoreUI21TWDefaultThemeManager *)themeManager {
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"]) return %orig;
  if ((self = %orig)) {
    Ivar headlinerManagerIvar =
        class_getInstanceVariable(object_getClass(self), "headlinerManager");
    if (headlinerManagerIvar) {
      Ivar displayAdStateManagerIvar =
          class_getInstanceVariable(object_getClass(self), "displayAdStateManager");
      if (displayAdStateManagerIvar) object_setIvar(self, displayAdStateManagerIvar, nil);
    }
  }
  return self;
}
- (instancetype)initWithGraphQL:(_TtC9TwitchKit9TKGraphQL *)graphQL
                   themeManager:(_TtC12TwitchCoreUI21TWDefaultThemeManager *)themeManager
                  urlController:(_TtC6Twitch13URLController *)urlController {
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"]) return %orig;
  if ((self = %orig)) {
    Ivar headlinerManagerIvar =
        class_getInstanceVariable(object_getClass(self), "headlinerManager");
    if (headlinerManagerIvar) {
      Ivar displayAdStateManagerIvar =
          class_getInstanceVariable(object_getClass(self), "displayAdStateManager");
      if (displayAdStateManagerIvar) object_setIvar(self, displayAdStateManagerIvar, nil);
    }
  }
  return self;
}
%end

%hook _TtC6Twitch27HeadlinerFollowingAdManager
+ (instancetype)shared {
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"]) return %orig;
  _TtC6Twitch27HeadlinerFollowingAdManager *shared = %orig;
  if (shared) {
    Ivar displayAdStateManagerIvar =
        class_getInstanceVariable(object_getClass(shared), "displayAdStateManager");
    if (displayAdStateManagerIvar) object_setIvar(shared, displayAdStateManagerIvar, nil);
  }
  return shared;
}
%end

// Block update prompt

%hook TWAppUpdatePrompt
+ (void)startMonitoringSavantSettingsToShowPromptIfNeeded {
}
%end

// Restriction Remover UI Hooks

@interface _TtC6Twitch30TheaterRequestErrorOverlayView : UIView
@end

@interface _TtC6Twitch19TheaterMetadataView : UIView
@end

@interface _TtC6Twitch31SubscriptionBenefitsSummaryView : UIView
@end

@interface _TtC6Twitch20UpsellViewController : UIViewController
@end

// Helper to hide views containing specific text
static void hideIfRestricted(UIView *view) {
    if (!view || ![tweakDefaults boolForKey:@"TWAdBlockRestrictionRemoverEnabled"]) return;
    
    @try {
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            NSString *text = [label.text lowercaseString];
            if (text && ([text containsString:@"réservé"] || [text containsString:@"abonné"] || [text containsString:@"restricted"] || [text containsString:@"sub"])) {
                view.superview.hidden = YES;
                return;
            }
        }
        for (UIView *subview in view.subviews) {
            hideIfRestricted(subview);
        }
    } @catch (NSException *e) {}
}

@interface _TtC6Twitch21PlayerCoreCoordinator : NSObject
@end

@interface _TtC6Twitch26PlaybackRequestInterceptor : NSObject
@end

%hook _TtC6Twitch21PlayerCoreCoordinator
- (void)handlePlaybackStatusUpdate:(id)arg1 {
    %orig;
}
%end

@interface _TtC9TwitchKit5Video : NSObject
- (BOOL)currentUserIsRestricted;
@end

%hook _TtC9TwitchKit5Video
- (BOOL)currentUserIsRestricted {
    if ([tweakDefaults boolForKey:@"TWAdBlockVODUnlockEnabled"]) {
        return NO;
    }
    return %orig;
}
%end

%hook _TtC6Twitch30TheaterRequestErrorOverlayView
- (void)didMoveToWindow {
    %orig;
    if ([tweakDefaults boolForKey:@"TWAdBlockRestrictionRemoverEnabled"]) {
        @try { self.hidden = YES; } @catch (NSException *e) {}
    }
}
- (void)setHidden:(BOOL)hidden {
    if ([tweakDefaults boolForKey:@"TWAdBlockRestrictionRemoverEnabled"]) {
        %orig(YES);
    } else {
        %orig;
    }
}
%end

%hook _TtC6Twitch19TheaterMetadataView
- (void)layoutSubviews {
    %orig;
    if ([tweakDefaults boolForKey:@"TWAdBlockRestrictionRemoverEnabled"]) {
        @try {
            UIView *subOnlyBanner = [(id)self valueForKey:@"subOnlyLiveBannerView"];
            if (subOnlyBanner) subOnlyBanner.hidden = YES;
        } @catch (NSException *e) {}
    }
}
%end

%hook _TtC6Twitch31SubscriptionBenefitsSummaryView
- (void)didMoveToWindow {
    %orig;
    if ([tweakDefaults boolForKey:@"TWAdBlockRestrictionRemoverEnabled"]) {
        @try { self.hidden = YES; } @catch (NSException *e) {}
    }
}
%end

%hook _TtC6Twitch20UpsellViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if ([tweakDefaults boolForKey:@"TWAdBlockRestrictionRemoverEnabled"]) {
        @try { [self dismissViewControllerAnimated:YES completion:nil]; } @catch (NSException *e) {}
    }
}
%end

%hook _TtC6Twitch21TheaterViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if ([tweakDefaults boolForKey:@"TWAdBlockRestrictionRemoverEnabled"]) {
        @try {
            id theaterView = [(id)self valueForKey:@"theaterView"];
            if (theaterView) {
                UIView *errorOverlay = [(id)theaterView valueForKey:@"requestErrorOverlayView"];
                if (errorOverlay) errorOverlay.hidden = YES;
            }
            hideIfRestricted([(id)self view]);
        } @catch (NSException *e) {}
    }
}
%end

%hook _TtC6Twitch11TheaterView
- (void)layoutSubviews {
    %orig;
    if ([tweakDefaults boolForKey:@"TWAdBlockRestrictionRemoverEnabled"]) {
        @try {
            UIView *errorOverlay = [(id)self valueForKey:@"requestErrorOverlayView"];
            if (errorOverlay) errorOverlay.hidden = YES;
        } @catch (NSException *e) {}
    }
}
%end

// Low-level hook using fishhook for PlaybackAccessTokenParams
// Based on Ghidra dump: _$s13TwitchGraphQL25PlaybackAccessTokenParamsV...

static void (*orig_PlaybackAccessTokenParams_init)(void *disableHTTPS, void *hasAdblock, void *platform_p, void *platform_m, void *playerBackend_p, void *playerBackend_m, void *playerType_p, void *playerType_m);

static void hook_PlaybackAccessTokenParams_init(void *disableHTTPS, void *hasAdblock, void *platform_p, void *platform_m, void *playerBackend_p, void *playerBackend_m, void *playerType_p, void *playerType_m) {
    // Force hasAdblock to 2 (some(false) in Swift Nullable<Bool>)
    // Force platform to "web" could be done here if we knew the Swift String layout for "web"
    orig_PlaybackAccessTokenParams_init(disableHTTPS, (void *)2, platform_p, platform_m, playerBackend_p, playerBackend_m, playerType_p, playerType_m);
}

%ctor {
  rebind_symbols(
      (struct rebinding[]){
          {"swift_unknownObjectWeakAssign", (void *)hook_swift_unknownObjectWeakAssign,
           (void **)&orig_swift_unknownObjectWeakAssign},
          {"swift_unknownObjectWeakLoadStrong", (void *)hook_swift_unknownObjectWeakLoadStrong,
           (void **)&orig_swift_unknownObjectWeakLoadStrong},
          {"_$s13TwitchGraphQL25PlaybackAccessTokenParamsV12disableHTTPS10hasAdblock8platform13playerBackend0M4TypeAC9ApolloAPI0B10QLNullableOySbG_ALSSAKySSGSStcfC", 
           (void *)hook_PlaybackAccessTokenParams_init, (void **)&orig_PlaybackAccessTokenParams_init},
      },
      3);
  tweakBundle = [NSBundle bundleWithPath:[NSBundle.mainBundle pathForResource:@"TwitchAdBlock"
                                                                       ofType:@"bundle"]];
  if (!tweakBundle)
    tweakBundle = [NSBundle
        bundleWithPath:ROOT_PATH_NS(@"/Library/Application Support/TwitchAdBlock.bundle")];
  tweakDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.level3tjg.twitchadblock"];
  
  if (![tweakDefaults objectForKey:@"TWAdBlockEnabled"])
    [tweakDefaults setBool:YES forKey:@"TWAdBlockEnabled"];
  if (![tweakDefaults objectForKey:@"TWAdBlockProxyEnabled"])
    [tweakDefaults setBool:NO forKey:@"TWAdBlockProxyEnabled"];
  if (![tweakDefaults objectForKey:@"TWAdBlockCustomProxyEnabled"])
    [tweakDefaults setBool:NO forKey:@"TWAdBlockCustomProxyEnabled"];
  
  // VOD Unlocker defaults
  if (![tweakDefaults objectForKey:@"TWAdBlockVODUnlockEnabled"])
    [tweakDefaults setBool:YES forKey:@"TWAdBlockVODUnlockEnabled"];
  if (![tweakDefaults objectForKey:@"TWAdBlockRestrictionRemoverEnabled"])
    [tweakDefaults setBool:YES forKey:@"TWAdBlockRestrictionRemoverEnabled"];

  assetResourceLoaderDelegate = [[TWAdBlockAssetResourceLoaderDelegate alloc] init];
}
