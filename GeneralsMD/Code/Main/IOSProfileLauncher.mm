#include "IOSProfileLauncher.h"

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

NSString *IOSIPadOverridesPath()
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/iOSIPadOverrides.ini"];
}

NSString *ZeroHourНастройкиPath()
{
    return DocumentsFilePath(@"ZeroHourНастройки.ini");
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

NSDictionary<NSString *, NSString *> *DefaultZeroHourНастройки()
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

void EnsureDefaultZeroHourНастройки()
{
    NSString *path = ZeroHourНастройкиPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:path])
        return;

    NSError *error = nil;
    if (!WriteKeyValueFile(path, DefaultZeroHourНастройки(), &error))
    {
        fprintf(stderr, "ERROR: failed to seed ZeroHourНастройки.ini: %s\n",
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

UIButton *MakeButton(NSString *title, id target, SEL action)
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
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
@property(nonatomic, strong) UILabel *diagnosticsText;
@property(nonatomic, strong) UIButton *shareДиагностикаButton;
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
    EnsureDefaultZeroHourНастройки();

    [self buildMenu];
    [self buildНастройки];
    [self buildДиагностика];
}

- (void)buildMenu
{
    NSString *bundledProfile = BundledAutoLaunchProfile();
    BOOL dedicatedZeroHour = [bundledProfile isEqualToString:@"zerohour"];

    UILabel *title = MakeLabel(dedicatedZeroHour ? @"ZERO HOUR" : @"ZERO HOUR",
                               34.0,
                               UIFontWeightBold);
    UILabel *subtitle = MakeLabel(dedicatedZeroHour
                                      ? @"iOS/iPad"
                                      : @"iOS/iPad launcher",
                                  14.0,
                                  UIFontWeightRegular);
    subtitle.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];

    UIButton *gameFile = MakeButton(@"Скачать GameFile", self, @selector(downloadGameFile));
    UIButton *settings = MakeButton(@"Настройки", self, @selector(showНастройки));
    UIButton *diagnostics = MakeButton(@"Диагностика", self, @selector(showДиагностика));
    gameFile.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    settings.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    diagnostics.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];

    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObjects:title, subtitle, nil];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];

    if (dedicatedZeroHour)
    {
        UIButton *zeroHour = MakeButton(@"Запустить ZeroHour", self, @selector(launchZeroHour));
        [views addObject:zeroHour];
        [buttons addObject:zeroHour];
        fprintf(stderr, "INFO: iOS launcher running in dedicated Zero Hour mode\n");
    }
    else
    {
        UIButton *vanilla = MakeButton(@"ZeroHour 1.04", self, @selector(launchVanilla));
        [views addObject:vanilla];
        [buttons addObject:vanilla];

        if (ProfileDirectoryExists(@"enhanced"))
        {
            UIButton *enhanced = MakeButton(@"ZeroHour Enhanced", self, @selector(launchEnhanced));
            [views addObject:enhanced];
            [buttons addObject:enhanced];
            fprintf(stderr, "INFO: iOS launcher found Enhanced profile\n");
        }

        if (ProfileDirectoryExists(@"zerohour"))
        {
            UIButton *zeroHour = MakeButton(@"ZeroHour Beta 2 + Patch 1", self, @selector(launchZeroHour));
            [views addObject:zeroHour];
            [buttons addObject:zeroHour];
            fprintf(stderr, "INFO: iOS launcher found Zero Hour profile\n");
        }
    }

    [views addObject:gameFile];
    [buttons addObject:gameFile];
    [views addObject:settings];
    [buttons addObject:settings];
    [views addObject:diagnostics];
    [buttons addObject:diagnostics];

    for (UIButton *button in buttons)
        [button.widthAnchor constraintEqualToConstant:460.0].active = YES;

    self.menuStack = [[UIStackView alloc] initWithArrangedSubviews:views];
    self.menuStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.menuStack.axis = UILayoutConstraintAxisVertical;
    self.menuStack.alignment = UIStackViewAlignmentCenter;
    self.menuStack.spacing = 12.0;
    [self.menuStack setCustomSpacing:26.0 afterView:subtitle];

    [self.view addSubview:self.menuStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.menuStack.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor],
        [self.menuStack.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
    ]];
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

