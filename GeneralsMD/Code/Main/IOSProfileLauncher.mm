#include "IOSProfileLauncher.h"
#import "IOSGameFileManager.h"

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

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
char gSelectedProfile[32] = "vanilla";
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

NSString *GameRootPath();

unsigned long long InstalledGameFilesSizeAtDocuments()
{
    NSString *documents = GameRootPath();
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDirectoryEnumerator<NSString *> *enumerator = [fileManager enumeratorAtPath:documents];
    if (enumerator == nil)
        return 0;

    unsigned long long total = 0;
    for (NSString *relativePath in enumerator)
    {
        NSString *lower = relativePath.lowercaseString;
        if ([lower isEqualToString:@"iosipadOverrides.ini"] ||
            [lower isEqualToString:@"zerohoursettings.ini"] ||
            [lower hasPrefix:@"generals-stderr"] ||
            [lower hasSuffix:@".zip"])
            continue;

        NSString *fullPath = [documents stringByAppendingPathComponent:relativePath];
        NSDictionary<NSFileAttributeKey, id> *attributes =
            [fileManager attributesOfItemAtPath:fullPath error:nil];
        if ([[attributes fileType] isEqualToString:NSFileTypeRegular])
            total += [attributes fileSize];
    }
    return total;
}

bool IsSupportedProfile(const char *profile)
{
    return profile != nullptr &&
        (strcmp(profile, "vanilla") == 0 ||
         strcmp(profile, "enhanced") == 0 ||
         strcmp(profile, "zerohour") == 0);
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

NSString *GameRootPath()
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return documents;
}

BOOL EnsureGameRootDirectory()
{
    NSString *root = GameRootPath();
    BOOL isDirectory = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:root isDirectory:&isDirectory])
        return isDirectory;
    return [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
}

NSString *IOSIPadOverridesPath()
{
    // Documents itself is the Generals ZH root; keep the INI beside all installed game files.
    return [GameRootPath() stringByAppendingPathComponent:@"iOSIPadOverrides.ini"];
}

NSString *ZeroHourSettingsPath()
{
    // Documents itself is the Generals ZH root; keep the INI beside all installed game files.
    return [GameRootPath() stringByAppendingPathComponent:@"ZeroHourSettings.ini"];
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

NSDictionary<NSString *, NSString *> *DefaultZeroHourSettings()
{
    return @{
        @"ControlBar": @"ZeroHour",
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
        @"AnisotropyLevel": @"8"
    };
}

void EnsureDefaultZeroHourSettings()
{
    EnsureGameRootDirectory();
    NSString *path = ZeroHourSettingsPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:path])
        return;

    NSError *error = nil;
    if (!WriteKeyValueFile(path, DefaultZeroHourSettings(), &error))
    {
        fprintf(stderr, "ERROR: failed to seed ZeroHourSettings.ini: %s\n",
                error != nil ? [[error description] UTF8String] : "unknown");
    }
}

bool ProfileDirectoryExists(NSString *profileDirectory)
{
    NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
    NSString *path = [[resourcePath stringByAppendingPathComponent:@"Profiles"]
                      stringByAppendingPathComponent:profileDirectory];

    BOOL isDirectory = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path
                                               isDirectory:&isDirectory] && isDirectory;
}

