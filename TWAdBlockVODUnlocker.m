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
    if (!vodID || vodID.length < 4) {
        completion(nil, [NSError errorWithDomain:@"TWAB" code:400 userInfo:nil]);
        return;
    }

    NSURL *url = [NSURL URLWithString:@"https://gql.twitch.tv/gql"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"kimne78kx3ncx6brgo4mv6wki5h1ko" forHTTPHeaderField:@"Client-Id"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://www.twitch.tv" forHTTPHeaderField:@"Origin"];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];

    NSString *formattedID = vodID;
    if (![vodID hasPrefix:@"v"] && [vodID rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound) {
        formattedID = [NSString stringWithFormat:@"v%@", vodID];
    }

    NSDictionary *body = @{
        @"query": @"query($id: ID!) { video(id: $id) { broadcastType, createdAt, seekPreviewsURL, owner { login } }}",
        @"variables": @{@"id": formattedID}
    };
    [request setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];

    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        id video = json[@"data"][@"video"];
        if (jsonError || !video || [video isEqual:[NSNull null]]) {
            if ([formattedID hasPrefix:@"v"]) {
                [self fetchVODMetadataWithoutV:vodID completion:completion];
            } else {
                completion(nil, jsonError);
            }
            return;
        }
        completion(video, nil);
    }] resume];
}

- (void)fetchVODMetadataWithoutV:(NSString *)vodID completion:(void (^)(NSDictionary *metadata, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:@"https://gql.twitch.tv/gql"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"kimne78kx3ncx6brgo4mv6wki5h1ko" forHTTPHeaderField:@"Client-Id"];
    
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
    if (!data) return NO;
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return NO;
    NSString *lower = [body lowercaseString];
    return [lower containsString:@"restricted"] || [lower containsString:@"errorauthorization"] || [lower containsString:@"denied"];
}

- (NSString *)reconstructManifest:(NSDictionary *)vodData forVodID:(NSString *)vodID {
    if (!vodData || ![vodData isKindOfClass:[NSDictionary class]]) return nil;
    
    NSString *seekPreviewsURL = vodData[@"seekPreviewsURL"];
    if (!seekPreviewsURL || [seekPreviewsURL isEqual:[NSNull null]]) return nil;
    
    NSURL *previewURL = [NSURL URLWithString:seekPreviewsURL];
    NSString *domain = previewURL.host;
    NSArray *pathComponents = previewURL.pathComponents;
    
    NSInteger storyboardIndex = -1;
    for (NSInteger i = 0; i < pathComponents.count; i++) {
        if ([pathComponents[i] containsString:@"storyboards"]) {
            storyboardIndex = i;
            break;
        }
    }
    if (storyboardIndex <= 0) return nil;
    NSString *vodSpecialID = pathComponents[storyboardIndex - 1];
    
    // Mandatory HLS tags for iOS VOD playback
    NSMutableString *manifest = [NSMutableString stringWithFormat:@"#EXTM3U\n"
                                 "#EXT-X-VERSION:3\n"
                                 "#EXT-X-PLAYLIST-TYPE:VOD\n"
                                 "#EXT-X-TARGETDURATION:10\n"];
    
    NSDictionary *resolutions = @{
        @"chunked": @{@"res": @"1920x1080", @"fps": @60, @"bw": @"8534000"},
        @"1080p60": @{@"res": @"1920x1080", @"fps": @60, @"bw": @"8254000"},
        @"720p60": @{@"res": @"1280x720", @"fps": @60, @"bw": @"3708000"},
        @"480p30": @{@"res": @"854x480", @"fps": @30, @"bw": @"1562000"},
        @"360p30": @{@"res": @"640x360", @"fps": @30, @"bw": @"1064000"}
    };
    
    NSArray *keys = @[@"chunked", @"1080p60", @"720p60", @"480p30", @"360p30"];
    
    for (NSString *resKey in keys) {
        NSString *streamUrl = [NSString stringWithFormat:@"twab://%@/%@/%@/index-dvr.m3u8", domain, vodSpecialID, resKey];
        NSDictionary *resInfo = resolutions[resKey];
        
        [manifest appendFormat:@"#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=\"%@\",NAME=\"%@\",AUTOSELECT=YES,DEFAULT=%@\n", resKey, resKey, [resKey isEqualToString:@"chunked"] ? @"YES" : @"NO"];
        [manifest appendFormat:@"#EXT-X-STREAM-INF:BANDWIDTH=%@,RESOLUTION=%@,FRAME-RATE=%@\n", resInfo[@"bw"], resInfo[@"res"], resInfo[@"fps"]];
        [manifest appendFormat:@"%@\n", streamUrl];
    }
    
    return manifest;
}

- (NSData *)patchPlaylistData:(NSData *)data {
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return data;
    NSString *patchedBody = [body stringByReplacingOccurrencesOfString:@"-unmuted" withString:@"-muted"];
    patchedBody = [patchedBody stringByReplacingOccurrencesOfString:@"https://" withString:@"twab://"];
    return [patchedBody dataUsingEncoding:NSUTF8StringEncoding];
}

@end
