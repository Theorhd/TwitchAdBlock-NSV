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
    [request setValue:@"kimne78kx3ncx6brgo4mv6wki5h1ko" forHTTPHeaderField:@"Client-Id"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://www.twitch.tv" forHTTPHeaderField:@"Origin"];
    [request setValue:@"https://www.twitch.tv/" forHTTPHeaderField:@"Referer"];

    NSString *formattedID = vodID;
    // Remove any non-digit characters if it's not starting with 'v'
    if (![vodID hasPrefix:@"v"]) {
        NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        if ([vodID rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
             // Handle cases like v2/12345678 or 12345678.m3u8
             formattedID = [vodID stringByTrimmingCharactersInSet:nonDigits];
        }
        if (formattedID.length > 0) {
            formattedID = [NSString stringWithFormat:@"v%@", formattedID];
        }
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
        if (jsonError || !json[@"data"] || [json[@"data"][@"video"] isEqual:[NSNull null]]) {
            // Try without the 'v' prefix if it failed
            NSString *rawID = [formattedID hasPrefix:@"v"] ? [formattedID substringFromIndex:1] : formattedID;
            [self fetchVODMetadataWithoutV:rawID completion:completion];
            return;
        }
        completion(json[@"data"][@"video"], nil);
    }] resume];
}

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
           [lower containsString:@"#ext-x-twitch-restricted"] ||
           [lower containsString:@"access denied"];
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
    
    // Manifest Master plus complet pour iOS
    NSMutableString *manifest = [NSMutableString stringWithFormat:@"#EXTM3U\n"];
    [manifest appendFormat:@"#EXT-X-VERSION:3\n"];
    [manifest appendFormat:@"#EXT-X-TWITCH-INFO:ORIGIN=\"s3\",B=\"false\",REGION=\"EU\",USER-IP=\"127.0.0.1\",SERVING-ID=\"%@\",CLUSTER=\"cloudfront_vod\",USER-COUNTRY=\"FR\",MANIFEST-CLUSTER=\"cloudfront_vod\"\n", servingID];
    
    NSDictionary *resolutions = @{
        @"160p30": @{@"res": @"284x160", @"fps": @30, @"bw": @638000},
        @"360p30": @{@"res": @"640x360", @"fps": @30, @"bw": @1064000},
        @"480p30": @{@"res": @"854x480", @"fps": @30, @"bw": @1562000},
        @"720p60": @{@"res": @"1280x720", @"fps": @60, @"bw": @3708000},
        @"1080p60": @{@"res": @"1920x1080", @"fps": @60, @"bw": @8254000},
        @"chunked": @{@"res": @"1920x1080", @"fps": @60, @"bw": @8534000}
    };
    
    NSArray *keys = @[@"chunked", @"1080p60", @"720p60", @"480p30", @"360p30", @"160p30"];
    
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZ"];
    NSDate *createdDate = [dateFormatter dateFromString:createdAt];
    NSTimeInterval daysDiff = createdDate ? [[NSDate date] timeIntervalSinceDate:createdDate] / 86400.0 : 0;
    
    NSString *cleanVodID = [vodID hasPrefix:@"v"] ? [vodID substringFromIndex:1] : vodID;

    for (NSString *resKey in keys) {
        NSString *streamUrl;
        if ([broadcastType isEqualToString:@"highlight"]) {
            streamUrl = [NSString stringWithFormat:@"twab://%@/%@/%@/highlight-%@.m3u8", domain, vodSpecialID, resKey, cleanVodID];
        } else if ([broadcastType isEqualToString:@"upload"] && daysDiff > 7) {
            streamUrl = [NSString stringWithFormat:@"twab://%@/%@/%@/%@/%@/index-dvr.m3u8", domain, owner[@"login"], cleanVodID, vodSpecialID, resKey];
        } else {
            streamUrl = [NSString stringWithFormat:@"twab://%@/%@/%@/index-dvr.m3u8", domain, vodSpecialID, resKey];
        }

        NSString *quality = [resKey isEqualToString:@"chunked"] ? @"1080p (source)" : resKey;
        NSDictionary *resInfo = resolutions[resKey];
        
        [manifest appendFormat:@"#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=\"%@\",NAME=\"%@\",AUTOSELECT=YES,DEFAULT=%@\n", resKey, quality, [resKey isEqualToString:@"chunked"] ? @"YES" : @"NO"];
        [manifest appendFormat:@"#EXT-X-STREAM-INF:BANDWIDTH=%@,CODECS=\"avc1.4D001E,mp4a.40.2\",RESOLUTION=%@,VIDEO=\"%@\",FRAME-RATE=%@\n", resInfo[@"bw"], resInfo[@"res"], resKey, resInfo[@"fps"]];
        [manifest appendFormat:@"%@\n", streamUrl];
    }
    
    return manifest;
}

- (NSData *)patchPlaylistData:(NSData *)data {
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return data;
    
    // Patch crucial pour éviter les 403 sur les segments audio protégés
    NSString *patchedBody = body;
    if ([patchedBody containsString:@"-unmuted"]) {
        patchedBody = [patchedBody stringByReplacingOccurrencesOfString:@"-unmuted" withString:@"-muted"];
    }
    
    // Forcer le passage par notre proxy pour tous les liens absolus
    if ([patchedBody containsString:@"https://"]) {
        patchedBody = [patchedBody stringByReplacingOccurrencesOfString:@"https://" withString:@"twab://"];
    }
    
    // Ajouter les tags VOD manquants si c'est une sub-playlist
    if ([patchedBody containsString:@"#EXT-X-TARGETDURATION"] && ![patchedBody containsString:@"#EXT-X-PLAYLIST-TYPE"]) {
        patchedBody = [patchedBody stringByReplacingOccurrencesOfString:@"#EXTM3U\n" withString:@"#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-ALLOW-CACHE:YES\n"];
    }
    
    return [patchedBody dataUsingEncoding:NSUTF8StringEncoding];
}

@end
