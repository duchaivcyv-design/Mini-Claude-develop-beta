#import "AttachmentStore.h"
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import "OfficeText.h"

const NSInteger  kMaxAttachmentsPerMessage = 6;
const NSUInteger kMaxInlineBytesPerMessage = 13 * 1024 * 1024;   // base64 adds a third: ~17.4 MB of the 20 MB request cap

static const CGFloat    kImageMaxSide      = 2048;                 // Gemini scales anything larger down anyway
static const CGFloat    kThumbMaxSide      = 160;
static const NSUInteger kMaxPDFBytes       = 10 * 1024 * 1024;
static const NSUInteger kMaxOfficeBytes    = 15 * 1024 * 1024;     // .docx / .pptx archive size
static const NSUInteger kMaxTextFileBytes  = 4 * 1024 * 1024;
static const NSUInteger kMaxImageFileBytes = 40 * 1024 * 1024;
static const NSUInteger kMaxTextChars      = 200000;

static NSString *RootDir(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
        dir = [[base stringByAppendingPathComponent:@"ClaudeMini"] stringByAppendingPathComponent:@"attachments"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return dir;
}

// Conversation ids and file names become path components, so refuse anything that could escape the folder.
static BOOL SafeComponent(id value) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *s = value;
    return s.length > 0 && [s rangeOfString:@"/"].location == NSNotFound && [s rangeOfString:@".."].location == NSNotFound;
}

@implementation AttachmentStore

#pragma mark - Folders

+ (NSString *)directoryForConversation:(NSString *)conversationId create:(BOOL)create {
    if (!SafeComponent(conversationId)) return nil;
    NSString *dir = [RootDir() stringByAppendingPathComponent:conversationId];
    if (create) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return dir;
}

+ (void)deleteDirectoryForConversation:(NSString *)conversationId {
    NSString *dir = [self directoryForConversation:conversationId create:NO];
    if (dir) [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
}

+ (void)deleteAll {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *item in [fm contentsOfDirectoryAtPath:RootDir() error:nil]) {
        [fm removeItemAtPath:[RootDir() stringByAppendingPathComponent:item] error:nil];
    }
}

+ (void)removeOrphansKeepingConversationIds:(NSSet *)conversationIds {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *item in [fm contentsOfDirectoryAtPath:RootDir() error:nil]) {
        if (![conversationIds containsObject:item]) {
            [fm removeItemAtPath:[RootDir() stringByAppendingPathComponent:item] error:nil];
        }
    }
}

+ (NSString *)pathForFile:(NSString *)file conversation:(NSString *)conversationId {
    if (!SafeComponent(file)) return nil;
    NSString *dir = [self directoryForConversation:conversationId create:NO];
    return dir ? [dir stringByAppendingPathComponent:file] : nil;
}

+ (void)deleteAttachment:(NSDictionary *)attachment conversation:(NSString *)conversationId {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *key in @[@"file", @"thumb"]) {
        NSString *path = [self pathForFile:attachment[key] conversation:conversationId];
        if (path) [fm removeItemAtPath:path error:nil];
    }
}

+ (NSString *)thumbnailDataURIForAttachment:(NSDictionary *)attachment conversation:(NSString *)conversationId {
    NSString *path = [self pathForFile:attachment[@"thumb"] conversation:conversationId];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (data.length == 0) return @"";
    return [@"data:image/jpeg;base64," stringByAppendingString:[data base64EncodedStringWithOptions:0]];
}

#pragma mark - Images

// Draws onto white (JPEG has no alpha) at no more than maxSide pixels on the long edge.
+ (NSData *)jpegFromImage:(UIImage *)image maxSide:(CGFloat)maxSide quality:(CGFloat)quality {
    CGSize size = image.size;
    if (size.width < 1 || size.height < 1) return nil;
    CGFloat scale = MIN(1.0, maxSide / MAX(size.width, size.height));
    CGSize target = CGSizeMake(MAX(1, floor(size.width * scale)), MAX(1, floor(size.height * scale)));

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target format:format];
    UIImage *flat = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor whiteColor] setFill];
        UIRectFill(CGRectMake(0, 0, target.width, target.height));
        [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
    return UIImageJPEGRepresentation(flat, quality);
}