NSString *DefaultIOSIPadOverrides()
{
    // GeneralsX @feature dvorovrus 26/09/2026 Default shared iOS/iPad tuning.
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

void EnsureDefaultIOSIPadOverrides()
{
    EnsureGameRootDirectory();
    NSString *path = IOSIPadOverridesPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:path])
        return;

    NSError *error = nil;
    BOOL ok = [DefaultIOSIPadOverrides() writeToFile:path
                                      atomically:YES
                                        encoding:NSUTF8StringEncoding
                                           error:&error];
    if (ok)
    {
        fprintf(stderr, "INFO: iOS launcher seeded %s\n", path.fileSystemRepresentation);
    }
    else
    {
        fprintf(stderr, "ERROR: iOS launcher failed to seed iOSIPadOverrides.ini: %s\n",
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

UILabel *MakeLabel(NSString *text, CGFloat size, UIFontWeight weight)
{
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.numberOfLines = 0;
    return label;
}

UIVisualEffectView *MakeGlassBlurView(UIView *container)
{
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:effect];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    blur.userInteractionEnabled = NO;
    blur.alpha = 0.82;
    [container addSubview:blur];
    [NSLayoutConstraint activateConstraints:@[
        [blur.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [blur.topAnchor constraintEqualToAnchor:container.topAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:container.bottomAnchor]
    ]];
    [container sendSubviewToBack:blur];
    return blur;
}

UIButton *MakeButton(NSString *title, id target, SEL action)
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.52];
    button.layer.shadowColor = [UIColor colorWithRed:0.0 green:0.45 blue:1.0 alpha:1.0].CGColor;
    button.layer.shadowOpacity = 0.22;
    button.layer.shadowRadius = 13.0;
    button.layer.shadowOffset = CGSizeMake(0, 5);
    button.layer.cornerRadius = 10.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:0.28 alpha:1.0].CGColor;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:58.0].active = YES;
    return button;
}
}

@interface GXProfileLauncherViewController : UIViewController
@property(nonatomic, strong) UIStackView *menuStack;
@property(nonatomic, strong) UIView *settingsView;
@property(nonatomic, strong) UILabel *settingsStatus;
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

@property(nonatomic, strong) UISegmentedControl *zeroHourControlBarSegment;
@property(nonatomic, strong) UISegmentedControl *zeroHourCameosSegment;
@property(nonatomic, strong) UISegmentedControl *zeroHourMusicSegment;
@property(nonatomic, strong) UISegmentedControl *zeroHourVoicesSegment;
@property(nonatomic, strong) UISegmentedControl *zeroHourHotkeysSegment;
@property(nonatomic, strong) UISegmentedControl *zeroHourHotkeyLanguageSegment;
@property(nonatomic, strong) UISegmentedControl *zeroHourPortraitsSegment;
@property(nonatomic, strong) UISwitch *zeroHourFogSwitch;
@property(nonatomic, strong) UISwitch *zeroHourWaterSwitch;
@property(nonatomic, strong) UISwitch *zeroHourExtraBuildingPropsSwitch;

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

@property(nonatomic, strong) UIView *diagnosticsView;
@property(nonatomic, strong) UIView *modalBackdrop;
@property(nonatomic, strong) UIView *profileView;
@property(nonatomic, strong) UILabel *diagnosticsText;
@property(nonatomic, strong) UIView *gameFileView;
@property(nonatomic, strong) UIProgressView *gameFileProgress;
@property(nonatomic, strong) UILabel *gameFileStage;
@property(nonatomic, strong) UILabel *gameFileDetail;
@property(nonatomic, strong) UIButton *gameFileCancelButton;
@property(nonatomic, strong) UIButton *gameFileMinimizeButton;
@property(nonatomic, strong) UIButton *gameFileCloseButton;
@property(nonatomic, strong) UILabel *gameFilePercentLabel;
@property(nonatomic, strong) UIButton *shareDiagnosticsButton;
@property(nonatomic, strong) UIButton *gameFileStatusButton;
@property(nonatomic, assign) BOOL diagnosticsScanRunning;
@end

void GeneralsXSetIOSDiagnosticClearCallback(GeneralsXIOSDiagnosticClearCallback callback)
{
    gDiagnosticClearCallback = callback;
}

@implementation GXProfileLauncherViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.blackColor;
    EnsureDefaultIOSIPadOverrides();
    EnsureDefaultZeroHourSettings();

    [self buildMenu];

    self.modalBackdrop = [[UIView alloc] init];
    self.modalBackdrop.translatesAutoresizingMaskIntoConstraints = NO;
    self.modalBackdrop.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.48];
    self.modalBackdrop.hidden = YES;
    [self.view addSubview:self.modalBackdrop];
    MakeGlassBlurView(self.modalBackdrop);
    [NSLayoutConstraint activateConstraints:@[
        [self.modalBackdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.modalBackdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.modalBackdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.modalBackdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    [self buildSettings];
    [self buildDiagnostics];
    [self buildProfileModal];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    // Home launcher intentionally stays one page; its constraints are adaptive.
}

