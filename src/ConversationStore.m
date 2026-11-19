#import "ConversationStore.h"
#import "AttachmentStore.h"

static const NSUInteger kConvStreamChunkBytes = 1024 * 1024; // 1 MB

static dispatch_queue_t ConvQueue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.claudemini.conversationstore", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *ChatsDir(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
        dir = [[base stringByAppendingPathComponent:@"ClaudeMini"] stringByAppendingPathComponent:@"chats"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    });
    return dir;
}

static NSString *IndexPath(void) {
    return [ChatsDir() stringByAppendingPathComponent:@"index.json"];
}

static BOOL ValidId(id value) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *cid = value;
    return cid.length > 0 &&
           [cid rangeOfString:@"/"].location == NSNotFound &&
           [cid rangeOfString:@".."].location == NSNotFound;
}

static NSString *FilePath(NSString *cid) {
    return [ChatsDir() stringByAppendingPathComponent:[cid stringByAppendingString:@".json"]];
}

static NSData *SerializeJSON(id obj) {
    if (!obj) return nil;
    NSJSONWritingOptions opts = 0;
    if (@available(iOS 13.0, *)) {
        opts = NSJSONWritingWithoutEscapingSlashes;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:opts error:nil];
    return data ?: [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
}

static BOOL WriteDataToPath(NSData *data, NSString *filePath) {
    if (!data || !filePath) return NO;
    if (data.length <= kConvStreamChunkBytes * 4) {
        return [data writeToFile:filePath options:NSDataWritingAtomic error:nil];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tempPath = [filePath stringByAppendingPathExtension:@"tmp"];
    [fm removeItemAtPath:tempPath error:nil];
    if (![fm createFileAtPath:tempPath contents:nil attributes:nil]) return NO;

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:tempPath];
    if (!handle) {
        [fm removeItemAtPath:tempPath error:nil];
        return NO;
    }

    @try {
        NSUInteger offset = 0;
        while (offset < data.length) {
            @autoreleasepool {
                NSUInteger len = MIN(kConvStreamChunkBytes, data.length - offset);
                NSData *chunk = [NSData dataWithBytesNoCopy:(void *)((const uint8_t *)data.bytes + offset)
                                                     length:len
                                               freeWhenDone:NO];
                [handle writeData:chunk];
                offset += len;
            }
        }
        [handle synchronizeFile];
        [handle closeFile];
        handle = nil;

        [fm removeItemAtPath:filePath error:nil];
        return [fm moveItemAtPath:tempPath toPath:filePath error:nil];
    } @catch (__unused NSException *ex) {
        [handle closeFile];
        [fm removeItemAtPath:tempPath error:nil];
        return NO;
    }
}

@implementation ConversationStore

#pragma mark - Index

static NSArray *gIndexCache;

+ (NSArray *)sortedEntries:(NSArray *)entries {
    if (![entries isKindOfClass:[NSArray class]]) return @[];
    return [entries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double ua = [a[@"updated"] doubleValue], ub = [b[@"updated"] doubleValue];
        if (ua == ub) return NSOrderedSame;
        return ua > ub ? NSOrderedAscending : NSOrderedDescending;
    }];
}

+ (void)writeIndex:(NSArray *)entries {
    NSArray *sorted = [self sortedEntries:entries];
    @synchronized (self) { gIndexCache = [sorted copy]; }
    NSData *data = SerializeJSON(sorted);
    if (data) {
        [data writeToFile:IndexPath() options:NSDataWritingAtomic error:nil];
    }
}

+ (NSArray *)rebuildIndex {
    NSMutableArray *entries = [NSMutableArray array];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:ChatsDir() error:nil];
    for (NSString *file in files) {
        if (![file hasSuffix:@".json"] || [file isEqualToString:@"index.json"]) continue;
        NSString *cid = [file stringByDeletingPathExtension];
        NSDictionary *conv = [self loadConversationWithId:cid];
        if (!conv) continue;
        [entries addObject:@{ @"id": cid,
                              @"title": conv[@"title"] ?: @"",
                              @"updated": conv[@"updated"] ?: @0 }];
    }
    NSArray *sorted = [self sortedEntries:entries];
    [self writeIndex:sorted];
    return sorted;
}

+ (NSArray *)rawIndex {
    @synchronized (self) { if (gIndexCache) return gIndexCache; }
    NSArray *loaded = [self readIndexFromDisk];
    @synchronized (self) { gIndexCache = [loaded copy]; }
    return loaded;
}

