#import "TWAdBlockAssetResourceLoaderDelegate.h"
#import "TWAdBlockVODUnlocker.h"

extern NSUserDefaults *tweakDefaults;

@implementation TWAdBlockAssetResourceLoaderDelegate

- (void)fillContentInformation:(AVAssetResourceLoadingRequest *)loadingRequest fromResponse:(NSHTTPURLResponse *)response data:(NSData *)data {
    if (!loadingRequest.contentInformationRequest) return;
    
    NSString *uti = @"public.mpeg-ts";
    NSString *contentType = response.allHeaderFields[@"Content-Type"] ?: @"video/mp2t";
    
    if ([contentType containsString:@"mpegurl"] || [loadingRequest.request.URL.pathExtension isEqualToString:@"m3u8"]) {
        uti = @"com.apple.mpegurl";
        contentType = @"application/vnd.apple.mpegurl";
    } else if ([contentType containsString:@"mp4"] || [loadingRequest.request.URL.pathExtension isEqualToString:@"mp4"]) {
        uti = @"public.mpeg-4";
        contentType = @"video/mp4";
    }
    
    loadingRequest.contentInformationRequest.contentType = uti;
    loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
    
    // Si la réponse est un 206 (Partial Content), extraire la taille totale depuis Content-Range
    long long totalLength = data.length;
    NSString *contentRange = response.allHeaderFields[@"Content-Range"];
    if (contentRange) {
        NSArray *parts = [contentRange componentsSeparatedByString:@"/"];
        if (parts.count > 1) {
            totalLength = [parts.lastObject longLongValue];
        }
    }
    
    loadingRequest.contentInformationRequest.contentLength = totalLength;
}

- (BOOL)handleLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
  NSURL *URL = loadingRequest.request.URL;
  if (![URL.scheme isEqualToString:@"twab"]) return NO;

  AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
  NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:YES];
  components.scheme = @"https";

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
  
  // Copier les headers d'origine (important pour les Range requests de segments)
  [request setAllHTTPHeaderFields:loadingRequest.request.allHTTPHeaderFields];
  [request setValue:@"https://www.twitch.tv" forHTTPHeaderField:@"Origin"];
  [request setValue:@"https://www.twitch.tv/" forHTTPHeaderField:@"Referer"];
  [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];

  BOOL isUsher = [request.URL.host isEqualToString:@"usher.ttvnw.net"];
  BOOL isMasterManifest = isUsher && [request.URL.path containsString:@"/vod/"] && ![request.URL.path containsString:@"index-dvr"] && ![request.URL.path containsString:@"highlight"];
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
                
                // 1. Reconstruction du Master Manifest si restreint ou erreur 403/401
                if (isMasterManifest && vodUnlockEnabled && (httpResponse.statusCode >= 400 || [unlocker isManifestRestricted:data])) {
                    NSString *vodID = [request.URL.lastPathComponent stringByDeletingPathExtension];
                    [unlocker fetchVODMetadata:vodID completion:^(NSDictionary *metadata, NSError *gqlError) {
                        if (metadata && !gqlError) {
                            NSString *fakeManifest = [unlocker reconstructManifest:metadata forVodID:vodID];
                            if (fakeManifest) {
                                NSData *finalData = [fakeManifest dataUsingEncoding:NSUTF8StringEncoding];
                                // Créer une fausse réponse 200 OK pour ne pas effrayer AVPlayer
                                NSHTTPURLResponse *fakeResponse = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/vnd.apple.mpegurl"}];
                                [self fillContentInformation:loadingRequest fromResponse:fakeResponse data:finalData];
                                [dataRequest respondWithData:finalData];
                                [loadingRequest finishLoading];
                                return;
                            }
                        }
                        // Fallback si GQL échoue
                        [self fillContentInformation:loadingRequest fromResponse:httpResponse data:data];
                        [dataRequest respondWithData:data];
                        [loadingRequest finishLoading];
                    }];
                    return;
                }

                // 2. Patch des sub-playlists (.m3u8) pour corriger les segments unmuted
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
