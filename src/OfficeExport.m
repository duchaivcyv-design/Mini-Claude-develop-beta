#import "OfficeExport.h"
#import <zlib.h>
#include <stdint.h>

static const NSUInteger kExportStreamChunkBytes = 1024 * 1024; // 1 MB

static void AppendLE16(NSMutableData *data, uint16_t value) {
    uint8_t bytes[2] = { (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF) };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void AppendLE32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[4] = { (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF),
                         (uint8_t)((value >> 16) & 0xFF), (uint8_t)((value >> 24) & 0xFF) };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static NSString *XMLSafe(NSString *text) {
    NSString *source = [text isKindOfClass:[NSString class]] ? text : @"";
    if (source.length == 0) return @"";

    NSMutableString *result = [NSMutableString stringWithCapacity:(NSUInteger)(source.length * 1.1)];
    for (NSUInteger i = 0; i < source.length; i++) {
        unichar c = [source characterAtIndex:i];
        if (c != 0x9 && c != 0xA && c != 0xD && c < 0x20) continue;

        switch (c) {
            case '&':  [result appendString:@"&amp;"]; break;
            case '<':  [result appendString:@"&lt;"]; break;
            case '>':  [result appendString:@"&gt;"]; break;
            case '"':  [result appendString:@"&quot;"]; break;
            case '\'': [result appendString:@"&apos;"]; break;
            default:   [result appendFormat:@"%C", c]; break;
        }
    }
    return result;
}

// Nén raw deflate (ZIP method 8). Trả về nil nếu nén không hiệu quả hoặc lỗi.
static NSData *DeflateRawData(NSData *input) {
    if (input.length == 0 || input.length > UINT32_MAX) return nil;

    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        return nil;
    }

    uLong bound = deflateBound(&stream, (uLong)input.length);
    if (bound == 0 || bound >= input.length) {
        deflateEnd(&stream);
        return nil;
    }

    NSMutableData *compressed = [NSMutableData dataWithLength:(NSUInteger)bound];
    stream.next_in = (Bytef *)input.bytes;
    stream.avail_in = (uInt)input.length;
    stream.next_out = (Bytef *)compressed.mutableBytes;
    stream.avail_out = (uInt)bound;

    int ret = deflate(&stream, Z_FINISH);
    NSUInteger outLen = (NSUInteger)stream.total_out;
    deflateEnd(&stream);

    if (ret != Z_STREAM_END || outLen == 0 || outLen >= input.length) {
        return nil;
    }
    compressed.length = outLen;
    return compressed;
}

static NSData *MinimalDOCXData(NSString *text) {
    NSMutableString *paragraphs = [NSMutableString stringWithCapacity:MIN((NSUInteger)(text.length * 1.2), (NSUInteger)(8 * 1024 * 1024))];
    NSString *source = [text isKindOfClass:[NSString class]] ? text : @"";

    if (source.length > 0) {
        [source enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
            #pragma unused(stop)
            [paragraphs appendFormat:@"<w:p><w:r><w:t xml:space=\"preserve\">%@</w:t></w:r></w:p>", XMLSafe(line)];
        }];
        unichar lastChar = [source characterAtIndex:source.length - 1];
        if (lastChar == '\n' || lastChar == '\r') {
            [paragraphs appendString:@"<w:p><w:r><w:t xml:space=\"preserve\"></w:t></w:r></w:p>"];
        }
    } else {
        [paragraphs appendString:@"<w:p><w:r><w:t xml:space=\"preserve\"></w:t></w:r></w:p>"];
    }

    NSString *document = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
         @"<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
         @"<w:body>%@<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/>"
         @"<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/>"
         @"</w:sectPr></w:body></w:document>", paragraphs];

    NSString *contentTypes =
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
         @"<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
         @"<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
         @"<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
         @"<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
         @"</Types>";

    NSString *relationships =
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
         @"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
         @"<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
         @"</Relationships>";

    NSData *ctData = [contentTypes dataUsingEncoding:NSUTF8StringEncoding];
    NSData *relData = [relationships dataUsingEncoding:NSUTF8StringEncoding];
    NSData *docData = [document dataUsingEncoding:NSUTF8StringEncoding];
    if (!ctData || !relData || !docData) return nil;

    NSArray *entries = @[
        @{ @"name": @"[Content_Types].xml", @"data": ctData },
        @{ @"name": @"_rels/.rels", @"data": relData },
        @{ @"name": @"word/document.xml", @"data": docData }
    ];

    NSMutableData *archive = [NSMutableData dataWithCapacity:docData.length / 2 + 4096];
    NSMutableData *central = [NSMutableData dataWithCapacity:512];

    for (NSDictionary *entry in entries) {
        NSData *name = [entry[@"name"] dataUsingEncoding:NSUTF8StringEncoding];
        NSData *rawPayload = entry[@"data"];
        if (name.length == 0 || name.length > UINT16_MAX || rawPayload.length > UINT32_MAX) return nil;

        uint32_t crc = (uint32_t)crc32(0L, (const Bytef *)rawPayload.bytes, (uInt)rawPayload.length);
        uint32_t uncompressedSize = (uint32_t)rawPayload.length;

        uint16_t method = 0; // 0 = STORE
        NSData *wirePayload = rawPayload;
        NSData *deflated = DeflateRawData(rawPayload);
        if (deflated.length > 0 && deflated.length <= UINT32_MAX) {
            method = 8; // 8 = DEFLATE
            wirePayload = deflated;
        }
        uint32_t compressedSize = (uint32_t)wirePayload.length;
        uint32_t offset = (uint32_t)archive.length;

        // Local file header
        AppendLE32(archive, 0x04034b50);
        AppendLE16(archive, 20);
        AppendLE16(archive, 0x0800); // UTF-8 file name
        AppendLE16(archive, method);
        AppendLE16(archive, 0);
        AppendLE16(archive, 0);
        AppendLE32(archive, crc);
        AppendLE32(archive, compressedSize);
        AppendLE32(archive, uncompressedSize);
        AppendLE16(archive, (uint16_t)name.length);
        AppendLE16(archive, 0);
        [archive appendData:name];
        [archive appendData:wirePayload];

        // Central directory header
        AppendLE32(central, 0x02014b50);
        AppendLE16(central, 20);
        AppendLE16(central, 20);
        AppendLE16(central, 0x0800);
        AppendLE16(central, method);
        AppendLE16(central, 0);
        AppendLE16(central, 0);
        AppendLE32(central, crc);
        AppendLE32(central, compressedSize);
        AppendLE32(central, uncompressedSize);
        AppendLE16(central, (uint16_t)name.length);
        AppendLE16(central, 0);
        AppendLE16(central, 0);
        AppendLE16(central, 0);
        AppendLE16(central, 0);
        AppendLE32(central, 0);
        AppendLE32(central, offset);
        [central appendData:name];
    }

    if (archive.length > UINT32_MAX || central.length > UINT32_MAX) return nil;
    uint32_t centralOffset = (uint32_t)archive.length;
    [archive appendData:central];

    // End of central directory record
    AppendLE32(archive, 0x06054b50);
    AppendLE16(archive, 0);
    AppendLE16(archive, 0);
    AppendLE16(archive, (uint16_t)entries.count);
    AppendLE16(archive, (uint16_t)entries.count);
    AppendLE32(archive, (uint32_t)central.length);
    AppendLE32(archive, centralOffset);
    AppendLE16(archive, 0);
    return archive;
}