- (void)buildНастройки
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

    UILabel *title = MakeLabel(@"Настройки ZeroHour", 26.0, UIFontWeightBold);
    title.textAlignment = NSTextAlignmentLeft;

    UILabel *note = MakeLabel(@"Эквиваленты настроек официального лаунчера ZeroHour для iOS/iPad. Изменения применяются при следующем запуске игры.", 13.0, UIFontWeightRegular);
    note.textAlignment = NSTextAlignmentLeft;
    note.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];

    self.zeroHourControlBarSegment = [self makeSegmented:@[@"ZeroHour", @"Pro", @"Standard"]];
    self.zeroHourCameosSegment = [self makeSegmented:@[@"Standard", @"HD"]];
    self.zeroHourMusicSegment = [self makeSegmented:@[@"Standard", @"Enhanced", @"The Score"]];
    self.zeroHourVoicesSegment = [self makeSegmented:@[@"English", @"Native"]];
    self.zeroHourHotkeysSegment = [self makeSegmented:@[@"Original", @"Leikeze"]];
    self.zeroHourHotkeyLanguageSegment = [self makeSegmented:@[@"English", @"Russian"]];
    self.zeroHourPortraitsSegment = [self makeSegmented:@[@"Standard", @"Funny"]];
    self.zeroHourFogSwitch = [[UISwitch alloc] init];
    self.zeroHourWaterSwitch = [[UISwitch alloc] init];
    self.zeroHourExtraBuildingPropsSwitch = [[UISwitch alloc] init];

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
    self.textureFilterSegment = [self makeSegmented:@[@"Bilinear", @"Trilinear", @"Anisotropic 8x"]];

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

    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self sectionLabel:@"ZERO HOUR"],
        [self segmentedRow:@"Панель управления" control:self.zeroHourControlBarSegment],
        [self segmentedRow:@"Качество иконок / портретов" control:self.zeroHourCameosSegment],
        [self segmentedRow:@"Music" control:self.zeroHourMusicSegment],
        [self segmentedRow:@"Голоса юнитов" control:self.zeroHourVoicesSegment],
        [self segmentedRow:@"Hotkeys" control:self.zeroHourHotkeysSegment],
        [self segmentedRow:@"Язык горячих клавиш" control:self.zeroHourHotkeyLanguageSegment],
        [self segmentedRow:@"Портреты генералов" control:self.zeroHourPortraitsSegment],
        [self switchRow:@"Эффекты тумана" control:self.zeroHourFogSwitch],
        [self switchRow:@"Эффекты воды" control:self.zeroHourWaterSwitch],
        [self switchRow:@"Дополнительные элементы зданий" control:self.zeroHourExtraBuildingPropsSwitch],

        [self sectionLabel:@"ГРАФИКА"],
        [self switchRow:@"3D-тени" control:self.shadow3DSwitch],
        [self switchRow:@"2D-тени" control:self.shadow2DSwitch],
        [self switchRow:@"Тени от облаков" control:self.cloudShadowsSwitch],
        [self switchRow:@"Освещение поверхности" control:self.groundLightingSwitch],
        [self switchRow:@"Плавные границы воды" control:self.softWaterSwitch],
        [self switchRow:@"Юниты за зданиями" control:self.buildingOcclusionSwitch],
        [self switchRow:@"Мелкие объекты / деревья" control:self.showPropsSwitch],
        [self switchRow:@"Дополнительные анимации" control:self.extraAnimationsSwitch],
        [self switchRow:@"Динамический LOD" control:self.dynamicLODSwitch],
        [self switchRow:@"Эффекты нагрева" control:self.heatEffectsSwitch],
        [self segmentedRow:@"Качество текстур" control:self.textureQualitySegment],
        [self segmentedRow:@"Частицы" control:self.particleQualitySegment],
        [self segmentedRow:@"Фильтрация текстур" control:self.textureFilterSegment],

        [self sectionLabel:@"КАМЕРА / ПРОИЗВОДИТЕЛЬНОСТЬ"],
        [self sliderRow:@"Максимальная высота камеры" slider:self.maxCameraSlider value:self.maxCameraValue],
        [self sliderRow:@"Минимальная высота камеры" slider:self.minCameraSlider value:self.minCameraValue],
        [self sliderRow:@"Наклон камеры" slider:self.cameraPitchSlider value:self.cameraPitchValue],
        [self switchRow:@"Ограничить максимальную высоту камеры" control:self.enforceMaxSwitch],
        [self sliderRow:@"Скорость прокрутки клавиатурой / у края экрана" slider:self.scrollSpeedSlider value:self.scrollSpeedValue],
        [self sliderRow:@"Дальность отрисовки ландшафта" slider:self.drawDistanceSlider value:self.drawDistanceValue],
        [self switchRow:@"Ограничение FPS" control:self.fpsLimitSwitch],
        [self sliderRow:@"Кадры в секунду" slider:self.fpsSlider value:self.fpsValue],
    ]];
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    controls.axis = UILayoutConstraintAxisVertical;
    controls.alignment = UIStackViewAlignmentFill;
    controls.spacing = 9.0;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = YES;
    [scroll addSubview:controls];

    UIButton *save = MakeButton(@"Сохранить", self, @selector(saveНастройки));
    UIButton *reset = MakeButton(@"Сбросить настройки", self, @selector(resetНастройки));
    UIButton *back = MakeButton(@"Назад", self, @selector(hideНастройки));

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

    [self resetНастройкиControls];
}

