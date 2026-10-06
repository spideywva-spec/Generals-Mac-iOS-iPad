#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <SDL3/SDL.h>

#include "IOSGameOverlay.h"

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

static UIButton *s_escButton = nil;
static SDL_Window *s_sdlWindow = nullptr;
static SDL_WindowID s_windowID = 0;
static id s_keyWindowObserver = nil;
static bool s_eventWatchInstalled = false;
static NSUInteger s_activityGeneration = 0;

static constexpr NSTimeInterval kIdleBeforeFade = 3.0;
static constexpr NSTimeInterval kFadeDuration = 2.0;
static constexpr NSTimeInterval kShowDuration = 0.20;

@interface GXEscButton : UIButton
@end

static UIWindow *GXFindSDLWindow(void)
{
    if (s_sdlWindow != nullptr) {
        SDL_PropertiesID props = SDL_GetWindowProperties(s_sdlWindow);
        if (props != 0) {
            UIWindow *window = (__bridge UIWindow *)SDL_GetPointerProperty(
                props, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
            if (window != nil && !window.hidden)
                return window;
        }
    }

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateForegroundActive &&
            windowScene.activationState != UISceneActivationStateForegroundInactive)
            continue;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow && !window.hidden)
                return window;
        }
    }
    return nil;
}

static void GXPushEscapeEvent(bool down)
{
    if (s_windowID == 0)
        return;

    SDL_Event event;
    SDL_zero(event);
    event.type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
    event.key.timestamp = SDL_GetTicksNS();
    event.key.windowID = s_windowID;
    event.key.scancode = SDL_SCANCODE_ESCAPE;
    event.key.key = SDLK_ESCAPE;
    event.key.mod = SDL_KMOD_NONE;
    event.key.raw = 0;
    event.key.down = down;
    event.key.repeat = false;
    SDL_PushEvent(&event);
}

static void GXFadeEscButton(void)
{
    if (s_escButton == nil)
        return;

    [UIView animateWithDuration:kFadeDuration
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        s_escButton.alpha = 0.0;
    } completion:nil];
}

static void GXScheduleIdleFade(void)
{
    const NSUInteger generation = ++s_activityGeneration;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kIdleBeforeFade * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (s_windowID != 0 && s_escButton != nil &&
                generation == s_activityGeneration) {
                GXFadeEscButton();
            }
        });
}

static void GXShowEscButtonAndRestartTimer(void)
{
    if (s_escButton == nil)
        return;

    ++s_activityGeneration;
    [s_escButton.layer removeAllAnimations];
    s_escButton.hidden = NO;
    s_escButton.userInteractionEnabled = YES;

    [UIView animateWithDuration:kShowDuration
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
        s_escButton.alpha = 1.0;
    } completion:nil];

    GXScheduleIdleFade();
}

static bool SDLCALL GXEscSDLActivityWatch(void *, SDL_Event *event)
{
    if (event == nullptr || s_windowID == 0)
        return true;

    bool activity = false;
    SDL_WindowID eventWindow = 0;

    switch (event->type) {
        case SDL_EVENT_FINGER_DOWN:
        case SDL_EVENT_FINGER_MOTION:
        case SDL_EVENT_FINGER_UP:
        case SDL_EVENT_FINGER_CANCELED:
            eventWindow = event->tfinger.windowID;
            activity = true;
            break;
        case SDL_EVENT_MOUSE_MOTION:
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EVENT_MOUSE_BUTTON_UP:
        case SDL_EVENT_MOUSE_WHEEL:
            eventWindow = event->motion.windowID;
            activity = true;
            break;
        case SDL_EVENT_KEY_DOWN:
        case SDL_EVENT_KEY_UP:
            eventWindow = event->key.windowID;
            activity = true;
            break;
        default:
            break;
    }

    if (activity && (eventWindow == 0 || eventWindow == s_windowID)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (s_windowID != 0 && s_escButton != nil)
                GXShowEscButtonAndRestartTimer();
        });
    }
    return true;
}

@implementation GXEscButton

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    if (self.hidden || !self.userInteractionEnabled)
        return nil;
    return [self pointInside:point withEvent:event] ? self : nil;
}

