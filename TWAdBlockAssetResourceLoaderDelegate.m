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
                    
                    // Correct UTIs for HLS segments and playlists
                    NSString *uti = isPlaylist ? @"com.apple.mpegurl" : ([path.pathExtension isEqualToString:@"mp4"] ? @"public.mpeg-4" : @"public.mpeg-ts");
                    
                    loadingRequest.contentInformationRequest.contentType = uti;
                    loadingRequest.contentInformationRequest.contentLength = finalData.length;
                    loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
                    
                    if (loadingRequest.dataRequest.requestedOffset > 0) {
                        long long offset = loadingRequest.dataRequest.requestedOffset;
                        long long length = loadingRequest.dataRequest.requestedLength;
                        if (offset < finalData.length) {
                            NSData *subData = [finalData subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)MIN(length, (long long)finalData.length - offset))];
                            [dataRequest respondWithData:subData];
                        }
                    } else {
                        [dataRequest respondWithData:finalData];
                    }
                    
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