- (NSString *)diagnosticsTextWithGameDataSize:(NSString *)gameDataSize
{
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *shortVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    NSString *buildVersion = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
    NSString *resourcePath = bundle.resourcePath ?: @"";
    NSString *gameDataPath = [resourcePath stringByAppendingPathComponent:@"GameData"];

    BOOL gameDataExists = [[NSFileManager defaultManager] fileExistsAtPath:gameDataPath];
    BOOL enhancedУстановлено = ProfileDirectoryExists(@"enhanced");
    BOOL zeroHourУстановлено = ProfileDirectoryExists(@"zerohour");

    NSString *settingsPath = IOSIPadOverridesPath();
    NSString *zeroHourНастройкиPath = ZeroHourНастройкиPath();
    BOOL settingsExists = [[NSFileManager defaultManager] fileExistsAtPath:settingsPath];
    BOOL zeroHourНастройкиExists = [[NSFileManager defaultManager] fileExistsAtPath:zeroHourНастройкиPath];

    NSString *currentLog = DocumentsFilePath(@"generals-stderr.log");
    BOOL currentLogExists = [[NSFileManager defaultManager] fileExistsAtPath:currentLog];
    NSString *currentLogText = currentLogExists
        ? [NSString stringWithFormat:@"Yes (%@)", HumanReadableBytes(FileSizeAtPath(currentLog))]
        : @"No";

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

    return [NSString stringWithFormat:
        @"ПРИЛОЖЕНИЕ\n"
         "Проект: %s\n"
         "Пакет: %@ (%@)\n"
         "iOS: %@\n"
         "Устройство: %@\n\n"
         "СБОРКА\n"
         "Лаунчер: v%s · %@\n"
         "Запуск лаунчера: %@\n"
         "Движок: v%s · %@\n"
         "Запуск базовой оболочки: %@\n\n"
         "КОНТЕНТ\n"
         "GameData: %@\n"
         "Размер GameData: %@\n"
         "Enhanced: %@\n"
         "ZeroHour: %@\n\n"
         "ФАЙЛЫ\n"
         "Настройки iOS/iPad: %@\n"
         "Настройки ZeroHour: %@\n"
         "Текущий сеанс: %@\n"
         "Логи сеансов: %@\n",
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
        enhancedУстановлено ? @"Установлено" : @"Не установлено",
        zeroHourУстановлено ? @"Установлено" : @"Не установлено",
        settingsExists ? @"Есть" : @"Отсутствует",
        zeroHourНастройкиExists ? @"Есть" : @"Отсутствует",
        currentLogText,
        sessionLogsText];
}

