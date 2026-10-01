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
@property(nonatomic,assign) BOOL cancelRequested;
@property(nonatomic,assign) BOOL extractionInProgress;
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
    self.cancelRequested = NO;
    self.extractionInProgress = NO;

    // Никогда не оставляем старый временный ZIP от предыдущей установки.
    NSString *staleZIP = [NSTemporaryDirectory() stringByAppendingPathComponent:@"generals by spideywv.zip"];
    [[NSFileManager defaultManager] removeItemAtPath:staleZIP error:nil];

    NSURL *url = [NSURL URLWithString:kGXGameFileURL];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 60.0;
    cfg.timeoutIntervalForResource = 60.0 * 60.0 * 6.0;
    self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];

    if (self.status) self.status(@"Скачивание", @"Подключение к файлу игры…");
    [[self.session downloadTaskWithURL:url] resume];
}

- (void)cancelDownload {
    self.cancelRequested = YES;
    NSURLSession *s = self.session;
    self.session = nil;
    [s invalidateAndCancel];

    // Удаляем временный ZIP и при ручной отмене. Если распаковка уже идёт,
    // открытый file handle закончит текущую операцию, а путь уже исчезнет.
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"generals by spideywv.zip"];
    if (!self.extractionInProgress)
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];

    if (self.completion) self.completion(NO, @"Загрузка файла игры отменена.");
    self.progress = nil;
    self.status = nil;
    self.completion = nil;
}

