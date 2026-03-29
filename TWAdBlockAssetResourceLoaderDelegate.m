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

                if (isVOD && vodUnlockEnabled && (httpResponse.statusCode == 403 || [unlocker isManifestRestricted:data])) {
                    NSString *vodID = [request.URL.lastPathComponent stringByDeletingPathExtension];
                    
                    [unlocker fetchVODMetadata:vodID completion:^(NSDictionary *metadata, NSError *gqlError) {
                        NSData *finalData = data;
                        if (metadata && !gqlError) {
                            NSString *fakeManifest = [unlocker reconstructManifest:metadata forVodID:vodID];
                            if (fakeManifest) {
                                finalData = [fakeManifest dataUsingEncoding:NSUTF8StringEncoding];
                            }
                        }
                        
                        loadingRequest.contentInformationRequest.contentType = AVFileTypeMPEG4;
                        [dataRequest respondWithData:finalData];
                        [loadingRequest finishLoading];
                    }];
                } else {
                    loadingRequest.contentInformationRequest.contentType = AVFileTypeMPEG4;
                    [dataRequest respondWithData:data];
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