+ (NSDictionary *)importImageData:(NSData *)data name:(NSString *)name conversation:(NSString *)conversationId errorKey:(NSString **)errorKey {
    if (data.length == 0) { if (errorKey) *errorKey = @"att_err_empty"; return nil; }
    if (data.length > kMaxImageFileBytes) { if (errorKey) *errorKey = @"att_err_too_large"; return nil; }
    NSString *dir = [self directoryForConversation:conversationId create:YES];
    if (!dir) { if (errorKey) *errorKey = @"att_err_unreadable"; return nil; }

    // ImageIO decodes straight to a size-limited bitmap and applies the EXIF rotation, without ever holding the full-size image.
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) { if (errorKey) *errorKey = @"att_err_unreadable"; return nil; }
    NSDictionary *options = @{ (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                               (__bridge id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                               (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @(kImageMaxSide) };
    CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!cgImage) { if (errorKey) *errorKey = @"att_err_unreadable"; return nil; }
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);

    NSData *jpeg = [self jpegFromImage:image maxSide:kImageMaxSide quality:0.8];
    NSData *thumb = [self jpegFromImage:image maxSide:kThumbMaxSide quality:0.7];
    if (jpeg.length == 0 || thumb.length == 0) { if (errorKey) *errorKey = @"att_err_unreadable"; return nil; }

    NSString *attachmentId = [[NSUUID UUID] UUIDString];
    NSString *file = [attachmentId stringByAppendingString:@".jpg"];
    NSString *thumbFile = [attachmentId stringByAppendingString:@"_t.jpg"];
    BOOL ok = [jpeg writeToFile:[dir stringByAppendingPathComponent:file] options:NSDataWritingAtomic error:nil]
           && [thumb writeToFile:[dir stringByAppendingPathComponent:thumbFile] options:NSDataWritingAtomic error:nil];
    if (!ok) { if (errorKey) *errorKey = @"att_err_unreadable"; return nil; }

    NSString *display = name.length > 0 ? name : @"photo.jpg";
    return @{ @"id": attachmentId, @"kind": @"image", @"name": display, @"mime": @"image/jpeg",
              @"file": file, @"thumb": thumbFile, @"bytes": @(jpeg.length) };
}

#pragma mark - Documents

+ (NSSet *)imageExtensions {
    return [NSSet setWithObjects:@"jpg", @"jpeg", @"png", @"gif", @"heic", @"heif", @"webp", @"tif", @"tiff", @"bmp", nil];
}

// Formats Gemini cannot read and that we cannot unpack either: better to say so than to send garbage.
+ (NSSet *)unsupportedExtensions {
    return [NSSet setWithObjects:@"doc", @"xls", @"xlsx", @"ppt", @"odt", @"ods", @"odp", @"pages", @"numbers", @"key", @"rtf",
            @"zip", @"rar", @"7z", @"mp3", @"mp4", @"mov", @"m4a", @"wav", @"avi", @"exe", @"dmg", @"ipa", @"deb", nil];
}

+ (NSString *)decodeText:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    NSUInteger probe = MIN(data.length, (NSUInteger)8192);
    BOOL utf16BOM = probe >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF));
    if (!utf16BOM) {
        for (NSUInteger i = 0; i < probe; i++) {
            if (bytes[i] == 0) return nil;   // NUL bytes: this is a binary file, not text
        }
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text) return text;
    NSString *converted = nil;
    [NSString stringEncodingForData:data encodingOptions:nil convertedString:&converted usedLossyConversion:NULL];
    if (converted.length > 0) return converted;
    return [[NSString alloc] initWithData:data encoding:NSWindowsCP1252StringEncoding];
}

+ (NSDictionary *)saveText:(NSString *)text name:(NSString *)name conversation:(NSString *)conversationId errorKey:(NSString **)errorKey {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) { if (errorKey) *errorKey = @"att_err_no_text"; return nil; }
    if (trimmed.length > kMaxTextChars) {
        NSRange safe = [trimmed rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, kMaxTextChars)];
        trimmed = [[trimmed substringWithRange:safe] stringByAppendingString:@"\n[… truncated]"];
    }
    NSString *dir = [self directoryForConversation:conversationId create:YES];
    NSData *utf8 = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
    if (!dir || utf8.length == 0) { if (errorKey) *errorKey = @"att_err_unreadable"; return nil; }

    NSString *attachmentId = [[NSUUID UUID] UUIDString];
    NSString *file = [attachmentId stringByAppendingString:@".txt"];
    if (![utf8 writeToFile:[dir stringByAppendingPathComponent:file] options:NSDataWritingAtomic error:nil]) {
        if (errorKey) *errorKey = @"att_err_unreadable";
        return nil;
    }
    return @{ @"id": attachmentId, @"kind": @"text", @"name": name, @"mime": @"text/plain", @"file": file, @"bytes": @(utf8.length) };
}

