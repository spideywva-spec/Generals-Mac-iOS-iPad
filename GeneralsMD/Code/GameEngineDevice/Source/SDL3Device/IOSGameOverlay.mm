#include "SDL3Device/IOSGameOverlay.h"

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <TargetConditionals.h>

#include <dispatch/dispatch.h>

namespace
{
constexpr NSTimeInterval kIdleBeforeFade = 3.0;
constexpr NSTimeInterval kFadeDuration = 2.0;
constexpr NSTimeInterval kShowDuration = 0.20;

@interface GXOverlayView : UIView
@property(nonatomic, weak) UIButton *escButton;
@end

@implementation GXOverlayView

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    UIButton *button = self.escButton;
    if (button != nil && !button.hidden && button.alpha > 0.01 &&
        CGRectContainsPoint(button.frame, point))
        return YES;

    // The overlay is transparent everywhere except the ESC button, so normal
    // touches continue to reach the SDL game view underneath it.
    return NO;
}

@end

@interface GXGameOverlayController : UIViewController
@property(nonatomic, strong) GXOverlayView *overlayView;
@property(nonatomic, strong) UIButton *escButton;
@property(nonatomic, strong) NSTimer *idleTimer;
@property(nonatomic, assign) SDL_Window *sdlWindow;
@property(nonatomic, assign) BOOL shuttingDown;
@end

@implementation GXGameOverlayController

- (void)loadView
{
    self.overlayView = [[GXOverlayView alloc] initWithFrame:CGRectZero];
    self.overlayView.backgroundColor = UIColor.clearColor;
    self.overlayView.userInteractionEnabled = YES;
    self.view = self.overlayView;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    self.escButton = button;
    self.overlayView.escButton = button;

    [button setTitle:@"ESC" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBlack];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:0.02 alpha:0.78];
    button.layer.cornerRadius = 9.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor =
        [UIColor colorWithRed:0.18 green:0.50 blue:0.93 alpha:0.85].CGColor;
    button.accessibilityLabel = @"ESC";
    button.accessibilityHint = @"Нажать Escape";

    [button addTarget:self
               action:@selector(escPressed:)
     forControlEvents:UIControlEventTouchUpInside];

    [self.overlayView addSubview:button];
    self.overlayView.alpha = 1.0;
    [self scheduleIdleFade];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];

    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGFloat width = 56.0;
    CGFloat height = 42.0;
    CGFloat x = MAX(10.0, insets.left + 10.0);
    CGFloat y = self.view.bounds.size.height - insets.bottom - height - 12.0;

    self.escButton.frame = CGRectMake(x, y, width, height);
}

- (void)escPressed:(id)sender
{
    // Pressing ESC is activity. It always remains available and gets a fresh
    // three-second visible period instead of disappearing permanently.
    [self showAndRestartIdleTimer];

    SDL_Window *window = self.sdlWindow;
    if (window == nullptr)
        return;

    SDL_Event event;
    SDL_zero(event);
    event.type = SDL_EVENT_KEY_DOWN;
    event.key.timestamp = SDL_GetTicksNS();
    event.key.windowID = SDL_GetWindowID(window);
    event.key.scancode = SDL_SCANCODE_ESCAPE;
    event.key.key = SDLK_ESCAPE;
    event.key.mod = SDL_KMOD_NONE;
    event.key.raw = 0;
    event.key.down = true;
    event.key.repeat = false;
    SDL_PushEvent(&event);

    SDL_zero(event);
    event.type = SDL_EVENT_KEY_UP;
    event.key.timestamp = SDL_GetTicksNS();
    event.key.windowID = SDL_GetWindowID(window);
    event.key.scancode = SDL_SCANCODE_ESCAPE;
    event.key.key = SDLK_ESCAPE;
    event.key.mod = SDL_KMOD_NONE;
    event.key.raw = 0;
    event.key.down = false;
    event.key.repeat = false;
    SDL_PushEvent(&event);
}

- (void)showAndRestartIdleTimer
{
    if (self.shuttingDown)
        return;

    [self.idleTimer invalidate];
    self.idleTimer = nil;

    [UIView animateWithDuration:kShowDuration
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         self.overlayView.alpha = 1.0;
                     }
                     completion:nil];

    [self scheduleIdleFade];
}

- (void)scheduleIdleFade
{
    [self.idleTimer invalidate];
    self.idleTimer = [NSTimer scheduledTimerWithTimeInterval:kIdleBeforeFade
                                                      target:self
                                                    selector:@selector(beginIdleFade:)
                                                    userInfo:nil
                                                     repeats:NO];
}

- (void)beginIdleFade:(NSTimer *)timer
{
    if (self.shuttingDown)
        return;

    [UIView animateWithDuration:kFadeDuration
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseInOut
                     animations:^{
                         self.overlayView.alpha = 0.0;
                     }
                     completion:nil];
}

- (void)shutdown
{
    self.shuttingDown = YES;
    [self.idleTimer invalidate];
    self.idleTimer = nil;
    [self.view removeFromSuperview];
    self.escButton = nil;
    self.overlayView = nil;
}

@end

UIWindow *s_overlayWindow = nil;
GXGameOverlayController *s_overlayController = nil;

UIWindowScene *GXActiveWindowScene(void)
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;

        UISceneActivationState state = scene.activationState;
        if (state == UISceneActivationStateForegroundActive ||
            state == UISceneActivationStateForegroundInactive)
            return (UIWindowScene *)scene;
    }

    return nil;
}

void GXRunOnMain(dispatch_block_t block)
{
    if ([NSThread isMainThread])
        block();
    else
        dispatch_async(dispatch_get_main_queue(), block);
}
}

void IOSGameOverlayInit(SDL_Window *window)
{
    if (window == nullptr)
        return;

    GXRunOnMain(^{
        if (s_overlayController != nil)
        {
            s_overlayController.sdlWindow = window;
            [s_overlayController showAndRestartIdleTimer];
            return;
        }

        UIWindowScene *scene = GXActiveWindowScene();
        if (scene == nil)
        {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                IOSGameOverlayInit(window);
            });
            return;
        }

        s_overlayController = [[GXGameOverlayController alloc] init];
        s_overlayController.sdlWindow = window;

        s_overlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
        s_overlayWindow.backgroundColor = UIColor.clearColor;
        s_overlayWindow.windowLevel = UIWindowLevelNormal + 0.1;
        s_overlayWindow.rootViewController = s_overlayController;
        s_overlayWindow.hidden = NO;
        s_overlayWindow.alpha = 1.0;

        [s_overlayWindow makeKeyAndVisible];
        [s_overlayWindow resignKeyWindow];

        [s_overlayController showAndRestartIdleTimer];
    });
}

void IOSGameOverlayShutdown()
{
    GXRunOnMain(^{
        [s_overlayController shutdown];
        s_overlayController = nil;

        s_overlayWindow.hidden = YES;
        s_overlayWindow.rootViewController = nil;
        s_overlayWindow = nil;
    });
}

void IOSGameOverlayNoteActivity()
{
    if (s_overlayController == nil)
        return;

    GXRunOnMain(^{
        [s_overlayController showAndRestartIdleTimer];
    });
}

void IOSGameOverlayHandleSDLKeyEvent(const SDL_Event *event)
{
    if (event != nullptr &&
        event->type == SDL_EVENT_KEY_DOWN &&
        event->key.key == SDLK_ESCAPE)
        IOSGameOverlayNoteActivity();
}

#endif
