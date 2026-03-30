#import "TWAdBlockAssetResourceLoaderDelegate.h"
#import "TWAdBlockVODUnlocker.h"

extern NSUserDefaults *tweakDefaults;

@implementation TWAdBlockAssetResourceLoaderDelegate

- (void)fillContentInformation:(AVAssetResourceLoadingRequest *)loadingRequest contentType:(NSString *)uti length:(long long)length {
    if (!loadingRequest.contentInformationRequest) return;
    loadingRequest.contentInformationRequest.contentType = uti;
    loadingRequest.contentInformationRequest.contentLength = length;
    loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
}

- (BOOL)handleLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
  NSURL *URL = loadingRequest.request.URL;
  if (![URL.scheme isEqualToString:@"twab"]) return NO;

  AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
  NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:YES];
  components.scheme = @"https";

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
  [request setAllHTTPHeaderFields:loadingRequest.request.allHTTPHeaderFields];
  [request setValue:@"kimne78kx3ncx6brgo4mv6wki5h1ko" forHTTPHeaderField:@"Client-Id"];
  [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];

  NSString *path = request.URL.path;
  BOOL isMasterManifest = [path containsString:@"/vod/"] && ![path containsString:@"index-dvr"];
  BOOL isPlaylist = [path.pathExtension isEqualToString:@"m3u8"];
  BOOL vodUnlockEnabled = [tweakDefaults boolForKey:@"TWAdBlockVODUnlockEnabled"];
  BOOL proxyEnabled = [tweakDefaults boolForKey:@"TWAdBlockProxyEnabled"];

  NSURLSession *session = proxyEnabled ? [[NSURLSession alloc] twab_proxySessionWithAddress:[tweakDefaults boolForKey:@"TWAdBlockCustomProxyEnabled"] ? [tweakDefaults stringForKey:@"TWAdBlockProxy"] : PROXY_ADDR] : [NSURLSession sharedSession];
  
  [[session dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                if (error) {
                    [loadingRequest finishLoadingWithError:error];
                    return;
                }

                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                TWAdBlockVODUnlocker *unlocker = [TWAdBlockVODUnlocker sharedInstance];

                // IF RESTRICTED VOD
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
                        // FORCE CORRECT HLS UTI FOR FAKE MANIFEST
                        [self fillContentInformation:loadingRequest contentType:@"com.apple.mpegurl" length:finalData.length];
                        [dataRequest respondWithData:finalData];
                        [loadingRequest finishLoading];
                    }];
                    return;
                }

                // NORMAL FLOW (Segments & Sub-playlists)
                NSData *finalData = data;
                if (isPlaylist) {
                    finalData = [unlocker patchPlaylistData:data];
                }
                
                NSString *uti = isPlaylist ? @"com.apple.mpegurl" : ([path.pathExtension isEqualToString:@"mp4"] ? @"public.mpeg-4" : @"public.mpeg-ts");
                
                // Get total length from response headers if possible
                long long totalLength = httpResponse.expectedContentLength;
                if (httpResponse.statusCode == 206) {
                    NSString *contentRange = httpResponse.allHeaderFields[@"Content-Range"];
                    if (contentRange) {
                        NSArray *rangeParts = [contentRange componentsSeparatedByString:@"/"];
                        if (rangeParts.count == 2) totalLength = [rangeParts[1] longLongValue];
                    }
                } else if (isPlaylist) {
                    totalLength = finalData.length;
                }

                [self fillContentInformation:loadingRequest contentType:uti length:totalLength > 0 ? totalLength : finalData.length];
                [dataRequest respondWithData:finalData];
                [loadingRequest finishLoading];
              }] resume];
  return YES;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
  return [self handleLoadingRequest:loadingRequest];
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest {
  return [self handleLoadingRequest:renewalRequest];
}

@end
