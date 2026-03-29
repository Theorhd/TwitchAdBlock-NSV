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
  NSString *host = request.URL.host;
  
  BOOL isMasterManifest = [path containsString:@"/vod/"] && ![path containsString:@"index-dvr"];
  BOOL isPlaylist = [path.pathExtension isEqualToString:@"m3u8"];
  
  // Broad domain check to ensure all Twitch video domains are covered
  BOOL isTwitchVideoDomain = [host containsString:@"cloudfront.net"] || 
                             [host containsString:@"ttvnw.net"] ||
                             [host containsString:@"akamaized.net"] ||
                             [host containsString:@"twitch.tv"];
                             
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
                    NSString *vodID = [request.URL.lastPathComponent stringByDeletingPathExtension];
                    
                    [unlocker fetchVODMetadata:vodID completion:^(NSDictionary *metadata, NSError *gqlError) {
                        NSData *finalData = data;
                        if (metadata && !gqlError) {
                            NSString *fakeManifest = [unlocker reconstructManifest:metadata forVodID:vodID];
                            if (fakeManifest) {
                                finalData = [fakeManifest dataUsingEncoding:NSUTF8StringEncoding];
                            }
                        }
                        
                        // Use Apple UTIs instead of MIME types
                        loadingRequest.contentInformationRequest.contentType = @"com.apple.mpegurl";
                        loadingRequest.contentInformationRequest.contentLength = finalData.length;
                        loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
                        [dataRequest respondWithData:finalData];
                        [loadingRequest finishLoading];
                    }];
                } else {
                    NSData *finalData = data;
                    if (isPlaylist && isTwitchVideoDomain) {
                        finalData = [unlocker patchPlaylistData:data];
                    }
                    
                    NSString *contentType = httpResponse.MIMEType;
                    if (!contentType) {
                        contentType = isPlaylist ? @"application/vnd.apple.mpegurl" : @"video/mp2t";
                    }
                    
                    // Convert MIME types to Apple UTIs for AVAssetResourceLoader if necessary
                    if ([contentType containsString:@"mpegurl"] || [contentType containsString:@"m3u8"]) {
                        contentType = @"com.apple.mpegurl";
                    } else if ([contentType containsString:@"mp4"]) {
                        contentType = @"public.mpeg-4";
                    } else if ([contentType containsString:@"mp2t"]) {
                        contentType = @"public.mpeg-ts";
                    }
                    
                    long long totalLength = httpResponse.expectedContentLength;
                    if (httpResponse.statusCode == 206) {
                        NSString *contentRange = httpResponse.allHeaderFields[@"Content-Range"];
                        if (contentRange) {
                            NSArray *components = [contentRange componentsSeparatedByString:@"/"];
                            if (components.count == 2) {
                                totalLength = [components[1] longLongValue];
                            }
                        }
                    } else if (isPlaylist) {
                        totalLength = finalData.length;
                    }
                    
                    if (loadingRequest.contentInformationRequest) {
                        loadingRequest.contentInformationRequest.contentType = contentType;
                        loadingRequest.contentInformationRequest.contentLength = totalLength > 0 ? totalLength : finalData.length;
                        loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
                    }
                    
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