- (void)finish:(BOOL)success message:(NSString *)message {
    NSURLSession *s = self.session;
    self.session = nil;
    [s invalidateAndCancel];

    // ZIP никогда не остаётся после завершения, ошибки или отмены.
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"generals by spideywv.zip"];
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];

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
        // Не перезаписываем detail после progress: лаунчер должен показывать
        // размер, скорость и оставшееся время до следующего callback.
        if (self.progress) self.progress(p, totalBytesWritten, totalBytesExpectedToWrite, speed, remaining);
    });
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"generals by spideywv.zip"];
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

    // Extraction AND verification stay off the main thread. Enumerating the
    // installed game after a large ZIP previously caused an iPhone UI freeze.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            self.extractionInProgress = YES;
            NSString *message = nil;
            BOOL ok = [self extractZIPAtPath:tmp message:&message];

        // The archive is no longer needed once extraction has completed.
        // Delete it BEFORE the verification pass so the temporary ZIP never
        // competes with the installed game for disk space during the final scan.
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];

        if (ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.status) self.status(@"Проверка", @"Проверка файла игры…");
            });
            ok = [self verifyGameFiles:&message];
        }

            self.extractionInProgress = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finish:ok message:message ?: (ok ? @"Файл игры готов." : @"Файл игры не установлен.")];
            });
        }
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
    if (!fh) {
        if (message) *message = @"Не удалось открыть ZIP.";
        return NO;
    }

    unsigned long long size = fh.seekToEndOfFile;
    if (size < 22) {
        [fh closeFile];
        if (message) *message = @"ZIP повреждён.";
        return NO;
    }

    // Read only the ZIP tail to locate EOCD; never load the archive itself into RAM.
    unsigned long long scan = MIN(size, 65557ULL);
    [fh seekToFileOffset:size - scan];
    NSData *tail = [fh readDataOfLength:(NSUInteger)scan];
    const uint8_t *b = (const uint8_t *)tail.bytes;
    NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)tail.length - 22; i >= 0; --i) {
        if (GXRead32(b + i) == 0x06054b50) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) {
        [fh closeFile];
        if (message) *message = @"ZIP: центральный каталог не найден.";
        return NO;
    }

    uint16_t count = GXRead16(b + eocd + 10);
    uint32_t cdSize = GXRead32(b + eocd + 12);
    uint32_t cdOffset = GXRead32(b + eocd + 16);
    if (count == 0 || (unsigned long long)cdOffset + cdSize > size) {
        [fh closeFile];
        if (message) *message = @"ZIP: неподдерживаемый или повреждённый архив.";
        return NO;
    }

    // Canonical root is Documents itself. The Files app exposes Documents as the\n    // user's "Generals ZH" game folder. Never create Documents/Generals ZH.\n    NSString *root = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;\n    NSFileManager *fm = [NSFileManager defaultManager];\n    NSError *mkdirError = nil;\n    if (![fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&mkdirError]) {\n        [fh closeFile];\n        if (message) *message = mkdirError.localizedDescription ?: @"Не удалось открыть папку игры.";\n        return NO;\n    }\n\n    // Extract directly into the canonical Documents root. This avoids keeping a\n    // second full copy of the game in NSTemporaryDirectory and avoids the large\n    // disk I/O spike that previously made iPhone/iPad lag during installation.\n    // We remember files written by this pass so a failed/cancelled extraction can\n    // clean only its own partial files without touching launcher settings.\n    NSMutableArray<NSString *> *writtenPaths = [NSMutableArray array];\n\n    [fh seekToFileOffset:cdOffset];\n    NSData *cd = [fh readDataOfLength:(NSUInteger)cdSize];\n    const uint8_t *p = (const uint8_t *)cd.bytes;\n    NSUInteger pos = 0;\n    BOOL ok = YES;\n\n    for (uint16_t index = 0; index < count && ok; ++index) {\n        @autoreleasepool {\n            if (self.cancelRequested) {\n                ok = NO;\n                if (message) *message = @"Загрузка файла игры отменена.";\n                break;\n            }\n\n            if (pos + 46 > cd.length || GXRead32(p + pos) != 0x02014b50) {\n                ok = NO;\n                if (message) *message = @"ZIP: ошибка записи каталога.";\n                break;\n            }\n\n            uint16_t method = GXRead16(p + pos + 10);\n            uint32_t compressed = GXRead32(p + pos + 20);\n            uint32_t uncompressed = GXRead32(p + pos + 24);\n            uint16_t nameLen = GXRead16(p + pos + 28);\n            uint16_t extraLen = GXRead16(p + pos + 30);\n            uint16_t commentLen = GXRead16(p + pos + 32);\n            uint32_t localOffset = GXRead32(p + pos + 42);\n\n            if (pos + 46 + nameLen + extraLen + commentLen > cd.length) {\n                ok = NO;\n                if (message) *message = @"ZIP: повреждённое имя файла.";\n                break;\n            }\n\n            NSData *nameData = [NSData dataWithBytes:p + pos + 46 length:nameLen];\n            NSString *name = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];\n            if (!name)\n                name = [[NSString alloc] initWithData:nameData encoding:NSISOLatin1StringEncoding];\n            if (!name) {\n                ok = NO;\n                if (message) *message = @"ZIP: неизвестное имя файла.";\n                break;\n            }\n\n            name = [name stringByReplacingOccurrencesOfString:@"\\\\" withString:@"/"];\n            while ([name hasPrefix:@"/"]) name = [name substringFromIndex:1];\n            while ([name hasPrefix:@"./"]) name = [name substringFromIndex:2];\n\n            // Strip every outer Generals ZH/ wrapper. Examples:\n            // Generals ZH/INIZH.big -> INIZH.big\n            // Generals ZH/Generals ZH/ZH_Generals/x -> ZH_Generals/x\n            NSString *wrapper = @"Generals ZH/";\n            while (name.length >= wrapper.length &&\n                   [name rangeOfString:wrapper options:NSCaseInsensitiveSearch\n                                   range:NSMakeRange(0, wrapper.length)].location == 0) {\n                name = [name substringFromIndex:wrapper.length];\n            }\n\n            NSString *safe = [name stringByStandardizingPath];\n            if (safe.length == 0) {\n                pos += 46 + nameLen + extraLen + commentLen;\n                continue;\n            }\n            if ([safe hasPrefix:@"../"] || [safe isEqualToString:@".."] || [safe containsString:@"/../"]) {\n                ok = NO;\n                if (message) *message = @"ZIP содержит небезопасный путь.";\n                break;\n            }\n\n            pos += 46 + nameLen + extraLen + commentLen;\n\n            // Directory entries are created implicitly by their files. All regular\n            // files are extracted; ZH_Generals is never filtered out.\n            if ([name hasSuffix:@"/"])\n                continue;\n            if (method != 0 && method != 8) {\n                ok = NO;\n                if (message) *message = [NSString stringWithFormat:@"ZIP: неподдерживаемый метод для %@.", name];\n                break;\n            }\n\n            [fh seekToFileOffset:localOffset];\n            NSData *lh = [fh readDataOfLength:30];\n            if (lh.length != 30 || GXRead32((const uint8_t *)lh.bytes) != 0x04034b50) {\n                ok = NO;\n                if (message) *message = @"ZIP: неверная локальная запись.";\n                break;\n            }\n\n            const uint8_t *lhBytes = (const uint8_t *)lh.bytes;\n            uint16_t localNameLen = GXRead16(lhBytes + 26);\n            uint16_t localExtraLen = GXRead16(lhBytes + 28);\n            unsigned long long dataOffset =\n                (unsigned long long)localOffset + 30ULL + localNameLen + localExtraLen;\n            if (dataOffset + compressed > size) {\n                ok = NO;\n                if (message) *message = [NSString stringWithFormat:@"ZIP: файл обрезан: %@.", name];\n                break;\n            }\n\n            NSString *destination = [root stringByAppendingPathComponent:safe];\n            NSString *parent = [destination stringByDeletingLastPathComponent];\n            NSError *dirError = nil;\n            if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:&dirError]) {\n                ok = NO;\n                if (message) *message = dirError.localizedDescription ?: @"Не удалось создать папку файла игры.";\n                break;\n            }\n\n            // The two INI files belong to the native launcher. If the archive ever\n            // contains them, do not overwrite the user's current launcher settings.\n            NSString *lower = safe.lowercaseString;\n            BOOL protectedSettings =\n                [lower isEqualToString:@"iosipadoverrides.ini"] ||\n                [lower isEqualToString:@"zerohoursettings.ini"];\n            if (protectedSettings && [fm fileExistsAtPath:destination])\n                continue;\n\n            [fm removeItemAtPath:destination error:nil];\n\n            NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:destination];\n            if (!out) {\n                if (![fm createFileAtPath:destination contents:nil attributes:nil]) {\n                    ok = NO;\n                    if (message) *message = [NSString stringWithFormat:@"Не удалось создать %@.", name];\n                    break;\n                }\n                out = [NSFileHandle fileHandleForWritingAtPath:destination];\n            }\n            if (!out) {\n                ok = NO;\n                if (message) *message = [NSString stringWithFormat:@"Не удалось открыть %@ для записи.", name];\n                break;\n            }\n\n            [writtenPaths addObject:destination];\n            [fh seekToFileOffset:dataOffset];\n            const NSUInteger chunkSize = 64 * 1024;\n            unsigned long long remainingCompressed = compressed;\n\n            if (method == 0) {\n                while (remainingCompressed > 0 && ok) {\n                    if (self.cancelRequested) {\n                        ok = NO;\n                        if (message) *message = @"Загрузка файла игры отменена.";\n                        break;\n                    }\n                    NSUInteger want = (NSUInteger)MIN((unsigned long long)chunkSize, remainingCompressed);\n                    NSData *chunk = [fh readDataOfLength:want];\n                    if (chunk.length != want) {\n                        ok = NO;\n                        if (message) *message = [NSString stringWithFormat:@"ZIP: файл обрезан: %@.", name];\n                        break;\n                    }\n                    [out writeData:chunk];\n                    remainingCompressed -= want;\n                }\n            } else {\n                z_stream zs;\n                memset(&zs, 0, sizeof(zs));\n                int zret = inflateInit2(&zs, -MAX_WBITS);\n                if (zret != Z_OK) {\n                    ok = NO;\n                    if (message) *message = [NSString stringWithFormat:@"Ошибка распаковки: %@.", name];\n                } else {\n                    uint8_t *outBuffer = (uint8_t *)malloc(chunkSize);\n                    if (!outBuffer) {\n                        inflateEnd(&zs);\n                        ok = NO;\n                        if (message) *message = @"Недостаточно памяти для распаковки.";\n                    } else {\n                        unsigned long long bytesWritten = 0;\n                        while (remainingCompressed > 0 && ok) {\n                            if (self.cancelRequested) {\n                                ok = NO;\n                                if (message) *message = @"Загрузка файла игры отменена.";\n                                break;\n                            }\n                            NSUInteger want = (NSUInteger)MIN((unsigned long long)chunkSize, remainingCompressed);\n                            NSData *chunk = [fh readDataOfLength:want];\n                            if (chunk.length != want) {\n                                ok = NO;\n                                if (message) *message = [NSString stringWithFormat:@"ZIP: файл обрезан: %@.", name];\n                                break;\n                            }\n                            zs.next_in = (Bytef *)chunk.bytes;\n                            zs.avail_in = (uInt)chunk.length;\n                            remainingCompressed -= chunk.length;\n\n                            while (zs.avail_in > 0 && ok) {\n                                zs.next_out = outBuffer;\n                                zs.avail_out = (uInt)chunkSize;\n                                int inflateRet = inflate(&zs, Z_NO_FLUSH);\n                                if (inflateRet != Z_OK && inflateRet != Z_STREAM_END) {\n                                    ok = NO;\n                                    if (message) *message = [NSString stringWithFormat:@"Ошибка распаковки: %@.", name];\n                                    break;\n                                }\n                                NSUInteger produced = chunkSize - zs.avail_out;\n                                if (produced > 0) {\n                                    [out writeData:[NSData dataWithBytes:outBuffer length:produced]];\n                                    bytesWritten += produced;\n                                }\n                                if (inflateRet == Z_STREAM_END) {\n                                    remainingCompressed = 0;\n                                    break;\n                                }\n                                if (zs.avail_in == 0) break;\n                            }\n                        }\n                        if (ok && bytesWritten != uncompressed) {\n                            ok = NO;\n                            if (message) *message = [NSString stringWithFormat:@"ZIP: размер после распаковки не совпал для %@.", name];\n                        }\n                        free(outBuffer);\n                        inflateEnd(&zs);\n                    }\n                }\n            }\n\n            [out closeFile];\n            if (!ok)\n                break;\n        }\n    }\n\n    [fh closeFile];\n    if (!ok) {\n        // Roll back only files written by this installation pass. Never delete\n        // iOSIPadOverrides.ini or ZeroHourSettings.ini.\n        for (NSString *path in writtenPaths)\n            [fm removeItemAtPath:path error:nil];\n        if (message && !*message) *message = @"Распаковка файла игры отменена.";\n        return NO;\n    }\n\n    if (message)\n        *message = @"Файл игры распакован в Documents: INIZH.big, ZH_Generals и остальные файлы рядом с iOSIPadOverrides.ini и ZeroHourSettings.ini.";\n    return YES;\n}\n\n
        [fm removeItemAtPath:staging error:nil];
        return NO;
    }

    // Canonical destination: Documents (Generals ZH root). It is the ONLY game root.
    // Merge every extracted file directly into it; never copy the archive's
    // outer "Generals ZH" directory itself. It is stripped into the canonical root.
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *root = documents;

    NSError *rootError = nil;
    if (![fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&rootError]) {
        [fm removeItemAtPath:staging error:nil];
        if (message) *message = rootError.localizedDescription ?: @"Не удалось создать папку игры.";
        return NO;
    }

    // Never create or delete a Generals ZH wrapper. Documents (Generals ZH root) is the canonical root.

    NSArray<NSString *> *stagedFiles = [fm subpathsAtPath:staging];
    for (NSString *relative in stagedFiles) {
        @autoreleasepool {
            if (self.cancelRequested) {
                [fm removeItemAtPath:staging error:nil];
                if (message) *message = @"Загрузка файла игры отменена.";
                return NO;
            }

            NSString *source = [staging stringByAppendingPathComponent:relative];
            BOOL isDirectory = NO;
            if (![fm fileExistsAtPath:source isDirectory:&isDirectory] || isDirectory)
                continue;

            NSString *destination = [root stringByAppendingPathComponent:relative];

            // Preserve launcher-owned settings on reinstallation.
            NSString *lower = relative.lowercaseString;
            BOOL protectedSettings =
                [lower isEqualToString:@"iosipadOverrides.ini".lowercaseString] ||
                [lower isEqualToString:@"zerohoursettings.ini".lowercaseString];

            if (protectedSettings && [fm fileExistsAtPath:destination])
                continue;

            NSString *parent = [destination stringByDeletingLastPathComponent];
            [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
            [fm removeItemAtPath:destination error:nil];

            NSError *moveError = nil;
            if (![fm moveItemAtPath:source toPath:destination error:&moveError]) {
                [fm removeItemAtPath:staging error:nil];
                if (message) *message = moveError.localizedDescription ?: [NSString stringWithFormat:@"Не удалось установить %@.", relative];
                return NO;
            }
        }
    }

    [fm removeItemAtPath:staging error:nil];

    // Launcher-owned INI files stay beside the installed game files:
    //   Documents/iOSIPadOverrides.ini
    //   Documents/ZeroHourSettings.ini
    // They are created by the native launcher on first launch/settings save.
    // The ZIP installer must never create another Generals ZH wrapper.

    if (message)
        *message = @"Файл игры распакован в Documents (Generals ZH root) рядом с iOSIPadOverrides.ini и ZeroHourSettings.ini.";
    return YES;
}

