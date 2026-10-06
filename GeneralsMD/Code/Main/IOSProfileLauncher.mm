#include "IOSProfileLauncher.h"
#include "IOSModManager.h"

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <WebKit/WebKit.h>
#include <malloc/malloc.h>

#include <atomic>
#include <cstring>
#include <cstdio>
#include <cmath>
#include <unistd.h>

#ifndef GX_LAUNCHER_COMMIT
#define GX_LAUNCHER_COMMIT "unknown"
#endif
#ifndef GX_ENGINE_COMMIT
#define GX_ENGINE_COMMIT "unknown"
#endif
#ifndef GX_BASE_SHELL_RUN
#define GX_BASE_SHELL_RUN "unknown"
#endif
#ifndef GX_PROJECT_VERSION
#define GX_PROJECT_VERSION "0.0.0"
#endif
#ifndef GX_ENGINE_VERSION
#define GX_ENGINE_VERSION "0.0.0"
#endif
#ifndef GX_LAUNCHER_VERSION
#define GX_LAUNCHER_VERSION "0.0.0"
#endif
#ifndef GX_LAUNCHER_RUN
#define GX_LAUNCHER_RUN "unknown"
#endif

namespace
{
std::atomic<bool> gLauncherFinished(false);
char gSelectedProfile[64] = "vanilla";
GeneralsXIOSDiagnosticClearCallback gDiagnosticClearCallback = nullptr;

NSString *ShortBuildIdentifier(const char *raw)
{
    if (raw == nullptr || raw[0] == '\0')
        return @"unknown";

    NSString *value = [NSString stringWithUTF8String:raw];
    if (value == nil || value.length == 0)
        return @"unknown";

    if ([value isEqualToString:@"unknown"] || value.length <= 10)
        return value;

    return [value substringToIndex:10];
}

NSString *DocumentsFilePath(NSString *name)
{
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
            stringByAppendingPathComponent:name];
}

NSArray<NSString *> *DiagnosticSessionLogNames()
{
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithObject:@"generals-stderr.log"];
    for (NSInteger index = 1; index <= 9; ++index)
        [names addObject:[NSString stringWithFormat:@"generals-stderr-%02ld.log", (long)index]];
    return names;
}

NSArray<NSString *> *DiagnosticReplayPaths()
{
    NSString *userData = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/GeneralsX/GeneralsZH/Replays"];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [fileManager contentsOfDirectoryAtPath:userData error:nil] ?: @[];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *name in names)
    {
        if ([[name.pathExtension lowercaseString] isEqualToString:@"rep"])
            [paths addObject:[userData stringByAppendingPathComponent:name]];
    }
    [paths sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *dateA = [[fileManager attributesOfItemAtPath:a error:nil] fileModificationDate] ?: NSDate.distantPast;
        NSDate *dateB = [[fileManager attributesOfItemAtPath:b error:nil] fileModificationDate] ?: NSDate.distantPast;
        return [dateB compare:dateA];
    }];
    if (paths.count > 3)
        [paths removeObjectsInRange:NSMakeRange(3, paths.count - 3)];
    return paths;
}

NSString *DiagnosticsExportDirectoryPath()
{
    return DocumentsFilePath(@"Diagnostics");
}

NSArray<NSURL *> *ExportDiagnosticsSnapshot(NSString *reportText)
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *directory = DiagnosticsExportDirectoryPath();
    NSError *directoryError = nil;
    if (![fileManager createDirectoryAtPath:directory
                 withIntermediateDirectories:YES
                                  attributes:nil
                                       error:&directoryError])
    {
        fprintf(stderr, "[HUB-DIAG] failed to create export directory: %s\n",
                directoryError.localizedDescription.UTF8String ?: "unknown");
        return @[];
    }

    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    NSString *reportPath = [directory stringByAppendingPathComponent:@"GeneralsZH-Diagnostics.txt"];
    if ((reportText ?: @"").length > 0 &&
        [reportText writeToFile:reportPath atomically:YES encoding:NSUTF8StringEncoding error:nil])
    {
        [files addObject:[NSURL fileURLWithPath:reportPath]];
    }

    for (NSString *name in DiagnosticSessionLogNames())
    {
        NSString *source = DocumentsFilePath(name);
        if (![fileManager fileExistsAtPath:source])
            continue;
        NSString *destination = [directory stringByAppendingPathComponent:name];
        [fileManager removeItemAtPath:destination error:nil];
        NSError *copyError = nil;
        if ([fileManager copyItemAtPath:source toPath:destination error:&copyError])
            [files addObject:[NSURL fileURLWithPath:destination]];
        else
            fprintf(stderr, "[HUB-DIAG] log export failed '%s': %s\n",
                    name.UTF8String,
                    copyError.localizedDescription.UTF8String ?: "unknown");
    }

    for (NSString *source in DiagnosticReplayPaths())
    {
        NSString *destination = [directory stringByAppendingPathComponent:source.lastPathComponent];
        [fileManager removeItemAtPath:destination error:nil];
        if ([fileManager copyItemAtPath:source toPath:destination error:nil])
            [files addObject:[NSURL fileURLWithPath:destination]];
    }

    fprintf(stderr, "[HUB-DIAG] exported %lu files to '%s'\n",
            (unsigned long)files.count,
            directory.UTF8String);
    return files;
}

unsigned long long FileSizeAtPath(NSString *path)
{
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return attributes != nil ? [attributes fileSize] : 0;
}

NSString *HumanReadableBytes(unsigned long long bytes)
{
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

unsigned long long DirectorySizeAtPath(NSString *path)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDirectoryEnumerator<NSString *> *enumerator = [fileManager enumeratorAtPath:path];
    if (enumerator == nil)
        return 0;

    unsigned long long total = 0;
    for (NSString *relativePath in enumerator)
    {
        NSString *fullPath = [path stringByAppendingPathComponent:relativePath];
        NSDictionary<NSFileAttributeKey, id> *attributes =
            [fileManager attributesOfItemAtPath:fullPath error:nil];
        if ([[attributes fileType] isEqualToString:NSFileTypeRegular])
            total += [attributes fileSize];
    }
    return total;
}

bool IsSupportedProfile(const char *profile)
{
    if (profile == nullptr || profile[0] == '\0')
        return false;
    const size_t length = strlen(profile);
    if (length >= sizeof(gSelectedProfile))
        return false;
    for (size_t i = 0; i < length; ++i)
    {
        const char c = profile[i];
        const bool valid = (c >= 'a' && c <= 'z') ||
                           (c >= 'A' && c <= 'Z') ||
                           (c >= '0' && c <= '9') ||
                           c == '.' || c == '_' || c == '-';
        if (!valid)
            return false;
    }
    return true;
}

void SetSelectedProfile(NSString *profile)
{
    if (profile == nil)
        return;

    const char *utf8 = [profile UTF8String];
    if (!IsSupportedProfile(utf8))
        return;

    strlcpy(gSelectedProfile, utf8, sizeof(gSelectedProfile));
    fprintf(stderr, "INFO: iOS native launcher selected profile: %s\n", gSelectedProfile);
    gLauncherFinished.store(true, std::memory_order_release);
}

NSString *BundledAutoLaunchProfile()
{
    NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
    NSString *markerPath = [resourcePath stringByAppendingPathComponent:@"AutoLaunchProfile.txt"];

    NSError *error = nil;
    NSString *value = [NSString stringWithContentsOfFile:markerPath
                                                encoding:NSUTF8StringEncoding
                                                   error:&error];
    if (value == nil)
        return nil;

    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    const char *utf8 = [value UTF8String];
    if (!IsSupportedProfile(utf8))
    {
        fprintf(stderr, "WARNING: iOS launcher ignored unsupported AutoLaunchProfile '%s'\n",
                utf8 != nullptr ? utf8 : "<null>");
        return nil;
    }

    return value;
}

NSString *IPadOverridesPath()
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/iPadOverrides.ini"];
}

NSString *ModSettingsPath(NSString *profileId, NSString *legacyName)
{
    NSString *dir = [GXHubModsRootPath() stringByAppendingPathComponent:profileId];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"settings.ini"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path] && legacyName.length > 0)
    {
        NSString *legacyPath = DocumentsFilePath(legacyName);
        if ([[NSFileManager defaultManager] fileExistsAtPath:legacyPath])
        {
            NSError *migrationError = nil;
            if ([[NSFileManager defaultManager] copyItemAtPath:legacyPath toPath:path error:&migrationError])
            {
                fprintf(stderr,
                        "[HUB-SETTINGS] migrated profile='%s' legacy='%s' -> '%s'\n",
                        profileId.UTF8String,
                        legacyPath.fileSystemRepresentation,
                        path.fileSystemRepresentation);
            }
            else
            {
                fprintf(stderr,
                        "WARNING: failed to migrate settings for profile '%s': %s\n",
                        profileId.UTF8String,
                        migrationError != nil ? migrationError.description.UTF8String : "unknown");
            }
        }
    }
    return path;
}

NSString *ContraSettingsPath()
{
    return ModSettingsPath(@"contra-x", @"ContraSettings.ini");
}

NSString *EnhancedSettingsPath()
{
    return ModSettingsPath(@"enhanced", @"EnhancedSettings.ini");
}

NSString *EngineOptionsPath()
{
    NSString *dir = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/GeneralsX/GeneralsZH"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [dir stringByAppendingPathComponent:@"Options.ini"];
}

NSMutableDictionary<NSString *, NSString *> *ReadKeyValueFile(NSString *path)
{
    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    NSString *contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    if (contents == nil)
        return values;

    NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *rawLine in [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]])
    {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:space];
        if (line.length == 0 || [line hasPrefix:@"#"] || [line hasPrefix:@";"])
            continue;

        NSRange equals = [line rangeOfString:@"="];
        if (equals.location == NSNotFound)
            continue;

        NSString *key = [[line substringToIndex:equals.location] stringByTrimmingCharactersInSet:space];
        NSString *value = [[line substringFromIndex:equals.location + 1] stringByTrimmingCharactersInSet:space];
        if (key.length > 0)
            values[key] = value;
    }
    return values;
}

NSString *SettingValue(NSDictionary<NSString *, NSString *> *values,
                       NSString *key,
                       NSString *fallback)
{
    NSString *value = values[key];
    return value.length > 0 ? value : fallback;
}

BOOL SettingBoolValue(NSDictionary<NSString *, NSString *> *values,
                      NSString *key,
                      BOOL fallback)
{
    NSString *value = [[SettingValue(values, key, fallback ? @"Yes" : @"No") lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [value isEqualToString:@"yes"] || [value isEqualToString:@"true"] ||
           [value isEqualToString:@"1"] || [value isEqualToString:@"on"];
}

BOOL WriteKeyValueFile(NSString *path, NSDictionary<NSString *, NSString *> *values, NSError **error)
{
    NSArray<NSString *> *keys =
        [[values allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableString *output = [NSMutableString string];
    for (NSString *key in keys)
        [output appendFormat:@"%@ = %@\n", key, values[key]];
    return [output writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error];
}

NSDictionary<NSString *, NSString *> *DefaultContraSettings()
{
    return @{
        @"ControlBar": @"Contra",
        @"Cameos": @"Standard",
        @"Music": @"Standard",
        @"UnitVoices": @"English",
        @"Hotkeys": @"Original",
        @"HotkeyLanguage": @"English",
        @"Portraits": @"Standard",
        @"FogEffects": @"No",
        @"WaterEffects": @"Yes",
        @"ExtraBuildingProps": @"Yes",
        @"UseShadowVolumes": @"No",
        @"UseShadowDecals": @"Yes",
        @"UseCloudMap": @"No",
        @"UseLightMap": @"Yes",
        @"ShowSoftWaterEdge": @"Yes",
        @"BuildingOcclusion": @"Yes",
        @"ShowTrees": @"Yes",
        @"ExtraAnimations": @"Yes",
        @"DynamicLOD": @"No",
        @"HeatEffects": @"No",
        @"TextureReduction": @"0",
        @"MaxParticleCount": @"2500",
        @"TextureFilter": @"Anisotropic",
        @"AnisotropyLevel": @"8",
        @"AntiAliasing": @"0"
    };
}

bool ProfileDirectoryExists(NSString *profileDirectory);

void EnsureDefaultContraSettings()
{
    if (!ProfileDirectoryExists(@"contra-x"))
        return;
    NSString *path = ContraSettingsPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:path])
        return;

    NSError *error = nil;
    if (!WriteKeyValueFile(path, DefaultContraSettings(), &error))
    {
        fprintf(stderr, "ERROR: failed to seed ContraSettings.ini: %s\n",
                error != nil ? [[error description] UTF8String] : "unknown");
    }
}

NSDictionary<NSString *, NSString *> *DefaultEnhancedSettings()
{
    return @{
        @"TextureResolution": @"High",
        @"UIQuality": @"FHD",
        @"InfantryIconScale": @"100",
        @"Cameos": @"HD",
        @"AIScripts": @"Default"
    };
}

void EnsureDefaultEnhancedSettings()
{
    NSString *path = EnhancedSettingsPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:path])
        return;

    NSError *error = nil;
    if (!WriteKeyValueFile(path, DefaultEnhancedSettings(), &error))
    {
        fprintf(stderr, "ERROR: failed to seed EnhancedSettings.ini: %s\n",
                error != nil ? [[error description] UTF8String] : "unknown");
    }
}

bool ProfileDirectoryExists(NSString *profileDirectory)
{
    if (GXHubProfileInstalled(profileDirectory))
        return true;

    NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
    NSString *path = [[resourcePath stringByAppendingPathComponent:@"Profiles"]
                      stringByAppendingPathComponent:profileDirectory];

    BOOL isDirectory = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path
                                               isDirectory:&isDirectory] && isDirectory;
}

NSArray<NSDictionary<NSString *, id> *> *HubCombinedEntries()
{
    NSMutableDictionary<NSString *, NSMutableDictionary *> *byId = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in GXHubCatalogEntries())
    {
        NSString *profileId = entry[@"profileId"];
        if (profileId.length > 0)
            byId[profileId] = [entry mutableCopy];
    }
    for (NSDictionary *installed in GXHubInstalledModEntries())
    {
        NSString *profileId = installed[@"profileId"];
        if (profileId.length == 0)
            continue;

        NSDictionary *catalog = byId[profileId];
        NSMutableDictionary *merged = [installed mutableCopy];
        if (catalog != nil)
        {
            [merged addEntriesFromDictionary:catalog];
        }
        byId[profileId] = merged;
    }
    NSArray *values = byId.allValues;
    return [values sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
}

NSDictionary<NSString *, id> *HubEntryForProfile(NSString *profileId)
{
    for (NSDictionary *entry in HubCombinedEntries())
    {
        if ([entry[@"profileId"] isEqualToString:profileId])
            return entry;
    }
    return nil;
}

BOOL HubVersionAtLeast(NSString *current, NSString *minimum)
{
    if (minimum.length == 0)
        return YES;
    if (current.length == 0)
        return NO;
    return [current compare:minimum options:NSNumericSearch] != NSOrderedAscending;
}

BOOL HubVersionDiffers(NSString *current, NSString *available)
{
    return current.length > 0 && available.length > 0 && ![current isEqualToString:available];
}

BOOL HubVersionIsNewer(NSString *current, NSString *available)
{
    if (current.length == 0 || available.length == 0)
        return NO;
    return [available compare:current options:NSNumericSearch] == NSOrderedDescending;
}

NSString *DefaultIPadOverrides()
{
    return @"GameData\n"
            @"  MaxCameraHeight = 550.0\n"
            @"  MinCameraHeight = 70.0\n"
            @"  CameraPitch = 37.0\n"
            @"  EnforceMaxCameraHeight = No\n"
            @"  KeyboardScrollSpeedFactor = 1.0\n"
            @"  TerrainDrawDistanceScale = 1.20\n"
            @"  UseFPSLimit = Yes\n"
            @"  FramesPerSecondLimit = 60\n"
            @"End\n";
}

void EnsureDefaultIPadOverrides()
{
    NSString *path = IPadOverridesPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:path])
        return;

    NSError *error = nil;
    BOOL ok = [DefaultIPadOverrides() writeToFile:path
                                      atomically:YES
                                        encoding:NSUTF8StringEncoding
                                           error:&error];
    if (ok)
    {
        fprintf(stderr, "INFO: iOS launcher seeded %s\n", path.fileSystemRepresentation);
    }
    else
    {
        fprintf(stderr, "ERROR: iOS launcher failed to seed iPadOverrides.ini: %s\n",
                [[error description] UTF8String]);
    }
}

UIWindowScene *FindActiveWindowScene()
{
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes)
    {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;

        if (scene.activationState == UISceneActivationStateForegroundActive ||
            scene.activationState == UISceneActivationStateForegroundInactive)
        {
            return (UIWindowScene *)scene;
        }
    }

    return nil;
}

