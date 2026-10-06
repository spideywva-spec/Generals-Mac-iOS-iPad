#include "IOSModManager.h"

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

#import <CommonCrypto/CommonDigest.h>
#import <dispatch/dispatch.h>

#ifndef GX_PROJECT_VERSION
#define GX_PROJECT_VERSION "0.0.0"
#endif

#include <array>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace
{
NSString * const GXHubErrorDomain = @"GeneralsXHub";

NSString * const GXHubChannelDefaultsKey = @"GXHubUpdateChannel";
NSString * const GXHubRemoteCatalogName = @"HubCatalog.remote.json";
NSString * const GXHubCatalogOverrideName = @"HubCatalog.json";
NSString * const GXHubCatalogURLOverrideName = @"HubCatalogURL.txt";

NSString *GXHubDocumentsPath(NSString *name)
{
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:name];
}

NSDictionary<NSString *, id> *GXHubReadJSONDictionary(NSString *path)
{
    if (path.length == 0)
        return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil)
        return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? (NSDictionary *)json : nil;
}

BOOL GXHubCatalogIsValid(NSDictionary<NSString *, id> *document)
{
    if (document == nil)
        return NO;
    NSNumber *schema = document[@"schemaVersion"];
    NSArray *mods = document[@"mods"];
    return schema.integerValue >= 1 && [mods isKindOfClass:[NSArray class]];
}

NSDictionary<NSString *, id> *GXHubBundledCatalogDocument(void)
{
    NSString *path = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"HubCatalog.json"];
    NSDictionary *document = GXHubReadJSONDictionary(path);
    return GXHubCatalogIsValid(document) ? document : @{};
}

NSDictionary<NSString *, id> *GXHubPreferredCatalogDocumentInternal(void)
{
    for (NSString *path in @[
        GXHubDocumentsPath(GXHubCatalogOverrideName),
        GXHubDocumentsPath(GXHubRemoteCatalogName)
    ])
    {
        NSDictionary *document = GXHubReadJSONDictionary(path);
        if (GXHubCatalogIsValid(document))
            return document;
    }
    return GXHubBundledCatalogDocument();
}

NSDictionary<NSString *, id> *GXHubFlattenRelease(
    NSDictionary<NSString *, id> *entry,
    NSString *channel)
{
    if (![entry isKindOfClass:[NSDictionary class]])
        return nil;

    NSDictionary *channels = entry[@"channels"];
    if (![channels isKindOfClass:[NSDictionary class]])
    {
        NSMutableDictionary *legacy = [entry mutableCopy];
        if (legacy[@"channel"] == nil)
            legacy[@"channel"] = @"stable";
        return legacy;
    }

    NSDictionary *release = channels[channel];
    NSString *effectiveChannel = channel;
    NSString *fallbackChannel = nil;
    NSDictionary *stableRelease = [channels[@"stable"] isKindOfClass:[NSDictionary class]] ? channels[@"stable"] : nil;
    if (![release isKindOfClass:[NSDictionary class]] && ![channel isEqualToString:@"stable"])
    {
        release = stableRelease;
        effectiveChannel = @"stable";
        fallbackChannel = @"stable";
    }
    if (![release isKindOfClass:[NSDictionary class]])
        return nil;

    NSString *packageURL = [release[@"packageURL"] isKindOfClass:[NSString class]] ? release[@"packageURL"] : @"";
    NSURL *parsedPackageURL = packageURL.length > 0 ? [NSURL URLWithString:packageURL] : nil;
    BOOL validHTTPSPackage = [[parsedPackageURL.scheme lowercaseString] isEqualToString:@"https"] && parsedPackageURL.host.length > 0;
    if (!validHTTPSPackage && ![channel isEqualToString:@"stable"] && stableRelease != nil)
    {
        NSString *stableURLText = [stableRelease[@"packageURL"] isKindOfClass:[NSString class]] ? stableRelease[@"packageURL"] : @"";
        NSURL *stableURL = stableURLText.length > 0 ? [NSURL URLWithString:stableURLText] : nil;
        if ([[stableURL.scheme lowercaseString] isEqualToString:@"https"] && stableURL.host.length > 0)
        {
            release = stableRelease;
            effectiveChannel = @"stable";
            fallbackChannel = @"stable";
            fprintf(stderr,
                    "[HUB-CATALOG] package fallback profile='%s' requested='%s' effective='stable'\n",
                    [entry[@"profileId"] UTF8String] ?: "unknown",
                    channel.UTF8String ?: "unknown");
        }
    }

    NSMutableDictionary *flattened = [NSMutableDictionary dictionary];
    for (NSString *key in entry)
    {
        if (![key isEqualToString:@"channels"])
            flattened[key] = entry[key];
    }
    [flattened addEntriesFromDictionary:release];
    flattened[@"channel"] = effectiveChannel;
    flattened[@"requestedChannel"] = channel;
    if (fallbackChannel.length > 0)
        flattened[@"fallbackChannel"] = fallbackChannel;
    return flattened;
}

