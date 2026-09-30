#import <UIKit/UIKit.h>
#include <SDL3/SDL.h>

#include "IOSGameOverlay.h"

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

static UIButton *s_escButton = nil;
static SDL_WindowID s_windowID = 0;

static UIWindow *GXFindForegroundWindow(void)
{
    UIApplication *application = UIApplication.sharedApplication;

    // Prefer the key window in the currently active scene.
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateForegroundActive &&
            windowScene.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }

        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow && !window.hidden) {
                return window;
            }
        }
    }

    // Fallback for SDL/older iOS window setups.
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (!window.hidden && window.alpha > 0.0 && window.windowLevel == UIWindowLevelNormal) {
                return window;
            }
        }
    }

    return nil;
}

static void GXPushEscapeEvent(bool down)
{
    SDL_Event event;
    SDL_zero(event);

    event.type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
    event.key.windowID = s_windowID;
    event.key.which = 0; // virtual/app-generated keyboard
    event.key.scancode = SDL_SCANCODE_ESCAPE;
    event.key.key = SDLK_ESCAPE;
    event.key.mod = SDL_KMOD_NONE;
    event.key.raw = 0;
    event.key.down = down;
    event.key.repeat = false;

    SDL_PushEvent(&event);
}

@interface GXEscButton : UIButton
@end

@implementation GXEscButton

- (void)touchesBegan:(NSSet<UITouch *> *)touches
           withEvent:(UIEvent *)event
{
    (void)touches;
    (void)event;

    self.alpha = 0.65;
    GXPushEscapeEvent(true);
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches
           withEvent:(UIEvent *)event
{
    (void)touches;
    (void)event;

    self.alpha = 1.0;
    GXPushEscapeEvent(false);
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches
                withEvent:(UIEvent *)event
{
    (void)touches;
    (void)event;

    self.alpha = 1.0;
    GXPushEscapeEvent(false);
    [super touchesCancelled:touches withEvent:event];
}

@end

extern "C" void GeneralsXInstallIOSEscOverlay(SDL_Window *window)
{
    if (window == nullptr) {
        return;
    }

    s_windowID = SDL_GetWindowID(window);

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *hostWindow = GXFindForegroundWindow();
        if (hostWindow == nil) {
            fprintf(stderr, "WARNING: iOS ESC overlay: no foreground UIWindow found\n");
            return;
        }

        if (s_escButton != nil) {
            [s_escButton removeFromSuperview];
            s_escButton = nil;
        }

        // The screenshot's marked area is roughly 100x90 physical pixels on a
        // 1792x828 Retina drawable. UIKit uses points, so keep the control at
        // about 50x50 points and anchor it close to the exact marked position.
        const CGFloat buttonSize = 50.0;
        const CGFloat left = 5.0;
        const CGFloat top = 25.0;

        GXEscButton *button = [GXEscButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(left, top, buttonSize, buttonSize);
        button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin |
                                  UIViewAutoresizingFlexibleBottomMargin;
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

        // Keep the overlay above the game's SDL view without creating another
        // UIWindow, so it cannot interfere with Vulkan/MoltenVK presentation.
        [hostWindow addSubview:button];
        [hostWindow bringSubviewToFront:button];
        s_escButton = button;

        fprintf(stderr, "INFO: iOS in-game ESC overlay installed at x=%.0f y=%.0f size=%.0fx%.0f\n",
                left, top, buttonSize, buttonSize);
    });
}

extern "C" void GeneralsXRemoveIOSEscOverlay(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_escButton != nil) {
            [s_escButton removeFromSuperview];
            s_escButton = nil;
        }
        s_windowID = 0;
    });
}

#endif