NSString *LauncherRussianText(NSString *text)
{
    static NSDictionary<NSString *, NSString *> *translations;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        translations = @{
            // Top-level menu
            @"Hub Settings": @"Настройки Hub",
            @"Enhanced settings": @"Настройки Enhanced",
            @"Contra X settings": @"Настройки Contra X",
            @"Hub settings": @"Настройки Hub",
            @"Diagnostics": @"Диагностика",
            @"Mods & Updates": @"Моды и обновления",
            @"Play Zero Hour Enhanced": @"Запустить Zero Hour Enhanced",
            @"Play Contra X": @"Запустить Contra X",
            @"Generals Online": @"Generals Online",
            @"MODS": @"МОДЫ",
            @"ENHANCED": @"ENHANCED",
            @"CONTRA X": @"CONTRA X",
            @"GRAPHICS": @"ГРАФИКА",
            @"CAMERA / PERFORMANCE": @"КАМЕРА / ПРОИЗВОДИТЕЛЬНОСТЬ",

            // Menu notes
            @"Install and update mods without reinstalling Generals Hub. Choose Stable for normal use or Beta for test releases.": @"Устанавливайте и обновляйте моды без переустановки Generals Hub. Выберите стабильный канал для обычного использования или Beta для тестовых версий.",
            @"Enhanced-only options. Stored separately from Hub and other mods. Changes apply on the next launch.": @"Опции только для Enhanced. Хранятся отдельно от Hub и других модов. Изменения применятся при следующем запуске.",
            @"Contra X-only options. Stored separately from Hub and other mods. Changes apply on the next launch.": @"Опции только для Contra X. Хранятся отдельно от Hub и других модов. Изменения применятся при следующем запуске.",
            @"Shared engine, graphics, camera and performance settings for Online and installed mods.": @"Общие настройки движка, графики, камеры и производительности для Online и установленных модов.",
            @"Build, installed content and crash logs. The last 10 app sessions are kept automatically.": @"Сборка, установленные файлы и журналы сбоев. Последние 10 сессий приложения сохраняются автоматически.",

            // Buttons
            @"Update channel": @"Канал обновлений",
            @"Stable": @"Стабильная",
            @"Beta": @"Бета",
            @"Refresh": @"Обновить",
            @"Import .gxmod": @"Импорт .gxmod",
            @"Back": @"Назад",
            @"Get Hub Update": @"Обновить Hub",
            @"Play": @"Запустить",
            @"Settings": @"Настройки",
            @"Remove": @"Удалить",
            @"Save": @"Сохранить",
            @"Reset defaults": @"Сбросить настройки",
            @"Share report + logs": @"Поделиться отчётом и логами",
            @"Clear logs": @"Очистить логи",
            @"Cancel": @"Отмена",
            @"Install": @"Установить",
            @"Update": @"Обновить",
            @"Downloading…": @"Скачивание…",

            // Empty / status
            @"No mod catalog entries yet. Import a .gxmod package from Files.": @"В каталоге пока нет модов. Импортируйте пакет .gxmod из приложения «Файлы».",
            @"Saved. Changes apply on the next game launch.": @"Сохранено. Изменения применятся при следующем запуске игры.",
            @"Save failed. See generals-stderr.log.": @"Не удалось сохранить. См. generals-stderr.log.",
            @"Default values loaded. Tap Save to apply.": @"Значения по умолчанию загружены. Нажмите «Сохранить» для применения.",
            @"Using camera defaults.": @"Используются параметры камеры по умолчанию.",
            @"Mod settings saved. Changes apply on the next launch.": @"Настройки мода сохранены. Изменения применятся при следующем запуске.",
            @"Mod removed.": @"Мод удалён.",
            @"Wait for the active mod download to finish before switching channels.": @"Дождитесь завершения активной загрузки мода, прежде чем переключать канал.",
            @"Remote catalog is not configured yet. Bundled catalog is active.": @"Удалённый каталог ещё не настроен. Используется встроенный каталог.",
            @"Catalog is up to date.": @"Каталог актуален.",
            @"Import failed.": @"Ошибка импорта.",
            @"Installing .gxmod…": @"Установка .gxmod…",
            @"Clear diagnostic logs?": @"Очистить журналы диагностики?",
            @"This clears the current session log and all saved session logs.": @"Будут удалены журнал текущей сессии и все сохранённые журналы прошлых сессий.",

            // Dynamic format strings
            @"%@ catalog updated.": @"Каталог %@ обновлён.",
            @"Checking %@ updates…": @"Проверка обновлений %@…",
            @"Using %@ channel.": @"Используется канал %@.",
            @"Catalog refresh failed; using cached data: %@": @"Не удалось обновить каталог, используются кэшированные данные: %@",
            @"Downloading %@…": @"Скачивание %@…",
            @"Another download is already running: %@.": @"Уже идёт другая загрузка: %@.",
            @"Preparing %@ download…": @"Подготовка загрузки %@…",
            @"Downloaded %@. Verifying SHA-256 and installing…": @"Загружено %@. Проверка SHA-256 и установка…",
            @"Install failed: %@": @"Ошибка установки: %@",
            @"Remove failed: %@": @"Ошибка удаления: %@",
            @"Import failed: %@": @"Ошибка импорта: %@",
            @"Installed %@ %@.": @"Установлено %@ %@.",

            // Section labels
            @"Faction textures": @"Текстуры фракций",
            @"UI quality": @"Качество интерфейса",
            @"Infantry icons": @"Иконки пехоты",
            @"Cameos": @"Камео",
            @"AI scripts": @"Скрипты ИИ",
            @"Control Bar": @"Панель управления",
            @"Icon / cameo quality": @"Качество иконок / камео",
            @"Music": @"Музыка",
            @"Unit voices": @"Голоса юнитов",
            @"Hotkeys": @"Горячие клавиши",
            @"Hotkey language": @"Язык горячих клавиш",
            @"General portraits": @"Портреты генералов",
            @"Fog effects": @"Эффекты тумана",
            @"Water effects": @"Эффекты воды",
            @"Extra building props": @"Дополнительные объекты зданий",
            @"3D shadows": @"Тени 3D",
            @"2D shadows": @"Тени 2D",
            @"Cloud shadows": @"Тени облаков",
            @"Ground lighting": @"Освещение земли",
            @"Smooth water borders": @"Сглаженные границы воды",
            @"Units behind buildings": @"Юниты за зданиями",
            @"Small props / trees": @"Мелкие объекты / деревья",
            @"Extra animations": @"Дополнительные анимации",
            @"Dynamic LOD": @"Динамический LOD",
            @"Heat effects": @"Эффекты жары",
            @"Engine texture quality": @"Качество текстур",
            @"Particles": @"Частицы",
            @"Texture filtering": @"Фильтрация текстур",
            @"Anisotropy": @"Анизотропия",
            @"MSAA": @"MSAA",
            @"Maximum camera height": @"Максимальная высота камеры",
            @"Minimum camera height": @"Минимальная высота камеры",
            @"Camera pitch": @"Наклон камеры",
            @"Enforce maximum camera height": @"Ограничить максимальную высоту камеры",
            @"Keyboard / edge scroll speed": @"Скорость прокрутки клавиатурой / у края",
            @"Terrain draw distance": @"Дальность прорисовки местности",
            @"FPS limit": @"Ограничение FPS",
            @"Frames per second": @"Кадров в секунду",

            // Enum values
            @"Default": @"По умолчанию",
            @"High": @"Высокое",
            @"Medium": @"Среднее",
            @"Low": @"Низкое",
            @"Bilinear": @"Билинейная",
            @"Trilinear": @"Трилинейная",
            @"Anisotropic": @"Анизотропная",
            @"Off": @"Выкл.",
            @"Original": @"Оригинал",
            @"English": @"Английский",
            @"Native": @"Родной",
            @"Funny": @"Забавные",
            @"Standard": @"Стандарт",
            @"Enhanced": @"Улучшенный",
            @"The Score": @"Саундтрек",
            @"Vanilla": @"Оригинал",
            @"Restrained": @"Ограниченный",
            @"Skynet": @"Скайнет",
            @"Pro": @"Профессиональный",
            @"Russian": @"Русский",
            @"HD": @"HD",
            @"FHD": @"FHD",
            @"QHD": @"QHD",
            @"SD": @"SD",
            @"100%": @"100%",
            @"75%": @"75%",
            @"50%": @"50%",
            @"2x": @"2x",
            @"4x": @"4x",
            @"8x": @"8x",
            @"16x": @"16x",
        };
    });
    NSString *translated = translations[text];
    return translated.length > 0 ? translated : text;
}

UILabel *MakeLabel(NSString *text, CGFloat size, UIFontWeight weight)
{
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = LauncherRussianText(text);
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.numberOfLines = 0;
    return label;
}

UIButton *MakeButton(NSString *title, id target, SEL action)
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:LauncherRussianText(title) forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    button.layer.cornerRadius = 10.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:0.28 alpha:1.0].CGColor;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:58.0].active = YES;
    return button;
}
}

@interface GXProfileLauncherViewController : UIViewController <UIDocumentPickerDelegate, WKScriptMessageHandler, WKNavigationDelegate>
@property(nonatomic, strong) UIStackView *menuStack;
@property(nonatomic, strong) UIButton *modsButton;
@property(nonatomic, strong) UIView *modsView;
@property(nonatomic, strong) UIStackView *modsListStack;
@property(nonatomic, strong) UILabel *modsStatus;
@property(nonatomic, strong) UISegmentedControl *modsChannelSegment;
@property(nonatomic, strong) UIView *settingsView;
@property(nonatomic, strong) UILabel *settingsStatus;
@property(nonatomic, copy) NSString *settingsProfileId;
@property(nonatomic, strong) UISlider *maxCameraSlider;
@property(nonatomic, strong) UISlider *minCameraSlider;
@property(nonatomic, strong) UISlider *cameraPitchSlider;
@property(nonatomic, strong) UISlider *scrollSpeedSlider;
@property(nonatomic, strong) UISlider *drawDistanceSlider;
@property(nonatomic, strong) UISlider *fpsSlider;
@property(nonatomic, strong) UILabel *maxCameraValue;
@property(nonatomic, strong) UILabel *minCameraValue;
@property(nonatomic, strong) UILabel *cameraPitchValue;
@property(nonatomic, strong) UILabel *scrollSpeedValue;
@property(nonatomic, strong) UILabel *drawDistanceValue;
@property(nonatomic, strong) UILabel *fpsValue;
@property(nonatomic, strong) UISwitch *enforceMaxSwitch;
@property(nonatomic, strong) UISwitch *fpsLimitSwitch;

@property(nonatomic, strong) UISegmentedControl *contraControlBarSegment;
@property(nonatomic, strong) UISegmentedControl *contraCameosSegment;
@property(nonatomic, strong) UISegmentedControl *contraMusicSegment;
@property(nonatomic, strong) UISegmentedControl *contraVoicesSegment;
@property(nonatomic, strong) UISegmentedControl *contraHotkeysSegment;
@property(nonatomic, strong) UISegmentedControl *contraHotkeyLanguageSegment;
@property(nonatomic, strong) UISegmentedControl *contraPortraitsSegment;
@property(nonatomic, strong) UISwitch *contraFogSwitch;
@property(nonatomic, strong) UISwitch *contraWaterSwitch;
@property(nonatomic, strong) UISwitch *contraExtraBuildingPropsSwitch;

@property(nonatomic, strong) UISegmentedControl *enhancedTextureResolutionSegment;
@property(nonatomic, strong) UISegmentedControl *enhancedUIQualitySegment;
@property(nonatomic, strong) UISegmentedControl *enhancedInfantryIconScaleSegment;
@property(nonatomic, strong) UISegmentedControl *enhancedCameosSegment;
@property(nonatomic, strong) UISegmentedControl *enhancedAIScriptsSegment;

@property(nonatomic, strong) UISwitch *shadow3DSwitch;
@property(nonatomic, strong) UISwitch *shadow2DSwitch;
@property(nonatomic, strong) UISwitch *cloudShadowsSwitch;
@property(nonatomic, strong) UISwitch *groundLightingSwitch;
@property(nonatomic, strong) UISwitch *softWaterSwitch;
@property(nonatomic, strong) UISwitch *buildingOcclusionSwitch;
@property(nonatomic, strong) UISwitch *showPropsSwitch;
@property(nonatomic, strong) UISwitch *extraAnimationsSwitch;
@property(nonatomic, strong) UISwitch *dynamicLODSwitch;
@property(nonatomic, strong) UISwitch *heatEffectsSwitch;
@property(nonatomic, strong) UISegmentedControl *textureQualitySegment;
@property(nonatomic, strong) UISegmentedControl *particleQualitySegment;
@property(nonatomic, strong) UISegmentedControl *textureFilterSegment;
@property(nonatomic, strong) UISegmentedControl *anisotropySegment;
@property(nonatomic, strong) UISegmentedControl *msaaSegment;

@property(nonatomic, strong) UIView *diagnosticsView;
@property(nonatomic, strong) UILabel *diagnosticsText;
@property(nonatomic, strong) UIButton *shareDiagnosticsButton;
@property(nonatomic, assign) BOOL diagnosticsScanRunning;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, copy) NSString *webLauncherHost;
@property(nonatomic, assign) BOOL webLauncherLoadedRemote;
@property(nonatomic, assign) BOOL webLauncherActive;
@end

void GeneralsXSetIOSDiagnosticClearCallback(GeneralsXIOSDiagnosticClearCallback callback)
{
    gDiagnosticClearCallback = callback;
}

@implementation GXProfileLauncherViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleMemoryWarning:)
                                                 name:UIApplicationDidReceiveMemoryWarningNotification
                                               object:nil];

    self.view.backgroundColor = UIColor.blackColor;
    EnsureDefaultIPadOverrides();

    NSString *bundledProfile = BundledAutoLaunchProfile();
    if ([bundledProfile isEqualToString:@"enhanced"])
    {
        EnsureDefaultEnhancedSettings();
    }
    else if ([bundledProfile isEqualToString:@"contra-x"])
    {
        EnsureDefaultContraSettings();
    }
    else
    {
        if (ProfileDirectoryExists(@"enhanced"))
            EnsureDefaultEnhancedSettings();
        if (ProfileDirectoryExists(@"contra-x"))
            EnsureDefaultContraSettings();
    }

    [self buildMenu];
    [self buildMods];
    [self buildSettings];
    [self buildDiagnostics];

    if (BundledAutoLaunchProfile().length == 0)
    {
        // The main launcher is native and must never depend on network/WebKit.
        // Remote catalog/web content is optional and may refresh in the background.
        self.menuStack.hidden = NO;
        self.modsView.hidden = YES;
        self.settingsView.hidden = YES;
        self.diagnosticsView.hidden = YES;
        self.webLauncherActive = NO;
        [self updateModsUpdatesBadge];
        [self refreshHubCatalog];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    NSString *report = [self diagnosticsTextWithGameDataSize:@"Open Diagnostics to refresh size"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ExportDiagnosticsSnapshot(report);
    });
}

- (void)handleMemoryWarning:(NSNotification *)notification
{
    (void)notification;
    const size_t relievedBytes = malloc_zone_pressure_relief(nullptr, 0);
    fprintf(stderr,
            "[IOS-MEMORY-WARNING] received relievedMB=%.2f\n",
            (double)relievedBytes / (1024.0 * 1024.0));
    fflush(stderr);
}

- (NSDictionary<NSString *, id> *)webLauncherState
{
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *projectVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    NSString *buildVersion = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
    NSString *channel = GXHubCatalogChannel();
    NSDictionary *catalog = GXHubCatalogDocument();

    NSDictionary *onlineEntry = HubEntryForProfile(@"online") ?: @{};
    NSDictionary *onlineInstalledManifest = GXHubInstalledManifest(@"online") ?: @{};
    NSString *onlineInstalledVersion = onlineInstalledManifest[@"version"] ?: @"";
    NSString *onlineAvailableVersion = onlineEntry[@"version"] ?: @"unknown";
    BOOL onlineInstalled = GXHubProfileInstalled(@"online");
    BOOL onlineUpdateAvailable = onlineInstalled && onlineInstalledVersion.length > 0 &&
        HubVersionDiffers(onlineInstalledVersion, onlineAvailableVersion) &&
        [onlineEntry[@"packageURL"] length] > 0;

    NSMutableArray *mods = [NSMutableArray array];
    for (NSDictionary *entry in GXHubCatalogEntries())
    {
        NSString *profileId = entry[@"profileId"] ?: @"";
        if (profileId.length == 0 || [profileId isEqualToString:@"online"])
            continue;
        NSDictionary *installedManifest = GXHubInstalledManifest(profileId);
        NSString *installedVersion = installedManifest[@"version"];
        NSString *availableVersion = entry[@"version"] ?: @"unknown";
        BOOL installed = GXHubProfileInstalled(profileId);
        BOOL updateAvailable = installed && installedVersion.length > 0 &&
            HubVersionDiffers(installedVersion, availableVersion) &&
            [entry[@"packageURL"] length] > 0;

        NSString *sourceURL = @"";
        NSString *author = @"";
        if ([profileId isEqualToString:@"enhanced"])
        {
            sourceURL = @"https://www.moddb.com/mods/cc-generals-zero-hour-enhanced";
            author = @"Acoustic Alpha";
        }
        else if ([profileId isEqualToString:@"contra-x"])
        {
            sourceURL = @"https://www.moddb.com/mods/contra";
            author = @"Contra Mod Team";
        }
        else if ([profileId isEqualToString:@"contra-007"])
        {
            sourceURL = @"https://www.moddb.com/mods/contra/downloads/contra-007";
            author = @"Contra Mod Team";
        }

        [mods addObject:@{
            @"profileId": profileId,
            @"name": entry[@"name"] ?: profileId,
            @"description": entry[@"description"] ?: @"",
            @"version": availableVersion,
            @"installed": @(installed),
            @"installedVersion": installedVersion ?: @"",
            @"updateAvailable": @(updateAvailable),
            @"packageURL": entry[@"packageURL"] ?: @"",
            @"packageBytes": entry[@"packageBytes"] ?: @0,
            @"releaseNotes": entry[@"releaseNotes"] ?: @"",
            @"minHubVersion": entry[@"minHubVersion"] ?: @"",
            @"channel": entry[@"channel"] ?: channel,
            @"requestedChannel": entry[@"requestedChannel"] ?: channel,
            @"fallbackChannel": entry[@"fallbackChannel"] ?: @"",
            @"sourceURL": sourceURL,
            @"author": author,
        }];
    }

    NSDictionary *hubRelease = GXHubHubReleaseForCurrentChannel() ?: @{};
    long long currentBuild = buildVersion.longLongValue;
    long long availableBuild = [hubRelease[@"build"] longLongValue];

    NSDictionary *launcherChannels = [catalog[@"launcherWeb"] isKindOfClass:[NSDictionary class]]
        ? catalog[@"launcherWeb"] : @{};
    NSDictionary *launcherRelease = [launcherChannels[channel] isKindOfClass:[NSDictionary class]]
        ? launcherChannels[channel]
        : ([launcherChannels[@"stable"] isKindOfClass:[NSDictionary class]] ? launcherChannels[@"stable"] : @{});

    return @{
        @"projectVersion": projectVersion,
        @"build": buildVersion,
        @"engineVersion": [NSString stringWithUTF8String:GX_ENGINE_VERSION] ?: @"unknown",
        @"launcherVersion": [NSString stringWithUTF8String:GX_LAUNCHER_VERSION] ?: @"unknown",
        @"launcherWebVersion": launcherRelease[@"version"] ?: @"bundled",
        @"channel": channel,
        @"online": @{
            @"profileId": @"online",
            @"name": onlineEntry[@"name"] ?: @"Zero Hour + Online",
            @"description": onlineEntry[@"description"] ?: @"Classic Zero Hour with Generals Online multiplayer integration.",
            @"installed": @(onlineInstalled),
            @"installedVersion": onlineInstalledVersion,
            @"version": onlineAvailableVersion,
            @"updateAvailable": @(onlineUpdateAvailable),
            @"packageURL": onlineEntry[@"packageURL"] ?: @"",
            @"packageBytes": onlineEntry[@"packageBytes"] ?: @0,
            @"releaseNotes": onlineEntry[@"releaseNotes"] ?: @"",
            @"minHubVersion": onlineEntry[@"minHubVersion"] ?: @"",
            @"channel": onlineEntry[@"channel"] ?: channel,
            @"requestedChannel": onlineEntry[@"requestedChannel"] ?: channel,
            @"fallbackChannel": onlineEntry[@"fallbackChannel"] ?: @"",
        },
        @"mods": mods,
        @"download": GXHubDownloadStatus(),
        @"hubUpdate": @{
            @"available": @(availableBuild > currentBuild),
            @"version": hubRelease[@"version"] ?: @"",
            @"build": hubRelease[@"build"] ?: @0,
            @"packageURL": hubRelease[@"packageURL"] ?: @"",
            @"releaseNotes": hubRelease[@"releaseNotes"] ?: @"",
        },
    };
}

- (void)sendWebEnvelope:(NSDictionary<NSString *, id> *)envelope
{
    if (self.webView == nil || envelope == nil)
        return;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:&error];
    if (data == nil)
        return;
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (json.length == 0)
        return;
    NSString *script = [NSString stringWithFormat:
        @"window.GeneralsXNative&&window.GeneralsXNative._receive(%@);", json];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.webView evaluateJavaScript:script completionHandler:nil];
    });
}

- (void)sendWebResponse:(NSString *)requestId result:(id)result error:(NSString *)errorText
{
    if (requestId.length == 0)
        return;
    [self sendWebEnvelope:@{
        @"type": @"response",
        @"id": requestId,
        @"ok": @(errorText.length == 0),
        @"result": result ?: [NSNull null],
        @"error": errorText ?: @"",
    }];
}

- (void)sendWebEvent:(NSString *)name payload:(id)payload
{
    if (name.length == 0)
        return;
    [self sendWebEnvelope:@{
        @"type": @"event",
        @"name": name,
        @"payload": payload ?: [NSNull null],
    }];
}

- (NSURL *)bundledWebLauncherURL
{
    NSString *path = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Launcher/index.html"];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? [NSURL fileURLWithPath:path] : nil;
}

- (NSURL *)remoteWebLauncherURL
{
    // The native iOS launcher always opens the live Render web launcher.
    // The internal bridge name remains "generalsX"; only the visible launcher
    // is served from the Render static site.
    NSString *urlText = @"https://generals-zh-launcher.onrender.com/index.html";
    NSURL *url = [NSURL URLWithString:urlText];
    if (![url.scheme isEqualToString:@"https"] || url.host.length == 0)
    {
        fprintf(stderr, "[HUB-WEB] invalid Render launcher URL\n");
        return nil;
    }

    fprintf(stderr, "[HUB-WEB] using Render launcher: %s\n", url.absoluteString.UTF8String);
    return url;
}

