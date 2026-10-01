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

        dispatch_async(dispatch_get_main_queue(), ^{
            [self finish:ok message:message ?: (ok ? @"Файл игры готов." : @"Файл игры не установлен.")];
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

    // Extract into temporary staging first. This keeps the real game directory
    // usable if extraction is interrupted or the app is killed by iOS.
    NSString *staging = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"GeneralsZH-Extract-%@", NSUUID.UUID.UUIDString]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:staging error:nil];

    NSError *mkdirError = nil;
    if (![fm createDirectoryAtPath:staging
        withIntermediateDirectories:YES
        attributes:nil
        error:&mkdirError]) {
        [fh closeFile];
        if (message) *message = mkdirError.localizedDescription ?: @"Не удалось создать временную папку распаковки.";
        return NO;
    }

    [fh seekToFileOffset:cdOffset];
    NSData *cd = [fh readDataOfLength:(NSUInteger)cdSize];
    const uint8_t *p = (const uint8_t *)cd.bytes;
    NSUInteger pos = 0;
    BOOL ok = YES;

    for (uint16_t index = 0; index < count && ok; ++index) {
        @autoreleasepool {
            if (self.cancelRequested) {
                ok = NO;
                if (message) *message = @"Загрузка файла игры отменена.";
                break;
            }

            if (pos + 46 > cd.length || GXRead32(p + pos) != 0x02014b50) {
                ok = NO;
                if (message) *message = @"ZIP: ошибка записи каталога.";
                break;
            }

            uint16_t method = GXRead16(p + pos + 10);
            uint32_t compressed = GXRead32(p + pos + 20);
            uint32_t uncompressed = GXRead32(p + pos + 24);
            uint16_t nameLen = GXRead16(p + pos + 28);
            uint16_t extraLen = GXRead16(p + pos + 30);
            uint16_t commentLen = GXRead16(p + pos + 32);
            uint32_t localOffset = GXRead32(p + pos + 42);

            if (pos + 46 + nameLen + extraLen + commentLen > cd.length) {
                ok = NO;
                if (message) *message = @"ZIP: повреждённое имя файла.";
                break;
            }

            NSData *nameData = [NSData dataWithBytes:p + pos + 46 length:nameLen];
            NSString *name = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
            if (!name)
                name = [[NSString alloc] initWithData:nameData encoding:NSISOLatin1StringEncoding];

            name = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            while ([name hasPrefix:@"/"])
                name = [name substringFromIndex:1];
            while ([name hasPrefix:@"./"])
                name = [name substringFromIndex:2];

            // Strip every outer "Generals ZH/" wrapper. The canonical root is
            // already Documents/Generals ZH, so this MUST never create a second
            // Documents/Generals ZH/Generals ZH directory.
            NSString *wrapper = @"Generals ZH/";
            while (name.length >= wrapper.length &&
                   [name rangeOfString:wrapper
                               options:NSCaseInsensitiveSearch
                                 range:NSMakeRange(0, wrapper.length)].location == 0) {
                name = [name substringFromIndex:wrapper.length];
            }

            NSString *safe = [name stringByStandardizingPath];
            if (safe.length == 0) {
                pos += 46 + nameLen + extraLen + commentLen;
                continue;
            }
            if ([safe hasPrefix:@"../"] || [safe isEqualToString:@".."] || [safe containsString:@"/../"]) {
                ok = NO;
                if (message) *message = @"ZIP содержит небезопасный путь.";
                break;
            }

            pos += 46 + nameLen + extraLen + commentLen;

            if ([name hasSuffix:@"/"])
                continue;
            if (method != 0 && method != 8) {
                ok = NO;
                if (message) *message = [NSString stringWithFormat:@"ZIP: неподдерживаемый метод для %@.", name];
                break;
            }

            [fh seekToFileOffset:localOffset];
            NSData *lh = [fh readDataOfLength:30];
            if (lh.length != 30 || GXRead32((const uint8_t *)lh.bytes) != 0x04034b50) {
                ok = NO;
                if (message) *message = @"ZIP: неверная локальная запись.";
                break;
            }

            const uint8_t *lhBytes = (const uint8_t *)lh.bytes;
            uint16_t localNameLen = GXRead16(lhBytes + 26);
            uint16_t localExtraLen = GXRead16(lhBytes + 28);
            unsigned long long dataOffset =
                (unsigned long long)localOffset + 30ULL + localNameLen + localExtraLen;
            if (dataOffset + compressed > size) {
                ok = NO;
                if (message) *message = [NSString stringWithFormat:@"ZIP: файл обрезан: %@.", name];
                break;
            }

            NSString *destination = [staging stringByAppendingPathComponent:safe];
            NSString *parent = [destination stringByDeletingLastPathComponent];
            NSError *dirError = nil;
            if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:&dirError]) {
                ok = NO;
                if (message) *message = dirError.localizedDescription ?: @"Не удалось создать папку файла игры.";
                break;
            }

            // Never keep a whole large ZIP entry in memory. Stream stored and
            // deflated entries through 256 KiB buffers.
            NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:destination];
            if (!out) {
                if (![fm createFileAtPath:destination contents:nil attributes:nil]) {
                    ok = NO;
                    if (message) *message = [NSString stringWithFormat:@"Не удалось создать %@.", name];
                    break;
                }
                out = [NSFileHandle fileHandleForWritingAtPath:destination];
            }

            [fh seekToFileOffset:dataOffset];
            const NSUInteger chunkSize = 256 * 1024;
            unsigned long long remainingCompressed = compressed;

            if (method == 0) {
                while (remainingCompressed > 0 && ok) {
                    if (self.cancelRequested) {
                        ok = NO;
                        if (message) *message = @"Загрузка файла игры отменена.";
                        break;
                    }

                    NSUInteger want = (NSUInteger)MIN((unsigned long long)chunkSize, remainingCompressed);
                    NSData *chunk = [fh readDataOfLength:want];
                    if (chunk.length != want) {
                        ok = NO;
                        if (message) *message = [NSString stringWithFormat:@"ZIP: файл обрезан: %@.", name];
                        break;
                    }
                    [out writeData:chunk];
                    remainingCompressed -= want;
                }
            } else {
                z_stream zs;
                memset(&zs, 0, sizeof(zs));
                int zret = inflateInit2(&zs, -MAX_WBITS);
                if (zret != Z_OK) {
                    ok = NO;
                    if (message) *message = [NSString stringWithFormat:@"Ошибка распаковки: %@.", name];
                } else {
                    uint8_t *outBuffer = (uint8_t *)malloc(chunkSize);
                    if (!outBuffer) {
                        free(outBuffer);
                        inflateEnd(&zs);
                        ok = NO;
                        if (message) *message = @"Недостаточно памяти для распаковки.";
                    } else {
                        unsigned long long bytesWritten = 0;
                        while (remainingCompressed > 0 && ok) {
                            if (self.cancelRequested) {
                                ok = NO;
                                if (message) *message = @"Загрузка файла игры отменена.";
                                break;
                            }

                            NSUInteger want = (NSUInteger)MIN((unsigned long long)chunkSize, remainingCompressed);
                            NSData *chunk = [fh readDataOfLength:want];
                            if (chunk.length != want) {
                                ok = NO;
                                if (message) *message = [NSString stringWithFormat:@"ZIP: файл обрезан: %@.", name];
                                break;
                            }

                            zs.next_in = (Bytef *)chunk.bytes;
                            zs.avail_in = (uInt)chunk.length;
                            remainingCompressed -= chunk.length;

                            while (zs.avail_in > 0 && ok) {
                                zs.next_out = outBuffer;
                                zs.avail_out = (uInt)chunkSize;
                                int inflateRet = inflate(&zs, Z_NO_FLUSH);

                                if (inflateRet != Z_OK && inflateRet != Z_STREAM_END) {
                                    ok = NO;
                                    if (message) *message = [NSString stringWithFormat:@"Ошибка распаковки: %@.", name];
                                    break;
                                }

                                NSUInteger produced = chunkSize - zs.avail_out;
                                if (produced > 0) {
                                    [out writeData:[NSData dataWithBytes:outBuffer length:produced]];
                                    bytesWritten += produced;
                                }

                                if (inflateRet == Z_STREAM_END) {
                                    remainingCompressed = 0;
                                    break;
                                }

                                if (zs.avail_in == 0)
                                    break;
                            }
                        }

                        if (ok && bytesWritten != uncompressed) {
                            ok = NO;
                            if (message) *message = [NSString stringWithFormat:
                                @"ZIP: размер после распаковки не совпал для %@.", name];
                        }

                        free(outBuffer);
                        inflateEnd(&zs);
                    }
                }
            }

            [out closeFile];

            if (!ok) {
                [fm removeItemAtPath:destination error:nil];
                break;
            }

            // Settings are created/updated by the native launcher. Do not let
            // a later game-file update overwrite the user's saved settings.
        }
    }

    [fh closeFile];
    if (!ok) {
        [fm removeItemAtPath:staging error:nil];
        return NO;
    }

    // Canonical destination: Documents/Generals ZH. It is the ONLY game root.
    // Merge every extracted file directly into it; never copy the archive's
    // outer "Generals ZH" directory itself.
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *root = [documents stringByAppendingPathComponent:@"Generals ZH"];

    NSError *rootError = nil;
    if (![fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&rootError]) {
        [fm removeItemAtPath:staging error:nil];
        if (message) *message = rootError.localizedDescription ?: @"Не удалось создать папку игры.";
        return NO;
    }

    // Remove only the legacy nested wrapper from older builds.
    // This code never creates Documents/Generals ZH/Generals ZH.
    NSString *legacyNestedRoot = [root stringByAppendingPathComponent:@"Generals ZH"];
    while ([fm fileExistsAtPath:legacyNestedRoot]) {
        [fm removeItemAtPath:legacyNestedRoot error:nil];
        NSString *next = [legacyNestedRoot stringByAppendingPathComponent:@"Generals ZH"];
        if ([next isEqualToString:legacyNestedRoot])
            break;
        legacyNestedRoot = next;
    }

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

    // Launcher-owned INI files intentionally stay at Documents level:
    //   Documents/iOSIPadOverrides.ini
    //   Documents/ZeroHourSettings.ini
    // They are created by the native launcher on first launch/settings save.
    // The ZIP installer must never move or recreate them inside Generals ZH.

    if (message)
        *message = @"Файл игры распакован в Documents/Generals ZH. iOSIPadOverrides.ini и ZeroHourSettings.ini находятся рядом с папкой игры в Documents.";
    return YES;
}

