#define PROXY_ADDR @"https://api.ttv.lol"
#define DISCORD_WEBHOOK_URL @"https://discord.com/api/webhooks/1488032310229074041/Qz2SM5WXkt73aHHAoR0jh9qUnK2HffJ1Vqfno7ZTksNPc8qx_L19zBz-g0gLRl0ef1Si"

#ifdef DEBUG
#define TWABLog(fmt, ...) NSLog(@"[TWAB] " fmt, ##__VA_ARGS__)
#else
#define TWABLog(fmt, ...) [TWABLogger log:[NSString stringWithFormat:fmt, ##__VA_ARGS__]]
#endif