- (void)loadBundledWebLauncher
{
    NSURL *local = [self bundledWebLauncherURL];
    if (local == nil)
        return;
    self.webLauncherLoadedRemote = NO;
    self.webLauncherHost = @"";
    NSURL *root = [local URLByDeletingLastPathComponent];
    [self.webView loadFileURL:local allowingReadAccessToURL:root];
    fprintf(stderr, "[HUB-WEB] loading bundled launcher path='%s'\n", local.path.UTF8String);
}

- (NSString *)russianWebLauncherScript
{
    return @"(function(){const map={'Settings':'Настройки','Graphics':'Графика','Diagnostics':'Диагностика','Friends':'Друзья','Online':'Онлайн','LAN':'LAN','Start Game':'Запустить игру','Play':'Играть','Install':'Установить','Installed':'Установлено','Update':'Обновить','Download':'Скачать','Refresh':'Обновить','Save':'Сохранить','Reset':'Сбросить','Cancel':'Отмена','Back':'Назад','Remove':'Удалить','Close':'Закрыть','Mods':'Моды','Mods & Updates':'Моды и обновления','Add mod':'Добавить мод','Clear logs':'Очистить логи','Share report + logs':'Поделиться отчётом и логами','Save to Files':'Сохранить в Файлы','Page actions':'Действия страницы','Stable':'Стабильная','Beta':'Бета','Current':'Текущая','READY':'ГОТОВО','NOT INSTALLED':'НЕ УСТАНОВЛЕНО','Downloading':'Скачивание','Updating':'Обновление','Download complete':'Скачивание завершено','Download failed':'Ошибка скачивания','Camera / Performance':'Камера / производительность','Maximum camera height':'Максимальная высота камеры','Minimum camera height':'Минимальная высота камеры','Camera pitch':'Наклон камеры','Keyboard / edge scroll speed':'Скорость прокрутки клавиатурой / у края','Terrain draw distance':'Дальность прорисовки местности','FPS limit':'Ограничение FPS','Frames per second':'Кадров в секунду','3D shadows':'Тени 3D','2D shadows':'Тени 2D','Cloud shadows':'Тени облаков','Ground lighting':'Освещение земли','Smooth water borders':'Сглаженные границы воды','Units behind buildings':'Юниты за зданиями','Small props / trees':'Мелкие объекты / деревья','Extra animations':'Дополнительные анимации','Dynamic LOD':'Динамический LOD','Heat effects':'Эффекты жары','Texture quality':'Качество текстур','Particles':'Частицы','Texture filtering':'Фильтрация текстур','Anisotropy':'Анизотропия','English':'Английский','Russian':'Русский','Default':'По умолчанию','High':'Высокое','Medium':'Среднее','Low':'Низкое','Standard':'Стандарт','Enhanced':'Улучшенный','Original':'Оригинал','Native':'Родной','Funny':'Забавные','Off':'Выкл.','Bilinear':'Билинейная','Trilinear':'Трилинейная','Anisotropic':'Анизотропная'};function tr(n){if(n.nodeType===3){const v=n.nodeValue.trim();if(map[v])n.nodeValue=n.nodeValue.replace(v,map[v]);return;}if(n.nodeType!==1)return;['title','aria-label','placeholder'].forEach(a=>{const v=n.getAttribute(a);if(v&&map[v])n.setAttribute(a,map[v]);});n.childNodes&&n.childNodes.forEach(tr);}function run(){if(document.body)tr(document.body);}run();new MutationObserver(run).observe(document.documentElement,{childList:true,subtree:true,characterData:true});})();";
}
- (void)buildWebLauncher
{
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    [configuration.userContentController addScriptMessageHandler:self name:@"generalsX"];
    WKUserScript *russianScript = [[WKUserScript alloc]
        initWithSource:[self russianWebLauncherScript]
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:NO];
    [configuration.userContentController addUserScript:russianScript];

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.navigationDelegate = self;
    self.webView.backgroundColor = UIColor.blackColor;
    self.webView.opaque = NO;
    self.webView.scrollView.bounces = NO;
    self.webView.scrollView.minimumZoomScale = 1.0;
    self.webView.scrollView.maximumZoomScale = 1.0;
    self.webView.scrollView.pinchGestureRecognizer.enabled = NO;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.webLauncherActive = YES;
    [self.view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    NSURL *remote = [self remoteWebLauncherURL];
    if (remote != nil)
    {
        self.webLauncherLoadedRemote = YES;
        self.webLauncherHost = remote.host ?: @"";
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:remote
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:20.0];
        [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
        [self.webView loadRequest:request];
        fprintf(stderr, "[HUB-WEB] loading remote launcher url='%s'\n", remote.absoluteString.UTF8String);
    }
    else
    {
        [self loadBundledWebLauncher];
    }
}

- (BOOL)isTrustedWebMessage:(WKScriptMessage *)message
{
    NSURL *url = message.webView.URL;
    if (url.isFileURL)
        return YES;
    return [url.scheme isEqualToString:@"https"] &&
           self.webLauncherHost.length > 0 &&
           [url.host isEqualToString:self.webLauncherHost];
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    (void)userContentController;
    if (![message.name isEqualToString:@"generalsX"] || ![self isTrustedWebMessage:message])
    {
        fprintf(stderr, "[HUB-WEB] rejected untrusted bridge message\n");
        return;
    }
    if (![message.body isKindOfClass:[NSDictionary class]])
        return;

    NSDictionary *body = (NSDictionary *)message.body;
    NSString *requestId = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : @"";
    NSString *action = [body[@"action"] isKindOfClass:[NSString class]] ? body[@"action"] : @"";
    NSDictionary *payload = [body[@"payload"] isKindOfClass:[NSDictionary class]] ? body[@"payload"] : @{};

    if ([action isEqualToString:@"getState"])
    {
        [self sendWebResponse:requestId result:[self webLauncherState] error:nil];
        return;
    }

    if ([action isEqualToString:@"haptic"])
    {
        NSString *style = [payload[@"style"] isKindOfClass:[NSString class]] ? payload[@"style"] : @"light";
        if ([style isEqualToString:@"selection"])
        {
            UISelectionFeedbackGenerator *generator = [[UISelectionFeedbackGenerator alloc] init];
            [generator prepare];
            [generator selectionChanged];
        }
        else if ([style isEqualToString:@"success"])
        {
            UINotificationFeedbackGenerator *generator = [[UINotificationFeedbackGenerator alloc] init];
            [generator prepare];
            [generator notificationOccurred:UINotificationFeedbackTypeSuccess];
        }
        else
        {
            UIImpactFeedbackStyle impactStyle = UIImpactFeedbackStyleLight;
            if ([style isEqualToString:@"medium"]) impactStyle = UIImpactFeedbackStyleMedium;
            else if ([style isEqualToString:@"heavy"]) impactStyle = UIImpactFeedbackStyleHeavy;
            else if (@available(iOS 13.0, *))
            {
                if ([style isEqualToString:@"soft"]) impactStyle = UIImpactFeedbackStyleSoft;
                else if ([style isEqualToString:@"rigid"]) impactStyle = UIImpactFeedbackStyleRigid;
            }
            UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:impactStyle];
            [generator prepare];
            [generator impactOccurred];
        }
        [self sendWebResponse:requestId result:@{ @"accepted": @YES } error:nil];
        return;
    }

    if ([action isEqualToString:@"play"])
    {
        NSString *profileId = [payload[@"profileId"] isKindOfClass:[NSString class]] ? payload[@"profileId"] : @"";
        BOOL baseInstalled = GXHubProfileInstalled(@"online");
        NSDictionary *catalogEntry = profileId.length > 0 ? HubEntryForProfile(profileId) : nil;
        BOOL selectedInstalled = [profileId isEqualToString:@"online"]
            ? baseInstalled
            : (catalogEntry != nil && GXHubProfileInstalled(profileId));
        fprintf(stderr,
                "[HUB-PLAY] profile='%s' baseInstalled=%d selectedInstalled=%d catalogEntry=%d\n",
                profileId.UTF8String,
                baseInstalled ? 1 : 0,
                selectedInstalled ? 1 : 0,
                catalogEntry != nil ? 1 : 0);
        if (baseInstalled && selectedInstalled)
        {
            [self sendWebResponse:requestId result:@{ @"accepted": @YES } error:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SetSelectedProfile(profileId);
            });
        }
        else
        {
            NSString *message = baseInstalled
                ? @"Профиль не установлен."
                : @"Базовый контент Zero Hour + Online не установлен.";
            [self sendWebResponse:requestId result:nil error:message];
        }
        return;
    }

    if ([action isEqualToString:@"install"])
    {
        NSString *profileId = payload[@"profileId"];
        NSDictionary *entry = HubEntryForProfile(profileId);
        if (entry == nil)
        {
            [self sendWebResponse:requestId result:nil error:@"Профиль недоступен в текущем канале каталога."];
            return;
        }
        if (GXHubDownloadBusy())
        {
            [self sendWebResponse:requestId result:nil error:[NSString stringWithFormat:@"%@ уже загружается.", GXHubActiveDownloadProfile() ?: @"Другой мод"]];
            return;
        }

        [self sendWebResponse:requestId result:@{ @"accepted": @YES, @"profileId": profileId ?: @"" } error:nil];
        __weak GXProfileLauncherViewController *weakSelf = self;
        GXHubDownloadAndInstallWithProgress(
            entry,
            ^(long long received, long long total, double fraction) {
                GXProfileLauncherViewController *strongSelf = weakSelf;
                if (strongSelf == nil)
                    return;
                NSMutableDictionary *downloadPayload = [GXHubDownloadStatus() mutableCopy];
                downloadPayload[@"profileId"] = profileId ?: @"";
                downloadPayload[@"received"] = @(received);
                downloadPayload[@"total"] = @(total);
                downloadPayload[@"fraction"] = @(fraction);
                [strongSelf sendWebEvent:@"downloadProgress" payload:downloadPayload];
            },
            ^(NSDictionary *manifest, NSError *error) {
                GXProfileLauncherViewController *strongSelf = weakSelf;
                if (strongSelf == nil)
                    return;
                if (error != nil)
                {
                    BOOL cancelled = [error.domain isEqualToString:@"GeneralsXHub"] && error.code == 189;
                    [strongSelf sendWebEvent:cancelled ? @"downloadCancelled" : @"installError" payload:@{
                        @"profileId": profileId ?: @"",
                        @"error": error.localizedDescription ?: (cancelled ? @"Загрузка отменена" : @"Ошибка установки"),
                    }];
                }
                else
                {
                    [strongSelf sendWebEvent:@"installComplete" payload:@{
                        @"profileId": profileId ?: @"",
                        @"manifest": manifest ?: @{},
                    }];
                }
                [strongSelf sendWebEvent:@"stateChanged" payload:[strongSelf webLauncherState]];
            });
        return;
    }

    if ([action isEqualToString:@"pauseDownload"] ||
        [action isEqualToString:@"resumeDownload"] ||
        [action isEqualToString:@"cancelDownload"])
    {
        NSString *profileId = [payload[@"profileId"] isKindOfClass:[NSString class]]
            ? payload[@"profileId"] : @"";
        NSError *downloadError = nil;
        BOOL ok = NO;
        if ([action isEqualToString:@"pauseDownload"])
            ok = GXHubPauseDownload(profileId, &downloadError);
        else if ([action isEqualToString:@"resumeDownload"])
            ok = GXHubResumeDownload(profileId, &downloadError);
        else
            ok = GXHubCancelDownload(profileId, &downloadError);

        if (!ok)
        {
            [self sendWebResponse:requestId result:nil
                           error:downloadError.localizedDescription ?: @"Не удалось выполнить действие."];
            return;
        }
        NSDictionary *state = [self webLauncherState];
        [self sendWebResponse:requestId result:state error:nil];
        [self sendWebEvent:@"stateChanged" payload:state];
        return;
    }

    if ([action isEqualToString:@"remove"])
    {
        NSString *profileId = payload[@"profileId"];
        NSError *error = nil;
        if (!GXHubRemoveMod(profileId, &error))
        {
            [self sendWebResponse:requestId result:nil error:error.localizedDescription ?: @"Не удалось удалить."];
            return;
        }
        [self sendWebResponse:requestId result:[self webLauncherState] error:nil];
        [self sendWebEvent:@"stateChanged" payload:[self webLauncherState]];
        return;
    }

    if ([action isEqualToString:@"refreshCatalog"] || [action isEqualToString:@"setChannel"])
    {
        if ([action isEqualToString:@"setChannel"])
        {
            NSString *channel = payload[@"channel"];
            GXHubSetCatalogChannel(channel);
        }
        __weak GXProfileLauncherViewController *weakSelf = self;
        GXHubRefreshRemoteCatalog(^(BOOL updated, NSError *error) {
            GXProfileLauncherViewController *strongSelf = weakSelf;
            if (strongSelf == nil)
                return;
            if (error != nil)
                [strongSelf sendWebResponse:requestId result:nil error:error.localizedDescription];
            else
                [strongSelf sendWebResponse:requestId result:[strongSelf webLauncherState] error:nil];
            if (updated)
                [strongSelf sendWebEvent:@"stateChanged" payload:[strongSelf webLauncherState]];
        });
        return;
    }

    if ([action isEqualToString:@"diagnostics"])
    {
        NSString *gameDataPath = GXHubInstalledProfilePath(@"online");
        BOOL exists = GXHubProfileInstalled(@"online");
        __weak GXProfileLauncherViewController *weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            unsigned long long bytes = exists ? DirectorySizeAtPath(gameDataPath) : 0;
            NSString *sizeText = exists ? HumanReadableBytes(bytes) : @"н/д";
            dispatch_async(dispatch_get_main_queue(), ^{
                GXProfileLauncherViewController *strongSelf = weakSelf;
                if (strongSelf != nil)
                {
                    NSString *report = [strongSelf diagnosticsTextWithGameDataSize:sizeText] ?: @"";
                    strongSelf.diagnosticsText.text = report;
                    ExportDiagnosticsSnapshot(report);
                    [strongSelf sendWebResponse:requestId
                                        result:@{ @"report": report,
                                                  @"exportPath": @"Файлы > На моём iPad > Generals ZH > Diagnostics" }
                                         error:nil];
                }
            });
        });
        return;
    }

    if ([action isEqualToString:@"exportDiagnostics"])
    {
        NSString *report = [self diagnosticsTextWithGameDataSize:@"Откройте «Диагностика» для обновления размера"] ?: @"";
        self.diagnosticsText.text = report;
        NSArray<NSURL *> *files = ExportDiagnosticsSnapshot(report);
        [self sendWebResponse:requestId
                      result:@{ @"accepted": @YES,
                                @"fileCount": @(files.count),
                                @"path": @"Файлы > На моём iPad > Generals ZH > Diagnostics" }
                       error:nil];
        return;
    }

    if ([action isEqualToString:@"shareDiagnostics"])
    {
        [self shareDiagnostics];
        [self sendWebResponse:requestId result:@{ @"accepted": @YES } error:nil];
        return;
    }

    if ([action isEqualToString:@"clearDiagnostics"])
    {
        [self clearDiagnosticsLogs];
        [self sendWebResponse:requestId result:@{ @"accepted": @YES } error:nil];
        return;
    }

    if ([action isEqualToString:@"settingsGet"])
    {
        NSString *profileId = [payload[@"profileId"] isKindOfClass:[NSString class]] ? payload[@"profileId"] : @"online";
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        if ([profileId isEqualToString:@"enhanced"])
        {
            EnsureDefaultEnhancedSettings();
            NSDictionary *raw = ReadKeyValueFile(EnhancedSettingsPath());
            values[@"textureResolution"] = SettingValue(raw, @"TextureResolution", @"High");
            values[@"uiQuality"] = SettingValue(raw, @"UIQuality", @"FHD");
            NSString *scale = SettingValue(raw, @"InfantryIconScale", @"100");
            values[@"infantryIconScale"] = [scale stringByAppendingString:@"%"];
            values[@"cameos"] = SettingValue(raw, @"Cameos", @"HD");
            values[@"aiScripts"] = SettingValue(raw, @"AIScripts", @"Default");
        }
        else if ([profileId isEqualToString:@"contra-x"])
        {
            EnsureDefaultContraSettings();
            NSDictionary *raw = ReadKeyValueFile(ContraSettingsPath());
            values[@"controlBar"] = SettingValue(raw, @"ControlBar", @"Contra");
            values[@"cameos"] = SettingValue(raw, @"Cameos", @"Standard");
            values[@"music"] = SettingValue(raw, @"Music", @"Standard");
            values[@"voices"] = SettingValue(raw, @"UnitVoices", @"English");
            values[@"hotkeys"] = SettingValue(raw, @"Hotkeys", @"Original");
            values[@"hotkeyLanguage"] = SettingValue(raw, @"HotkeyLanguage", @"English");
            values[@"portraits"] = SettingValue(raw, @"Portraits", @"Standard");
            values[@"fogEffects"] = @(SettingBoolValue(raw, @"FogEffects", NO));
            values[@"waterEffects"] = @(SettingBoolValue(raw, @"WaterEffects", YES));
            values[@"extraBuildingProps"] = @(SettingBoolValue(raw, @"ExtraBuildingProps", YES));
        }
        else
        {
            NSDictionary *options = ReadKeyValueFile(EngineOptionsPath());
            NSString *camera = [NSString stringWithContentsOfFile:IPadOverridesPath() encoding:NSUTF8StringEncoding error:nil] ?: DefaultIPadOverrides();
            values[@"shadow3D"] = @(SettingBoolValue(options, @"UseShadowVolumes", NO));
            values[@"shadow2D"] = @(SettingBoolValue(options, @"UseShadowDecals", YES));
            values[@"cloudShadows"] = @(SettingBoolValue(options, @"UseCloudMap", NO));
            values[@"groundLighting"] = @(SettingBoolValue(options, @"UseLightMap", YES));
            values[@"softWater"] = @(SettingBoolValue(options, @"ShowSoftWaterEdge", YES));
            values[@"buildingOcclusion"] = @(SettingBoolValue(options, @"BuildingOcclusion", YES));
            values[@"showProps"] = @(SettingBoolValue(options, @"ShowTrees", YES));
            values[@"extraAnimations"] = @(SettingBoolValue(options, @"ExtraAnimations", YES));
            values[@"dynamicLOD"] = @(SettingBoolValue(options, @"DynamicLOD", NO));
            values[@"heatEffects"] = @(SettingBoolValue(options, @"HeatEffects", NO));
            NSInteger textureReduction = [SettingValue(options, @"TextureReduction", @"0") integerValue];
            values[@"textureQuality"] = textureReduction <= 0 ? @"High" : (textureReduction == 1 ? @"Medium" : @"Low");
            NSInteger particles = [SettingValue(options, @"MaxParticleCount", @"2500") integerValue];
            values[@"particles"] = particles <= 1000 ? @"Low" : (particles >= 5000 ? @"High" : @"Medium");
            values[@"textureFilter"] = SettingValue(options, @"TextureFilter", @"Anisotropic");
            values[@"anisotropy"] = [NSString stringWithFormat:@"%@x", SettingValue(options, @"AnisotropyLevel", @"8")];
            NSString *aa = SettingValue(options, @"AntiAliasing", @"0");
            values[@"msaa"] = [aa isEqualToString:@"0"] ? @"Off" : [aa stringByAppendingString:@"x"];
            values[@"maxCamera"] = @([self floatSetting:@"MaxCameraHeight" contents:camera fallback:550.0f]);
            values[@"minCamera"] = @([self floatSetting:@"MinCameraHeight" contents:camera fallback:70.0f]);
            values[@"cameraPitch"] = @([self floatSetting:@"CameraPitch" contents:camera fallback:37.0f]);
            values[@"enforceMax"] = @([self boolSetting:@"EnforceMaxCameraHeight" contents:camera fallback:NO]);
            values[@"scrollSpeed"] = @([self floatSetting:@"KeyboardScrollSpeedFactor" contents:camera fallback:1.0f]);
            values[@"drawDistance"] = @([self floatSetting:@"TerrainDrawDistanceScale" contents:camera fallback:1.20f]);
            values[@"fpsLimit"] = @([self boolSetting:@"UseFPSLimit" contents:camera fallback:YES]);
            values[@"fps"] = @([self floatSetting:@"FramesPerSecondLimit" contents:camera fallback:60.0f]);
        }
        [self sendWebResponse:requestId result:@{ @"profileId": profileId, @"values": values } error:nil];
        return;
    }

    if ([action isEqualToString:@"settingsSave"])
    {
        NSString *profileId = [payload[@"profileId"] isKindOfClass:[NSString class]] ? payload[@"profileId"] : @"online";
        NSDictionary *values = [payload[@"values"] isKindOfClass:[NSDictionary class]] ? payload[@"values"] : @{};
        NSString *(^stringValue)(NSString *, NSString *) = ^NSString *(NSString *key, NSString *fallback) {
            id value = values[key];
            return [value isKindOfClass:[NSString class]] ? value : fallback;
        };
        BOOL (^boolValue)(NSString *, BOOL) = ^BOOL(NSString *key, BOOL fallback) {
            id value = values[key];
            return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
        };
        double (^numberValue)(NSString *, double) = ^double(NSString *key, double fallback) {
            id value = values[key];
            return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
        };
        NSError *saveError = nil;
        BOOL ok = YES;
        if ([profileId isEqualToString:@"enhanced"])
        {
            NSMutableDictionary *out = [DefaultEnhancedSettings() mutableCopy];
            out[@"TextureResolution"] = stringValue(@"textureResolution", @"High");
            out[@"UIQuality"] = stringValue(@"uiQuality", @"FHD");
            NSString *scale = [stringValue(@"infantryIconScale", @"100%") stringByReplacingOccurrencesOfString:@"%" withString:@""];
            out[@"InfantryIconScale"] = scale;
            out[@"Cameos"] = stringValue(@"cameos", @"HD");
            out[@"AIScripts"] = stringValue(@"aiScripts", @"Default");
            ok = WriteKeyValueFile(EnhancedSettingsPath(), out, &saveError);
        }
        else if ([profileId isEqualToString:@"contra-x"])
        {
            NSMutableDictionary *out = [DefaultContraSettings() mutableCopy];
            out[@"ControlBar"] = stringValue(@"controlBar", @"Contra");
            out[@"Cameos"] = stringValue(@"cameos", @"Standard");
            out[@"Music"] = stringValue(@"music", @"Standard");
            out[@"UnitVoices"] = stringValue(@"voices", @"English");
            out[@"Hotkeys"] = stringValue(@"hotkeys", @"Original");
            out[@"HotkeyLanguage"] = stringValue(@"hotkeyLanguage", @"English");
            out[@"Portraits"] = stringValue(@"portraits", @"Standard");
            out[@"FogEffects"] = boolValue(@"fogEffects", NO) ? @"Yes" : @"No";
            out[@"WaterEffects"] = boolValue(@"waterEffects", YES) ? @"Yes" : @"No";
            out[@"ExtraBuildingProps"] = boolValue(@"extraBuildingProps", YES) ? @"Yes" : @"No";
            ok = WriteKeyValueFile(ContraSettingsPath(), out, &saveError);
        }
        else
        {
            NSString *camera = [NSString stringWithFormat:
                @"GameData\n"
                 "  MaxCameraHeight = %.1f\n"
                 "  MinCameraHeight = %.1f\n"
                 "  CameraPitch = %.1f\n"
                 "  EnforceMaxCameraHeight = %@\n"
                 "  KeyboardScrollSpeedFactor = %.1f\n"
                 "  TerrainDrawDistanceScale = %.2f\n"
                 "  UseFPSLimit = %@\n"
                 "  FramesPerSecondLimit = %.0f\n"
                 "End\n",
                numberValue(@"maxCamera", 550.0),
                numberValue(@"minCamera", 70.0),
                numberValue(@"cameraPitch", 37.0),
                boolValue(@"enforceMax", NO) ? @"Yes" : @"No",
                numberValue(@"scrollSpeed", 1.0),
                numberValue(@"drawDistance", 1.20),
                boolValue(@"fpsLimit", YES) ? @"Yes" : @"No",
                numberValue(@"fps", 60.0)];
            ok = [camera writeToFile:IPadOverridesPath() atomically:YES encoding:NSUTF8StringEncoding error:&saveError];
            NSMutableDictionary *options = ReadKeyValueFile(EngineOptionsPath());
            options[@"IdealStaticGameLOD"] = @"High";
            options[@"StaticGameLOD"] = @"Custom";
            options[@"UseShadowVolumes"] = boolValue(@"shadow3D", NO) ? @"Yes" : @"No";
            options[@"UseShadowDecals"] = boolValue(@"shadow2D", YES) ? @"Yes" : @"No";
            options[@"UseCloudMap"] = boolValue(@"cloudShadows", NO) ? @"Yes" : @"No";
            options[@"UseLightMap"] = boolValue(@"groundLighting", YES) ? @"Yes" : @"No";
            options[@"ShowSoftWaterEdge"] = boolValue(@"softWater", YES) ? @"Yes" : @"No";
            options[@"BuildingOcclusion"] = boolValue(@"buildingOcclusion", YES) ? @"Yes" : @"No";
            options[@"ShowTrees"] = boolValue(@"showProps", YES) ? @"Yes" : @"No";
            options[@"ExtraAnimations"] = boolValue(@"extraAnimations", YES) ? @"Yes" : @"No";
            options[@"DynamicLOD"] = boolValue(@"dynamicLOD", NO) ? @"Yes" : @"No";
            options[@"HeatEffects"] = boolValue(@"heatEffects", NO) ? @"Yes" : @"No";
            NSString *quality = stringValue(@"textureQuality", @"High");
            options[@"TextureReduction"] = [quality isEqualToString:@"High"] ? @"0" : ([quality isEqualToString:@"Medium"] ? @"1" : @"2");
            NSString *particles = stringValue(@"particles", @"Medium");
            options[@"MaxParticleCount"] = [particles isEqualToString:@"Low"] ? @"1000" : ([particles isEqualToString:@"High"] ? @"5000" : @"2500");
            options[@"TextureFilter"] = stringValue(@"textureFilter", @"Anisotropic");
            options[@"AnisotropyLevel"] = [stringValue(@"anisotropy", @"8x") stringByReplacingOccurrencesOfString:@"x" withString:@""];
            NSString *msaa = stringValue(@"msaa", @"Off");
            options[@"AntiAliasing"] = [msaa isEqualToString:@"Off"] ? @"0" : [msaa stringByReplacingOccurrencesOfString:@"x" withString:@""];
            if (ok) ok = WriteKeyValueFile(EngineOptionsPath(), options, &saveError);
        }
        if (!ok)
        {
            [self sendWebResponse:requestId result:nil error:saveError.localizedDescription ?: @"Не удалось сохранить настройки."];
            return;
        }
        fprintf(stderr, "[HUB-SETTINGS] web saved profile='%s'\n", profileId.UTF8String);
        [self sendWebResponse:requestId result:@{ @"accepted": @YES } error:nil];
        return;
    }

    if ([action isEqualToString:@"settings"])
    {
        NSString *profileId = payload[@"profileId"];
        self.webView.hidden = YES;
        if ([profileId isEqualToString:@"enhanced"] || [profileId isEqualToString:@"contra-x"])
        {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.accessibilityIdentifier = profileId;
            [self showHubModSettings:button];
        }
        else
        {
            [self showSettings];
        }
        [self sendWebResponse:requestId result:@{ @"accepted": @YES } error:nil];
        return;
    }

    if ([action isEqualToString:@"chooseFile"])
    {
        [self importModPackage];
        [self sendWebResponse:requestId result:@{ @"accepted": @YES } error:nil];
        return;
    }

    if ([action isEqualToString:@"openURL"])
    {
        NSURL *url = [NSURL URLWithString:[payload[@"url"] isKindOfClass:[NSString class]] ? payload[@"url"] : @""];
        if ([url.scheme isEqualToString:@"https"])
        {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
            [self sendWebResponse:requestId result:@{ @"accepted": @YES } error:nil];
        }
        else
        {
            [self sendWebResponse:requestId result:nil error:@"Разрешены только ссылки HTTPS."];
        }
        return;
    }

    [self sendWebResponse:requestId result:nil error:[NSString stringWithFormat:@"Неизвестное действие моста: %@", action]];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    (void)webView;
    (void)navigation;
    fprintf(stderr, "[HUB-WEB] navigation-failed remote=%d error='%s'\n",
            self.webLauncherLoadedRemote ? 1 : 0,
            error.localizedDescription.UTF8String);
    if (self.webLauncherLoadedRemote)
        [self loadBundledWebLauncher];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    [self webView:webView didFailProvisionalNavigation:navigation withError:error];
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
 decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    (void)webView;
    NSURL *url = navigationAction.request.URL;
    if (url == nil)
    {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    BOOL trusted = url.isFileURL ||
        ([url.scheme isEqualToString:@"https"] && self.webLauncherHost.length > 0 && [url.host isEqualToString:self.webLauncherHost]);
    if (trusted)
    {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if ([url.scheme isEqualToString:@"https"])
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    decisionHandler(WKNavigationActionPolicyCancel);
}

- (void)buildMenu
{
    NSString *bundledProfile = BundledAutoLaunchProfile();
    BOOL dedicatedEnhanced = [bundledProfile isEqualToString:@"enhanced"];
    BOOL dedicatedContra = [bundledProfile isEqualToString:@"contra-x"];

    NSString *titleText = dedicatedEnhanced ? @"ZERO HOUR ENHANCED"
        : (dedicatedContra ? @"CONTRA X" : @"GENERALS ZH");
    NSString *subtitleText = dedicatedEnhanced ? @"v1.0 + патч 28/03/2024 · iPad"
        : (dedicatedContra ? @"Beta 2 + Patch 1 · iPad" : @"НАТИВНЫЙ КОМАНДНЫЙ ЦЕНТР · iOS / iPad");

    UILabel *eyebrow = MakeLabel(@"КОМАНДНЫЙ ЦЕНТР", 12.0, UIFontWeightBold);
    eyebrow.textColor = [UIColor colorWithRed:0.25 green:0.58 blue:1.0 alpha:1.0];

    UILabel *title = MakeLabel(titleText, 38.0, UIFontWeightBold);
    title.textAlignment = NSTextAlignmentLeft;

    UILabel *subtitle = MakeLabel(subtitleText, 14.0, UIFontWeightRegular);
    subtitle.textAlignment = NSTextAlignmentLeft;
    subtitle.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];

    UIView *hero = [[UIView alloc] init];
    hero.translatesAutoresizingMaskIntoConstraints = NO;
    hero.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];
    hero.layer.cornerRadius = 18.0;
    hero.layer.borderWidth = 1.0;
    hero.layer.borderColor = [UIColor colorWithWhite:0.18 alpha:1.0].CGColor;

    UILabel *heroKicker = MakeLabel(@"ВЫБЕРИТЕ РЕЖИМ", 11.0, UIFontWeightBold);
    heroKicker.textAlignment = NSTextAlignmentLeft;
    heroKicker.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];

    UILabel *modeTitle = MakeLabel(
        dedicatedEnhanced ? @"Zero Hour Enhanced" :
        (dedicatedContra ? @"Contra X" : @"Zero Hour + Онлайн"),
        27.0,
        UIFontWeightBold);
    modeTitle.textAlignment = NSTextAlignmentLeft;

    UILabel *modeDescription = MakeLabel(
        dedicatedEnhanced ? @"Улучшенный профиль Zero Hour."
        : (dedicatedContra ? @"Contra X Beta 2 + Patch 1." :
           @"Классический Zero Hour со встроенной сетевой игрой."),
        14.0,
        UIFontWeightRegular);
    modeDescription.textAlignment = NSTextAlignmentLeft;
    modeDescription.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];

    UILabel *statusCaption = MakeLabel(@"СТАТУС", 10.0, UIFontWeightBold);
    statusCaption.textAlignment = NSTextAlignmentLeft;
    statusCaption.textColor = [UIColor colorWithWhite:0.48 alpha:1.0];

    BOOL baseInstalled = GXHubProfileInstalled(@"online");
    UILabel *status = MakeLabel(baseInstalled ? @"ГОТОВО" : @"НЕ УСТАНОВЛЕНО", 14.0, UIFontWeightBold);
    status.textAlignment = NSTextAlignmentLeft;
    status.textColor = baseInstalled ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];

    UIButton *play = MakeButton(
        dedicatedEnhanced ? @"ИГРАТЬ · ENHANCED" :
        (dedicatedContra ? @"ИГРАТЬ · CONTRA X" : @"ИГРАТЬ"),
        self,
        dedicatedEnhanced ? @selector(launchEnhanced) :
        (dedicatedContra ? @selector(launchContra) : @selector(launchOnline)));
    play.backgroundColor = [UIColor colorWithRed:0.16 green:0.45 blue:0.88 alpha:1.0];
    play.layer.borderColor = [UIColor colorWithRed:0.32 green:0.65 blue:1.0 alpha:1.0].CGColor;
    [play.widthAnchor constraintEqualToConstant:320.0].active = YES;

    UIButton *settings = MakeButton(@"НАСТРОЙКИ", self, @selector(showSettings));
    UIButton *diagnostics = MakeButton(@"ДИАГНОСТИКА", self, @selector(showDiagnostics));
    UIButton *mods = MakeButton(@"МОДЫ И ОБНОВЛЕНИЯ", self, @selector(showMods));
    [settings.widthAnchor constraintEqualToConstant:230.0].active = YES;
    [diagnostics.widthAnchor constraintEqualToConstant:230.0].active = YES;
    [mods.widthAnchor constraintEqualToConstant:230.0].active = YES;
    settings.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    diagnostics.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    mods.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    self.modsButton = mods;

    UIStackView *statusRow = [[UIStackView alloc] initWithArrangedSubviews:@[statusCaption, status]];
    statusRow.axis = UILayoutConstraintAxisHorizontal;
    statusRow.alignment = UIStackViewAlignmentCenter;
    statusRow.spacing = 10.0;

    UIStackView *heroStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        heroKicker, modeTitle, modeDescription, statusRow, play
    ]];
    heroStack.translatesAutoresizingMaskIntoConstraints = NO;
    heroStack.axis = UILayoutConstraintAxisVertical;
    heroStack.alignment = UIStackViewAlignmentFill;
    heroStack.spacing = 9.0;
    heroStack.layoutMargins = UIEdgeInsetsMake(20.0, 22.0, 20.0, 22.0);
    heroStack.layoutMarginsRelativeArrangement = YES;
    [hero addSubview:heroStack];

    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[settings, diagnostics, mods]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.alignment = UIStackViewAlignmentCenter;
    actions.spacing = 10.0;

    UILabel *footer = MakeLabel(@"GENERALS ZH  ·  Нативный лаунчер  ·  Офлайн-доступен", 11.0, UIFontWeightRegular);
    footer.textColor = [UIColor colorWithWhite:0.42 alpha:1.0];

    self.menuStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        eyebrow, title, subtitle, hero, actions, footer
    ]];
    self.menuStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.menuStack.axis = UILayoutConstraintAxisVertical;
    self.menuStack.alignment = UIStackViewAlignmentCenter;
    self.menuStack.spacing = 8.0;
    [self.menuStack setCustomSpacing:18.0 afterView:subtitle];
    [self.menuStack setCustomSpacing:14.0 afterView:hero];
    [self.menuStack setCustomSpacing:16.0 afterView:actions];

    [self.view addSubview:self.menuStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.menuStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:28.0],
        [self.menuStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-28.0],
        [self.menuStack.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor],
        [self.menuStack.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [hero.leadingAnchor constraintEqualToAnchor:self.menuStack.leadingAnchor],
        [hero.trailingAnchor constraintEqualToAnchor:self.menuStack.trailingAnchor],
        [heroStack.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],
        [heroStack.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],
        [heroStack.topAnchor constraintEqualToAnchor:hero.topAnchor],
        [heroStack.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
    ]];
}