NSString *GXHubTrimmedString(NSString *value)
{
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

BOOL GXHubVersionSatisfies(NSString *current, NSString *minimum)
{
    if (minimum.length == 0)
        return YES;
    if (current.length == 0)
        return NO;
    return [current compare:minimum options:NSNumericSearch] != NSOrderedAscending;
}

NSString *GXHubProjectVersion(void)
{
    id bundleValue = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if ([bundleValue isKindOfClass:[NSString class]])
    {
        NSString *bundleVersion = GXHubTrimmedString((NSString *)bundleValue);
        if (bundleVersion.length > 0)
            return bundleVersion;
    }

    return [NSString stringWithUTF8String:GX_PROJECT_VERSION] ?: @"0.0.0";
}

NSString *GXHubCatalogBootstrapURL(void)
{
    NSString *overridePath = GXHubDocumentsPath(GXHubCatalogURLOverrideName);
    NSString *override = [NSString stringWithContentsOfFile:overridePath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    override = GXHubTrimmedString(override ?: @"");
    if ([override hasPrefix:@"https://"])
        return override;

    NSDictionary *preferred = GXHubPreferredCatalogDocumentInternal();
    NSString *url = GXHubTrimmedString(preferred[@"remoteCatalogURL"] ?: @"");
    if ([url hasPrefix:@"https://"])
        return url;

    NSDictionary *bundled = GXHubBundledCatalogDocument();
    url = GXHubTrimmedString(bundled[@"remoteCatalogURL"] ?: @"");
    return [url hasPrefix:@"https://"] ? url : nil;
}

NSError *GXHubError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:GXHubErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown Generals Hub error"}];
}

BOOL GXHubSafeId(NSString *value)
{
    if (value.length == 0 || value.length > 63)
        return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    return [value rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound;
}

BOOL GXHubSafeRelativePath(NSString *relative)
{
    if (relative.length == 0 || [relative hasPrefix:@"/"] || [relative hasPrefix:@"\\"])
        return NO;
    NSArray<NSString *> *parts = [relative pathComponents];
    for (NSString *part in parts)
    {
        if ([part isEqualToString:@".."] || [part isEqualToString:@"."])
            return NO;
    }
    return YES;
}

NSData *GXHubReadExact(NSFileHandle *handle, NSUInteger count, NSError **error)
{
    NSMutableData *data = [NSMutableData dataWithCapacity:count];
    while (data.length < count)
    {
        @try
        {
            NSData *chunk = [handle readDataOfLength:count - data.length];
            if (chunk.length == 0)
                break;
            [data appendData:chunk];
        }
        @catch (NSException *exception)
        {
            if (error != nullptr)
                *error = GXHubError(20, [NSString stringWithFormat:@"Package read failed: %@", exception.reason]);
            return nil;
        }
    }
    if (data.length != count)
    {
        if (error != nullptr)
            *error = GXHubError(21, @"Unexpected end of .gxmod package.");
        return nil;
    }
    return data;
}

unsigned long long GXHubParseOctal(const unsigned char *bytes, size_t length)
{
    char buffer[32] = {};
    size_t out = 0;
    for (size_t i = 0; i < length && out + 1 < sizeof(buffer); ++i)
    {
        unsigned char c = bytes[i];
        if (c == '\0' || c == ' ')
        {
            if (out == 0)
                continue;
            break;
        }
        if (c < '0' || c > '7')
            break;
        buffer[out++] = (char)c;
    }
    return out == 0 ? 0 : strtoull(buffer, nullptr, 8);
}

NSString *GXHubTarString(const unsigned char *bytes, size_t length)
{
    size_t actual = 0;
    while (actual < length && bytes[actual] != '\0')
        ++actual;
    if (actual == 0)
        return @"";
    return [[NSString alloc] initWithBytes:bytes length:actual encoding:NSUTF8StringEncoding] ?: @"";
}

BOOL GXHubHeaderIsZero(const unsigned char *bytes)
{
    for (size_t i = 0; i < 512; ++i)
    {
        if (bytes[i] != 0)
            return NO;
    }
    return YES;
}

NSString *GXHubSHA256ForFile(NSURL *url, NSError **error)
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:error];
    if (handle == nil)
        return nil;

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    @try
    {
        while (true)
        {
            @autoreleasepool
            {
                NSData *data = [handle readDataOfLength:1024 * 1024];
                if (data.length == 0)
                    break;
                CC_SHA256_Update(&ctx, data.bytes, (CC_LONG)data.length);
            }
        }
    }
    @catch (NSException *exception)
    {
        [handle closeFile];
        if (error != nullptr)
            *error = GXHubError(22, [NSString stringWithFormat:@"SHA-256 read failed: %@", exception.reason]);
        return nil;
    }
    [handle closeFile];

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i)
        [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

NSDictionary<NSString *, id> *GXHubParseManifest(NSData *data, NSError **error)
{
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![json isKindOfClass:[NSDictionary class]])
    {
        if (error != nullptr && *error == nil)
            *error = GXHubError(30, @"manifest.json is not an object.");
        return nil;
    }

    NSDictionary *manifest = (NSDictionary *)json;
    NSNumber *schema = manifest[@"schemaVersion"];
    NSString *profileId = manifest[@"profileId"];
    NSString *name = manifest[@"name"];
    NSString *version = manifest[@"version"];
    if (schema.integerValue != 1 || !GXHubSafeId(profileId) || name.length == 0 || version.length == 0)
    {
        if (error != nullptr)
            *error = GXHubError(31, @"Invalid .gxmod manifest (schemaVersion/profileId/name/version).");
        return nil;
    }
    return manifest;
}

BOOL GXHubCopyTarFile(
    NSFileHandle *input,
    unsigned long long size,
    NSString *destination,
    NSError **error)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *parent = [destination stringByDeletingLastPathComponent];
    if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:error])
        return NO;
    if (![fm createFileAtPath:destination contents:nil attributes:nil])
    {
        if (error != nullptr)
            *error = GXHubError(40, [NSString stringWithFormat:@"Cannot create %@", destination.lastPathComponent]);
        return NO;
    }

    NSFileHandle *output = [NSFileHandle fileHandleForWritingAtPath:destination];
    if (output == nil)
    {
        if (error != nullptr)
            *error = GXHubError(41, @"Cannot open extracted file for writing.");
        return NO;
    }

    unsigned long long remaining = size;
    @try
    {
        while (remaining > 0)
        {
            @autoreleasepool
            {
                NSUInteger request = (NSUInteger)MIN(remaining, (unsigned long long)(1024 * 1024));
                NSData *chunk = [input readDataOfLength:request];
                if (chunk.length != request)
                {
                    [output closeFile];
                    if (error != nullptr)
                        *error = GXHubError(42, @"Unexpected end while extracting .gxmod.");
                    return NO;
                }
                [output writeData:chunk];
                remaining -= chunk.length;
            }
        }
    }
    @catch (NSException *exception)
    {
        [output closeFile];
        if (error != nullptr)
            *error = GXHubError(43, [NSString stringWithFormat:@"Extraction failed: %@", exception.reason]);
        return NO;
    }

    [output closeFile];
    return YES;
}

