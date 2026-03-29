#import "TWAdBlockVODUnlocker.h"
#import "Config.h"

@implementation TWAdBlockVODUnlocker

+ (instancetype)sharedInstance {
    static TWAdBlockVODUnlocker *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (void)fetchVODMetadata:(NSString *)vodID completion:(void (^)(NSDictionary *metadata, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:@"https://gql.twitch.tv/gql"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];

    // Standard Twitch Client-Id for Web/iOS
    [request setValue:@"kimne78kx3ncx6brgo4mv6wki5h1ko" forHTTPHeaderField:@"Client-Id"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://www.twitch.tv" forHTTPHeaderField:@"Origin"];
    [request setValue:@"https://www.twitch.tv/" forHTTPHeaderField:@"Referer"];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];

    // Ensure vodID format is correct (sometimes needs 'v' prefix)
    NSString *formattedID = vodID;
    if (![vodID hasPrefix:@"v"] && [vodID rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound) {
        formattedID = [NSString stringWithFormat:@"v%@", vodID];
    }

    NSDictionary *body = @{
        @"query": @"query($id: ID!) { video(id: $id) { broadcastType, createdAt, seekPreviewsURL, owner { login } }}",
        @"variables": @{@"id": formattedID}
    };

    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setHTTPBody:bodyData];

    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || !json[@"data"]) {
            // Try again without 'v' prefix if it failed
            if ([formattedID hasPrefix:@"v"]) {
                [self fetchVODMetadataWithoutV:vodID completion:completion];
            } else {
                completion(nil, jsonError);
            }
            return;
        }
        completion(json[@"data"][@"video"], nil);
    }] resume];
}

// Fallback helper
- (void)fetchVODMetadataWithoutV:(NSString *)vodID completion:(void (^)(NSDictionary *metadata, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:@"https://gql.twitch.tv/gql"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"kimne78kx3ncx6brgo4mv6wki5h1ko" forHTTPHeaderField:@"Client-Id"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{
        @"query": @"query($id: ID!) { video(id: $id) { broadcastType, createdAt, seekPreviewsURL, owner { login } }}",
        @"variables": @{@"id": vodID}
    };
    [request setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        completion(json[@"data"][@"video"], nil);
    }] resume];
}


- (BOOL)isManifestRestricted:(NSData *)data {
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return NO;
    NSString *lower = [body lowercaseString];
    return [lower containsString:@"vod_manifest_restricted"] ||
           [lower containsString:@"errorauthorization"] ||
           [lower containsString:@"restricted=1"] ||
           [lower containsString:@"restricted=\"true\""] ||
           [lower containsString:@"#ext-x-twitch-restricted"];
}

- (NSString *)reconstructManifest:(NSDictionary *)vodData forVodID:(NSString *)vodID {
    if (!vodData || ![vodData isKindOfClass:[NSDictionary class]]) return nil;
    
    NSString *seekPreviewsURL = vodData[@"seekPreviewsURL"];
    NSDictionary *owner = vodData[@"owner"];
    NSString *broadcastType = [vodData[@"broadcastType"] lowercaseString];
    NSString *createdAt = vodData[@"createdAt"];
    
    if (!seekPreviewsURL || !owner) return nil;
    
    NSURL *previewURL = [NSURL URLWithString:seekPreviewsURL];
    if (!previewURL) return nil;
    
    NSString *domain = previewURL.host;
    NSArray *pathComponents = previewURL.pathComponents;
    
    // Find storyboards index to get vodSpecialID
    NSInteger storyboardIndex = -1;
    for (NSInteger i = 0; i < pathComponents.count; i++) {
        if ([pathComponents[i] containsString:@"storyboards"]) {
            storyboardIndex = i;
            break;
        }
    }
    
    if (storyboardIndex <= 0) return nil;
    NSString *vodSpecialID = pathComponents[storyboardIndex - 1];
    
    NSString *servingID = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSMutableString *manifest = [NSMutableString stringWithFormat:@"#EXTM3U\n"
                                 "#EXT-X-TWITCH-INFO:ORIGIN=\"s3\",B=\"false\",REGION=\"EU\",USER-IP=\"127.0.0.1\",SERVING-ID=\"%@\",CLUSTER=\"cloudfront_vod\",USER-COUNTRY=\"BE\",MANIFEST-CLUSTER=\"cloudfront_vod\"\n", servingID];
    
    NSDictionary *resolutions = @{
        @"160p30": @{@"res": @"284x160", @"fps": @30},
        @"360p30": @{@"res": @"640x360", @"fps": @30},
        @"480p30": @{@"res": @"854x480", @"fps": @30},
        @"720p60": @{@"res": @"1280x720", @"fps": @60},
        @"1080p60": @{@"res": @"1920x1080", @"fps": @60},
        @"chunked": @{@"res": @"1920x1080", @"fps": @60}
    };
    
    NSArray *keys = @[@"chunked", @"1080p60", @"720p60", @"480p30", @"360p30", @"160p30"];
    
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZ"];
    NSDate *createdDate = [dateFormatter dateFromString:createdAt];
    NSTimeInterval daysDiff = [[NSDate date] timeIntervalSinceDate:createdDate] / 86400.0;
    
    NSInteger startBandwidth = 8534030;
    
    for (NSString *resKey in keys) {
        NSString *streamUrl;
        if ([broadcastType isEqualToString:@"highlight"]) {
            streamUrl = [NSString stringWithFormat:@"https://%@/%@/%@/highlight-%@.m3u8", domain, vodSpecialID, resKey, vodID];
        } else if ([broadcastType isEqualToString:@"upload"] && daysDiff > 7) {
            streamUrl = [NSString stringWithFormat:@"https://%@/%@/%@/%@/%@/index-dvr.m3u8", domain, owner[@"login"], vodID, vodSpecialID, resKey];
        } else {
            streamUrl = [NSString stringWithFormat:@"https://%@/%@/%@/index-dvr.m3u8", domain, vodSpecialID, resKey];
        }
        
        NSString *quality = [resKey isEqualToString:@"chunked"] ? @"1080p" : resKey;
        NSString *enabled = [resKey isEqualToString:@"chunked"] ? @"YES" : @"NO";
        
        [manifest appendFormat:@"#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=\"%@\",NAME=\"%@\",AUTOSELECT=%@,DEFAULT=%@\n", quality, quality, enabled, enabled];
        [manifest appendFormat:@"#EXT-X-STREAM-INF:BANDWIDTH=%ld,CODECS=\"avc1.4D001E,mp4a.40.2\",RESOLUTION=%@,VIDEO=\"%@\",FRAME-RATE=%@\n", (long)startBandwidth, resolutions[resKey][@"res"], quality, resolutions[resKey][@"fps"]];
        [manifest appendFormat:@"%@\n", streamUrl];
        
        startBandwidth -= 100;
    }
    
    return manifest;
}

- (NSData *)patchPlaylistData:(NSData *)data {
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return data;
    if ([body containsString:@"-unmuted"]) {
        NSString *patchedBody = [body stringByReplacingOccurrencesOfString:@"-unmuted" withString:@"-muted"];
        return [patchedBody dataUsingEncoding:NSUTF8StringEncoding];
    }
    return data;
}

@end