- (void)buildMods
{
    self.modsView = [[UIView alloc] init];
    self.modsView.translatesAutoresizingMaskIntoConstraints = NO;
    self.modsView.backgroundColor = UIColor.blackColor;
    self.modsView.hidden = YES;
    [self.view addSubview:self.modsView];

    [NSLayoutConstraint activateConstraints:@[
        [self.modsView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:28.0],
        [self.modsView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-28.0],
        [self.modsView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:18.0],
        [self.modsView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-18.0],
    ]];

    UILabel *title = MakeLabel(@"MODS", 28.0, UIFontWeightBold);
    title.textAlignment = NSTextAlignmentLeft;
    UILabel *note = MakeLabel(
        @"Install and update mods without reinstalling Generals Hub. Choose Stable for normal use or Beta for test releases.",
        13.0,
        UIFontWeightRegular);
    note.textAlignment = NSTextAlignmentLeft;
    note.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];

    UILabel *channelLabel = MakeLabel(@"Update channel", 14.0, UIFontWeightSemibold);
    channelLabel.textAlignment = NSTextAlignmentLeft;
    self.modsChannelSegment = [[UISegmentedControl alloc] initWithItems:@[@"Stable", @"Beta"]];
    self.modsChannelSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.modsChannelSegment.selectedSegmentIndex = [GXHubCatalogChannel() isEqualToString:@"beta"] ? 1 : 0;
    [self.modsChannelSegment setTitle:LauncherRussianText(@"Stable") forSegmentAtIndex:0];
    [self.modsChannelSegment setTitle:LauncherRussianText(@"Beta") forSegmentAtIndex:1];
    [self.modsChannelSegment addTarget:self action:@selector(modsChannelChanged:) forControlEvents:UIControlEventValueChanged];

    UIButton *refreshButton = MakeButton(@"Refresh", self, @selector(refreshHubCatalog));
    [refreshButton.widthAnchor constraintEqualToConstant:140.0].active = YES;

    UIStackView *channelRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        channelLabel, self.modsChannelSegment, refreshButton
    ]];
    channelRow.translatesAutoresizingMaskIntoConstraints = NO;
    channelRow.axis = UILayoutConstraintAxisHorizontal;
    channelRow.alignment = UIStackViewAlignmentCenter;
    channelRow.spacing = 12.0;
    [self.modsChannelSegment.widthAnchor constraintEqualToConstant:220.0].active = YES;

    self.modsListStack = [[UIStackView alloc] init];
    self.modsListStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.modsListStack.axis = UILayoutConstraintAxisVertical;
    self.modsListStack.alignment = UIStackViewAlignmentFill;
    self.modsListStack.spacing = 10.0;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = YES;
    [scroll addSubview:self.modsListStack];

    UIButton *importButton = MakeButton(@"Import .gxmod", self, @selector(importModPackage));
    UIButton *back = MakeButton(@"Back", self, @selector(hideMods));
    [importButton.widthAnchor constraintEqualToConstant:220.0].active = YES;
    [back.widthAnchor constraintEqualToConstant:180.0].active = YES;
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[importButton, back]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.alignment = UIStackViewAlignmentCenter;
    buttons.spacing = 14.0;

    self.modsStatus = MakeLabel(@"", 13.0, UIFontWeightRegular);
    self.modsStatus.textAlignment = NSTextAlignmentLeft;
    self.modsStatus.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];

    [self.modsView addSubview:title];
    [self.modsView addSubview:note];
    [self.modsView addSubview:channelRow];
    [self.modsView addSubview:scroll];
    [self.modsView addSubview:buttons];
    [self.modsView addSubview:self.modsStatus];

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:self.modsView.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:self.modsView.trailingAnchor],
        [title.topAnchor constraintEqualToAnchor:self.modsView.topAnchor],
        [note.leadingAnchor constraintEqualToAnchor:self.modsView.leadingAnchor],
        [note.trailingAnchor constraintEqualToAnchor:self.modsView.trailingAnchor],
        [note.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4.0],
        [channelRow.leadingAnchor constraintEqualToAnchor:self.modsView.leadingAnchor],
        [channelRow.trailingAnchor constraintLessThanOrEqualToAnchor:self.modsView.trailingAnchor],
        [channelRow.topAnchor constraintEqualToAnchor:note.bottomAnchor constant:10.0],
        [scroll.leadingAnchor constraintEqualToAnchor:self.modsView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.modsView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:channelRow.bottomAnchor constant:12.0],
        [scroll.bottomAnchor constraintEqualToAnchor:buttons.topAnchor constant:-12.0],
        [self.modsListStack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [self.modsListStack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [self.modsListStack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [self.modsListStack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [self.modsListStack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [buttons.centerXAnchor constraintEqualToAnchor:self.modsView.centerXAnchor],
        [buttons.bottomAnchor constraintEqualToAnchor:self.modsStatus.topAnchor constant:-7.0],
        [self.modsStatus.leadingAnchor constraintEqualToAnchor:self.modsView.leadingAnchor],
        [self.modsStatus.trailingAnchor constraintEqualToAnchor:self.modsView.trailingAnchor],
        [self.modsStatus.bottomAnchor constraintEqualToAnchor:self.modsView.bottomAnchor],
    ]];

    [self reloadModsList];
}

- (NSInteger)availableHubUpdateCount
{
    NSInteger count = 0;
    NSString *currentHubVersion = [NSString stringWithUTF8String:GX_PROJECT_VERSION] ?: @"0.0.0";
    NSInteger currentHubBuild = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] integerValue];

    NSDictionary *hubRelease = GXHubHubReleaseForCurrentChannel();
    if (hubRelease != nil)
    {
        NSString *availableHubVersion = hubRelease[@"version"] ?: currentHubVersion;
        NSInteger availableHubBuild = [hubRelease[@"build"] integerValue];
        NSString *hubURL = hubRelease[@"packageURL"];
        BOOL hubUpdateAvailable = HubVersionIsNewer(currentHubVersion, availableHubVersion) ||
            ([currentHubVersion isEqualToString:availableHubVersion] && availableHubBuild > currentHubBuild);
        if (hubUpdateAvailable && hubURL.length > 0)
            ++count;
    }

    for (NSDictionary<NSString *, id> *entry in GXHubCatalogEntries())
    {
        NSString *profileId = entry[@"profileId"];
        NSDictionary *installed = profileId.length > 0 ? GXHubInstalledManifest(profileId) : nil;
        NSString *installedVersion = installed[@"version"];
        NSString *availableVersion = entry[@"version"];
        NSString *packageURL = entry[@"packageURL"];
        NSString *minimumHub = entry[@"minHubVersion"];
        if (installedVersion.length > 0 &&
            availableVersion.length > 0 &&
            packageURL.length > 0 &&
            HubVersionAtLeast(currentHubVersion, minimumHub) &&
            HubVersionDiffers(installedVersion, availableVersion))
        {
            ++count;
        }
    }
    return count;
}

