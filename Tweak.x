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

@interface TWHLSProvider : NSObject
@end

%hook TWHLSProvider
- (BOOL)isLuminousV1 {
    return NO; // Force standard HLS path
}
%end

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

%hook AVURLAsset
- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
  if ([URL.scheme isEqualToString:@"twab"]) {
      if ((self = %orig)) {
          [self.resourceLoader setDelegate:assetResourceLoaderDelegate queue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)];
      }
      return self;
  }
  return %orig;
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
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
  if ([keyPath isEqualToString:@"status"] && [self status] == AVPlayerStatusReadyToPlay) {
      [self play];
  } else if ([keyPath isEqualToString:@"rate"] && [self rate] == 0.0 && [self status] == AVPlayerStatusReadyToPlay) {
      [self play];
  }
}
%end

@interface _TtC9TwitchKit5Video : NSObject
- (BOOL)currentUserIsRestricted;
@end

%hook _TtC9TwitchKit5Video
- (BOOL)currentUserIsRestricted {
    return [tweakDefaults boolForKey:@"TWAdBlockVODUnlockEnabled"] ? NO : %orig;
}
%end

@interface _TtC6Twitch30TheaterRequestErrorOverlayView : UIView
@end

%hook _TtC6Twitch30TheaterRequestErrorOverlayView
- (void)didMoveToWindow {
    %orig;
    if ([tweakDefaults boolForKey:@"TWAdBlockRestrictionRemoverEnabled"]) self.hidden = YES;
}
%end

%ctor {
  tweakBundle = [NSBundle bundleWithPath:[NSBundle.mainBundle pathForResource:@"TwitchAdBlock" ofType:@"bundle"]];
  if (!tweakBundle) tweakBundle = [NSBundle bundleWithPath:ROOT_PATH_NS(@"/Library/Application Support/TwitchAdBlock.bundle")];
  tweakDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.level3tjg.twitchadblock"];
  
  if (![tweakDefaults objectForKey:@"TWAdBlockEnabled"]) [tweakDefaults setBool:YES forKey:@"TWAdBlockEnabled"];
  if (![tweakDefaults objectForKey:@"TWAdBlockVODUnlockEnabled"]) [tweakDefaults setBool:YES forKey:@"TWAdBlockVODUnlockEnabled"];
  if (![tweakDefaults objectForKey:@"TWAdBlockRestrictionRemoverEnabled"]) [tweakDefaults setBool:YES forKey:@"TWAdBlockRestrictionRemoverEnabled"];

  assetResourceLoaderDelegate = [[TWAdBlockAssetResourceLoaderDelegate alloc] init];
}