- (void)buildДиагностика
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

    UILabel *title = MakeLabel(@"Диагностика", 26.0, UIFontWeightBold);
    title.textAlignment = NSTextAlignmentLeft;

    UILabel *note = MakeLabel(@"Сборка, установленный контент и логи сбоев. Последние 10 сеансов приложения сохраняются автоматически.", 13.0, UIFontWeightRegular);
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

    UIButton *refresh = MakeButton(@"Обновить", self, @selector(refreshДиагностика));
    self.shareДиагностикаButton = MakeButton(@"Поделиться отчётом + логами", self, @selector(shareДиагностика));
    UIButton *clearLogs = MakeButton(@"Очистить логи", self, @selector(clearДиагностикаLogs));
    UIButton *back = MakeButton(@"Назад", self, @selector(hideДиагностика));

    clearLogs.backgroundColor = [UIColor colorWithRed:0.24 green:0.06 blue:0.06 alpha:1.0];

    [refresh.widthAnchor constraintEqualToConstant:160.0].active = YES;
    [self.shareДиагностикаButton.widthAnchor constraintEqualToConstant:220.0].active = YES;
    [clearLogs.widthAnchor constraintEqualToConstant:160.0].active = YES;
    [back.widthAnchor constraintEqualToConstant:160.0].active = YES;

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[
        refresh, self.shareДиагностикаButton, clearLogs, back
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

- (void)showДиагностика
{
    self.menuStack.hidden = YES;
    self.settingsView.hidden = YES;
    self.diagnosticsView.hidden = NO;
    [self refreshДиагностика];
}

- (void)hideДиагностика
{
    self.diagnosticsView.hidden = YES;
    self.menuStack.hidden = NO;
}

- (void)refreshДиагностика
{
    if (self.diagnosticsScanRunning)
        return;

    self.diagnosticsScanRunning = YES;
    self.diagnosticsText.text = [self diagnosticsTextWithGameDataSize:@"Вычисление…"];

    NSString *resourcePath = [NSBundle mainBundle].resourcePath ?: @"";
    NSString *gameDataPath = [resourcePath stringByAppendingPathComponent:@"GameData"];
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:gameDataPath];

    __weak GXProfileLauncherViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long bytes = exists ? DirectorySizeAtPath(gameDataPath) : 0;
        NSString *sizeText = exists ? HumanReadableBytes(bytes) : @"нет данных";

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

- (void)clearДиагностикаLogs
{
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Очистить диагностические логи?"
                                            message:@"Это удалит лог текущего сеанса и все сохранённые логи сеансов."
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Отмена"
                                             style:UIAlertActionStyleОтмена
                                           handler:nil]];

    __weak GXProfileLauncherViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Очистить логи"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *action) {
        if (gDiagnosticClearCallback != nullptr)
        {
            // Full shell: ask the engine to reset its live logger FD and size/cap bookkeeping.
            gDiagnosticClearCallback();
        }
        else
        {
            // Launcher-only fast builds can be overlaid on an older successful shell.
            // In that case no callback is installed, so clear only the visible files.
            NSFileManager *fileManager = [NSFileManager defaultManager];
            for (NSString *name in DiagnosticSessionLogNames())
                [fileManager removeItemAtPath:DocumentsFilePath(name) error:nil];
            [fileManager removeItemAtPath:DocumentsFilePath(@"generals-stderr-prev.log") error:nil];
        }

        GXProfileLauncherViewController *strongSelf = weakSelf;
        if (strongSelf != nil)
        {
            strongSelf.diagnosticsScanRunning = NO;
            [strongSelf refreshДиагностика];
        }
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}


- (void)shareДиагностика
{
    NSMutableArray *items = [NSMutableArray array];

    NSString *reportPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"GeneralsZH-Диагностика.txt"];
    NSError *writeError = nil;
    BOOL wroteReport = [self.diagnosticsText.text writeToFile:reportPath
                                                  atomically:YES
                                                    encoding:NSUTF8StringEncoding
                                                       error:&writeError];
    if (wroteReport)
        [items addObject:[NSURL fileURLWithPath:reportPath]];
    else
        [items addObject:self.diagnosticsText.text ?: @"Диагностика Generals ZH недоступна"];

    for (NSString *name in DiagnosticSessionLogNames())
    {
        NSString *path = DocumentsFilePath(name);
        if ([[NSFileManager defaultManager] fileExistsAtPath:path])
            [items addObject:[NSURL fileURLWithPath:path]];
    }

    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];

    UIPopoverЕстьationController *popover = activity.popoverЕстьationController;
    if (popover != nil)
    {
        popover.sourceView = self.shareДиагностикаButton;
        popover.sourceRect = self.shareДиагностикаButton.bounds;
    }

    [self presentViewController:activity animated:YES completion:nil];

    if (!wroteReport && writeError != nil)
    {
        fprintf(stderr, "WARNING: failed to write diagnostics report: %s\n",
                [[writeError description] UTF8String]);
    }
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