- (void)updateModsUpdatesBadge
{
    if (self.modsButton == nil)
        return;
    NSInteger count = [self availableHubUpdateCount];
    NSString *title = count > 0
        ? [NSString stringWithFormat:@"Моды и обновления · %ld", (long)count]
        : @"Моды и обновления";
    [self.modsButton setTitle:title forState:UIControlStateNormal];
    self.modsButton.accessibilityLabel = count > 0
        ? [NSString stringWithFormat:@"Моды и обновления, доступно обновлений: %ld", (long)count]
        : @"Моды и обновления";
}

- (void)reloadModsList
{
    [self updateModsUpdatesBadge];
    for (UIView *view in [self.modsListStack.arrangedSubviews copy])
    {
        [self.modsListStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSString *channel = GXHubCatalogChannel();
    BOOL downloadBusy = GXHubDownloadBusy();
    NSString *activeDownloadProfile = GXHubActiveDownloadProfile();
    self.modsChannelSegment.enabled = !downloadBusy;
    NSString *currentHubVersion = [NSString stringWithUTF8String:GX_PROJECT_VERSION] ?: @"0.0.0";
    NSDictionary *hubRelease = GXHubHubReleaseForCurrentChannel();
    if (hubRelease != nil)
    {
        NSString *availableHubVersion = hubRelease[@"version"] ?: currentHubVersion;
        NSInteger currentHubBuild = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] integerValue];
        NSInteger availableHubBuild = [hubRelease[@"build"] integerValue];
        BOOL hubUpdateAvailable = HubVersionIsNewer(currentHubVersion, availableHubVersion) ||
            ([currentHubVersion isEqualToString:availableHubVersion] && availableHubBuild > currentHubBuild);
        UILabel *hubName = MakeLabel(@"Generals Hub", 17.0, UIFontWeightSemibold);
        hubName.textAlignment = NSTextAlignmentLeft;
        NSString *hubStatusText = hubUpdateAvailable
            ? [NSString stringWithFormat:@"Установлено %@ (%ld) · Доступно %@ %@ (%ld)",
                currentHubVersion, (long)currentHubBuild, [channel uppercaseString],
                availableHubVersion, (long)availableHubBuild]
            : [NSString stringWithFormat:@"Установлено %@ (%ld) · %@ · актуально",
                currentHubVersion, (long)currentHubBuild, [channel uppercaseString]];
        UILabel *hubDetail = MakeLabel(hubStatusText, 12.0, UIFontWeightRegular);
        hubDetail.textAlignment = NSTextAlignmentLeft;
        hubDetail.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];

        NSMutableArray<UIView *> *hubViews = [NSMutableArray arrayWithObjects:hubName, hubDetail, nil];
        NSString *hubNotes = hubRelease[@"releaseNotes"];
        if (hubUpdateAvailable && hubNotes.length > 0)
        {
            UILabel *notes = MakeLabel(hubNotes, 12.0, UIFontWeightRegular);
            notes.textAlignment = NSTextAlignmentLeft;
            notes.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
            [hubViews addObject:notes];
        }

        NSString *hubURL = hubRelease[@"packageURL"];
        if (hubUpdateAvailable && hubURL.length > 0)
        {
            UIButton *updateHub = MakeButton(@"Get Hub Update", self, @selector(openHubUpdate:));
            updateHub.accessibilityIdentifier = hubURL;
            [updateHub.widthAnchor constraintEqualToConstant:190.0].active = YES;
            UIStackView *hubActions = [[UIStackView alloc] initWithArrangedSubviews:@[updateHub]];
            hubActions.axis = UILayoutConstraintAxisHorizontal;
            hubActions.alignment = UIStackViewAlignmentCenter;
            [hubViews addObject:hubActions];
        }

        UIStackView *hubRow = [[UIStackView alloc] initWithArrangedSubviews:hubViews];
        hubRow.axis = UILayoutConstraintAxisVertical;
        hubRow.alignment = UIStackViewAlignmentFill;
        hubRow.spacing = 6.0;
        hubRow.layoutMargins = UIEdgeInsetsMake(10.0, 14.0, 10.0, 14.0);
        hubRow.layoutMarginsRelativeArrangement = YES;
        hubRow.backgroundColor = [UIColor colorWithWhite:0.075 alpha:1.0];
        hubRow.layer.cornerRadius = 9.0;
        [self.modsListStack addArrangedSubview:hubRow];
    }

    NSArray<NSDictionary<NSString *, id> *> *entries = HubCombinedEntries();
    if (entries.count == 0)
    {
        UILabel *empty = MakeLabel(@"No mod catalog entries yet. Import a .gxmod package from Files.", 15.0, UIFontWeightRegular);
        empty.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
        [self.modsListStack addArrangedSubview:empty];
        return;
    }

    for (NSDictionary *entry in entries)
    {
        NSString *profileId = entry[@"profileId"] ?: @"";
        NSString *name = entry[@"name"] ?: profileId;
        NSString *catalogVersion = entry[@"version"] ?: @"unknown";
        NSDictionary *installed = GXHubInstalledManifest(profileId);
        BOOL externalInstalled = GXHubProfileInstalled(profileId);
        BOOL available = ProfileDirectoryExists(profileId);
        NSString *installedVersion = installed[@"version"];
        NSString *minimumHub = entry[@"minHubVersion"];
        BOOL compatible = HubVersionAtLeast(currentHubVersion, minimumHub);
        BOOL updateAvailable = externalInstalled && installedVersion.length > 0 &&
            HubVersionDiffers(installedVersion, catalogVersion) &&
            [entry[@"packageURL"] length] > 0 && compatible;

        UILabel *nameLabel = MakeLabel(name, 17.0, UIFontWeightSemibold);
        nameLabel.textAlignment = NSTextAlignmentLeft;
        NSString *statusText = nil;
        if (externalInstalled)
            statusText = updateAvailable
                ? [NSString stringWithFormat:@"Установлено %@ · Доступно обновление %@", installedVersion, catalogVersion]
                : [NSString stringWithFormat:@"Установлено %@", installedVersion ?: catalogVersion];
        else if (available)
            statusText = [NSString stringWithFormat:@"Встроено · %@", catalogVersion];
        else
            statusText = [NSString stringWithFormat:@"Не установлено · %@", catalogVersion];

        statusText = [statusText stringByAppendingFormat:@" · %@",
            [channel uppercaseString]];
        if (!compatible)
            statusText = [statusText stringByAppendingFormat:@" · Требуется Hub %@", minimumHub];

        NSNumber *sizeBytes = entry[@"packageBytes"];
        if (sizeBytes.unsignedLongLongValue > 0)
            statusText = [statusText stringByAppendingFormat:@" · %@",
                HumanReadableBytes(sizeBytes.unsignedLongLongValue)];
        UILabel *detail = MakeLabel(statusText, 12.0, UIFontWeightRegular);
        detail.textAlignment = NSTextAlignmentLeft;
        detail.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];

        UIStackView *actions = [[UIStackView alloc] init];
        actions.axis = UILayoutConstraintAxisHorizontal;
        actions.alignment = UIStackViewAlignmentCenter;
        actions.spacing = 8.0;

        if (available)
        {
            UIButton *play = MakeButton(@"Play", self, @selector(playHubMod:));
            play.accessibilityIdentifier = profileId;
            [play.widthAnchor constraintEqualToConstant:130.0].active = YES;
            [actions addArrangedSubview:play];
        }

        BOOL hasDedicatedSettings = [profileId isEqualToString:@"enhanced"] ||
                                    [profileId isEqualToString:@"contra-x"];
        if (available && hasDedicatedSettings)
        {
            UIButton *settings = MakeButton(@"Settings", self, @selector(showHubModSettings:));
            settings.accessibilityIdentifier = profileId;
            [settings.widthAnchor constraintEqualToConstant:140.0].active = YES;
            [actions addArrangedSubview:settings];
        }

        NSString *packageURL = entry[@"packageURL"];
        if (compatible && packageURL.length > 0 && (!externalInstalled || updateAvailable))
        {
            BOOL thisDownloadActive = downloadBusy && [activeDownloadProfile isEqualToString:profileId];
            NSString *installTitle = thisDownloadActive
                ? @"Скачивание…"
                : (externalInstalled ? @"Обновить" : @"Установить");
            UIButton *install = MakeButton(installTitle, self, @selector(downloadHubMod:));
            install.accessibilityIdentifier = profileId;
            install.enabled = !downloadBusy;
            [install.widthAnchor constraintEqualToConstant:160.0].active = YES;
            [actions addArrangedSubview:install];
        }

        if (externalInstalled)
        {
            UIButton *remove = MakeButton(@"Remove", self, @selector(removeHubMod:));
            remove.accessibilityIdentifier = profileId;
            [remove.widthAnchor constraintEqualToConstant:130.0].active = YES;
            [actions addArrangedSubview:remove];
        }

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[nameLabel, detail, actions]];
        row.axis = UILayoutConstraintAxisVertical;
        row.alignment = UIStackViewAlignmentFill;
        row.spacing = 6.0;
        row.layoutMargins = UIEdgeInsetsMake(10.0, 14.0, 10.0, 14.0);
        row.layoutMarginsRelativeArrangement = YES;
        row.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];
        row.layer.cornerRadius = 9.0;
        [self.modsListStack addArrangedSubview:row];
    }
}

- (void)rebuildHubMenuAfterMutation
{
    [self.menuStack removeFromSuperview];
    self.menuStack = nil;
    [self buildMenu];
    self.menuStack.hidden = YES;

    [self.settingsView removeFromSuperview];
    self.settingsView = nil;
    [self buildSettings];
    self.settingsView.hidden = YES;

    [self reloadModsList];
    [self updateModsUpdatesBadge];
}

- (void)showMods
{
    self.menuStack.hidden = YES;
    self.settingsView.hidden = YES;
    self.diagnosticsView.hidden = YES;
    self.modsView.hidden = NO;
    self.modsStatus.text = @"";
    [self reloadModsList];
    [self refreshHubCatalog];
}

- (void)hideMods
{
    self.modsView.hidden = YES;
    self.menuStack.hidden = NO;
}

- (void)modsChannelChanged:(UISegmentedControl *)sender
{
    if (GXHubDownloadBusy())
    {
        sender.selectedSegmentIndex = [GXHubCatalogChannel() isEqualToString:@"beta"] ? 1 : 0;
        self.modsStatus.textColor = [UIColor systemBlueColor];
        self.modsStatus.text = @"Дождитесь завершения активной загрузки мода, прежде чем переключать канал.";
        return;
    }
    NSString *channel = sender.selectedSegmentIndex == 1 ? @"beta" : @"stable";
    GXHubSetCatalogChannel(channel);
    self.modsStatus.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    self.modsStatus.text = [NSString stringWithFormat:@"Используется канал %@.", [channel uppercaseString]];
    [self reloadModsList];
    [self refreshHubCatalog];
}

- (void)refreshHubCatalog
{
    if (GXHubDownloadBusy())
    {
        if (!self.modsView.hidden)
        {
            self.modsStatus.textColor = [UIColor systemBlueColor];
            self.modsStatus.text = [NSString stringWithFormat:@"Скачивание %@…",
                GXHubActiveDownloadProfile() ?: @"мода"];
        }
        return;
    }
    NSString *url = GXHubRemoteCatalogURL();
    if (url.length == 0)
    {
        self.modsStatus.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
        self.modsStatus.text = @"Удалённый каталог ещё не настроен. Используется встроенный каталог.";
        return;
    }

    self.modsStatus.textColor = [UIColor systemBlueColor];
    self.modsStatus.text = [NSString stringWithFormat:@"Проверка обновлений %@…", [GXHubCatalogChannel() uppercaseString]];
    __weak GXProfileLauncherViewController *weakSelf = self;
    GXHubRefreshRemoteCatalog(^(BOOL updated, NSError *error) {
        GXProfileLauncherViewController *strongSelf = weakSelf;
        if (strongSelf == nil)
            return;
        if (error != nil)
        {
            strongSelf.modsStatus.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
            strongSelf.modsStatus.text = [NSString stringWithFormat:@"Не удалось обновить каталог, используются кэшированные данные: %@",
                error.localizedDescription];
            [strongSelf reloadModsList];
            return;
        }
        strongSelf.modsStatus.textColor = [UIColor systemGreenColor];
        strongSelf.modsStatus.text = updated
            ? [NSString stringWithFormat:@"Каталог %@ обновлён.", [GXHubCatalogChannel() uppercaseString]]
            : @"Каталог актуален.";
        [strongSelf reloadModsList];
    });
}

- (void)openHubUpdate:(UIButton *)sender
{
    NSURL *url = [NSURL URLWithString:sender.accessibilityIdentifier ?: @""];
    if (url == nil || ![[url scheme] isEqualToString:@"https"])
        return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)playHubMod:(UIButton *)sender
{
    NSString *profileId = sender.accessibilityIdentifier;
    if (profileId.length > 0 && ProfileDirectoryExists(profileId))
        SetSelectedProfile(profileId);
}

- (void)showHubModSettings:(UIButton *)sender
{
    NSString *profileId = sender.accessibilityIdentifier;
    if (!([profileId isEqualToString:@"enhanced"] || [profileId isEqualToString:@"contra-x"]))
        return;

    self.settingsProfileId = profileId;
    [self.settingsView removeFromSuperview];
    self.settingsView = nil;
    [self buildSettings];
    [self loadSettingsControls];
    self.menuStack.hidden = YES;
    self.modsView.hidden = YES;
    self.diagnosticsView.hidden = YES;
    self.settingsView.hidden = NO;
}

- (void)downloadHubMod:(UIButton *)sender
{
    NSString *profileId = sender.accessibilityIdentifier;
    NSDictionary *entry = HubEntryForProfile(profileId);
    if (entry == nil)
        return;

    if (GXHubDownloadBusy())
    {
        self.modsStatus.textColor = [UIColor systemBlueColor];
        self.modsStatus.text = [NSString stringWithFormat:@"Уже идёт другая загрузка: %@.",
            GXHubActiveDownloadProfile() ?: @"мод"];
        return;
    }

    NSString *displayName = entry[@"name"] ?: profileId;
    self.modsStatus.textColor = [UIColor systemBlueColor];
    self.modsStatus.text = [NSString stringWithFormat:@"Подготовка загрузки %@…", displayName];
    sender.enabled = NO;

    __weak GXProfileLauncherViewController *weakSelf = self;
    GXHubDownloadAndInstallWithProgress(
        entry,
        ^(long long bytesReceived, long long totalBytes, double fractionCompleted) {
            GXProfileLauncherViewController *strongSelf = weakSelf;
            if (strongSelf == nil)
                return;

            strongSelf.modsStatus.textColor = [UIColor systemBlueColor];
            if (fractionCompleted >= 0.999 && totalBytes > 0)
            {
                strongSelf.modsStatus.text = [NSString stringWithFormat:
                    @"Загружено %@. Проверка SHA-256 и установка…", displayName];
                return;
            }

            if (totalBytes > 0)
            {
                strongSelf.modsStatus.text = [NSString stringWithFormat:
                    @"Скачивание %@… %ld%% · %.2f / %.2f ГБ",
                    displayName,
                    (long)(fractionCompleted * 100.0 + 0.5),
                    (double)bytesReceived / 1024.0 / 1024.0 / 1024.0,
                    (double)totalBytes / 1024.0 / 1024.0 / 1024.0];
            }
            else
            {
                strongSelf.modsStatus.text = [NSString stringWithFormat:
                    @"Скачивание %@… %.1f МБ",
                    displayName,
                    (double)bytesReceived / 1024.0 / 1024.0];
            }
        },
        ^(NSDictionary *manifest, NSError *error) {
            GXProfileLauncherViewController *strongSelf = weakSelf;
            if (strongSelf == nil)
                return;
            if (error != nil)
            {
                strongSelf.modsStatus.textColor = [UIColor systemRedColor];
                strongSelf.modsStatus.text = [NSString stringWithFormat:@"Ошибка установки: %@", error.localizedDescription];
                [strongSelf reloadModsList];
                return;
            }
            strongSelf.modsStatus.textColor = [UIColor systemGreenColor];
            strongSelf.modsStatus.text = [NSString stringWithFormat:@"Установлено %@ %@.", manifest[@"name"], manifest[@"version"]];
            [strongSelf rebuildHubMenuAfterMutation];
        });

    [self reloadModsList];
}

- (void)removeHubMod:(UIButton *)sender
{
    NSString *profileId = sender.accessibilityIdentifier;
    NSError *error = nil;
    if (!GXHubRemoveMod(profileId, &error))
    {
        self.modsStatus.textColor = [UIColor systemRedColor];
        self.modsStatus.text = [NSString stringWithFormat:@"Ошибка удаления: %@", error.localizedDescription];
        return;
    }
    self.modsStatus.textColor = [UIColor systemGreenColor];
    self.modsStatus.text = @"Мод удалён.";
    [self rebuildHubMenuAfterMutation];
}