BOOL GXHubSkipBytes(NSFileHandle *handle, unsigned long long count, NSError **error)
{
    @try
    {
        unsigned long long offset = handle.offsetInFile;
        [handle seekToFileOffset:offset + count];
        return YES;
    }
    @catch (NSException *exception)
    {
        if (error != nullptr)
            *error = GXHubError(44, [NSString stringWithFormat:@"Package seek failed: %@", exception.reason]);
        return NO;
    }
}

BOOL GXHubInstallTar(NSURL *packageURL, NSDictionary **installedManifest, NSError **error)
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:packageURL error:error];
    if (handle == nil)
        return NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *modsRoot = GXHubModsRootPath();
    if (![fm createDirectoryAtPath:modsRoot withIntermediateDirectories:YES attributes:nil error:error])
    {
        [handle closeFile];
        return NO;
    }

    NSString *stage = [modsRoot stringByAppendingPathComponent:
        [@".staging-" stringByAppendingString:[NSUUID UUID].UUIDString]];
    if (![fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:error])
    {
        [handle closeFile];
        return NO;
    }

    NSDictionary *manifest = nil;
    NSUInteger extractedFiles = 0;
    BOOL ok = YES;

    while (ok)
    {
        NSError *readError = nil;
        NSData *header = GXHubReadExact(handle, 512, &readError);
        if (header == nil)
        {
            if (error != nullptr)
                *error = readError;
            ok = NO;
            break;
        }

        const unsigned char *bytes = (const unsigned char *)header.bytes;
        if (GXHubHeaderIsZero(bytes))
            break;

        NSString *name = GXHubTarString(bytes, 100);
        NSString *prefix = GXHubTarString(bytes + 345, 155);
        if (prefix.length > 0)
            name = [prefix stringByAppendingFormat:@"/%@", name];

        unsigned long long size = GXHubParseOctal(bytes + 124, 12);
        unsigned char type = bytes[156];
        BOOL regular = type == '\0' || type == '0';
        BOOL directory = type == '5';

        if (!GXHubSafeRelativePath(name))
        {
            if (error != nullptr)
                *error = GXHubError(45, [NSString stringWithFormat:@"Unsafe package path: %@", name]);
            ok = NO;
            break;
        }

        if ([name isEqualToString:@"manifest.json"])
        {
            if (!regular || size == 0 || size > 1024 * 1024)
            {
                if (error != nullptr)
                    *error = GXHubError(46, @"Invalid manifest.json entry.");
                ok = NO;
                break;
            }
            NSData *manifestData = GXHubReadExact(handle, (NSUInteger)size, error);
            if (manifestData == nil)
            {
                ok = NO;
                break;
            }
            manifest = GXHubParseManifest(manifestData, error);
            if (manifest == nil)
            {
                ok = NO;
                break;
            }
            NSString *minimumHub = manifest[@"minHubVersion"];
            if (minimumHub.length > 0 && !GXHubVersionSatisfies(GXHubProjectVersion(), minimumHub))
            {
                if (error != nullptr)
                    *error = GXHubError(
                        54,
                        [NSString stringWithFormat:@"This mod requires Generals Hub %@ or newer. Installed Hub: %@.",
                            minimumHub, GXHubProjectVersion()]);
                ok = NO;
                break;
            }
        }
        else if ([name hasPrefix:@"profile/"])
        {
            if (manifest == nil)
            {
                if (error != nullptr)
                    *error = GXHubError(47, @"manifest.json must be the first .gxmod entry.");
                ok = NO;
                break;
            }

            NSString *relative = [name substringFromIndex:[@"profile/" length]];
            if (!GXHubSafeRelativePath(relative))
            {
                if (error != nullptr)
                    *error = GXHubError(48, @"Unsafe profile path in package.");
                ok = NO;
                break;
            }

            NSString *destination = [[stage stringByAppendingPathComponent:@"profile"]
                stringByAppendingPathComponent:relative];
            if (directory)
            {
                if (![fm createDirectoryAtPath:destination
                    withIntermediateDirectories:YES attributes:nil error:error])
                {
                    ok = NO;
                    break;
                }
            }
            else if (regular)
            {
                if (!GXHubCopyTarFile(handle, size, destination, error))
                {
                    ok = NO;
                    break;
                }
                ++extractedFiles;
            }
            else
            {
                if (error != nullptr)
                    *error = GXHubError(49, @"Unsupported entry type in .gxmod package.");
                ok = NO;
                break;
            }
        }
        else if (regular)
        {
            if (!GXHubSkipBytes(handle, size, error))
            {
                ok = NO;
                break;
            }
        }
        else if (!directory)
        {
            if (error != nullptr)
                *error = GXHubError(50, @"Unsupported top-level .gxmod entry.");
            ok = NO;
            break;
        }

        unsigned long long padding = (512 - (size % 512)) % 512;
        if (padding > 0 && !GXHubSkipBytes(handle, padding, error))
        {
            ok = NO;
            break;
        }
    }

    [handle closeFile];

    if (ok && manifest == nil)
    {
        if (error != nullptr)
            *error = GXHubError(51, @".gxmod package has no manifest.json.");
        ok = NO;
    }
    if (ok && extractedFiles == 0)
    {
        if (error != nullptr)
            *error = GXHubError(52, @".gxmod package contains no profile files.");
        ok = NO;
    }

    NSNumber *expectedFiles = manifest[@"profileFiles"];
    if (ok && expectedFiles != nil && expectedFiles.unsignedIntegerValue != extractedFiles)
    {
        if (error != nullptr)
            *error = GXHubError(
                53,
                [NSString stringWithFormat:@"Profile file count mismatch: expected %@, extracted %lu.",
                    expectedFiles, (unsigned long)extractedFiles]);
        ok = NO;
    }

    if (!ok)
    {
        [fm removeItemAtPath:stage error:nil];
        return NO;
    }

    NSString *profileId = manifest[@"profileId"];
    NSData *installedData = [NSJSONSerialization dataWithJSONObject:manifest
                                                            options:NSJSONWritingPrettyPrinted
                                                             error:error];
    if (installedData == nil)
    {
        [fm removeItemAtPath:stage error:nil];
        return NO;
    }
    if (![installedData writeToFile:[stage stringByAppendingPathComponent:@"installed.json"]
                            options:NSDataWritingAtomic
                              error:error])
    {
        [fm removeItemAtPath:stage error:nil];
        return NO;
    }

    NSString *finalPath = [modsRoot stringByAppendingPathComponent:profileId];
    NSString *existingSettings = [finalPath stringByAppendingPathComponent:@"settings.ini"];
    if ([fm fileExistsAtPath:existingSettings])
    {
        NSString *stageSettings = [stage stringByAppendingPathComponent:@"settings.ini"];
        NSError *settingsError = nil;
        if (![fm copyItemAtPath:existingSettings toPath:stageSettings error:&settingsError])
        {
            fprintf(stderr,
                    "WARNING: preserving settings for profile '%s' failed: %s\n",
                    profileId.UTF8String,
                    settingsError != nil ? settingsError.description.UTF8String : "unknown");
        }
    }
    NSString *backupPath = [modsRoot stringByAppendingPathComponent:
        [@".backup-" stringByAppendingString:[NSUUID UUID].UUIDString]];

    if ([fm fileExistsAtPath:finalPath])
    {
        if (![fm moveItemAtPath:finalPath toPath:backupPath error:error])
        {
            [fm removeItemAtPath:stage error:nil];
            return NO;
        }
    }

    if (![fm moveItemAtPath:stage toPath:finalPath error:error])
    {
        if ([fm fileExistsAtPath:backupPath])
            [fm moveItemAtPath:backupPath toPath:finalPath error:nil];
        [fm removeItemAtPath:stage error:nil];
        return NO;
    }

    [fm removeItemAtPath:backupPath error:nil];

    fprintf(stderr,
            "[HUB] installed profile='%s' version='%s' files=%lu path='%s'\n",
            [profileId UTF8String],
            [manifest[@"version"] UTF8String],
            (unsigned long)extractedFiles,
            [finalPath fileSystemRepresentation]);

    if (installedManifest != nullptr)
        *installedManifest = manifest;
    return YES;
}
} // namespace