static NSURL *WriteExport(NSData *data, NSString *extension, NSError **error) {
    if (data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"ClaudeMini.Export"
                                         code:1
                                     userInfo:@{ NSLocalizedDescriptionKey: @"Empty export" }];
        }
        return nil;
    }

    NSString *directory = NSTemporaryDirectory();
    NSString *name = [NSString stringWithFormat:@"ClaudeMini-Reply-%@.%@", [[NSUUID UUID] UUIDString], extension];
    NSString *filePath = [directory stringByAppendingPathComponent:name];
    NSURL *url = [NSURL fileURLWithPath:filePath];

    if (data.length <= kExportStreamChunkBytes * 4) {
        if (![data writeToURL:url options:NSDataWritingAtomic error:error]) return nil;
        return url;
    }

    // Ghi theo từng khối 1 MB để tránh tăng đột biến RAM với file lớn
    if (![[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ClaudeMini.Export"
                                         code:3
                                     userInfo:@{ NSLocalizedDescriptionKey: @"Could not create export file" }];
        }
        return nil;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:filePath];
    if (!handle) {
        if (error) {
            *error = [NSError errorWithDomain:@"ClaudeMini.Export"
                                         code:4
                                     userInfo:@{ NSLocalizedDescriptionKey: @"Could not open export file for writing" }];
        }
        return nil;
    }

    @try {
        NSUInteger offset = 0;
        while (offset < data.length) {
            @autoreleasepool {
                NSUInteger len = MIN(kExportStreamChunkBytes, data.length - offset);
                NSData *chunk = [NSData dataWithBytesNoCopy:(void *)((const uint8_t *)data.bytes + offset)
                                                     length:len
                                               freeWhenDone:NO];
                [handle writeData:chunk];
                offset += len;
            }
        }
        [handle synchronizeFile];
        return url;
    } @catch (NSException *ex) {
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        if (error) {
            *error = [NSError errorWithDomain:@"ClaudeMini.Export"
                                         code:5
                                     userInfo:@{ NSLocalizedDescriptionKey: ex.reason ?: @"Stream write failed" }];
        }
        return nil;
    } @finally {
        [handle closeFile];
    }
}

@implementation OfficeExport

+ (NSURL *)writeTextFile:(NSString *)text error:(NSError **)error {
    NSData *data = [(text ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    return WriteExport(data, @"txt", error);
}

+ (NSURL *)writeWordFile:(NSString *)text error:(NSError **)error {
    NSData *data = MinimalDOCXData(text ?: @"");
    if (!data && error) {
        *error = [NSError errorWithDomain:@"ClaudeMini.Export"
                                     code:2
                                 userInfo:@{ NSLocalizedDescriptionKey: @"Could not build DOCX package" }];
    }
    return data ? WriteExport(data, @"docx", error) : nil;
}

@end