- (void)importModPackage
{
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData]
                                                                    asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (url == nil)
        return;

    self.modsStatus.textColor = [UIColor systemBlueColor];
    self.modsStatus.text = @"Установка .gxmod…";
    __weak GXProfileLauncherViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSError *error = nil;
        NSDictionary *manifest = nil;
        BOOL ok = GXHubInstallPackageAtURL(url, nil, &manifest, &error);
        if (scoped)
            [url stopAccessingSecurityScopedResource];

        dispatch_async(dispatch_get_main_queue(), ^{
            GXProfileLauncherViewController *strongSelf = weakSelf;
            if (strongSelf == nil)
                return;
            if (!ok)
            {
                strongSelf.modsStatus.textColor = [UIColor systemRedColor];
                strongSelf.modsStatus.text = [NSString stringWithFormat:@"Ошибка импорта: %@", error.localizedDescription];
                if (strongSelf.webLauncherActive)
                    [strongSelf sendWebEvent:@"installError" payload:@{ @"profileId": @"file", @"error": error.localizedDescription ?: @"Ошибка импорта" }];
                return;
            }
            strongSelf.modsStatus.textColor = [UIColor systemGreenColor];
            strongSelf.modsStatus.text = [NSString stringWithFormat:@"Установлено %@ %@.", manifest[@"name"], manifest[@"version"]];
            [strongSelf rebuildHubMenuAfterMutation];
            if (strongSelf.webLauncherActive)
            {
                [strongSelf sendWebEvent:@"installComplete" payload:@{
                    @"profileId": manifest[@"profileId"] ?: @"",
                    @"manifest": manifest ?: @{},
                }];
                [strongSelf sendWebEvent:@"stateChanged" payload:[strongSelf webLauncherState]];
            }
        });
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    self.modsStatus.text = @"";
}

- (UISlider *)makeSliderWithMin:(float)minimum max:(float)maximum
{
    UISlider *slider = [[UISlider alloc] init];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    slider.minimumValue = minimum;
    slider.maximumValue = maximum;
    slider.minimumTrackTintColor = UIColor.whiteColor;
    slider.maximumTrackTintColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    [slider addTarget:self action:@selector(settingsSliderChanged:) forControlEvents:UIControlEventValueChanged];
    return slider;
}

- (UILabel *)makeValueLabel
{
    UILabel *label = MakeLabel(@"", 15.0, UIFontWeightSemibold);
    label.textAlignment = NSTextAlignmentRight;
    label.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightSemibold];
    [label.widthAnchor constraintEqualToConstant:72.0].active = YES;
    return label;
}

- (UIStackView *)sliderRow:(NSString *)title slider:(UISlider *)slider value:(UILabel *)value
{
    UILabel *name = MakeLabel(title, 15.0, UIFontWeightMedium);
    name.textAlignment = NSTextAlignmentLeft;

    UIStackView *line = [[UIStackView alloc] initWithArrangedSubviews:@[slider, value]];
    line.axis = UILayoutConstraintAxisHorizontal;
    line.alignment = UIStackViewAlignmentCenter;
    line.spacing = 14.0;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, line]];
    row.axis = UILayoutConstraintAxisVertical;
    row.alignment = UIStackViewAlignmentFill;
    row.spacing = 7.0;
    row.layoutMargins = UIEdgeInsetsMake(10.0, 14.0, 10.0, 14.0);
    row.layoutMarginsRelativeArrangement = YES;
    row.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];
    row.layer.cornerRadius = 9.0;
    return row;
}

- (UIStackView *)switchRow:(NSString *)title control:(UISwitch *)control
{
    UILabel *name = MakeLabel(title, 15.0, UIFontWeightMedium);
    name.textAlignment = NSTextAlignmentLeft;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, control]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.distribution = UIStackViewDistributionFill;
    row.spacing = 18.0;
    row.layoutMargins = UIEdgeInsetsMake(10.0, 14.0, 10.0, 14.0);
    row.layoutMarginsRelativeArrangement = YES;
    row.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];
    row.layer.cornerRadius = 9.0;
    return row;
}

- (UILabel *)sectionLabel:(NSString *)title
{
    UILabel *label = MakeLabel(title, 13.0, UIFontWeightBold);
    label.textAlignment = NSTextAlignmentLeft;
    label.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    return label;
}

- (UISegmentedControl *)makeSegmented:(NSArray<NSString *> *)items
{
    UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:items];
    for (NSUInteger index = 0; index < items.count; ++index)
        [control setTitle:LauncherRussianText(items[index]) forSegmentAtIndex:index];
    control.translatesAutoresizingMaskIntoConstraints = NO;
    control.selectedSegmentIndex = 0;
    return control;
}

- (UIStackView *)segmentedRow:(NSString *)title control:(UISegmentedControl *)control
{
    UILabel *name = MakeLabel(title, 15.0, UIFontWeightMedium);
    name.textAlignment = NSTextAlignmentLeft;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, control]];
    row.axis = UILayoutConstraintAxisVertical;
    row.alignment = UIStackViewAlignmentFill;
    row.spacing = 8.0;
    row.layoutMargins = UIEdgeInsetsMake(10.0, 14.0, 10.0, 14.0);
    row.layoutMarginsRelativeArrangement = YES;
    row.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1.0];
    row.layer.cornerRadius = 9.0;
    return row;
}

- (void)buildSettings
{
    self.settingsView = [[UIView alloc] init];
    self.settingsView.translatesAutoresizingMaskIntoConstraints = NO;
    self.settingsView.backgroundColor = UIColor.blackColor;
    self.settingsView.hidden = YES;
    [self.view addSubview:self.settingsView];

    [NSLayoutConstraint activateConstraints:@[
        [self.settingsView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:28.0],
        [self.settingsView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-28.0],
        [self.settingsView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:18.0],
        [self.settingsView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-18.0],
    ]];

    NSString *bundledProfile = BundledAutoLaunchProfile();
    BOOL dedicatedEnhanced = [bundledProfile isEqualToString:@"enhanced"];
    BOOL dedicatedContra = [bundledProfile isEqualToString:@"contra-x"];

    BOOL hubEnhancedSettings = [self.settingsProfileId isEqualToString:@"enhanced"];
    BOOL hubContraSettings = [self.settingsProfileId isEqualToString:@"contra-x"];
    BOOL hubModSettings = hubEnhancedSettings || hubContraSettings;

    NSString *settingsTitle = (dedicatedEnhanced || hubEnhancedSettings)
        ? @"Enhanced settings"
        : ((dedicatedContra || hubContraSettings) ? @"Contra X settings" : @"Hub settings");
    NSString *settingsNote = (dedicatedEnhanced || hubEnhancedSettings)
        ? @"Enhanced-only options. Stored separately from Hub and other mods. Changes apply on the next launch."
        : ((dedicatedContra || hubContraSettings)
            ? @"Contra X-only options. Stored separately from Hub and other mods. Changes apply on the next launch."
            : @"Shared engine, graphics, camera and performance settings for Online and installed mods.");

    UILabel *title = MakeLabel(settingsTitle, 26.0, UIFontWeightBold);
    title.textAlignment = NSTextAlignmentLeft;

    UILabel *note = MakeLabel(settingsNote, 13.0, UIFontWeightRegular);
    note.textAlignment = NSTextAlignmentLeft;
    note.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];

    self.contraControlBarSegment = [self makeSegmented:@[@"Contra", @"Pro", @"Standard"]];
    self.contraCameosSegment = [self makeSegmented:@[@"Standard", @"HD"]];
    self.contraMusicSegment = [self makeSegmented:@[@"Standard", @"Enhanced", @"The Score"]];
    self.contraVoicesSegment = [self makeSegmented:@[@"English", @"Native"]];
    self.contraHotkeysSegment = [self makeSegmented:@[@"Original", @"Leikeze"]];
    self.contraHotkeyLanguageSegment = [self makeSegmented:@[@"English", @"Russian"]];
    self.contraPortraitsSegment = [self makeSegmented:@[@"Standard", @"Funny"]];
    self.contraFogSwitch = [[UISwitch alloc] init];
    self.contraWaterSwitch = [[UISwitch alloc] init];
    self.contraExtraBuildingPropsSwitch = [[UISwitch alloc] init];

    self.enhancedTextureResolutionSegment = [self makeSegmented:@[@"Vanilla", @"High"]];
    self.enhancedUIQualitySegment = [self makeSegmented:@[@"HD", @"FHD", @"QHD"]];
    self.enhancedInfantryIconScaleSegment = [self makeSegmented:@[@"100%", @"75%", @"50%"]];
    self.enhancedCameosSegment = [self makeSegmented:@[@"SD", @"HD"]];
    self.enhancedAIScriptsSegment = [self makeSegmented:@[@"Default", @"Restrained", @"Skynet"]];

    self.shadow3DSwitch = [[UISwitch alloc] init];
    self.shadow2DSwitch = [[UISwitch alloc] init];
    self.cloudShadowsSwitch = [[UISwitch alloc] init];
    self.groundLightingSwitch = [[UISwitch alloc] init];
    self.softWaterSwitch = [[UISwitch alloc] init];
    self.buildingOcclusionSwitch = [[UISwitch alloc] init];
    self.showPropsSwitch = [[UISwitch alloc] init];
    self.extraAnimationsSwitch = [[UISwitch alloc] init];
    self.dynamicLODSwitch = [[UISwitch alloc] init];
    self.heatEffectsSwitch = [[UISwitch alloc] init];
    self.textureQualitySegment = [self makeSegmented:@[@"High", @"Medium", @"Low"]];
    self.particleQualitySegment = [self makeSegmented:@[@"Low", @"Medium", @"High"]];
    self.textureFilterSegment = [self makeSegmented:@[@"Bilinear", @"Trilinear", @"Anisotropic"]];
    self.anisotropySegment = [self makeSegmented:@[@"2x", @"4x", @"8x", @"16x"]];
    self.msaaSegment = [self makeSegmented:@[@"Off", @"2x", @"4x", @"8x"]];
    [self.textureFilterSegment addTarget:self action:@selector(textureFilterChanged:) forControlEvents:UIControlEventValueChanged];

    self.maxCameraSlider = [self makeSliderWithMin:300.0f max:800.0f];
    self.minCameraSlider = [self makeSliderWithMin:40.0f max:150.0f];
    self.cameraPitchSlider = [self makeSliderWithMin:20.0f max:60.0f];
    self.scrollSpeedSlider = [self makeSliderWithMin:0.5f max:2.0f];
    self.drawDistanceSlider = [self makeSliderWithMin:0.5f max:2.0f];
    self.fpsSlider = [self makeSliderWithMin:30.0f max:120.0f];

    self.maxCameraValue = [self makeValueLabel];
    self.minCameraValue = [self makeValueLabel];
    self.cameraPitchValue = [self makeValueLabel];
    self.scrollSpeedValue = [self makeValueLabel];
    self.drawDistanceValue = [self makeValueLabel];
    self.fpsValue = [self makeValueLabel];

    self.enforceMaxSwitch = [[UISwitch alloc] init];
    self.fpsLimitSwitch = [[UISwitch alloc] init];
    [self.fpsLimitSwitch addTarget:self action:@selector(fpsLimitChanged:) forControlEvents:UIControlEventValueChanged];

    NSMutableArray<UIView *> *controlViews = [NSMutableArray array];
    BOOL showEnhanced = dedicatedEnhanced || hubEnhancedSettings;
    BOOL showContra = dedicatedContra || hubContraSettings;
    BOOL showCommonSettings = !hubModSettings;

    if (showEnhanced)
    {
        [controlViews addObjectsFromArray:@[
            [self sectionLabel:@"ENHANCED"],
            [self segmentedRow:@"Faction textures" control:self.enhancedTextureResolutionSegment],
            [self segmentedRow:@"UI quality" control:self.enhancedUIQualitySegment],
            [self segmentedRow:@"Infantry icons" control:self.enhancedInfantryIconScaleSegment],
            [self segmentedRow:@"Cameos" control:self.enhancedCameosSegment],
            [self segmentedRow:@"AI scripts" control:self.enhancedAIScriptsSegment],
        ]];
    }

    if (showContra)
    {
        [controlViews addObjectsFromArray:@[
            [self sectionLabel:@"CONTRA X"],
            [self segmentedRow:@"Control Bar" control:self.contraControlBarSegment],
            [self segmentedRow:@"Icon / cameo quality" control:self.contraCameosSegment],
            [self segmentedRow:@"Music" control:self.contraMusicSegment],
            [self segmentedRow:@"Unit voices" control:self.contraVoicesSegment],
            [self segmentedRow:@"Hotkeys" control:self.contraHotkeysSegment],
            [self segmentedRow:@"Hotkey language" control:self.contraHotkeyLanguageSegment],
            [self segmentedRow:@"General portraits" control:self.contraPortraitsSegment],
            [self switchRow:@"Fog effects" control:self.contraFogSwitch],
            [self switchRow:@"Water effects" control:self.contraWaterSwitch],
            [self switchRow:@"Extra building props" control:self.contraExtraBuildingPropsSwitch],
        ]];
    }

    if (showCommonSettings)
    {
        [controlViews addObjectsFromArray:@[
            [self sectionLabel:@"GRAPHICS"],
            [self switchRow:@"3D shadows" control:self.shadow3DSwitch],
            [self switchRow:@"2D shadows" control:self.shadow2DSwitch],
            [self switchRow:@"Cloud shadows" control:self.cloudShadowsSwitch],
            [self switchRow:@"Ground lighting" control:self.groundLightingSwitch],
            [self switchRow:@"Smooth water borders" control:self.softWaterSwitch],
            [self switchRow:@"Units behind buildings" control:self.buildingOcclusionSwitch],
            [self switchRow:@"Small props / trees" control:self.showPropsSwitch],
            [self switchRow:@"Extra animations" control:self.extraAnimationsSwitch],
            [self switchRow:@"Dynamic LOD" control:self.dynamicLODSwitch],
            [self switchRow:@"Heat effects" control:self.heatEffectsSwitch],
            [self segmentedRow:@"Engine texture quality" control:self.textureQualitySegment],
            [self segmentedRow:@"Particles" control:self.particleQualitySegment],
            [self segmentedRow:@"Texture filtering" control:self.textureFilterSegment],
            [self segmentedRow:@"Anisotropy" control:self.anisotropySegment],
            [self segmentedRow:@"MSAA" control:self.msaaSegment],

            [self sectionLabel:@"CAMERA / PERFORMANCE"],
            [self sliderRow:@"Maximum camera height" slider:self.maxCameraSlider value:self.maxCameraValue],
            [self sliderRow:@"Minimum camera height" slider:self.minCameraSlider value:self.minCameraValue],
            [self sliderRow:@"Camera pitch" slider:self.cameraPitchSlider value:self.cameraPitchValue],
            [self switchRow:@"Enforce maximum camera height" control:self.enforceMaxSwitch],
            [self sliderRow:@"Keyboard / edge scroll speed" slider:self.scrollSpeedSlider value:self.scrollSpeedValue],
            [self sliderRow:@"Terrain draw distance" slider:self.drawDistanceSlider value:self.drawDistanceValue],
            [self switchRow:@"FPS limit" control:self.fpsLimitSwitch],
            [self sliderRow:@"Frames per second" slider:self.fpsSlider value:self.fpsValue],
        ]];
    }

    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:controlViews];
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    controls.axis = UILayoutConstraintAxisVertical;
    controls.alignment = UIStackViewAlignmentFill;
    controls.spacing = 9.0;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = YES;
    [scroll addSubview:controls];

    UIButton *save = MakeButton(@"Save", self, @selector(saveSettings));
    UIButton *reset = MakeButton(@"Reset defaults", self, @selector(resetSettings));
    UIButton *back = MakeButton(@"Back", self, @selector(hideSettings));

    [save.widthAnchor constraintEqualToConstant:180.0].active = YES;
    [reset.widthAnchor constraintEqualToConstant:180.0].active = YES;
    [back.widthAnchor constraintEqualToConstant:180.0].active = YES;

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[save, reset, back]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.alignment = UIStackViewAlignmentCenter;
    buttons.distribution = UIStackViewDistributionEqualSpacing;
    buttons.spacing = 12.0;

    self.settingsStatus = MakeLabel(@"", 13.0, UIFontWeightRegular);
    self.settingsStatus.textAlignment = NSTextAlignmentLeft;
    self.settingsStatus.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];

    [self.settingsView addSubview:title];
    [self.settingsView addSubview:note];
    [self.settingsView addSubview:scroll];
    [self.settingsView addSubview:buttons];
    [self.settingsView addSubview:self.settingsStatus];

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:self.settingsView.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:self.settingsView.trailingAnchor],
        [title.topAnchor constraintEqualToAnchor:self.settingsView.topAnchor],

        [note.leadingAnchor constraintEqualToAnchor:self.settingsView.leadingAnchor],
        [note.trailingAnchor constraintEqualToAnchor:self.settingsView.trailingAnchor],
        [note.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4.0],

        [scroll.leadingAnchor constraintEqualToAnchor:self.settingsView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.settingsView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:note.bottomAnchor constant:12.0],
        [scroll.bottomAnchor constraintEqualToAnchor:buttons.topAnchor constant:-12.0],

        [controls.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [controls.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [controls.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [controls.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [controls.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],

        [buttons.centerXAnchor constraintEqualToAnchor:self.settingsView.centerXAnchor],
        [buttons.bottomAnchor constraintEqualToAnchor:self.settingsStatus.topAnchor constant:-7.0],

        [self.settingsStatus.leadingAnchor constraintEqualToAnchor:self.settingsView.leadingAnchor],
        [self.settingsStatus.trailingAnchor constraintEqualToAnchor:self.settingsView.trailingAnchor],
        [self.settingsStatus.bottomAnchor constraintEqualToAnchor:self.settingsView.bottomAnchor],
    ]];

    [self resetSettingsControls];
}

- (NSString *)diagnosticsTextWithGameDataSize:(NSString *)gameDataSize
{
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *shortVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    NSString *buildVersion = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
    NSString *gameDataPath = GXHubInstalledProfilePath(@"online");

    BOOL gameDataExists = GXHubProfileInstalled(@"online");
    BOOL enhancedInstalled = ProfileDirectoryExists(@"enhanced");
    BOOL contraInstalled = ProfileDirectoryExists(@"contra-x");

    NSString *settingsPath = IPadOverridesPath();
    NSString *enhancedSettingsPath = EnhancedSettingsPath();
    NSString *contraSettingsPath = ContraSettingsPath();
    BOOL settingsExists = [[NSFileManager defaultManager] fileExistsAtPath:settingsPath];
    BOOL enhancedSettingsExists = [[NSFileManager defaultManager] fileExistsAtPath:enhancedSettingsPath];
    BOOL contraSettingsExists = [[NSFileManager defaultManager] fileExistsAtPath:contraSettingsPath];
    NSString *enhancedSettingsText = enhancedInstalled
        ? (enhancedSettingsExists ? @"Присутствует" : @"Отсутствует")
        : @"н/д";
    NSString *contraSettingsText = contraInstalled
        ? (contraSettingsExists ? @"Присутствует" : @"Отсутствует")
        : @"н/д";

    NSString *currentLog = DocumentsFilePath(@"generals-stderr.log");
    BOOL currentLogExists = [[NSFileManager defaultManager] fileExistsAtPath:currentLog];
    NSString *currentLogText = currentLogExists
        ? [NSString stringWithFormat:@"Да (%@)", HumanReadableBytes(FileSizeAtPath(currentLog))]
        : @"Нет";

    NSUInteger sessionLogCount = 0;
    unsigned long long sessionLogBytes = 0;
    for (NSString *name in DiagnosticSessionLogNames())
    {
        NSString *path = DocumentsFilePath(name);
        if ([[NSFileManager defaultManager] fileExistsAtPath:path])
        {
            ++sessionLogCount;
            sessionLogBytes += FileSizeAtPath(path);
        }
    }

    NSString *sessionLogsText =
        [NSString stringWithFormat:@"%lu/10 (%@)",
                                   (unsigned long)sessionLogCount,
                                   HumanReadableBytes(sessionLogBytes)];

    NSMutableArray<NSString *> *installedModDescriptions = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *manifest in GXHubInstalledModEntries())
    {
        NSString *profileId = [manifest[@"profileId"] isKindOfClass:[NSString class]] ? manifest[@"profileId"] : @"";
        if (profileId.length == 0 || [profileId isEqualToString:@"online"])
            continue;
        NSString *name = [manifest[@"name"] isKindOfClass:[NSString class]] ? manifest[@"name"] : profileId;
        NSString *version = [manifest[@"version"] isKindOfClass:[NSString class]] ? manifest[@"version"] : @"";
        [installedModDescriptions addObject:(version.length > 0
            ? [NSString stringWithFormat:@"%@ %@ (%@)", name, version, profileId]
            : [NSString stringWithFormat:@"%@ (%@)", name, profileId])];
    }
    NSString *installedModsText = installedModDescriptions.count > 0
        ? [installedModDescriptions componentsJoinedByString:@", "]
        : @"Нет";

    return [NSString stringWithFormat:
        @"ПРИЛОЖЕНИЕ\n"
         "Проект: %s\n"
         "Сборка: %@ (%@)\n"
         "iOS: %@\n"
         "Устройство: %@\n\n"
         "СБОРКА\n"
         "Лончер: v%s · %@\n"
         "Запуск лончера: %@\n"
         "Движок: v%s · %@\n"
         "Запуск базовой оболочки: %@\n\n"
         "КОНТЕНТ\n"
         "GameData: %@\n"
         "Размер GameData: %@\n"
         "Enhanced: %@\n"
         "Contra X: %@\n"
         "Установленные моды: %@\n\n"
         "ФАЙЛЫ\n"
         "Настройки iPad: %@\n"
         "Настройки Enhanced: %@\n"
         "Настройки Contra: %@\n"
         "Текущая сессия: %@\n"
         "Журналы сессий: %@\n",
        GX_PROJECT_VERSION,
        shortVersion,
        buildVersion,
        UIDevice.currentDevice.systemVersion,
        UIDevice.currentDevice.model,
        GX_LAUNCHER_VERSION,
        ShortBuildIdentifier(GX_LAUNCHER_COMMIT),
        ShortBuildIdentifier(GX_LAUNCHER_RUN),
        GX_ENGINE_VERSION,
        ShortBuildIdentifier(GX_ENGINE_COMMIT),
        ShortBuildIdentifier(GX_BASE_SHELL_RUN),
        gameDataExists ? @"Установлено" : @"Отсутствует",
        gameDataSize,
        enhancedInstalled ? @"Установлено" : @"Не установлено",
        contraInstalled ? @"Установлено" : @"Не установлено",
        installedModsText,
        settingsExists ? @"Присутствует" : @"Отсутствует",
        enhancedSettingsText,
        contraSettingsText,
        currentLogText,
        sessionLogsText];
}