+ (NSArray *)readIndexFromDisk {
    NSData *data = [NSData dataWithContentsOfFile:IndexPath()];
    if (data.length == 0) return [self rebuildIndex];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSArray class]]) return [self rebuildIndex];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[(NSArray *)obj count]];
    for (id entry in (NSArray *)obj) {
        if ([entry isKindOfClass:[NSDictionary class]] && ValidId(entry[@"id"])) {
            [out addObject:entry];
        }
    }
    return [self sortedEntries:out];
}

+ (NSArray *)allEntries {
    return [self sortedEntries:[self rawIndex]];
}

#pragma mark - Conversations

+ (NSMutableDictionary *)newConversationWithModel:(NSString *)model {
    NSNumber *now = @([[NSDate date] timeIntervalSince1970]);
    return [@{ @"id": [[NSUUID UUID] UUIDString],
               @"title": @"",
               @"customTitle": @NO,
               @"model": model ?: @"",
               @"created": now,
               @"updated": now,
               @"messages": [NSMutableArray array] } mutableCopy];
}

+ (NSMutableDictionary *)loadConversationWithId:(NSString *)cid {
    if (!ValidId(cid)) return nil;
    NSString *path = FilePath(cid);
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (data.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data
                                             options:NSJSONReadingMutableContainers | NSJSONReadingMutableLeaves
                                               error:nil];
    if (![obj isKindOfClass:[NSMutableDictionary class]]) return nil;
    NSMutableDictionary *conv = obj;
    if (![conv[@"messages"] isKindOfClass:[NSMutableArray class]]) {
        conv[@"messages"] = [NSMutableArray array];
    }
    return conv;
}

+ (void)saveConversation:(NSDictionary *)conv {
    NSString *cid = conv[@"id"];
    if (!ValidId(cid)) return;
    NSData *data = SerializeJSON(conv);
    if (!data) return;

    __block BOOL wrote = NO;
    dispatch_sync(ConvQueue(), ^{
        wrote = WriteDataToPath(data, FilePath(cid));
    });
    if (!wrote) return;

    NSMutableArray *entries = [[self rawIndex] mutableCopy];
    for (NSInteger i = (NSInteger)entries.count - 1; i >= 0; i--) {
        if ([entries[i][@"id"] isEqualToString:cid]) [entries removeObjectAtIndex:i];
    }
    [entries addObject:@{ @"id": cid,
                          @"title": conv[@"title"] ?: @"",
                          @"updated": conv[@"updated"] ?: @0 }];
    [self writeIndex:entries];
}

+ (void)deleteConversationWithId:(NSString *)cid {
    if (!ValidId(cid)) return;
    dispatch_sync(ConvQueue(), ^{
        [[NSFileManager defaultManager] removeItemAtPath:FilePath(cid) error:nil];
    });
    [AttachmentStore deleteDirectoryForConversation:cid];

    NSMutableArray *entries = [[self rawIndex] mutableCopy];
    for (NSInteger i = (NSInteger)entries.count - 1; i >= 0; i--) {
        if ([entries[i][@"id"] isEqualToString:cid]) [entries removeObjectAtIndex:i];
    }
    [self writeIndex:entries];
}

+ (void)renameConversationWithId:(NSString *)cid title:(NSString *)title {
    NSMutableDictionary *conv = [self loadConversationWithId:cid];
    if (!conv) return;
    conv[@"title"] = title ?: @"";
    conv[@"customTitle"] = @YES;
    [self saveConversation:conv];
}

+ (void)deleteAll {
    @synchronized (self) { gIndexCache = nil; }
    dispatch_sync(ConvQueue(), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *file in [fm contentsOfDirectoryAtPath:ChatsDir() error:nil]) {
            [fm removeItemAtPath:[ChatsDir() stringByAppendingPathComponent:file] error:nil];
        }
    });
    [AttachmentStore deleteAll];
}

+ (NSArray *)entriesMatching:(NSString *)query {
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (q.length == 0) return [self allEntries];

    NSStringCompareOptions opts = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSMutableArray *matches = [NSMutableArray array];
    for (NSDictionary *entry in [self allEntries]) {
        NSString *title = entry[@"title"];
        if ([title isKindOfClass:[NSString class]] && [title rangeOfString:q options:opts].location != NSNotFound) {
            [matches addObject:entry];
            continue;
        }
        NSDictionary *conv = [self loadConversationWithId:entry[@"id"]];
        NSArray *messages = [conv[@"messages"] isKindOfClass:[NSArray class]] ? conv[@"messages"] : @[];
        for (NSDictionary *message in messages) {
            if (![message isKindOfClass:[NSDictionary class]]) continue;
            NSString *text = message[@"text"];
            if ([text isKindOfClass:[NSString class]] && [text rangeOfString:q options:opts].location != NSNotFound) {
                [matches addObject:entry];
                break;
            }
        }
    }
    return matches;
}

@end