static NSURLSession *sGXHubDownloadSession = nil;
static NSURLSessionDownloadTask *sGXHubDownloadTask = nil;
static NSDictionary<NSString *, id> *sGXHubDownloadEntry = nil;
static GXHubDownloadProgress sGXHubDownloadProgress = nil;
static GXHubInstallCompletion sGXHubDownloadCompletion = nil;
static dispatch_source_t sGXHubDownloadTimer = nil;
static NSInteger sGXHubLastProgressPercent = -1;
static BOOL sGXHubDownloadPaused = NO;
static BOOL sGXHubDownloadCancelling = NO;
static long long sGXHubDownloadLastSampleBytes = 0;
static NSTimeInterval sGXHubDownloadLastSampleTime = 0.0;
static double sGXHubDownloadSpeedBytesPerSecond = 0.0;

static void GXHubStopDownloadTimer(void)
{
    if (sGXHubDownloadTimer != nil)
    {
        dispatch_source_cancel(sGXHubDownloadTimer);
        sGXHubDownloadTimer = nil;
    }
}

static void GXHubCompleteRemoteDownload(
    NSDictionary<NSString *, id> *manifest,
    NSError *error)
{
    GXHubInstallCompletion completion = [sGXHubDownloadCompletion copy];
    NSURLSession *session = sGXHubDownloadSession;
    NSString *profileId = sGXHubDownloadEntry[@"profileId"] ?: @"unknown";

    GXHubStopDownloadTimer();
    sGXHubDownloadTask = nil;
    sGXHubDownloadSession = nil;
    sGXHubDownloadEntry = nil;
    sGXHubDownloadProgress = nil;
    sGXHubDownloadCompletion = nil;
    sGXHubLastProgressPercent = -1;
    sGXHubDownloadPaused = NO;
    sGXHubDownloadCancelling = NO;
    sGXHubDownloadLastSampleBytes = 0;
    sGXHubDownloadLastSampleTime = 0.0;
    sGXHubDownloadSpeedBytesPerSecond = 0.0;

    [session finishTasksAndInvalidate];

    if (error != nil)
    {
        fprintf(stderr,
                "[HUB-DOWNLOAD] failed profile='%s' domain='%s' code=%ld error='%s'\n",
                profileId.UTF8String,
                error.domain.UTF8String,
                (long)error.code,
                error.localizedDescription.UTF8String);
    }
    else
    {
        fprintf(stderr,
                "[HUB-DOWNLOAD] install-complete profile='%s' version='%s'\n",
                profileId.UTF8String,
                [manifest[@"version"] UTF8String]);
    }
    fflush(stderr);

    if (completion != nil)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(manifest, error);
        });
    }
}

