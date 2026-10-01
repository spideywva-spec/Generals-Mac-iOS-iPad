#import "IOSGameFileManager.h"
#import <zlib.h>

static NSString * const kGXGameFileURL = @"https://www.dropbox.com/scl/fi/11yzk5dnym9d7cm1ie45g/generals-by-spideywv.zip?rlkey=c8wtkjf7dzos0kzq31vyfmomm&st=ts5phkhp&dl=1";

@interface GXGameFileManager () <NSURLSessionDownloadDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,copy) GXGameFileProgressBlock progress;
@property(nonatomic,copy) GXGameFileStatusBlock status;
@property(nonatomic,copy) GXGameFileCompletionBlock completion;
@property(nonatomic,strong) NSURL *downloadURL;
@property(nonatomic,assign) NSTimeInterval startedAt;
@end

@implementation GXGameFileManager

+ (instancetype)sharedManager {
    static GXGameFileManager *m;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ m = [GXGameFileManager new]; });
    return m;
}

- (void)downloadAndInstallGameFileWithProgress:(GXGameFileProgressBlock)progress
                                        status:(GXGameFileStatusBlock)status
                                    completion:(GXGameFileCompletionBlock)completion {
    if (self.session) {
        if (completion) completion(NO, @"Скачивание уже выполняется.");
        return;
    }

    self.progress = progress;
    self.status = status;
    self.completion = completion;
    self.startedAt = [NSDate date].timeIntervalSince1970;

    NSURL *url = [NSURL URLWithString:kGXGameFileURL];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 60.0;
    cfg.timeoutIntervalForResource = 60.0 * 60.0 * 6.0;
    self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];

    if (self.status) self.status(@"Скачивание", @"Подключение к GameFile…");
    [[self.session downloadTaskWithURL:url] resume];
}

- (void)finish:(BOOL)success message:(NSString *)message {
    NSURLSession *s = self.session;
    self.session = nil;
    [s invalidateAndCancel];
    if (self.completion) self.completion(success, message);
    self.progress = nil;
    self.status = nil;
    self.completion = nil;
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    NSTimeInterval elapsed = MAX(0.001, [NSDate date].timeIntervalSince1970 - self.startedAt);
    double speed = (double)totalBytesWritten / elapsed;
    NSTimeInterval remaining = totalBytesExpectedToWrite > 0 && speed > 0
        ? (double)(totalBytesExpectedToWrite - totalBytesWritten) / speed : 0;
    double p = totalBytesExpectedToWrite > 0 ? (double)totalBytesWritten / (double)totalBytesExpectedToWrite : 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progress) self.progress(p, totalBytesWritten, totalBytesExpectedToWrite, speed, remaining);
        if (self.status) self.status(@"Скачивание", @"Загрузка GameFile…");
    });
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"GeneralsGameFile.zip"];
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];

    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtURL:location toURL:[NSURL fileURLWithPath:tmp] error:&copyError]) {
        [self finish:NO message:copyError.localizedDescription ?: @"Не удалось сохранить ZIP."];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progress) self.progress(1.0, 1, 1, 0, 0);
        if (self.status) self.status(@"Распаковка", @"Подготовка файлов…");
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block NSString *message = nil;
        __block BOOL ok = [self extractZIPAtPath:tmp message:&message];
        // The result is updated inside the main-queue verification block.
        __block BOOL verified = ok;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.status) self.status(@"Проверка", ok ? @"Проверка GameFile…" : @"Ошибка распаковки");
            if (ok) {
                BOOL valid = [self verifyGameFiles:&message];
                verified = valid;
            }
            ok = verified;
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            [self finish:ok message:message ?: (ok ? @"GAMEFILE готов." : @"GameFile не установлен.")];
        });
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (!error) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finish:NO message:error.localizedDescription ?: @"Ошибка скачивания."];
    });
}