- (void)launchEnhanced
{
    SetSelectedProfile(@"enhanced");
}

- (void)launchZeroHour
{
    SetSelectedProfile(@"zerohour");
}

- (void)downloadGameFile
{
    NSURL *url = [NSURL URLWithString:
        @"https://www.dropbox.com/scl/fi/jg0y2m0mioxm09jkrl5bn/GeneralsRus.zip?rlkey=yr7fslgqqw901ogzhmq86qaji&st=ba0b7oju&dl=1"];
    if (url == nil)
    {
        fprintf(stderr, "ERROR: invalid GameFile download URL\\n");
        return;
    }

    [[UIApplication sharedApplication] openURL:url
                                       options:@{}
                             completionHandler:^(BOOL success) {
        if (!success)
            fprintf(stderr, "ERROR: failed to open GameFile download URL\\n");
    }];
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

- (void)resetZeroHourНастройкиControls
{
    NSDictionary<NSString *, NSString *> *defaults = DefaultZeroHourНастройки();
    self.zeroHourControlBarSegment.selectedSegmentIndex = 0;
    self.zeroHourCameosSegment.selectedSegmentIndex = 0;
    self.zeroHourMusicSegment.selectedSegmentIndex = 0;
    self.zeroHourVoicesSegment.selectedSegmentIndex = 0;
    self.zeroHourHotkeysSegment.selectedSegmentIndex = 0;
    self.zeroHourHotkeyLanguageSegment.selectedSegmentIndex = 0;
    self.zeroHourPortraitsSegment.selectedSegmentIndex = 0;
    self.zeroHourFogSwitch.on = SettingBoolValue(defaults, @"FogEffects", NO);
    self.zeroHourWaterSwitch.on = SettingBoolValue(defaults, @"WaterEffects", YES);
    self.zeroHourExtraBuildingPropsSwitch.on = SettingBoolValue(defaults, @"ExtraBuildingProps", YES);

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
}

- (void)loadZeroHourНастройкиControls
{
    EnsureDefaultZeroHourНастройки();
    NSDictionary<NSString *, NSString *> *values = ReadKeyValueFile(ZeroHourНастройкиPath());

    self.zeroHourControlBarSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"ControlBar", @"ZeroHour")
                           choices:@[@"ZeroHour", @"Pro", @"Standard"]
                          fallback:0];
    self.zeroHourCameosSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"Cameos", @"Standard")
                           choices:@[@"Standard", @"HD"]
                          fallback:0];
    self.zeroHourMusicSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"Music", @"Standard")
                           choices:@[@"Standard", @"Enhanced", @"The Score"]
                          fallback:0];
    self.zeroHourVoicesSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"UnitVoices", @"English")
                           choices:@[@"English", @"Native"]
                          fallback:0];
    self.zeroHourHotkeysSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"Hotkeys", @"Original")
                           choices:@[@"Original", @"Leikeze"]
                          fallback:0];
    self.zeroHourHotkeyLanguageSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"HotkeyLanguage", @"English")
                           choices:@[@"English", @"Russian"]
                          fallback:0];
    self.zeroHourPortraitsSegment.selectedSegmentIndex =
        [self segmentIndexForValue:SettingValue(values, @"Portraits", @"Standard")
                           choices:@[@"Standard", @"Funny"]
                          fallback:0];

    self.zeroHourFogSwitch.on = SettingBoolValue(values, @"FogEffects", NO);
    self.zeroHourWaterSwitch.on = SettingBoolValue(values, @"WaterEffects", YES);
    self.zeroHourExtraBuildingPropsSwitch.on = SettingBoolValue(values, @"ExtraBuildingProps", YES);

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
}

