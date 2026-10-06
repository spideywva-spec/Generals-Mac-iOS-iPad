#include "SDL3Device/IOSGameOverlay.h"

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>

#include <SDL3/SDL.h>

namespace {
constexpr NSTimeInterval kIdleBeforeFade = 3.0;
constexpr NSTimeInterval kFadeDuration = 2.0;
constexpr NSTimeInterval kShowDuration = 0.20;

@interface GXEscButton : UIButton
@end

@interface GXOverlayView : UIView
@property(nonatomic, weak) GXEscButton *escButton;
@end

@interface GXGameOverlayController : UIViewController
@property(nonatomic, strong) GXOverlayView *overlayView;
@property(nonatomic, strong) GXEscButton *escButton;
@property(nonatomic, strong) NSTimer *idleTimer;
@property(nonatomic, assign) SDL_Window *sdlWindow;
@property(nonatomic, assign) BOOL shuttingDown;
@end

static UIWindow *s_overlayWindow = nil;
static GXGameOverlayController *s_overlayController = nil;
static bool s_eventWatchInstalled = false;

@implementation GXEscButton
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    if (self.hidden || !self.userInteractionEnabled) return nil;
    return [self pointInside:point withEvent:event] ? self : nil;
}
@end

@implementation GXOverlayView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    GXEscButton *button = self.escButton;
    return button != nil && !button.hidden &&
           CGRectContainsPoint(button.frame, point);
}
@end

static void GXPushEscape(SDL_Window *window, bool down)
{
    if (window == nullptr) return;
    SDL_Event event;
    SDL_zero(event);
    event.type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
    event.key.timestamp = SDL_GetTicksNS();
    event.key.windowID = SDL_GetWindowID(window);
    event.key.scancode = SDL_SCANCODE_ESCAPE;
    event.key.key = SDLK_ESCAPE;
    event.key.mod = SDL_KMOD_NONE;
    event.key.raw = 0;
    event.key.down = down;
    event.key.repeat = false;
    SDL_PushEvent(&event);
}

static bool SDLCALL GXEscSDLActivityWatch(void *, SDL_Event *event)
{
    if (event == nullptr || s_overlayController == nil) return true;

    SDL_WindowID target = SDL_GetWindowID(s_overlayController.sdlWindow);
    SDL_WindowID eventWindow = 0;
    bool activity = false;

    switch (event->type) {
        case SDL_EVENT_FINGER_DOWN:
        case SDL_EVENT_FINGER_MOTION:
        case SDL_EVENT_FINGER_UP:
        case SDL_EVENT_FINGER_CANCELED:
            eventWindow = event->tfinger.windowID; activity = true; break;
        case SDL_EVENT_MOUSE_MOTION:
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EVENT_MOUSE_BUTTON_UP:
        case SDL_EVENT_MOUSE_WHEEL:
            eventWindow = event->motion.windowID; activity = true; break;
        case SDL_EVENT_KEY_DOWN:
        case SDL_EVENT_KEY_UP:
            eventWindow = event->key.windowID; activity = true; break;
        default: break;
    }

    if (activity && (eventWindow == 0 || eventWindow == target)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (s_overlayController != nil)
                [s_overlayController showAndRestartIdleTimer];
        });
    }
    return true;
}

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

    self.escButton = [GXEscButton buttonWithType:UIButtonTypeSystem];
    self.overlayView.escButton = self.escButton;

    [self.escButton setTitle:@"ESC" forState:UIControlStateNormal];
    self.escButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    [self.escButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.92]
                          forState:UIControlStateNormal];
    self.escButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];
    self.escButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.78].CGColor;
    self.escButton.layer.borderWidth = 1.25;
    self.escButton.layer.cornerRadius = 2.0;
    self.escButton.accessibilityLabel = @"Escape";
    self.escButton.accessibilityTraits = UIAccessibilityTraitButton;

    [self.escButton addTarget:self action:@selector(escPressed:)
              forControlEvents:UIControlEventTouchUpInside |
                              UIControlEventTouchUpOutside |
                              UIControlEventTouchCancel];
    [self.overlayView addSubview:self.escButton];

    // Keep the overlay view itself fully hit-testable; only the button fades.
    self.overlayView.alpha = 1.0;
    self.escButton.alpha = 1.0;
    [self scheduleIdleFade];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    const CGFloat size = 50.0;
    const CGFloat left = 5.0;
    const CGFloat top = 25.0;
    self.escButton.frame = CGRectMake(left, top, size, size);
}

- (void)escPressed:(id)sender
{
    (void)sender;
    [self showAndRestartIdleTimer];
    GXPushEscape(self.sdlWindow, true);
    GXPushEscape(self.sdlWindow, false);
}

- (void)showAndRestartIdleTimer
{
    if (self.shuttingDown) return;

    [self.idleTimer invalidate];
    self.idleTimer = nil;

    [UIView animateWithDuration:kShowDuration
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.escButton.alpha = 1.0;
    } completion:nil];

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
    (void)timer;
    if (self.shuttingDown) return;

    [UIView animateWithDuration:kFadeDuration
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.escButton.alpha = 0.0;
    } completion:nil];
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

static UIWindowScene *GXActiveWindowScene(void)
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UISceneActivationState state = scene.activationState;
        if (state == UISceneActivationStateForegroundActive ||
            state == UISceneActivationStateForegroundInactive)
            return (UIWindowScene *)scene;
    }
    return nil;
}

static void GXRunOnMain(dispatch_block_t block)
{
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

void IOSGameOverlayInit(SDL_Window *window)
{
    if (window == nullptr) return;

    GXRunOnMain(^{
        if (s_overlayController != nil) {
            s_overlayController.sdlWindow = window;
            [s_overlayController showAndRestartIdleTimer];
            return;
        }

        UIWindowScene *scene = GXActiveWindowScene();
        if (scene == nil) {
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

        if (!s_eventWatchInstalled) {
            s_eventWatchInstalled = SDL_AddEventWatch(GXEscSDLActivityWatch, nullptr);
            if (!s_eventWatchInstalled)
                fprintf(stderr, "WARNING: iOS ESC overlay: SDL event watch install failed: %s\n",
                        SDL_GetError());
        }

        [s_overlayController showAndRestartIdleTimer];
    });
}

void IOSGameOverlayShutdown()
{
    GXRunOnMain(^{
        if (s_eventWatchInstalled) {
            SDL_RemoveEventWatch(GXEscSDLActivityWatch, nullptr);
            s_eventWatchInstalled = false;
        }
        [s_overlayController shutdown];
        s_overlayController = nil;
        s_overlayWindow.hidden = YES;
        s_overlayWindow.rootViewController = nil;
        s_overlayWindow = nil;
    });
}

void IOSGameOverlayNoteActivity()
{
    GXRunOnMain(^{
        if (s_overlayController != nil)
            [s_overlayController showAndRestartIdleTimer];
    });
}

void IOSGameOverlayHandleSDLKeyEvent(const SDL_Event *event)
{
    if (event != nullptr &&
        (event->type == SDL_EVENT_KEY_DOWN || event->type == SDL_EVENT_KEY_UP))
        IOSGameOverlayNoteActivity();
}

#endif