static void GXHubStartDownloadProgressTimer(void)
{
    GXHubStopDownloadTimer();
    sGXHubLastProgressPercent = -1;
    sGXHubDownloadTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        dispatch_get_main_queue());
    dispatch_source_set_timer(
        sGXHubDownloadTimer,
        dispatch_time(DISPATCH_TIME_NOW, 0),
        (uint64_t)(0.5 * NSEC_PER_SEC),
        (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(sGXHubDownloadTimer, ^{
        NSURLSessionDownloadTask *task = sGXHubDownloadTask;
        NSDictionary<NSString *, id> *entry = sGXHubDownloadEntry;
        if (task == nil || entry == nil)
            return;

        long long received = task.countOfBytesReceived;
        long long expected = task.countOfBytesExpectedToReceive;
        if (expected <= 0)
            expected = [entry[@"packageBytes"] longLongValue];

        double fraction = expected > 0
            ? MIN(1.0, MAX(0.0, (double)received / (double)expected))
            : 0.0;

        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (!sGXHubDownloadPaused)
        {
            if (sGXHubDownloadLastSampleTime > 0.0 && now > sGXHubDownloadLastSampleTime &&
                received >= sGXHubDownloadLastSampleBytes)
            {
                double instantaneous =
                    (double)(received - sGXHubDownloadLastSampleBytes) /
                    (now - sGXHubDownloadLastSampleTime);
                sGXHubDownloadSpeedBytesPerSecond = sGXHubDownloadSpeedBytesPerSecond > 0.0
                    ? (sGXHubDownloadSpeedBytesPerSecond * 0.72 + instantaneous * 0.28)
                    : instantaneous;
            }
            sGXHubDownloadLastSampleBytes = received;
            sGXHubDownloadLastSampleTime = now;
        }
        else
        {
            sGXHubDownloadSpeedBytesPerSecond = 0.0;
        }

        NSInteger percent = expected > 0 ? (NSInteger)(fraction * 100.0) : -1;
        if (percent >= 0 &&
            (sGXHubLastProgressPercent < 0 || percent >= sGXHubLastProgressPercent + 5 || percent == 100))
        {
            sGXHubLastProgressPercent = percent;
            fprintf(stderr,
                    "[HUB-DOWNLOAD] progress profile='%s' percent=%ld received=%lld expected=%lld\n",
                    [entry[@"profileId"] UTF8String],
                    (long)percent,
                    received,
                    expected);
            fflush(stderr);
        }

        if (sGXHubDownloadProgress != nil)
            sGXHubDownloadProgress(received, expected, fraction);
    });
    dispatch_resume(sGXHubDownloadTimer);
}

NSString *GXHubModsRootPath(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Mods"];
}

NSString *GXHubInstalledProfilePath(NSString *profileId)
{
    if (!GXHubSafeId(profileId))
        return @"";
    return [[[GXHubModsRootPath() stringByAppendingPathComponent:profileId]
        stringByAppendingPathComponent:@"profile"] stringByStandardizingPath];
}

BOOL GXHubProfileInstalled(NSString *profileId)
{
    NSString *path = GXHubInstalledProfilePath(profileId);
    if (path.length == 0)
        return NO;
    BOOL isDirectory = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory;
}

NSDictionary<NSString *, id> *GXHubInstalledManifest(NSString *profileId)
{
    if (!GXHubSafeId(profileId))
        return nil;
    NSString *path = [[GXHubModsRootPath() stringByAppendingPathComponent:profileId]
        stringByAppendingPathComponent:@"installed.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil)
        return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

NSString *GXHubCatalogChannel(void)
{
    NSString *channel = [[[NSUserDefaults standardUserDefaults] stringForKey:GXHubChannelDefaultsKey] lowercaseString];
    return [channel isEqualToString:@"beta"] ? @"beta" : @"stable";
}

void GXHubSetCatalogChannel(NSString *channel)
{
    NSString *normalized = [[channel lowercaseString] isEqualToString:@"beta"] ? @"beta" : @"stable";
    [[NSUserDefaults standardUserDefaults] setObject:normalized forKey:GXHubChannelDefaultsKey];
    fprintf(stderr, "[HUB-CATALOG] channel='%s'\n", normalized.UTF8String);
}

NSDictionary<NSString *, id> *GXHubCatalogDocument(void)
{
    return GXHubPreferredCatalogDocumentInternal();
}

NSString *GXHubRemoteCatalogURL(void)
{
    return GXHubCatalogBootstrapURL();
}

NSArray<NSDictionary<NSString *, id> *> *GXHubCatalogEntries(void)
{
    NSDictionary *document = GXHubPreferredCatalogDocumentInternal();
    NSArray *entries = document[@"mods"];
    if (![entries isKindOfClass:[NSArray class]])
        return @[];

    NSString *channel = GXHubCatalogChannel();
    NSMutableArray *valid = [NSMutableArray array];
    for (id raw in entries)
    {
        if (![raw isKindOfClass:[NSDictionary class]])
            continue;
        NSDictionary *entry = GXHubFlattenRelease(raw, channel);
        if (entry == nil)
            continue;
        if (GXHubSafeId(entry[@"profileId"]) &&
            [entry[@"name"] isKindOfClass:[NSString class]] &&
            [entry[@"version"] isKindOfClass:[NSString class]])
        {
            [valid addObject:entry];
        }
    }
    return valid;
}

NSDictionary<NSString *, id> *GXHubHubReleaseForCurrentChannel(void)
{
    NSDictionary *document = GXHubPreferredCatalogDocumentInternal();
    NSDictionary *hub = document[@"hub"];
    if (![hub isKindOfClass:[NSDictionary class]])
        return nil;
    return GXHubFlattenRelease(hub, GXHubCatalogChannel());
}

void GXHubRefreshRemoteCatalog(GXHubCatalogCompletion completion)
{
    NSString *urlText = GXHubCatalogBootstrapURL();
    NSURL *url = urlText.length > 0 ? [NSURL URLWithString:urlText] : nil;
    if (url == nil || ![[url scheme] isEqualToString:@"https"])
    {
        NSError *error = GXHubError(90, @"No HTTPS remote catalog URL is configured.");
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, error);
        });
        return;
    }

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 30.0;
    configuration.timeoutIntervalForResource = 60.0;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

    fprintf(stderr, "[HUB-CATALOG] refresh-start url='%s' channel='%s'\n",
            urlText.UTF8String, GXHubCatalogChannel().UTF8String);

    NSURLSessionDataTask *task =
        [session dataTaskWithURL:url
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *requestError) {
        NSError *finalError = requestError;
        BOOL updated = NO;

        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? (NSHTTPURLResponse *)response
            : nil;
        if (finalError == nil && http != nil && (http.statusCode < 200 || http.statusCode >= 300))
            finalError = GXHubError(91, [NSString stringWithFormat:@"Catalog HTTP %ld.", (long)http.statusCode]);

        if (finalError == nil && (data.length == 0 || data.length > 2 * 1024 * 1024))
            finalError = GXHubError(92, @"Remote catalog is empty or too large.");

        NSDictionary *document = nil;
        if (finalError == nil)
        {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&finalError];
            if ([json isKindOfClass:[NSDictionary class]])
                document = json;
            if (finalError == nil && !GXHubCatalogIsValid(document))
                finalError = GXHubError(93, @"Remote catalog schema is invalid.");
        }

        if (finalError == nil)
        {
            NSString *path = GXHubDocumentsPath(GXHubRemoteCatalogName);
            updated = [data writeToFile:path options:NSDataWritingAtomic error:&finalError];
            if (updated)
            {
                [[NSUserDefaults standardUserDefaults] setObject:[NSDate date]
                                                         forKey:@"GXHubCatalogLastRefresh"];
                fprintf(stderr,
                        "[HUB-CATALOG] refresh-ok schema=%ld bytes=%lu path='%s'\n",
                        (long)[document[@"schemaVersion"] integerValue],
                        (unsigned long)data.length,
                        path.fileSystemRepresentation);
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(updated, finalError);
        });
        [session finishTasksAndInvalidate];
    }];
    [task resume];
}