+ (NSDictionary *)importOffice:(NSData *)data isPPTX:(BOOL)isPPTX name:(NSString *)name conversation:(NSString *)conversationId errorKey:(NSString **)errorKey {
    int err = OFFICE_OK;
    char *raw = isPPTX ? office_pptx_text(data.bytes, data.length, &err) : office_docx_text(data.bytes, data.length, &err);
    if (!raw) {
        if (errorKey) *errorKey = (err == OFFICE_ERR_UNSUPPORTED) ? @"att_err_encrypted" : @"att_err_unreadable";
        return nil;
    }
    NSString *text = [NSString stringWithUTF8String:raw];
    free(raw);
    if (!text) { if (errorKey) *errorKey = @"att_err_unreadable"; return nil; }
    return [self saveText:text name:name conversation:conversationId errorKey:errorKey];
}

+ (NSDictionary *)importDocumentAtURL:(NSURL *)url conversation:(NSString *)conversationId errorKey:(NSString **)errorKey {
    NSString *name = url.lastPathComponent.length > 0 ? url.lastPathComponent : @"file";
    NSString *ext = name.pathExtension.lowercaseString;

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (!data) { if (errorKey) *errorKey = @"att_err_unreadable"; return nil; }
    if (data.length == 0) { if (errorKey) *errorKey = @"att_err_empty"; return nil; }

    if ([[self imageExtensions] containsObject:ext]) {
        return [self importImageData:data name:name conversation:conversationId errorKey:errorKey];
    }

    if ([ext isEqualToString:@"pdf"]) {
        if (data.length > kMaxPDFBytes) { if (errorKey) *errorKey = @"att_err_too_large"; return nil; }
        NSData *head = [data subdataWithRange:NSMakeRange(0, MIN(data.length, (NSUInteger)1024))];
        if ([head rangeOfData:[NSData dataWithBytes:"%PDF" length:4] options:0 range:NSMakeRange(0, head.length)].location == NSNotFound) {
            if (errorKey) *errorKey = @"att_err_unreadable";
            return nil;
        }
        NSString *dir = [self directoryForConversation:conversationId create:YES];
        NSString *attachmentId = [[NSUUID UUID] UUIDString];
        NSString *file = [attachmentId stringByAppendingString:@".pdf"];
        if (!dir || ![data writeToFile:[dir stringByAppendingPathComponent:file] options:NSDataWritingAtomic error:nil]) {
            if (errorKey) *errorKey = @"att_err_unreadable";
            return nil;
        }
        return @{ @"id": attachmentId, @"kind": @"pdf", @"name": name, @"mime": @"application/pdf", @"file": file, @"bytes": @(data.length) };
    }

    if ([ext isEqualToString:@"docx"] || [ext isEqualToString:@"pptx"]) {
        if (data.length > kMaxOfficeBytes) { if (errorKey) *errorKey = @"att_err_too_large"; return nil; }
        return [self importOffice:data isPPTX:[ext isEqualToString:@"pptx"] name:name conversation:conversationId errorKey:errorKey];
    }

    if ([[self unsupportedExtensions] containsObject:ext]) {
        if (errorKey) *errorKey = @"att_err_unsupported";
        return nil;
    }

    // Everything else: accept it only if it really is text (txt, md, csv, json, source code, ...).
    if (data.length > kMaxTextFileBytes) { if (errorKey) *errorKey = @"att_err_too_large"; return nil; }
    NSString *text = [self decodeText:data];
    if (!text) { if (errorKey) *errorKey = @"att_err_unsupported"; return nil; }
    return [self saveText:text name:name conversation:conversationId errorKey:errorKey];
}

@end