- (void)buildDiagnostics
{
    self.diagnosticsView = [[UIView alloc] init];
    self.diagnosticsView.translatesAutoresizingMaskIntoConstraints = NO;
    self.diagnosticsView.backgroundColor = UIColor.blackColor;
    self.diagnosticsView.hidden = YES;
    [self.view addSubview:self.diagnosticsView];

    [NSLayoutConstraint activateConstraints:@[
        [self.diagnosticsView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:28.0],
        [self.diagnosticsView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-28.0],
        [self.diagnosticsView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:18.0],
        [self.diagnosticsView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-18.0],
    ]];

    UILabel *title = MakeLabel(@"Diagnostics", 26.0, UIFontWeightBold);
    title.textAlignment = NSTextAlignmentLeft;

    UILabel *note = MakeLabel(@"Build, installed content and crash logs. The last 10 app sessions are kept automatically.", 13.0, UIFontWeightRegular);
    note.textAlignment = NSTextAlignmentLeft;
    note.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = YES;

    self.diagnosticsText = MakeLabel(@"", 15.0, UIFontWeightRegular);
    self.diagnosticsText.textAlignment = NSTextAlignmentLeft;
    self.diagnosticsText.font = [UIFont monospacedSystemFontOfSize:15.0 weight:UIFontWeightRegular];
    [scroll addSubview:self.diagnosticsText];

    UIButton *refresh = MakeButton(@"Refresh", self, @selector(refreshDiagnostics));
    self.shareDiagnosticsButton = MakeButton(@"Share report + logs", self, @selector(shareDiagnostics));
    UIButton *clearLogs = MakeButton(@"Clear logs", self, @selector(clearDiagnosticsLogs));
    UIButton *back = MakeButton(@"Back", self, @selector(hideDiagnostics));

    clearLogs.backgroundColor = [UIColor colorWithRed:0.24 green:0.06 blue:0.06 alpha:1.0];

    [refresh.widthAnchor constraintEqualToConstant:160.0].active = YES;
    [self.shareDiagnosticsButton.widthAnchor constraintEqualToConstant:220.0].active = YES;
    [clearLogs.widthAnchor constraintEqualToConstant:160.0].active = YES;
    [back.widthAnchor constraintEqualToConstant:160.0].active = YES;

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[
        refresh, self.shareDiagnosticsButton, clearLogs, back
    ]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.alignment = UIStackViewAlignmentCenter;
    buttons.spacing = 12.0;

    [self.diagnosticsView addSubview:title];
    [self.diagnosticsView addSubview:note];
    [self.diagnosticsView addSubview:scroll];
    [self.diagnosticsView addSubview:buttons];

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:self.diagnosticsView.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:self.diagnosticsView.trailingAnchor],
        [title.topAnchor constraintEqualToAnchor:self.diagnosticsView.topAnchor],

        [note.leadingAnchor constraintEqualToAnchor:self.diagnosticsView.leadingAnchor],
        [note.trailingAnchor constraintEqualToAnchor:self.diagnosticsView.trailingAnchor],
        [note.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4.0],

        [scroll.leadingAnchor constraintEqualToAnchor:self.diagnosticsView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.diagnosticsView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:note.bottomAnchor constant:14.0],
        [scroll.bottomAnchor constraintEqualToAnchor:buttons.topAnchor constant:-14.0],

        [self.diagnosticsText.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [self.diagnosticsText.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [self.diagnosticsText.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [self.diagnosticsText.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [self.diagnosticsText.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],

        [buttons.centerXAnchor constraintEqualToAnchor:self.diagnosticsView.centerXAnchor],
        [buttons.bottomAnchor constraintEqualToAnchor:self.diagnosticsView.bottomAnchor],
    ]];
}

- (void)showDiagnostics
{
    self.menuStack.hidden = YES;
    self.settingsView.hidden = YES;
    self.diagnosticsView.hidden = NO;
    self.modsView.hidden = YES;
    [self refreshDiagnostics];
}

- (void)hideDiagnostics
{
    self.diagnosticsView.hidden = YES;
    if (self.webLauncherActive)
    {
        self.menuStack.hidden = YES;
        self.webView.hidden = NO;
    }
    else
    {
        self.menuStack.hidden = NO;
    }
}

- (void)refreshDiagnostics
{
    if (self.diagnosticsScanRunning)
        return;

    self.diagnosticsScanRunning = YES;
    self.diagnosticsText.text = [self diagnosticsTextWithGameDataSize:@"Вычисление…"];

    NSString *gameDataPath = GXHubInstalledProfilePath(@"online");
    BOOL exists = GXHubProfileInstalled(@"online");

    __weak GXProfileLauncherViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long bytes = exists ? DirectorySizeAtPath(gameDataPath) : 0;
        NSString *sizeText = exists ? HumanReadableBytes(bytes) : @"н/д";

        dispatch_async(dispatch_get_main_queue(), ^{
            GXProfileLauncherViewController *strongSelf = weakSelf;
            if (strongSelf == nil)
                return;

            strongSelf.diagnosticsScanRunning = NO;
            strongSelf.diagnosticsText.text =
                [strongSelf diagnosticsTextWithGameDataSize:sizeText];
        });
    });
}

- (void)clearDiagnosticsLogs
{
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Очистить журналы диагностики?"
                                            message:@"Будут удалены журнал текущей сессии и все сохранённые журналы прошлых сессий."
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Отмена"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    __weak GXProfileLauncherViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Очистить логи"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *action) {
        if (gDiagnosticClearCallback != nullptr)
        {
            gDiagnosticClearCallback();
        }
        else
        {
            NSFileManager *fileManager = [NSFileManager defaultManager];
            for (NSString *name in DiagnosticSessionLogNames())
                [fileManager removeItemAtPath:DocumentsFilePath(name) error:nil];
            [fileManager removeItemAtPath:DocumentsFilePath(@"generals-stderr-prev.log") error:nil];
        }
        [NSFileManager.defaultManager removeItemAtPath:DiagnosticsExportDirectoryPath() error:nil];

        GXProfileLauncherViewController *strongSelf = weakSelf;
        if (strongSelf != nil)
        {
            strongSelf.diagnosticsScanRunning = NO;
            [strongSelf refreshDiagnostics];
        }
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}


- (void)shareDiagnostics
{
    NSString *report = self.diagnosticsText.text;
    if (report.length == 0)
        report = [self diagnosticsTextWithGameDataSize:@"Откройте «Диагностика» для обновления размера"] ?: @"";

    NSArray<NSURL *> *exportedFiles = ExportDiagnosticsSnapshot(report);
    NSMutableArray *items = [NSMutableArray arrayWithArray:exportedFiles];
    if (items.count == 0)
        [items addObject:report.length > 0 ? report : @"Диагностика Generals ZH недоступна"];

    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];

    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover != nil)
    {
        UIView *anchor = (self.webLauncherActive && !self.webView.hidden && self.webView.window != nil)
            ? self.webView
            : self.view;
        popover.sourceView = anchor;
        popover.sourceRect = CGRectMake(CGRectGetMidX(anchor.bounds), CGRectGetMidY(anchor.bounds), 1.0, 1.0);
        popover.permittedArrowDirections = 0;
    }

    [self presentViewController:activity animated:YES completion:nil];
}

- (BOOL)prefersStatusBarHidden
{
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskLandscape;
}

- (BOOL)shouldAutorotate
{
    return YES;
}

- (void)launchVanilla
{
    SetSelectedProfile(@"vanilla");
}

- (void)launchOnline
{
    SetSelectedProfile(@"online");
}

- (void)launchEnhanced
{
    SetSelectedProfile(@"enhanced");
}

- (void)launchContra
{
    SetSelectedProfile(@"contra-x");
}

- (NSString *)valueForKey:(NSString *)key inContents:(NSString *)contents
{
    NSString *prefix = [key stringByAppendingString:@"="];
    for (NSString *line in [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]])
    {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *compact = [trimmed stringByReplacingOccurrencesOfString:@" " withString:@""];
        if ([compact hasPrefix:prefix])
        {
            NSRange equals = [trimmed rangeOfString:@"="];
            if (equals.location != NSNotFound)
            {
                return [[trimmed substringFromIndex:equals.location + 1]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
        }
    }
    return nil;
}

- (float)floatSetting:(NSString *)key contents:(NSString *)contents fallback:(float)fallback
{
    NSString *value = [self valueForKey:key inContents:contents];
    return value.length > 0 ? value.floatValue : fallback;
}

- (BOOL)boolSetting:(NSString *)key contents:(NSString *)contents fallback:(BOOL)fallback
{
    NSString *value = [[self valueForKey:key inContents:contents] lowercaseString];
    if ([value isEqualToString:@"yes"] || [value isEqualToString:@"true"] || [value isEqualToString:@"1"])
        return YES;
    if ([value isEqualToString:@"no"] || [value isEqualToString:@"false"] || [value isEqualToString:@"0"])
        return NO;
    return fallback;
}

- (NSInteger)segmentIndexForValue:(NSString *)value choices:(NSArray<NSString *> *)choices fallback:(NSInteger)fallback
{
    for (NSInteger i = 0; i < (NSInteger)choices.count; ++i)
    {
        if ([value caseInsensitiveCompare:choices[i]] == NSOrderedSame)
            return i;
    }
    return fallback;
}

- (void)resetEnhancedSettingsControls
{
    self.enhancedTextureResolutionSegment.selectedSegmentIndex = 1;
    self.enhancedUIQualitySegment.selectedSegmentIndex = 1;
    self.enhancedInfantryIconScaleSegment.selectedSegmentIndex = 0;
    self.enhancedCameosSegment.selectedSegmentIndex = 1;
    self.enhancedAIScriptsSegment.selectedSegmentIndex = 0;
}

- (void)loadGraphicsSettingsFromValues:(NSDictionary<NSString *, NSString *> *)values
{
    self.shadow3DSwitch.on = SettingBoolValue(values, @"UseShadowVolumes", NO);
    self.shadow2DSwitch.on = SettingBoolValue(values, @"UseShadowDecals", YES);
    self.cloudShadowsSwitch.on = SettingBoolValue(values, @"UseCloudMap", NO);
    self.groundLightingSwitch.on = SettingBoolValue(values, @"UseLightMap", YES);
    self.softWaterSwitch.on = SettingBoolValue(values, @"ShowSoftWaterEdge", YES);
    self.buildingOcclusionSwitch.on = SettingBoolValue(values, @"BuildingOcclusion", YES);
    self.showPropsSwitch.on = SettingBoolValue(values, @"ShowTrees", YES);
    self.extraAnimationsSwitch.on = SettingBoolValue(values, @"ExtraAnimations", YES);
    self.dynamicLODSwitch.on = SettingBoolValue(values, @"DynamicLOD", NO);
    self.heatEffectsSwitch.on = SettingBoolValue(values, @"HeatEffects", NO);

    NSInteger textureReduction = [SettingValue(values, @"TextureReduction", @"0") integerValue];
    self.textureQualitySegment.selectedSegmentIndex = MAX(0, MIN(2, textureReduction));

    NSInteger particleCount = [SettingValue(values, @"MaxParticleCount", @"2500") integerValue];
    self.particleQualitySegment.selectedSegmentIndex = particleCount <= 1200 ? 0 : (particleCount >= 4000 ? 2 : 1);

    NSString *filter = SettingValue(values, @"TextureFilter", @"Anisotropic");
    self.textureFilterSegment.selectedSegmentIndex =
        [filter caseInsensitiveCompare:@"Bilinear"] == NSOrderedSame ? 0 :
        ([filter caseInsensitiveCompare:@"Trilinear"] == NSOrderedSame ? 1 : 2);

    NSInteger anisotropy = [SettingValue(values, @"AnisotropyLevel", @"8") integerValue];
    self.anisotropySegment.selectedSegmentIndex = anisotropy >= 16 ? 3 : (anisotropy >= 8 ? 2 : (anisotropy >= 4 ? 1 : 0));

    NSInteger antiAliasing = [SettingValue(values, @"AntiAliasing", @"0") integerValue];
    self.msaaSegment.selectedSegmentIndex = antiAliasing >= 8 ? 3 : (antiAliasing >= 4 ? 2 : (antiAliasing >= 2 ? 1 : 0));
    [self textureFilterChanged:self.textureFilterSegment];
}

- (void)loadEnhancedSettingsControls
{
    EnsureDefaultEnhancedSettings();
    NSDictionary<NSString *, NSString *> *values = ReadKeyValueFile(EnhancedSettingsPath());

    self.enhancedTextureResolutionSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"TextureResolution", @"High")
                           choices:@[@"Vanilla", @"High"]
                          fallback:1];
    self.enhancedUIQualitySegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"UIQuality", @"FHD")
                           choices:@[@"HD", @"FHD", @"QHD"]
                          fallback:1];
    self.enhancedInfantryIconScaleSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"InfantryIconScale", @"100")
                           choices:@[@"100", @"75", @"50"]
                          fallback:0];
    self.enhancedCameosSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"Cameos", @"HD")
                           choices:@[@"SD", @"HD"]
                          fallback:1];
    self.enhancedAIScriptsSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"AIScripts", @"Default")
                           choices:@[@"Default", @"Restrained", @"Skynet"]
                          fallback:0];

}

- (void)resetContraSettingsControls
{
    NSDictionary<NSString *, NSString *> *defaults = DefaultContraSettings();
    self.contraControlBarSegment.selectedSegmentIndex = 0;
    self.contraCameosSegment.selectedSegmentIndex = 0;
    self.contraMusicSegment.selectedSegmentIndex = 0;
    self.contraVoicesSegment.selectedSegmentIndex = 0;
    self.contraHotkeysSegment.selectedSegmentIndex = 0;
    self.contraHotkeyLanguageSegment.selectedSegmentIndex = 0;
    self.contraPortraitsSegment.selectedSegmentIndex = 0;
    self.contraFogSwitch.on = SettingBoolValue(defaults, @"FogEffects", NO);
    self.contraWaterSwitch.on = SettingBoolValue(defaults, @"WaterEffects", YES);
    self.contraExtraBuildingPropsSwitch.on = SettingBoolValue(defaults, @"ExtraBuildingProps", YES);

    self.shadow3DSwitch.on = SettingBoolValue(defaults, @"UseShadowVolumes", NO);
    self.shadow2DSwitch.on = SettingBoolValue(defaults, @"UseShadowDecals", YES);
    self.cloudShadowsSwitch.on = SettingBoolValue(defaults, @"UseCloudMap", NO);
    self.groundLightingSwitch.on = SettingBoolValue(defaults, @"UseLightMap", YES);
    self.softWaterSwitch.on = SettingBoolValue(defaults, @"ShowSoftWaterEdge", YES);
    self.buildingOcclusionSwitch.on = SettingBoolValue(defaults, @"BuildingOcclusion", YES);
    self.showPropsSwitch.on = SettingBoolValue(defaults, @"ShowTrees", YES);
    self.extraAnimationsSwitch.on = SettingBoolValue(defaults, @"ExtraAnimations", YES);
    self.dynamicLODSwitch.on = SettingBoolValue(defaults, @"DynamicLOD", NO);
    self.heatEffectsSwitch.on = SettingBoolValue(defaults, @"HeatEffects", NO);
    self.textureQualitySegment.selectedSegmentIndex = 0;
    self.particleQualitySegment.selectedSegmentIndex = 1;
    self.textureFilterSegment.selectedSegmentIndex = 2;
    self.anisotropySegment.selectedSegmentIndex = 2;
    self.msaaSegment.selectedSegmentIndex = 0;
    [self textureFilterChanged:self.textureFilterSegment];
}

- (void)loadContraSettingsControls
{
    EnsureDefaultContraSettings();
    NSDictionary<NSString *, NSString *> *values = ReadKeyValueFile(ContraSettingsPath());

    self.contraControlBarSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"ControlBar", @"Contra")
                           choices:@[@"Contra", @"Pro", @"Standard"]
                          fallback:0];
    self.contraCameosSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"Cameos", @"Standard")
                           choices:@[@"Standard", @"HD"]
                          fallback:0];
    self.contraMusicSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"Music", @"Standard")
                           choices:@[@"Standard", @"Enhanced", @"The Score"]
                          fallback:0];
    self.contraVoicesSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"UnitVoices", @"English")
                           choices:@[@"English", @"Native"]
                          fallback:0];
    self.contraHotkeysSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"Hotkeys", @"Original")
                           choices:@[@"Original", @"Leikeze"]
                          fallback:0];
    self.contraHotkeyLanguageSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"HotkeyLanguage", @"English")
                           choices:@[@"English", @"Russian"]
                          fallback:0];
    self.contraPortraitsSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"Portraits", @"Standard")
                           choices:@[@"Standard", @"Funny"]
                          fallback:0];

    self.contraFogSwitch.on = SettingBoolValue(values, @"FogEffects", NO);
    self.contraWaterSwitch.on = SettingBoolValue(values, @"WaterEffects", YES);
    self.contraExtraBuildingPropsSwitch.on = SettingBoolValue(values, @"ExtraBuildingProps", YES);

}