NSArray<NSDictionary<NSString *, id> *> *GXHubInstalledModEntries(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:GXHubModsRootPath() error:nil] ?: @[];
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *child in children)
    {
        if ([child hasPrefix:@"."] || !GXHubSafeId(child))
            continue;
        NSDictionary *manifest = GXHubInstalledManifest(child);
        if (manifest != nil && GXHubProfileInstalled(child))
            [entries addObject:manifest];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return entries;
}

BOOL GXHubRemoveMod(NSString *profileId, NSError **error)
{
    if (!GXHubSafeId(profileId))
    {
        if (error != nullptr)
            *error = GXHubError(60, @"Invalid mod profile ID.");
        return NO;
    }
    NSString *path = [GXHubModsRootPath() stringByAppendingPathComponent:profileId];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        return YES;
    BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:path error:error];
    if (ok)
        fprintf(stderr, "[HUB] removed profile='%s'\n", [profileId UTF8String]);
    return ok;
}

BOOL GXHubInstallPackageAtURL(
    NSURL *packageURL,
    NSString *expectedSHA256,
    NSDictionary<NSString *, id> **installedManifest,
    NSError **error)
{
    if (packageURL == nil || !packageURL.isFileURL)
    {
        if (error != nullptr)
            *error = GXHubError(70, @"Installer requires a local .gxmod file URL.");
        return NO;
    }

    if (![[packageURL.pathExtension lowercaseString] isEqualToString:@"gxmod"])
    {
        if (error != nullptr)
            *error = GXHubError(72, @"Selected file is not a .gxmod package.");
        return NO;
    }

    NSDictionary<NSFileAttributeKey, id> *packageAttributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:packageURL.path error:error];
    if (packageAttributes == nil)
        return NO;

    unsigned long long packageBytes = [packageAttributes fileSize];
    NSDictionary<NSFileAttributeKey, id> *fsAttributes =
        [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:error];
    if (fsAttributes == nil)
        return NO;

    unsigned long long freeBytes = [fsAttributes[NSFileSystemFreeSize] unsignedLongLongValue];
    const unsigned long long reserveBytes = 256ULL * 1024ULL * 1024ULL;
    if (freeBytes < packageBytes + reserveBytes)
    {
        if (error != nullptr)
        {
            *error = GXHubError(
                73,
                [NSString stringWithFormat:
                    @"Not enough free space. Need about %.1f GB free to install this mod; available %.1f GB.",
                    (double)(packageBytes + reserveBytes) / 1024.0 / 1024.0 / 1024.0,
                    (double)freeBytes / 1024.0 / 1024.0 / 1024.0]);
        }
        return NO;
    }

    if (expectedSHA256.length > 0)
    {
        NSString *actual = GXHubSHA256ForFile(packageURL, error);
        if (actual == nil)
            return NO;
        if ([actual caseInsensitiveCompare:expectedSHA256] != NSOrderedSame)
        {
            if (error != nullptr)
                *error = GXHubError(
                    71,
                    [NSString stringWithFormat:@"Package SHA-256 mismatch. Expected %@, got %@.",
                        expectedSHA256, actual]);
            return NO;
        }
    }

    return GXHubInstallTar(packageURL, installedManifest, error);
}

BOOL GXHubDownloadBusy(void)
{
    return sGXHubDownloadTask != nil || sGXHubDownloadEntry != nil;
}

NSString *GXHubActiveDownloadProfile(void)
{
    return sGXHubDownloadEntry[@"profileId"];
}