- (void)resetНастройкиControls
{
    [self resetZeroHourНастройкиControls];

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

- (void)loadНастройкиControls
{
    [self loadZeroHourНастройкиControls];

    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfFile:IOSIPadOverridesPath()
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
        self.settingsStatus.text = @"Используются настройки камеры по умолчанию.";
        if (error != nil)
        {
            fprintf(stderr, "WARNING: iOS launcher could not read iOSIPadOverrides.ini: %s\n",
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

- (void)showНастройки
{
    [self loadНастройкиControls];
    self.menuStack.hidden = YES;
    self.settingsView.hidden = NO;
}

- (void)hideНастройки
{
    self.settingsView.hidden = YES;
    self.menuStack.hidden = NO;
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

- (BOOL)saveZeroHourНастройкиAndOptions:(NSError **)error
{
    NSArray<NSString *> *controlBars = @[@"ZeroHour", @"Pro", @"Standard"];
    NSArray<NSString *> *cameos = @[@"Standard", @"HD"];
    NSArray<NSString *> *music = @[@"Standard", @"Enhanced", @"The Score"];
    NSArray<NSString *> *voices = @[@"English", @"Native"];
    NSArray<NSString *> *hotkeys = @[@"Original", @"Leikeze"];
    NSArray<NSString *> *languages = @[@"English", @"Russian"];
    NSArray<NSString *> *portraits = @[@"Standard", @"Funny"];

    NSInteger particleIndex = self.particleQualitySegment.selectedSegmentIndex;
    NSInteger particleCount = particleIndex == 0 ? 1000 : (particleIndex == 2 ? 5000 : 2500);

    NSArray<NSString *> *filters = @[@"Bilinear", @"Trilinear", @"Anisotropic"];
    NSString *filter = filters[MAX(0, MIN(2, self.textureFilterSegment.selectedSegmentIndex))];

    NSMutableDictionary<NSString *, NSString *> *zeroHour = [DefaultZeroHourНастройки() mutableCopy];
    zeroHour[@"ControlBar"] = controlBars[self.zeroHourControlBarSegment.selectedSegmentIndex];
    zeroHour[@"Cameos"] = cameos[self.zeroHourCameosSegment.selectedSegmentIndex];
    zeroHour[@"Music"] = music[self.zeroHourMusicSegment.selectedSegmentIndex];
    zeroHour[@"UnitVoices"] = voices[self.zeroHourVoicesSegment.selectedSegmentIndex];
    zeroHour[@"Hotkeys"] = hotkeys[self.zeroHourHotkeysSegment.selectedSegmentIndex];
    zeroHour[@"HotkeyLanguage"] = languages[self.zeroHourHotkeyLanguageSegment.selectedSegmentIndex];
    zeroHour[@"Portraits"] = portraits[self.zeroHourPortraitsSegment.selectedSegmentIndex];
    zeroHour[@"FogEffects"] = self.zeroHourFogSwitch.on ? @"Yes" : @"No";
    zeroHour[@"WaterEffects"] = self.zeroHourWaterSwitch.on ? @"Yes" : @"No";
    zeroHour[@"ExtraBuildingProps"] = self.zeroHourExtraBuildingPropsSwitch.on ? @"Yes" : @"No";

    zeroHour[@"UseShadowVolumes"] = self.shadow3DSwitch.on ? @"Yes" : @"No";
    zeroHour[@"UseShadowDecals"] = self.shadow2DSwitch.on ? @"Yes" : @"No";
    zeroHour[@"UseCloudMap"] = self.cloudShadowsSwitch.on ? @"Yes" : @"No";
    zeroHour[@"UseLightMap"] = self.groundLightingSwitch.on ? @"Yes" : @"No";
    zeroHour[@"ShowSoftWaterEdge"] = self.softWaterSwitch.on ? @"Yes" : @"No";
    zeroHour[@"BuildingOcclusion"] = self.buildingOcclusionSwitch.on ? @"Yes" : @"No";
    zeroHour[@"ShowTrees"] = self.showPropsSwitch.on ? @"Yes" : @"No";
    zeroHour[@"ExtraAnimations"] = self.extraAnimationsSwitch.on ? @"Yes" : @"No";
    zeroHour[@"DynamicLOD"] = self.dynamicLODSwitch.on ? @"Yes" : @"No";
    zeroHour[@"HeatEffects"] = self.heatEffectsSwitch.on ? @"Yes" : @"No";
    zeroHour[@"TextureReduction"] = [NSString stringWithFormat:@"%ld", (long)self.textureQualitySegment.selectedSegmentIndex];
    zeroHour[@"MaxParticleCount"] = [NSString stringWithFormat:@"%ld", (long)particleCount];
    zeroHour[@"TextureFilter"] = filter;
    zeroHour[@"AnisotropyLevel"] = self.textureFilterSegment.selectedSegmentIndex == 2 ? @"8" : @"2";

    if (!WriteKeyValueFile(ZeroHourНастройкиPath(), zeroHour, error))
        return NO;

    NSMutableDictionary<NSString *, NSString *> *options = ReadKeyValueFile(EngineOptionsPath());
    options[@"IdealStaticGameLOD"] = @"High";
    options[@"StaticGameLOD"] = @"Custom";
    for (NSString *key in @[
        @"UseShadowVolumes", @"UseShadowDecals", @"UseCloudMap", @"UseLightMap",
        @"ShowSoftWaterEdge", @"BuildingOcclusion", @"ShowTrees", @"ExtraAnimations",
        @"DynamicLOD", @"HeatEffects", @"TextureReduction", @"MaxParticleCount",
        @"TextureFilter", @"AnisotropyLevel"
    ])
    {
        options[key] = zeroHour[key];
    }

    return WriteKeyValueFile(EngineOptionsPath(), options, error);
}

- (void)saveНастройки
{
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

    NSError *error = nil;
    BOOL cameraOK = [contents writeToFile:IOSIPadOverridesPath()
                               atomically:YES
                                 encoding:NSUTF8StringEncoding
                                    error:&error];
    BOOL zeroHourOK = cameraOK ? [self saveZeroHourНастройкиAndOptions:&error] : NO;

    if (cameraOK && zeroHourOK)
    {
        self.settingsStatus.text = @"Сохранитьd. Changes apply on the next game launch.";
        self.settingsStatus.textColor = [UIColor systemGreenColor];
        fprintf(stderr,
                "[ZEROHOUR-SETTINGS] saved settings=%s options=%s camera=%s\n",
                ZeroHourНастройкиPath().fileSystemRepresentation,
                EngineOptionsPath().fileSystemRepresentation,
                IOSIPadOverridesPath().fileSystemRepresentation);
    }
    else
    {
        self.settingsStatus.text = @"Сохранить failed. See generals-stderr.log.";
        self.settingsStatus.textColor = [UIColor systemRedColor];
        fprintf(stderr, "ERROR: iOS launcher failed to save settings: %s\n",
                error != nil ? [[error description] UTF8String] : "unknown");
    }
}

- (void)resetНастройки
{
    [self resetНастройкиControls];
    self.settingsStatus.text = @"Default values loaded. Tap Сохранить to apply.";
    self.settingsStatus.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
}

@end

const char *GeneralsXRunIOSProfileLauncher()
{
    // GeneralsX @feature dvorovrus 25/09/2026 Allow automation/debug builds to skip the UI.
    const char *forcedProfile = getenv("GX_LAUNCH_PROFILE");
    if (IsSupportedProfile(forcedProfile))
    {
        strlcpy(gSelectedProfile, forcedProfile, sizeof(gSelectedProfile));
        fprintf(stderr, "INFO: iOS launcher forced profile: %s\n", gSelectedProfile);
        return gSelectedProfile;
    }

    // Dedicated variants keep a single-game launcher so settings remain
    // accessible. Quick Start restores direct boot when the user enables it.
    NSString *autoProfile = BundledAutoLaunchProfile();
    if (autoProfile != nil)
    {
        const char *utf8 = [autoProfile UTF8String];
        strlcpy(gSelectedProfile, utf8, sizeof(gSelectedProfile));

        if (![autoProfile isEqualToString:@"zerohour"])
        {
            fprintf(stderr, "INFO: iOS launcher auto-selected bundled profile: %s\n",
                    gSelectedProfile);
            return gSelectedProfile;
        }

        fprintf(stderr,
                "[ZEROHOUR-SETTINGS] dedicated ZeroHour launcher shown for settings access\n");
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

    // SDL's iOS bootstrap is already inside UIApplicationMain. Keep the native
    // main run loop alive until a profile is selected.
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
