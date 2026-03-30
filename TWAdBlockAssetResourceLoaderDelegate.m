#import "TWAdBlockAssetResourceLoaderDelegate.h"
#import "TWAdBlockVODUnlocker.h"

extern NSUserDefaults *tweakDefaults;

@implementation TWAdBlockAssetResourceLoaderDelegate

- (void)fillContentInformation:(AVAssetResourceLoadingRequest *)loadingRequest fromResponse:(NSHTTPURLResponse *)response data:(NSData *)data {
    if (!loadingRequest.contentInformationRequest) return;
    
    NSString *mimeType = response.MIMEType;
    NSString *uti = @"public.mpeg-ts"; // Default
    if ([mimeType containsString:@"mpegurl"] || [loadingRequest.request.URL.pathExtension isEqualToString:@"m3u8"]) {
        uti = @"com.apple.mpegurl";
    } else if ([mimeType containsString:@"mp4"] || [loadingRequest.request.URL.pathExtension isEqualToString:@"mp4"]) {
        uti = @"public.mpeg-4";
    }
    
    loadingRequest.contentInformationRequest.contentType = uti;
    loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
    
    // Crucial: Use the data length we actually have if it's a reconstructed manifest
    loadingRequest.contentInformationRequest.contentLength = data.length;
}

- (BOOL)handleLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
  NSURL *URL = loadingRequest.request.URL;
  if (![URL.scheme isEqualToString:@"twab"]) return NO;

  AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
  NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:YES];
  components.scheme = @"https";

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
  
  // Set headers that Twitch/Cloudfront might expect
  [request setValue:@"https://www.twitch.tv" forHTTPHeaderField:@"Origin"];
  [request setValue:@"https://www.twitch.tv/" forHTTPHeaderField:@"Referer"];
  [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];

  BOOL isUsher = [request.URL.host isEqualToString:@"usher.ttvnw.net"];
  BOOL isVOD = isUsher && [request.URL.path containsString:@"/vod/"];
  BOOL isMasterManifest = isVOD && ![request.URL.path containsString:@"index-dvr"] && ![request.URL.path containsString:@"highlight"];
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
                
                // 1. Check if we need to reconstruct the master manifest
                if (isMasterManifest && vodUnlockEnabled && (httpResponse.statusCode >= 400 || [unlocker isManifestRestricted:data])) {
                    NSString *vodID = [request.URL.lastPathComponent stringByDeletingPathExtension];
                    [unlocker fetchVODMetadata:vodID completion:^(NSDictionary *metadata, NSError *gqlError) {
                        NSData *finalData = data;
                        if (metadata && !gqlError) {
                            NSString *fakeManifest = [unlocker reconstructManifest:metadata forVodID:vodID];
                            if (fakeManifest) {
                                finalData = [fakeManifest dataUsingEncoding:NSUTF8StringEncoding];
                                // Use a fake 200 response for the reconstructed manifest to avoid player confusion
                                NSHTTPURLResponse *fakeResponse = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/vnd.apple.mpegurl"}];
                                [self fillContentInformation:loadingRequest fromResponse:fakeResponse data:finalData];
                            } else {
                                [self fillContentInformation:loadingRequest fromResponse:httpResponse data:finalData];
                            }
                        } else {
                            [self fillContentInformation:loadingRequest fromResponse:httpResponse data:finalData];
                        }
                        [dataRequest respondWithData:finalData];
                        [loadingRequest finishLoading];
                    }];
                    return;
                }

                // 2. Handle sub-playlists and segments
                NSData *finalData = data;
                if ([request.URL.pathExtension isEqualToString:@"m3u8"]) {
                    finalData = [unlocker patchPlaylistData:data];
                }

                [self fillContentInformation:loadingRequest fromResponse:httpResponse data:finalData];
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