static uint32_t GXRead32(const uint8_t *p) {
    return ((uint32_t)p[0]) | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t GXRead16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

- (BOOL)extractZIPAtPath:(NSString *)zipPath message:(NSString **)message {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:zipPath];
    if (!fh) { if (message) *message = @"Не удалось открыть ZIP."; return NO; }

    unsigned long long size = fh.seekToEndOfFile;
    if (size < 22) { [fh closeFile]; if (message) *message = @"ZIP повреждён."; return NO; }

    unsigned long long scan = MIN(size, 65557);
    [fh seekToFileOffset:size - scan];
    NSData *tail = [fh readDataOfLength:(NSUInteger)scan];
    const uint8_t *b = (const uint8_t *)tail.bytes;
    NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)tail.length - 22; i >= 0; --i) {
        if (GXRead32(b+i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) { [fh closeFile]; if (message) *message = @"ZIP: центральный каталог не найден."; return NO; }

    uint16_t count = GXRead16(b+eocd+10);
    uint32_t cdSize = GXRead32(b+eocd+12);
    uint32_t cdOffset = GXRead32(b+eocd+16);
    if (count == 0 || cdOffset + cdSize > size) {
        [fh closeFile]; if (message) *message = @"ZIP: неподдерживаемый или повреждённый архив."; return NO;
    }

    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *root = [documents stringByAppendingPathComponent:@"Generals ZH"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];

    [fh seekToFileOffset:cdOffset];
    NSData *cd = [fh readDataOfLength:cdSize];
    const uint8_t *p = (const uint8_t *)cd.bytes;
    NSUInteger pos = 0;

    for (uint16_t index = 0; index < count; ++index) {
        if (pos + 46 > cd.length || GXRead32(p+pos) != 0x02014b50) {
            [fh closeFile]; if (message) *message = @"ZIP: ошибка записи каталога."; return NO;
        }
        uint16_t method = GXRead16(p+pos+10);
        uint32_t compressed = GXRead32(p+pos+20);
        uint32_t uncompressed = GXRead32(p+pos+24);
        uint16_t nameLen = GXRead16(p+pos+28);
        uint16_t extraLen = GXRead16(p+pos+30);
        uint16_t commentLen = GXRead16(p+pos+32);
        uint32_t localOffset = GXRead32(p+pos+42);
        if (pos + 46 + nameLen + extraLen + commentLen > cd.length) {
            [fh closeFile]; if (message) *message = @"ZIP: повреждённое имя файла."; return NO;
        }

        NSData *nameData = [NSData dataWithBytes:p+pos+46 length:nameLen];
        NSString *name = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
        if (!name) name = [[NSString alloc] initWithData:nameData encoding:NSISOLatin1StringEncoding];
        name = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        while ([name hasPrefix:@"/"]) name = [name substringFromIndex:1];

        // Prevent archive path traversal.
        NSString *safe = [name stringByStandardizingPath];
        if ([safe hasPrefix:@"../"] || [safe isEqualToString:@".."] || [safe containsString:@"/../"]) {
            [fh closeFile]; if (message) *message = @"ZIP содержит небезопасный путь."; return NO;
        }

        pos += 46 + nameLen + extraLen + commentLen;
        if (name.length == 0 || [name hasSuffix:@"/"]) continue;
        if (method != 0 && method != 8) {
            [fh closeFile]; if (message) *message = [NSString stringWithFormat:@"ZIP: неподдерживаемый метод для %@.", name]; return NO;
        }

        [fh seekToFileOffset:localOffset];
        NSData *lh = [fh readDataOfLength:30];
        if (lh.length != 30 || GXRead32((const uint8_t *)lh.bytes) != 0x04034b50) {
            [fh closeFile]; if (message) *message = @"ZIP: неверная локальная запись."; return NO;
        }
        uint16_t localNameLen = GXRead16((const uint8_t *)lh.bytes+26);
        uint16_t localExtraLen = GXRead16((const uint8_t *)lh.bytes+28);
        [fh seekToFileOffset:localOffset + 30 + localNameLen + localExtraLen];
        NSData *compressedData = [fh readDataOfLength:compressed];
        if (compressedData.length != compressed) {
            [fh closeFile]; if (message) *message = @"ZIP: файл обрезан."; return NO;
        }

        NSData *outData = nil;
        if (method == 0) {
            outData = compressedData;
        } else {
            NSMutableData *decoded = [NSMutableData dataWithLength:uncompressed];
            z_stream zs;
            memset(&zs, 0, sizeof(zs));
            zs.next_in = (Bytef *)compressedData.bytes;
            zs.avail_in = (uInt)compressedData.length;
            zs.next_out = (Bytef *)decoded.mutableBytes;
            zs.avail_out = (uInt)decoded.length;
            if (inflateInit2(&zs, -MAX_WBITS) != Z_OK ||
                inflate(&zs, Z_FINISH) != Z_STREAM_END) {
                inflateEnd(&zs);
                [fh closeFile]; if (message) *message = [NSString stringWithFormat:@"Ошибка распаковки: %@.", name]; return NO;
            }
            inflateEnd(&zs);
            outData = decoded;
        }

        NSString *destination = [root stringByAppendingPathComponent:safe];
        NSString *parent = [destination stringByDeletingLastPathComponent];
        if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil]) {
            [fh closeFile]; if (message) *message = @"Не удалось создать папку GameFile."; return NO;
        }
        if (![outData writeToFile:destination atomically:NO]) {
            [fh closeFile]; if (message) *message = [NSString stringWithFormat:@"Не удалось записать %@.", name]; return NO;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.status) self.status(@"Распаковка", [NSString stringWithFormat:@"Распакован: %@", name.lastPathComponent]);
        });
    }

    [fh closeFile];
    return YES;
}

- (BOOL)validateInstalledGameFile:(NSString **)message {
    // Единая проверка GameFile: используется после установки, в статусе лаунчера
    // и в разделе Диагностика. Ожидается ровно 44 обычных файла.
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *root = [documents stringByAppendingPathComponent:@"Generals ZH"];
    NSFileManager *fm = [NSFileManager defaultManager];

    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) {
        if (message) *message = @"GameFile: НЕ УСТАНОВЛЕН — папка Generals ZH отсутствует.";
        return NO;
    }

    NSArray *items = [fm subpathsAtPath:root];
    NSUInteger files = 0;
    NSUInteger emptyFiles = 0;

    for (NSString *relative in items) {
        NSString *path = [root stringByAppendingPathComponent:relative];
        BOOL dir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&dir] && !dir) {
            NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
            unsigned long long size = attr != nil ? [attr fileSize] : 0;
            if (size == 0)
                emptyFiles++;
            files++;
        }
    }

    if (files != 44) {
        if (message) *message = [NSString stringWithFormat:
            @"GameFile: НЕ ГОТОВ — объектов %lu/44, пустых: %lu.",
            (unsigned long)files, (unsigned long)emptyFiles];
        return NO;
    }

    if (emptyFiles != 0) {
        if (message) *message = [NSString stringWithFormat:
            @"GameFile: НЕ ГОТОВ — объектов 44/44, пустых: %lu.",
            (unsigned long)emptyFiles];
        return NO;
    }

    if (message) *message = @"GameFile: ГОТОВ — 44/44 объектов, пустых: 0.";
    return YES;
}

- (BOOL)verifyGameFiles:(NSString **)message {
    return [self validateInstalledGameFile:message];
}

@end
