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
  [request setAllHTTPHeaderFields:loadingRequest.request.allHTTPHeaderFields];
  [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];

  BOOL isVOD = [request.URL.path containsString:@"/vod/"];
  BOOL isMasterManifest = isVOD && ![request.URL.path containsString:@"index-dvr"];
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
                if (isMasterManifest && vodUnlockEnabled && (httpResponse.statusCode == 403 || [unlocker isManifestRestricted:data])) {
                    NSString *vodID = [request.URL.lastPathComponent stringByDeletingPathExtension];
                    [unlocker fetchVODMetadata:vodID completion:^(NSDictionary *metadata, NSError *gqlError) {
                        NSData *finalData = data;
                        if (metadata && !gqlError) {
                            NSString *fakeManifest = [unlocker reconstructManifest:metadata forVodID:vodID];
                            if (fakeManifest) finalData = [fakeManifest dataUsingEncoding:NSUTF8StringEncoding];
                        }
                        [self fillContentInformation:loadingRequest fromResponse:httpResponse data:finalData];
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
                
                // Handle range requests correctly
                if (dataRequest.requestedOffset > 0) {
                    // NSURLSession already handled the range if request headers were passed
                    // but we ensure we don't send more than requested.
                    [dataRequest respondWithData:finalData];
                } else {
                    [dataRequest respondWithData:finalData];
                }
                
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
