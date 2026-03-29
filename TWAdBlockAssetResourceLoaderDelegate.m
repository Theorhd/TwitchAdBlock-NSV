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

  NSString *path = request.URL.path;
  BOOL isMasterManifest = [path containsString:@"/vod/"] && ![path containsString:@"index-dvr"];
  BOOL isPlaylist = [path.pathExtension isEqualToString:@"m3u8"];
  BOOL isCloudfront = [request.URL.host containsString:@"cloudfront.net"] || 
                      [request.URL.host containsString:@"ttvnw.net"] ||
                      [request.URL.host containsString:@"akamaized.net"];
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

                if (isMasterManifest && vodUnlockEnabled && (httpResponse.statusCode == 403 || [unlocker isManifestRestricted:data])) {
                    // Extract VOD ID: /vod/v2/123456.m3u8 -> 123456
                    NSString *vodID = [request.URL.lastPathComponent stringByDeletingPathExtension];
                    
                    [unlocker fetchVODMetadata:vodID completion:^(NSDictionary *metadata, NSError *gqlError) {
                        NSData *finalData = data;
                        if (metadata && !gqlError) {
                            NSString *fakeManifest = [unlocker reconstructManifest:metadata forVodID:vodID];
                            if (fakeManifest) {
                                finalData = [fakeManifest dataUsingEncoding:NSUTF8StringEncoding];
                            }
                        }
                        
                        loadingRequest.contentInformationRequest.contentType = @"application/vnd.apple.mpegurl";
                        loadingRequest.contentInformationRequest.contentLength = finalData.length;
                        loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
                        [dataRequest respondWithData:finalData];
                        [loadingRequest finishLoading];
                    }];
                } else {
                    NSData *finalData = data;
                    if (isPlaylist && isCloudfront) {
                        finalData = [unlocker patchPlaylistData:data];
                    }
                    
                    NSString *contentType = isPlaylist ? @"application/vnd.apple.mpegurl" : @"video/mp2t";
                    loadingRequest.contentInformationRequest.contentType = contentType;
                    loadingRequest.contentInformationRequest.contentLength = finalData.length;
                    loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
                    
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