NSDictionary<NSString *, id> *GXHubDownloadStatus(void)
{
    NSURLSessionDownloadTask *task = sGXHubDownloadTask;
    NSDictionary<NSString *, id> *entry = sGXHubDownloadEntry;
    if (task == nil || entry == nil)
    {
        return @{
            @"busy": @NO,
            @"profileId": @"",
            @"paused": @NO,
            @"received": @0,
            @"total": @0,
            @"fraction": @0.0,
            @"speedBytesPerSecond": @0.0,
            @"etaSeconds": @0.0,
        };
    }

    long long received = task.countOfBytesReceived;
    long long total = task.countOfBytesExpectedToReceive;
    if (total <= 0)
        total = [entry[@"packageBytes"] longLongValue];
    double fraction = total > 0
        ? MIN(1.0, MAX(0.0, (double)received / (double)total))
        : 0.0;
    double speed = sGXHubDownloadPaused ? 0.0 : MAX(0.0, sGXHubDownloadSpeedBytesPerSecond);
    double eta = (speed > 1024.0 && total > received)
        ? (double)(total - received) / speed
        : 0.0;

    return @{
        @"busy": @YES,
        @"profileId": entry[@"profileId"] ?: @"",
        @"paused": @(sGXHubDownloadPaused),
        @"received": @(MAX((long long)0, received)),
        @"total": @(MAX((long long)0, total)),
        @"fraction": @(fraction),
        @"speedBytesPerSecond": @(speed),
        @"etaSeconds": @(eta),
    };
}

static BOOL GXHubDownloadProfileMatches(NSString *profileId, NSError **error)
{
    if (!GXHubDownloadBusy())
    {
        if (error != nullptr)
            *error = GXHubError(89, @"There is no active download.");
        return NO;
    }
    NSString *active = GXHubActiveDownloadProfile() ?: @"";
    if (profileId.length > 0 && ![active isEqualToString:profileId])
    {
        if (error != nullptr)
            *error = GXHubError(89, [NSString stringWithFormat:@"%@ is not the active download.", profileId]);
        return NO;
    }
    return YES;
}

BOOL GXHubPauseDownload(NSString *profileId, NSError **error)
{
    if (!GXHubDownloadProfileMatches(profileId, error))
        return NO;
    if (!sGXHubDownloadPaused)
    {
        [sGXHubDownloadTask suspend];
        sGXHubDownloadPaused = YES;
        sGXHubDownloadSpeedBytesPerSecond = 0.0;
        fprintf(stderr, "[HUB-DOWNLOAD] paused profile='%s'\n",
                (GXHubActiveDownloadProfile() ?: @"unknown").UTF8String);
        fflush(stderr);
    }
    return YES;
}

BOOL GXHubResumeDownload(NSString *profileId, NSError **error)
{
    if (!GXHubDownloadProfileMatches(profileId, error))
        return NO;
    if (sGXHubDownloadPaused)
    {
        sGXHubDownloadPaused = NO;
        sGXHubDownloadLastSampleBytes = sGXHubDownloadTask.countOfBytesReceived;
        sGXHubDownloadLastSampleTime = [NSDate timeIntervalSinceReferenceDate];
        sGXHubDownloadSpeedBytesPerSecond = 0.0;
        [sGXHubDownloadTask resume];
        fprintf(stderr, "[HUB-DOWNLOAD] resumed profile='%s'\n",
                (GXHubActiveDownloadProfile() ?: @"unknown").UTF8String);
        fflush(stderr);
    }
    return YES;
}

BOOL GXHubCancelDownload(NSString *profileId, NSError **error)
{
    if (!GXHubDownloadProfileMatches(profileId, error))
        return NO;
    sGXHubDownloadCancelling = YES;
    [sGXHubDownloadTask cancel];
    fprintf(stderr, "[HUB-DOWNLOAD] cancelling profile='%s'\n",
            (GXHubActiveDownloadProfile() ?: @"unknown").UTF8String);
    fflush(stderr);
    return YES;
}

void GXHubDownloadAndInstall(
    NSDictionary<NSString *, id> *catalogEntry,
    GXHubInstallCompletion completion)
{
    GXHubDownloadAndInstallWithProgress(catalogEntry, nil, completion);
}