- (void)escTouchDown:(UIButton *)sender
{
    (void)sender;
    GXShowEscButtonAndRestartTimer();
    GXPushEscapeEvent(true);
}

- (void)escTouchUp:(UIButton *)sender
{
    (void)sender;
    GXShowEscButtonAndRestartTimer();
    GXPushEscapeEvent(false);
}

@end

static void GXAttachEscButtonToSDLWindow(void)
{
    if (s_windowID == 0)
        return;

    UIWindow *hostWindow = GXFindSDLWindow();
    if (hostWindow == nil)
        return;

    const CGFloat buttonSize = 50.0;
    const CGFloat left = 5.0;
    const CGFloat top = 25.0;

    if (s_escButton == nil) {
        GXEscButton *button = [GXEscButton buttonWithType:UIButtonTypeSystem];
        button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];
        button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.78].CGColor;
        button.layer.borderWidth = 1.25;
        button.layer.cornerRadius = 2.0;
        button.clipsToBounds = YES;
        [button setTitle:@"ESC" forState:UIControlStateNormal];
        [button setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.92]
                     forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        button.accessibilityLabel = @"Escape";
        button.accessibilityTraits = UIAccessibilityTraitButton;
        [button addTarget:button action:@selector(escTouchDown:)
         forControlEvents:UIControlEventTouchDown];
        [button addTarget:button action:@selector(escTouchUp:)
         forControlEvents:UIControlEventTouchUpInside |
                         UIControlEventTouchUpOutside |
                         UIControlEventTouchCancel];
        s_escButton = button;
        s_escButton.userInteractionEnabled = YES;
        s_escButton.multipleTouchEnabled = NO;
    }

    s_escButton.frame = CGRectMake(left, top, buttonSize, buttonSize);
    if (s_escButton.superview != hostWindow) {
        [s_escButton removeFromSuperview];
        [hostWindow addSubview:s_escButton];
    }
    [hostWindow bringSubviewToFront:s_escButton];

    if (s_activityGeneration == 0) {
        s_escButton.alpha = 1.0;
        GXScheduleIdleFade();
    }

    fprintf(stderr, "INFO: iOS in-game ESC overlay attached at x=%.0f y=%.0f size=%.0f\n",
            left, top, buttonSize);
}

extern "C" void GeneralsXInstallIOSEscOverlay(SDL_Window *window)
{
    if (window == nullptr)
        return;

    s_sdlWindow = window;
    s_windowID = SDL_GetWindowID(window);

    if (!s_eventWatchInstalled) {
        s_eventWatchInstalled = SDL_AddEventWatch(GXEscSDLActivityWatch, nullptr);
        if (!s_eventWatchInstalled)
            fprintf(stderr, "WARNING: iOS ESC overlay: SDL event watch install failed: %s\n",
                    SDL_GetError());
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        GXAttachEscButtonToSDLWindow();

        const double delays[] = {0.10, 0.30, 0.75, 1.50};
        for (double delay : delays) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    if (s_windowID != 0)
                        GXAttachEscButtonToSDLWindow();
                });
        }

        if (s_keyWindowObserver == nil) {
            s_keyWindowObserver =
                [[NSNotificationCenter defaultCenter]
                    addObserverForName:UIWindowDidBecomeKeyNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *) {
                if (s_windowID != 0)
                    GXAttachEscButtonToSDLWindow();
            }];
        }
    });
}

extern "C" void GeneralsXRemoveIOSEscOverlay(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        ++s_activityGeneration;

        if (s_keyWindowObserver != nil) {
            [[NSNotificationCenter defaultCenter] removeObserver:s_keyWindowObserver];
            s_keyWindowObserver = nil;
        }

        if (s_eventWatchInstalled) {
            SDL_RemoveEventWatch(GXEscSDLActivityWatch, nullptr);
            s_eventWatchInstalled = false;
        }

        if (s_escButton != nil) {
            [s_escButton.layer removeAllAnimations];
            [s_escButton removeFromSuperview];
            s_escButton = nil;
        }

        s_sdlWindow = nullptr;
        s_windowID = 0;
        s_activityGeneration = 0;
    });
}

#endif