- (BOOL)validateInstalledGameFile:(NSString **)message {
    // Единая проверка файла игры: используется после установки, в статусе лаунчера
    // и в разделе Диагностика. В корне игры также находятся два launcher-owned INI,
    // поэтому они не входят в число 44 файлов игрового архива.
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *root = [documents stringByAppendingPathComponent:@"Generals ZH"];
    NSFileManager *fm = [NSFileManager defaultManager];

    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) {
        if (message) *message = @"Файл игры: НЕ УСТАНОВЛЕН — папка Generals ZH отсутствует.";
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

    // Launcher-owned INI files are deliberately outside the game root.
    // Verify them at their real Documents-level paths; never look inside
    // Documents/Generals ZH for another copy.
    NSString *documentsIOSOverrides = [documents stringByAppendingPathComponent:@"iOSIPadOverrides.ini"];
    NSString *documentsZeroHourSettings = [documents stringByAppendingPathComponent:@"ZeroHourSettings.ini"];
    BOOL iosOverridesExists = [fm fileExistsAtPath:documentsIOSOverrides];
    BOOL zeroHourSettingsExists = [fm fileExistsAtPath:documentsZeroHourSettings];

    if (!iosOverridesExists || !zeroHourSettingsExists) {
        if (message) *message = [NSString stringWithFormat:
            @"Файл игры: НЕ ГОТОВ — 44/44 объектов, пустых: 0; Documents/iOSIPadOverrides.ini: %@; Documents/ZeroHourSettings.ini: %@.",
            iosOverridesExists ? @"есть" : @"нет",
            zeroHourSettingsExists ? @"есть" : @"нет"];
        return NO;
    }

    if (message) *message = @"Файл игры: ГОТОВ — 44/44 объектов, пустых: 0; оба INI проверены в Documents.";
    return YES;
}

- (BOOL)verifyGameFiles:(NSString **)message {
    return [self validateInstalledGameFile:message];
}

@end