- (void)resetSettingsControls
{
    if ([self.settingsProfileId isEqualToString:@"enhanced"])
    {
        [self resetEnhancedSettingsControls];
        return;
    }
    if ([self.settingsProfileId isEqualToString:@"contra-x"])
    {
        [self resetContraSettingsControls];
        return;
    }

    [self resetContraSettingsControls];
    [self resetEnhancedSettingsControls];
    [self loadGraphicsSettingsFromValues:DefaultContraSettings()];

    self.maxCameraSlider.value = 550.0f;
    self.minCameraSlider.value = 70.0f;
    self.cameraPitchSlider.value = 37.0f;
    self.enforceMaxSwitch.on = NO;
    self.scrollSpeedSlider.value = 1.0f;
    self.drawDistanceSlider.value = 1.20f;
    self.fpsLimitSwitch.on = YES;
    self.fpsSlider.value = 60.0f;
    [self settingsSliderChanged:nil];
    [self fpsLimitChanged:self.fpsLimitSwitch];
}

- (void)loadSettingsControls
{
    if ([self.settingsProfileId isEqualToString:@"enhanced"])
    {
        [self loadEnhancedSettingsControls];
        self.settingsStatus.text = @"";
        return;
    }
    if ([self.settingsProfileId isEqualToString:@"contra-x"])
    {
        [self loadContraSettingsControls];
        self.settingsStatus.text = @"";
        return;
    }

    NSString *bundledProfile = BundledAutoLaunchProfile();
    if ([bundledProfile isEqualToString:@"enhanced"])
        [self loadEnhancedSettingsControls];
    else if ([bundledProfile isEqualToString:@"contra-x"])
        [self loadContraSettingsControls];

    [self loadGraphicsSettingsFromValues:ReadKeyValueFile(EngineOptionsPath())];

    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfFile:IPadOverridesPath()
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
    if (contents == nil)
    {
        self.maxCameraSlider.value = 550.0f;
        self.minCameraSlider.value = 70.0f;
        self.cameraPitchSlider.value = 37.0f;
        self.enforceMaxSwitch.on = NO;
        self.scrollSpeedSlider.value = 1.0f;
        self.drawDistanceSlider.value = 1.20f;
        self.fpsLimitSwitch.on = YES;
        self.fpsSlider.value = 60.0f;
        self.settingsStatus.text = @"Используются параметры камеры по умолчанию.";
        if (error != nil)
        {
            fprintf(stderr, "WARNING: iOS launcher could not read iPadOverrides.ini: %s\n",
                    [[error description] UTF8String]);
        }
    }
    else
    {
        self.maxCameraSlider.value = [self floatSetting:@"MaxCameraHeight" contents:contents fallback:550.0f];
        self.minCameraSlider.value = [self floatSetting:@"MinCameraHeight" contents:contents fallback:70.0f];
        self.cameraPitchSlider.value = [self floatSetting:@"CameraPitch" contents:contents fallback:37.0f];
        self.enforceMaxSwitch.on = [self boolSetting:@"EnforceMaxCameraHeight" contents:contents fallback:NO];
        self.scrollSpeedSlider.value = [self floatSetting:@"KeyboardScrollSpeedFactor" contents:contents fallback:1.0f];
        self.drawDistanceSlider.value = [self floatSetting:@"TerrainDrawDistanceScale" contents:contents fallback:1.20f];
        self.fpsLimitSwitch.on = [self boolSetting:@"UseFPSLimit" contents:contents fallback:YES];
        self.fpsSlider.value = [self floatSetting:@"FramesPerSecondLimit" contents:contents fallback:60.0f];
        self.settingsStatus.text = @"";
    }

    [self settingsSliderChanged:nil];
    [self fpsLimitChanged:self.fpsLimitSwitch];
}

- (void)showSettings
{
    self.settingsProfileId = nil;
    [self.settingsView removeFromSuperview];
    self.settingsView = nil;
    [self buildSettings];
    [self loadSettingsControls];
    self.menuStack.hidden = YES;
    self.modsView.hidden = YES;
    self.diagnosticsView.hidden = YES;
    self.settingsView.hidden = NO;
}

- (void)hideSettings
{
    BOOL returnToMods = self.settingsProfileId.length > 0;
    self.settingsView.hidden = YES;

    if (self.webLauncherActive)
    {
        self.settingsProfileId = nil;
        self.menuStack.hidden = YES;
        self.modsView.hidden = YES;
        self.diagnosticsView.hidden = YES;
        self.webView.hidden = NO;
        [self sendWebEvent:@"stateChanged" payload:[self webLauncherState]];
        return;
    }

    if (returnToMods)
    {
        self.settingsProfileId = nil;
        self.modsView.hidden = NO;
        [self reloadModsList];
    }
    else
    {
        self.menuStack.hidden = NO;
    }
}

- (void)settingsSliderChanged:(UISlider *)sender
{
    auto snap = [](float value, float step) -> float {
        return roundf(value / step) * step;
    };

    self.maxCameraSlider.value = snap(self.maxCameraSlider.value, 10.0f);
    self.minCameraSlider.value = snap(self.minCameraSlider.value, 5.0f);
    self.cameraPitchSlider.value = snap(self.cameraPitchSlider.value, 1.0f);
    self.scrollSpeedSlider.value = snap(self.scrollSpeedSlider.value, 0.1f);
    self.drawDistanceSlider.value = snap(self.drawDistanceSlider.value, 0.05f);
    self.fpsSlider.value = snap(self.fpsSlider.value, 5.0f);

    self.maxCameraValue.text = [NSString stringWithFormat:@"%.0f", self.maxCameraSlider.value];
    self.minCameraValue.text = [NSString stringWithFormat:@"%.0f", self.minCameraSlider.value];
    self.cameraPitchValue.text = [NSString stringWithFormat:@"%.0f°", self.cameraPitchSlider.value];
    self.scrollSpeedValue.text = [NSString stringWithFormat:@"%.1fx", self.scrollSpeedSlider.value];
    self.drawDistanceValue.text = [NSString stringWithFormat:@"%.2fx", self.drawDistanceSlider.value];
    self.fpsValue.text = [NSString stringWithFormat:@"%.0f", self.fpsSlider.value];
}

- (void)fpsLimitChanged:(UISwitch *)sender
{
    BOOL enabled = self.fpsLimitSwitch.on;
    self.fpsSlider.enabled = enabled;
    self.fpsSlider.alpha = enabled ? 1.0 : 0.35;
    self.fpsValue.alpha = enabled ? 1.0 : 0.35;
}

- (void)textureFilterChanged:(UISegmentedControl *)sender
{
    BOOL anisotropic = self.textureFilterSegment.selectedSegmentIndex == 2;
    self.anisotropySegment.enabled = anisotropic;
    self.anisotropySegment.alpha = anisotropic ? 1.0 : 0.35;
}

- (BOOL)saveGraphicsOptions:(NSError **)error
{
    NSInteger particleIndex = self.particleQualitySegment.selectedSegmentIndex;
    NSInteger particleCount = particleIndex == 0 ? 1000 : (particleIndex == 2 ? 5000 : 2500);
    NSArray<NSString *> *filters = @[@"Bilinear", @"Trilinear", @"Anisotropic"];
    NSString *filter = filters[MAX(0, MIN(2, self.textureFilterSegment.selectedSegmentIndex))];
    NSArray<NSString *> *anisotropyLevels = @[@"2", @"4", @"8", @"16"];
    NSString *anisotropy = anisotropyLevels[MAX(0, MIN(3, self.anisotropySegment.selectedSegmentIndex))];
    NSArray<NSString *> *msaaLevels = @[@"0", @"2", @"4", @"8"];
    NSString *antiAliasing = msaaLevels[MAX(0, MIN(3, self.msaaSegment.selectedSegmentIndex))];

    NSMutableDictionary<NSString *, NSString *> *options = ReadKeyValueFile(EngineOptionsPath());
    options[@"IdealStaticGameLOD"] = @"High";
    options[@"StaticGameLOD"] = @"Custom";
    options[@"UseShadowVolumes"] = self.shadow3DSwitch.on ? @"Yes" : @"No";
    options[@"UseShadowDecals"] = self.shadow2DSwitch.on ? @"Yes" : @"No";
    options[@"UseCloudMap"] = self.cloudShadowsSwitch.on ? @"Yes" : @"No";
    options[@"UseLightMap"] = self.groundLightingSwitch.on ? @"Yes" : @"No";
    options[@"ShowSoftWaterEdge"] = self.softWaterSwitch.on ? @"Yes" : @"No";
    options[@"BuildingOcclusion"] = self.buildingOcclusionSwitch.on ? @"Yes" : @"No";
    options[@"ShowTrees"] = self.showPropsSwitch.on ? @"Yes" : @"No";
    options[@"ExtraAnimations"] = self.extraAnimationsSwitch.on ? @"Yes" : @"No";
    options[@"DynamicLOD"] = self.dynamicLODSwitch.on ? @"Yes" : @"No";
    options[@"HeatEffects"] = self.heatEffectsSwitch.on ? @"Yes" : @"No";
    options[@"TextureReduction"] = [NSString stringWithFormat:@"%ld", (long)self.textureQualitySegment.selectedSegmentIndex];
    options[@"MaxParticleCount"] = [NSString stringWithFormat:@"%ld", (long)particleCount];
    options[@"TextureFilter"] = filter;
    options[@"AnisotropyLevel"] = anisotropy;
    options[@"AntiAliasing"] = antiAliasing;
    return WriteKeyValueFile(EngineOptionsPath(), options, error);
}

- (BOOL)saveEnhancedSettingsAndOptions:(NSError **)error
{
    NSArray<NSString *> *textureModes = @[@"Vanilla", @"High"];
    NSArray<NSString *> *uiModes = @[@"HD", @"FHD", @"QHD"];
    NSArray<NSString *> *infantryIconScales = @[@"100", @"75", @"50"];
    NSArray<NSString *> *cameoModes = @[@"SD", @"HD"];
    NSArray<NSString *> *aiModes = @[@"Default", @"Restrained", @"Skynet"];

    NSMutableDictionary<NSString *, NSString *> *enhanced = [DefaultEnhancedSettings() mutableCopy];
    enhanced[@"TextureResolution"] = textureModes[MAX(0, MIN(1, self.enhancedTextureResolutionSegment.selectedSegmentIndex))];
    enhanced[@"UIQuality"] = uiModes[MAX(0, MIN(2, self.enhancedUIQualitySegment.selectedSegmentIndex))];
    enhanced[@"InfantryIconScale"] = infantryIconScales[MAX(0, MIN(2, self.enhancedInfantryIconScaleSegment.selectedSegmentIndex))];
    enhanced[@"Cameos"] = cameoModes[MAX(0, MIN(1, self.enhancedCameosSegment.selectedSegmentIndex))];
    enhanced[@"AIScripts"] = aiModes[MAX(0, MIN(2, self.enhancedAIScriptsSegment.selectedSegmentIndex))];

    return WriteKeyValueFile(EnhancedSettingsPath(), enhanced, error);
}

- (BOOL)saveContraSettingsAndOptions:(NSError **)error
{
    NSArray<NSString *> *controlBars = @[@"Contra", @"Pro", @"Standard"];
    NSArray<NSString *> *cameos = @[@"Standard", @"HD"];
    NSArray<NSString *> *music = @[@"Standard", @"Enhanced", @"The Score"];
    NSArray<NSString *> *voices = @[@"English", @"Native"];
    NSArray<NSString *> *hotkeys = @[@"Original", @"Leikeze"];
    NSArray<NSString *> *languages = @[@"English", @"Russian"];
    NSArray<NSString *> *portraits = @[@"Standard", @"Funny"];

    NSMutableDictionary<NSString *, NSString *> *contra = [DefaultContraSettings() mutableCopy];
    contra[@"ControlBar"] = controlBars[self.contraControlBarSegment.selectedSegmentIndex];
    contra[@"Cameos"] = cameos[self.contraCameosSegment.selectedSegmentIndex];
    contra[@"Music"] = music[self.contraMusicSegment.selectedSegmentIndex];
    contra[@"UnitVoices"] = voices[self.contraVoicesSegment.selectedSegmentIndex];
    contra[@"Hotkeys"] = hotkeys[self.contraHotkeysSegment.selectedSegmentIndex];
    contra[@"HotkeyLanguage"] = languages[self.contraHotkeyLanguageSegment.selectedSegmentIndex];
    contra[@"Portraits"] = portraits[self.contraPortraitsSegment.selectedSegmentIndex];
    contra[@"FogEffects"] = self.contraFogSwitch.on ? @"Yes" : @"No";
    contra[@"WaterEffects"] = self.contraWaterSwitch.on ? @"Yes" : @"No";
    contra[@"ExtraBuildingProps"] = self.contraExtraBuildingPropsSwitch.on ? @"Yes" : @"No";

    return WriteKeyValueFile(ContraSettingsPath(), contra, error);
}

- (void)saveSettings
{
    NSError *error = nil;
    if ([self.settingsProfileId isEqualToString:@"enhanced"] ||
        [self.settingsProfileId isEqualToString:@"contra-x"])
    {
        BOOL ok = [self.settingsProfileId isEqualToString:@"enhanced"]
            ? [self saveEnhancedSettingsAndOptions:&error]
            : [self saveContraSettingsAndOptions:&error];
        if (ok)
        {
            self.settingsStatus.text = @"Настройки мода сохранены. Изменения применятся при следующем запуске.";
            self.settingsStatus.textColor = [UIColor systemGreenColor];
            fprintf(stderr,
                    "[HUB-SETTINGS] saved profile='%s' path='%s'\n",
                    self.settingsProfileId.UTF8String,
                    ([self.settingsProfileId isEqualToString:@"enhanced"]
                        ? EnhancedSettingsPath()
                        : ContraSettingsPath()).fileSystemRepresentation);
        }
        else
        {
            self.settingsStatus.text = @"Не удалось сохранить. См. generals-stderr.log.";
            self.settingsStatus.textColor = [UIColor systemRedColor];
        }
        return;
    }

    NSString *contents = [NSString stringWithFormat:
        @"GameData\n"
         "  MaxCameraHeight = %.1f\n"
         "  MinCameraHeight = %.1f\n"
         "  CameraPitch = %.1f\n"
         "  EnforceMaxCameraHeight = %@\n"
         "  KeyboardScrollSpeedFactor = %.1f\n"
         "  TerrainDrawDistanceScale = %.2f\n"
         "  UseFPSLimit = %@\n"
         "  FramesPerSecondLimit = %.0f\n"
         "End\n",
        self.maxCameraSlider.value,
        self.minCameraSlider.value,
        self.cameraPitchSlider.value,
        self.enforceMaxSwitch.on ? @"Yes" : @"No",
        self.scrollSpeedSlider.value,
        self.drawDistanceSlider.value,
        self.fpsLimitSwitch.on ? @"Yes" : @"No",
        self.fpsSlider.value];

    BOOL cameraOK = [contents writeToFile:IPadOverridesPath()
                               atomically:YES
                                 encoding:NSUTF8StringEncoding
                                    error:&error];
    BOOL profileOK = cameraOK && [self saveGraphicsOptions:&error];
    NSString *bundledProfile = BundledAutoLaunchProfile();
    if (profileOK && [bundledProfile isEqualToString:@"enhanced"])
        profileOK = [self saveEnhancedSettingsAndOptions:&error];
    else if (profileOK && [bundledProfile isEqualToString:@"contra-x"])
        profileOK = [self saveContraSettingsAndOptions:&error];

    if (cameraOK && profileOK)
    {
        self.settingsStatus.text = @"Сохранено. Изменения применятся при следующем запуске игры.";
        self.settingsStatus.textColor = [UIColor systemGreenColor];
        fprintf(stderr,
                "[HUB-SETTINGS] saved shared options=%s camera=%s\n",
                EngineOptionsPath().fileSystemRepresentation,
                IPadOverridesPath().fileSystemRepresentation);
    }
    else
    {
        self.settingsStatus.text = @"Не удалось сохранить. См. generals-stderr.log.";
        self.settingsStatus.textColor = [UIColor systemRedColor];
        fprintf(stderr, "ERROR: iOS launcher failed to save settings: %s\n",
                error != nil ? [[error description] UTF8String] : "unknown");
    }
}

- (void)resetSettings
{
    [self resetSettingsControls];
    self.settingsStatus.text = @"Значения по умолчанию загружены. Нажмите «Сохранить» для применения.";
    self.settingsStatus.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
}

@end

const char *GeneralsXRunIOSProfileLauncher()
{
    const char *forcedProfile = getenv("GX_LAUNCH_PROFILE");
    if (IsSupportedProfile(forcedProfile))
    {
        strlcpy(gSelectedProfile, forcedProfile, sizeof(gSelectedProfile));
        fprintf(stderr, "INFO: iOS launcher forced profile: %s\n", gSelectedProfile);
        return gSelectedProfile;
    }

    NSString *autoProfile = BundledAutoLaunchProfile();
    if (autoProfile != nil)
    {
        const char *utf8 = [autoProfile UTF8String];
        strlcpy(gSelectedProfile, utf8, sizeof(gSelectedProfile));

        if ([autoProfile isEqualToString:@"enhanced"])
        {
            fprintf(stderr,
                    "INFO: dedicated Enhanced launcher shown for settings access\n");
        }
        else if ([autoProfile isEqualToString:@"contra-x"])
        {
            fprintf(stderr,
                    "[CONTRA-SETTINGS] dedicated Contra launcher shown for settings access\n");
        }
        else
        {
            fprintf(stderr, "INFO: iOS launcher auto-selected bundled profile: %s\n",
                    gSelectedProfile);
            return gSelectedProfile;
        }
    }

    gLauncherFinished.store(false, std::memory_order_release);
    if (autoProfile == nil)
        strlcpy(gSelectedProfile, "vanilla", sizeof(gSelectedProfile));

    __block UIWindow *launcherWindow = nil;

    void (^presentLauncher)(void) = ^{
        UIWindowScene *scene = FindActiveWindowScene();
        if (scene != nil)
        {
            launcherWindow = [[UIWindow alloc] initWithWindowScene:scene];
            launcherWindow.frame = scene.coordinateSpace.bounds;
        }
        else
        {
            launcherWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }

        launcherWindow.windowLevel = UIWindowLevelNormal + 1.0;
        launcherWindow.rootViewController = [[GXProfileLauncherViewController alloc] init];
        [launcherWindow makeKeyAndVisible];

        fprintf(stderr, "INFO: iOS native launcher presented\n");
    };

    if ([NSThread isMainThread])
    {
        presentLauncher();
    }
    else
    {
        dispatch_sync(dispatch_get_main_queue(), presentLauncher);
    }

    if ([NSThread isMainThread])
    {
        while (!gLauncherFinished.load(std::memory_order_acquire))
        {
            @autoreleasepool
            {
                [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                                      beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            }
        }
    }
    else
    {
        while (!gLauncherFinished.load(std::memory_order_acquire))
        {
            usleep(10000);
        }
    }

    void (^dismissLauncher)(void) = ^{
        launcherWindow.hidden = YES;
        launcherWindow.rootViewController = nil;
        launcherWindow = nil;
    };

    if ([NSThread isMainThread])
    {
        dismissLauncher();
    }
    else
    {
        dispatch_sync(dispatch_get_main_queue(), dismissLauncher);
    }

    return gSelectedProfile;
}

#endif