void GXHubDownloadAndInstallWithProgress(
    NSDictionary<NSString *, id> *catalogEntry,
    GXHubDownloadProgress progress,
    GXHubInstallCompletion completion)
{
    NSString *profileId = catalogEntry[@"profileId"] ?: @"unknown";
    NSString *urlText = catalogEntry[@"packageURL"];
    NSString *expected = catalogEntry[@"sha256"];
    NSURL *url = urlText.length > 0 ? [NSURL URLWithString:urlText] : nil;

    void (^failNow)(NSError *) = ^(NSError *error) {
        fprintf(stderr,
                "[HUB-DOWNLOAD] rejected profile='%s' code=%ld error='%s'\n",
                profileId.UTF8String,
                (long)error.code,
                error.localizedDescription.UTF8String);
        fflush(stderr);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, error);
        });
    };

    if (GXHubDownloadBusy())
    {
        failNow(GXHubError(
            84,
            [NSString stringWithFormat:@"Another mod is already downloading: %@.",
                GXHubActiveDownloadProfile() ?: @"unknown"]));
        return;
    }
    if (url == nil || ![[url scheme] isEqualToString:@"https"])
    {
        failNow(GXHubError(80, @"This catalog entry has no valid HTTPS package URL."));
        return;
    }
    if (expected.length != 64)
    {
        failNow(GXHubError(81, @"Remote packages require a SHA-256 value in the catalog."));
        return;
    }

    NSString *minimumHub = catalogEntry[@"minHubVersion"];
    if (minimumHub.length > 0 && !GXHubVersionSatisfies(GXHubProjectVersion(), minimumHub))
    {
        failNow(GXHubError(
            83,
            [NSString stringWithFormat:@"This release requires Generals Hub %@ or newer. Installed Hub: %@.",
                minimumHub, GXHubProjectVersion()]));
        return;
    }

    unsigned long long packageBytes = [catalogEntry[@"packageBytes"] unsignedLongLongValue];
    NSError *spaceError = nil;
    NSDictionary<NSFileAttributeKey, id> *fsAttributes =
        [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:&spaceError];
    if (fsAttributes == nil)
    {
        failNow(spaceError ?: GXHubError(85, @"Unable to check free storage."));
        return;
    }
    unsigned long long freeBytes = [fsAttributes[NSFileSystemFreeSize] unsignedLongLongValue];
    const unsigned long long reserveBytes = 512ULL * 1024ULL * 1024ULL;
    unsigned long long requiredBytes = packageBytes > 0
        ? packageBytes * 2ULL + reserveBytes
        : reserveBytes;

    fprintf(stderr,
            "[HUB-DOWNLOAD] preflight profile='%s' packageBytes=%llu requiredFreeBytes=%llu availableBytes=%llu\n",
            profileId.UTF8String,
            packageBytes,
            requiredBytes,
            freeBytes);
    fflush(stderr);

    if (packageBytes > 0 && freeBytes < requiredBytes)
    {
        failNow(GXHubError(
            86,
            [NSString stringWithFormat:
                @"Not enough free space. %@ needs about %.1f GB free while downloading and installing; available %.1f GB.",
                catalogEntry[@"name"] ?: profileId,
                (double)requiredBytes / 1024.0 / 1024.0 / 1024.0,
                (double)freeBytes / 1024.0 / 1024.0 / 1024.0]));
        return;
    }

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.timeoutIntervalForRequest = 300.0;
    configuration.timeoutIntervalForResource = 60.0 * 60.0 * 24.0;
    configuration.allowsCellularAccess = YES;
    configuration.waitsForConnectivity = YES;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    sGXHubDownloadSession = session;
    sGXHubDownloadEntry = [catalogEntry copy];
    sGXHubDownloadProgress = [progress copy];
    sGXHubDownloadCompletion = [completion copy];
    sGXHubDownloadPaused = NO;
    sGXHubDownloadCancelling = NO;
    sGXHubDownloadLastSampleBytes = 0;
    sGXHubDownloadLastSampleTime = [NSDate timeIntervalSinceReferenceDate];
    sGXHubDownloadSpeedBytesPerSecond = 0.0;

    fprintf(stderr,
            "[HUB-DOWNLOAD] start profile='%s' bytes=%llu url='%s'\n",
            profileId.UTF8String,
            packageBytes,
            urlText.UTF8String);
    fflush(stderr);

    NSURLSessionDownloadTask *task =
        [session downloadTaskWithURL:url
                  completionHandler:^(NSURL *location, NSURLResponse *response, NSError *downloadError) {
        if (downloadError != nil)
        {
            if (sGXHubDownloadCancelling &&
                [downloadError.domain isEqualToString:NSURLErrorDomain] &&
                downloadError.code == NSURLErrorCancelled)
            {
                GXHubCompleteRemoteDownload(nil, GXHubError(189, @"Download cancelled."));
            }
            else
            {
                GXHubCompleteRemoteDownload(nil, downloadError);
            }
            return;
        }

        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? (NSHTTPURLResponse *)response
            : nil;
        if (http != nil && (http.statusCode < 200 || http.statusCode >= 300))
        {
            GXHubCompleteRemoteDownload(
                nil,
                GXHubError(
                    82,
                    [NSString stringWithFormat:@"Download failed with HTTP %ld.", (long)http.statusCode]));
            return;
        }
        if (location == nil)
        {
            GXHubCompleteRemoteDownload(nil, GXHubError(87, @"Download completed without a temporary file."));
            return;
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *downloadsRoot = GXHubDocumentsPath(@"Downloads");
        NSError *fileError = nil;
        if (![fm createDirectoryAtPath:downloadsRoot
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:&fileError])
        {
            GXHubCompleteRemoteDownload(nil, fileError);
            return;
        }

        NSString *downloadPath = [downloadsRoot stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.download.gxmod", profileId]];
        [fm removeItemAtPath:downloadPath error:nil];
        NSURL *downloadURL = [NSURL fileURLWithPath:downloadPath];
        if (![fm moveItemAtURL:location toURL:downloadURL error:&fileError])
        {
            GXHubCompleteRemoteDownload(nil, fileError);
            return;
        }

        NSDictionary<NSFileAttributeKey, id> *downloadAttributes =
            [fm attributesOfItemAtPath:downloadPath error:&fileError];
        if (downloadAttributes == nil)
        {
            [fm removeItemAtURL:downloadURL error:nil];
            GXHubCompleteRemoteDownload(nil, fileError);
            return;
        }
        unsigned long long actualBytes = [downloadAttributes fileSize];
        if (packageBytes > 0 && actualBytes != packageBytes)
        {
            [fm removeItemAtURL:downloadURL error:nil];
            GXHubCompleteRemoteDownload(
                nil,
                GXHubError(
                    88,
                    [NSString stringWithFormat:@"Downloaded file size mismatch. Expected %llu bytes, got %llu.",
                        packageBytes, actualBytes]));
            return;
        }

        fprintf(stderr,
                "[HUB-DOWNLOAD] download-complete profile='%s' bytes=%llu path='%s'\n",
                profileId.UTF8String,
                actualBytes,
                downloadPath.fileSystemRepresentation);
        fflush(stderr);

        GXHubDownloadProgress finalProgress = [sGXHubDownloadProgress copy];
        if (finalProgress != nil)
        {
            long long expectedBytes = packageBytes > 0 ? (long long)packageBytes : (long long)actualBytes;
            dispatch_async(dispatch_get_main_queue(), ^{
                finalProgress((long long)actualBytes, expectedBytes, 1.0);
            });
        }

        NSError *installError = nil;
        NSDictionary *manifest = nil;
        BOOL installed = GXHubInstallPackageAtURL(downloadURL, expected, &manifest, &installError);
        [fm removeItemAtURL:downloadURL error:nil];
        GXHubCompleteRemoteDownload(installed ? manifest : nil, installError);
    }];

    sGXHubDownloadTask = task;
    GXHubStartDownloadProgressTimer();
    [task resume];
}

#endif
