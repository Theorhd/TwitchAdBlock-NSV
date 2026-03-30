#import "TWABLogger.h"
#import "Config.h"

@implementation TWABLogger

+ (void)log:(NSString *)message {
    NSLog(@"[TWAB] %@", message); // Toujours loguer localement aussi
    
    // Éviter l'envoi Discord si l'URL n'est pas configurée
    if ([DISCORD_WEBHOOK_URL isEqualToString:@"TON_URL_WEBHOOK"]) return;

    static dispatch_queue_t logQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logQueue = dispatch_queue_create("com.twab.logger", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(logQueue, ^{
        NSURL *url = [NSURL URLWithString:DISCORD_WEBHOOK_URL];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        [request setHTTPMethod:@"POST"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

        NSDictionary *payload = @{@"content": [NSString stringWithFormat:@"`[VOD]` %@", message]};
        NSData *postData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        [request setHTTPBody:postData];

        [[[NSURLSession sharedSession] dataTaskWithRequest:request] resume];
    });
}

@end
