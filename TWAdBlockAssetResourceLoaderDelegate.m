#import "TWAdBlockAssetResourceLoaderDelegate.h"
#import "TWAdBlockVODUnlocker.h"
#import "Config.h"
#import "TWABLogger.h"

extern NSUserDefaults *tweakDefaults;

@implementation TWAdBlockAssetResourceLoaderDelegate

- (void)fillContentInformation:(AVAssetResourceLoadingRequest *)loadingRequest fromResponse:(NSHTTPURLResponse *)response data:(NSData *)data {
    if (!loadingRequest.contentInformationRequest) return;
    
    NSString *uti = @"public.mpeg-ts";
    
    NSString *path = loadingRequest.request.URL.path.lowercaseString;
    if ([path hasSuffix:@".m3u8"] || [path hasSuffix:@".m3u"]) {
        uti = @"com.apple.mpegurl";
    } else if ([path hasSuffix:@".mp4"]) {
        uti = @"public.mpeg-4";
    }
    
    loadingRequest.contentInformationRequest.contentType = uti;
    loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
    loadingRequest.contentInformationRequest.contentLength = data.length;
}

- (BOOL)handleLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
  NSURL *URL = loadingRequest.request.URL;
  if (![URL.scheme isEqualToString:@"twab"]) return NO;

  AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
  NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:YES];
  components.scheme = @"https";
  
  TWABLog(@"🚀 Request: %@", components.URL.path);

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
  
  [request setValue:@"https://www.twitch.tv" forHTTPHeaderField:@"Origin"];
  [request setValue:@"https://www.twitch.tv/" forHTTPHeaderField:@"Referer"];
  [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];

  BOOL isUsher = [request.URL.host isEqualToString:@"usher.ttvnw.net"];
  BOOL isVOD = [request.URL.path containsString:@"/vod/"];
  BOOL isMasterManifest = isUsher && isVOD && ![request.URL.path containsString:@"index-dvr"] && ![request.URL.path containsString:@"highlight"];
  BOOL vodUnlockEnabled = [tweakDefaults boolForKey:@"TWAdBlockVODUnlockEnabled"];
  BOOL proxyEnabled = [tweakDefaults boolForKey:@"TWAdBlockProxyEnabled"];

  NSURLSession *session = proxyEnabled ? [[NSURLSession alloc] twab_proxySessionWithAddress:[tweakDefaults boolForKey:@"TWAdBlockCustomProxyEnabled"] ? [tweakDefaults stringForKey:@"TWAdBlockProxy"] : PROXY_ADDR] : [NSURLSession sharedSession];
  
  [[session dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                if (error) {
                    TWABLog(@"❌ Session Error: %@", error.localizedDescription);
                    [loadingRequest finishLoadingWithError:error];
                    return;
                }

                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                TWAdBlockVODUnlocker *unlocker = [TWAdBlockVODUnlocker sharedInstance];
                
                if (isMasterManifest && vodUnlockEnabled && (httpResponse.statusCode >= 400 || [unlocker isManifestRestricted:data])) {
                    NSString *vodID = [request.URL.lastPathComponent stringByDeletingPathExtension];
                    TWABLog(@"⚠️ Restricted (%ld). Reconstructing: %@", (long)httpResponse.statusCode, vodID);
                    
                    [unlocker fetchVODMetadata:vodID completion:^(NSDictionary *metadata, NSError *gqlError) {
                        if (metadata && !gqlError) {
                            NSString *fakeManifest = [unlocker reconstructManifest:metadata forVodID:vodID];
                            if (fakeManifest) {
                                TWABLog(@"✅ Master reconstructed");
                                NSData *finalData = [fakeManifest dataUsingEncoding:NSUTF8StringEncoding];
                                NSHTTPURLResponse *fakeResponse = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/vnd.apple.mpegurl"}];
                                [self fillContentInformation:loadingRequest fromResponse:fakeResponse data:finalData];
                                [dataRequest respondWithData:finalData];
                                [loadingRequest finishLoading];
                                return;
                            }
                        }
                        TWABLog(@"❌ Reconstruction failed: %@", gqlError.localizedDescription);
                        [self fillContentInformation:loadingRequest fromResponse:httpResponse data:data];
                        [dataRequest respondWithData:data];
                        [loadingRequest finishLoading];
                    }];
                    return;
                }

                NSData *finalData = data;
                if ([request.URL.pathExtension isEqualToString:@"m3u8"]) {
                    finalData = [unlocker patchPlaylistData:data];
                }

                [self fillContentInformation:loadingRequest fromResponse:httpResponse data:finalData];
                
                if (dataRequest.requestedOffset < finalData.length) {
                    NSUInteger start = (NSUInteger)dataRequest.requestedOffset;
                    NSUInteger length = MIN((NSUInteger)dataRequest.requestedLength, finalData.length - start);
                    [dataRequest respondWithData:[finalData subdataWithRange:NSMakeRange(start, length)]];
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
