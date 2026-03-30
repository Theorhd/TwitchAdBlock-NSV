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

- (NSString *)extractVodID:(NSString *)path {
    if (!path) return nil;
    // Handle formats: /vod/v2/12345.m3u8, /vod/12345/chunked/..., etc.
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"/vod/(?:v\\d+/)?(\\d+)" options:0 error:&error];
    NSTextCheckingResult *match = [regex firstMatchInString:path options:0 range:NSMakeRange(0, [path length])];
    if (match) {
        return [path substringWithRange:[match rangeAtIndex:1]];
    }
    return nil;
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

  NSString *path = request.URL.path;
  BOOL isMasterManifest = [path containsString:@"/vod/"] && ![path containsString:@"index-dvr"];
  BOOL isPlaylist = [path.pathExtension isEqualToString:@"m3u8"];
  BOOL vodUnlockEnabled = [tweakDefaults boolForKey:@"TWAdBlockVODUnlockEnabled"];
  
  NSURLSession *session = [NSURLSession sharedSession];
  
  [[session dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error) {
                        [loadingRequest finishLoadingWithError:error];
                        return;
                    }

                    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                    TWAdBlockVODUnlocker *unlocker = [TWAdBlockVODUnlocker sharedInstance];

                    // 1. If restricted master manifest
                    if (isMasterManifest && vodUnlockEnabled && (httpResponse.statusCode == 403 || [unlocker isManifestRestricted:data])) {
                        NSString *vodID = [self extractVodID:path];
                        [unlocker fetchVODMetadata:vodID completion:^(NSDictionary *metadata, NSError *gqlError) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                NSData *finalData = data;
                                if (metadata && !gqlError) {
                                    NSString *fakeManifest = [unlocker reconstructManifest:metadata forVodID:vodID];
                                    if (fakeManifest) finalData = [fakeManifest dataUsingEncoding:NSUTF8StringEncoding];
                                }
                                [self fillContentInformation:loadingRequest contentType:@"com.apple.mpegurl" length:finalData.length];
                                [dataRequest respondWithData:finalData];
                                [loadingRequest finishLoading];
                            });
                        }];
                        return;
                    }

                    // 2. Normal flow (segments & sub-playlists)
                    NSData *finalData = data;
                    if (isPlaylist) {
                        finalData = [unlocker patchPlaylistData:data];
                    }
                    
                    NSString *uti = isPlaylist ? @"com.apple.mpegurl" : ([path.pathExtension isEqualToString:@"mp4"] ? @"public.mpeg-4" : @"public.mpeg-ts");
                    
                    long long totalLength = httpResponse.expectedContentLength;
                    if (httpResponse.statusCode == 206) {
                        NSString *contentRange = httpResponse.allHeaderFields[@"Content-Range"];
                        if (contentRange) {
                            NSArray *parts = [contentRange componentsSeparatedByString:@"/"];
                            if (parts.count == 2) totalLength = [parts[1] longLongValue];
                        }
                    } else if (isPlaylist) {
                        totalLength = finalData.length;
                    }

                    [self fillContentInformation:loadingRequest contentType:uti length:totalLength > 0 ? totalLength : finalData.length];
                    [dataRequest respondWithData:finalData];
                    [loadingRequest finishLoading];
                });
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
