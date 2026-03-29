#import "TWAdBlockAssetResourceLoaderDelegate.h"
#import "TWAdBlockVODUnlocker.h"

extern NSUserDefaults *tweakDefaults;

@implementation TWAdBlockAssetResourceLoaderDelegate
- (BOOL)handleLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
  NSURL *URL = loadingRequest.request.URL;
  if (![URL.scheme isEqualToString:@"twab"]) return NO;

  AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
  NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:YES];
  components.scheme = @"https";

  NSMutableURLRequest *request = loadingRequest.request.mutableCopy;
  request.URL = components.URL;

  BOOL isVOD = [request.URL.path containsString:@"/vod/"];
  BOOL isCloudfront = [request.URL.host containsString:@"cloudfront.net"] || [request.URL.host containsString:@"ttvnw.net"];
  BOOL vodUnlockEnabled = [tweakDefaults boolForKey:@"TWAdBlockVODUnlockEnabled"];
  BOOL proxyEnabled = [tweakDefaults boolForKey:@"TWAdBlockProxyEnabled"];

  NSURLSession *session;
  if (proxyEnabled) {
      NSString *proxy = [tweakDefaults boolForKey:@"TWAdBlockCustomProxyEnabled"]
                            ? [tweakDefaults stringForKey:@"TWAdBlockProxy"]
                            : PROXY_ADDR;
      session = [[NSURLSession alloc] twab_proxySessionWithAddress:proxy];
  } else {
      session = [NSURLSession sharedSession];
  }
  
  [[session dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                if (error) {
                    [loadingRequest finishLoadingWithError:error];
                    return;
                }

                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                TWAdBlockVODUnlocker *unlocker = [TWAdBlockVODUnlocker sharedInstance];
                NSData *finalData = data;

                if (isVOD && vodUnlockEnabled && (httpResponse.statusCode == 403 || [unlocker isManifestRestricted:data])) {
                    // Improved vodID extraction: /vod/v2/12345678.m3u8 or /vod/12345678.m3u8
                    NSString *path = request.URL.path;
                    NSString *lastPart = [path lastPathComponent];
                    NSString *vodID = [lastPart stringByDeletingPathExtension];
                    
                    // If lastPart was something like "index-dvr.m3u8", we need to look one level up
                    if ([vodID isEqualToString:@"index-dvr"] || [vodID isEqualToString:@"playlist"]) {
                        NSArray *parts = [path pathComponents];
                        if (parts.count > 2) {
                            vodID = parts[parts.count - 2];
                        }
                    }
                    
                    [unlocker fetchVODMetadata:vodID completion:^(NSDictionary *metadata, NSError *gqlError) {
                        NSData *patchedData = data;
                        if (metadata && !gqlError) {
                            NSString *fakeManifest = [unlocker reconstructManifest:metadata forVodID:vodID];
                            if (fakeManifest) {
                                patchedData = [fakeManifest dataUsingEncoding:NSUTF8StringEncoding];
                            }
                        }
                        
                        loadingRequest.contentInformationRequest.contentType = @"com.apple.mpegurl";
                        [dataRequest respondWithData:patchedData];
                        [loadingRequest finishLoading];
                    }];
                } else {
                    // Apply unmuted -> muted patch for segments/playlists if needed
                    if (isCloudfront && [request.URL.pathExtension isEqualToString:@"m3u8"]) {
                        finalData = [unlocker patchPlaylistData:data];
                    }
                    
                    loadingRequest.contentInformationRequest.contentType = @"com.apple.mpegurl";
                    [dataRequest respondWithData:finalData];
                    [loadingRequest finishLoading];
                }
              }] resume];
  return YES;
}
- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
  return [self handleLoadingRequest:loadingRequest];
}
- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest {
  return [self handleLoadingRequest:renewalRequest];
}
@end