- (BOOL)validateInstalledGameFile:(NSString **)message {
    // Единая проверка файла игры: после установки, в статусе и в Диагностике.
    // Canonical root is Documents (Generals ZH root): INIZH.big, ZH_Generals/ and all
    // game files are siblings of the two launcher-owned INI files.
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *root = documents;
    NSFileManager *fm = [NSFileManager defaultManager];

    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) {
        if (message) *message = @"Файл игры: НЕ УСТАНОВЛЕН — Documents недоступен.";
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
            NSString *lowerName = relative.lowercaseString;
            BOOL launcherINI =
                [lowerName isEqualToString:@"iosipadOverrides.ini".lowercaseString] ||
                [lowerName isEqualToString:@"zerohoursettings.ini".lowercaseString];
            if (launcherINI)
                continue;
            if (size == 0)
                emptyFiles++;
            files++;
        }
    }

    if (files != 44) {
        if (message) *message = [NSString stringWithFormat:
            @"Файл игры: НЕ ГОТОВ — объектов %lu/44, пустых: %lu.",
            (unsigned long)files, (unsigned long)emptyFiles];
        return NO;
    }

    if (emptyFiles != 0) {
        if (message) *message = [NSString stringWithFormat:
            @"Файл игры: НЕ ГОТОВ — объектов 44/44, пустых: %lu.",
            (unsigned long)emptyFiles];
        return NO;
    }

    // Launcher-owned INI files are verified at their real canonical-root paths.
    NSString *documentsIOSOverrides = [root stringByAppendingPathComponent:@"iOSIPadOverrides.ini"];
    NSString *documentsZeroHourSettings = [root stringByAppendingPathComponent:@"ZeroHourSettings.ini"];
    BOOL iosOverridesExists = [fm fileExistsAtPath:documentsIOSOverrides];
    BOOL zeroHourSettingsExists = [fm fileExistsAtPath:documentsZeroHourSettings];

    if (!iosOverridesExists || !zeroHourSettingsExists) {
        if (message) *message = [NSString stringWithFormat:
            @"Файл игры: НЕ ГОТОВ — 44/44 объектов, пустых: 0; Documents/iOSIPadOverrides.ini: %@; Documents/ZeroHourSettings.ini: %@.",
            iosOverridesExists ? @"есть" : @"нет",
            zeroHourSettingsExists ? @"есть" : @"нет"];
        return NO;
    }

    if (message) *message = @"Файл игры: ГОТОВ — 44/44 объектов, пустых: 0; оба INI проверены в Generals ZH.";
    return YES;
}

- (BOOL)verifyGameFiles:(NSString **)message {
    return [self validateInstalledGameFile:message];
}

@end
