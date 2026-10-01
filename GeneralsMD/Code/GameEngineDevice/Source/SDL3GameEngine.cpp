/*
**	Command & Conquer Generals Zero Hour(tm)
**	Copyright 2025 Electronic Arts Inc.
**
**	This program is free software: you can redistribute it and/or modify
**	it under the terms of the GNU General Public License as published by
**	the Free Software Foundation, either version 3 of the License, or
**	(at your option) any later version.
**
**	This program is distributed in the hope that it will be useful,
**	but WITHOUT ANY WARRANTY; without even the implied warranty of
**	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
**	GNU General Public License for more details.
**
**	You should have received a copy of the GNU General Public License
**	along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

/*
** SDL3GameEngine.cpp
**
** Linux implementation of GameEngine using SDL3 for windowing/input.
**
** TheSuperHackers @feature CnC_Generals_Linux 07/02/2026
** Provides SDL3-based input and window management for Linux builds.
** Based on fighter19 reference implementation.
*/

#ifndef _WIN32

#include "SDL3GameEngine.h"
#include "OpenALAudioManager.h"
#include "SDL3Device/GameClient/SDL3Mouse.h"
#include "SDL3Device/GameClient/SDL3Keyboard.h"
#include "GameClient/Mouse.h"
#include "GameClient/Keyboard.h"
#include "GameClient/GameWindow.h"
#include "GameClient/GameWindowManager.h"
#include "GameClient/Gadget.h"
#include "W3DDevice/GameLogic/W3DGameLogic.h"
#include "W3DDevice/GameClient/W3DGameClient.h"
#include "W3DDevice/Common/W3DModuleFactory.h"
#include "W3DDevice/Common/W3DThingFactory.h"
#include "W3DDevice/Common/W3DFunctionLexicon.h"
#include "W3DDevice/Common/W3DRadar.h"
#include "W3DDevice/GameClient/W3DParticleSys.h"
#include "W3DDevice/GameClient/W3DWebBrowser.h"
#include "StdDevice/Common/StdLocalFileSystem.h"
#include "StdDevice/Common/StdBIGFileSystem.h"
#include "Common/GlobalData.h"
#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

// Extern globals for input devices (set by GameClient)
extern Mouse *TheMouse;
extern Keyboard *TheKeyboard;
extern GameWindowManager *TheWindowManager;

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#include <atomic>

// ---------------------------------------------------------------------------
// iOS app lifecycle
//
// iOS suspends the process when the app leaves the foreground. Any GPU work
// submitted around suspension stalls on drawable acquisition (MoltenVK waits
// out a timeout per present), which surfaces as multi-second input hangs right
// after resuming. SDL warns that lifecycle events can arrive outside the
// normal poll cycle, so they are captured in an event watcher that fires
// immediately on the delivering thread; the engine update loop checks the
// flag and skips simulation + rendering while backgrounded.
// ---------------------------------------------------------------------------
// Two independent reasons to halt the render/sim loop on iOS:
//  - BACKGROUNDED (home / switched away): the process is about to be suspended.
//  - INACTIVE (multitasking switcher open, Control Center, a notification
//    banner): iOS snapshots the window and owns the CAMetalLayer drawable during
//    this window — and crucially, opening the app switcher fires resign-active
//    WITHOUT a full background transition.
// Acquiring a Metal drawable during EITHER state fights iOS for the layer; across
// repeated suspend/switcher cycles MoltenVK is driven into an unrecoverable
// surface state and the app crashes (the reported "crashes after backgrounding /
// multitasking a few times"). Pause whenever either is set.
static std::atomic<bool> s_appBackgrounded{false};
static std::atomic<bool> s_appInactive{false};

static inline bool iosShouldPauseRendering()
{
	return s_appBackgrounded.load() || s_appInactive.load();
}

static bool SDLCALL iosLifecycleWatcher(void *userdata, SDL_Event *event)
{
	switch (event->type) {
		case SDL_EVENT_WILL_ENTER_BACKGROUND:
		case SDL_EVENT_DID_ENTER_BACKGROUND:
			s_appBackgrounded.store(true);
			break;
		case SDL_EVENT_DID_ENTER_FOREGROUND:
			s_appBackgrounded.store(false);
			break;
		// Resign/become active. On iOS, SDL maps applicationWillResignActive ->
		// window focus lost and applicationDidBecomeActive -> window focus gained.
		// Stay paused until fully active again (focus regained), which arrives
		// after DID_ENTER_FOREGROUND.
		case SDL_EVENT_WINDOW_FOCUS_LOST:
			s_appInactive.store(true);
			break;
		case SDL_EVENT_WINDOW_FOCUS_GAINED:
			s_appInactive.store(false);
			break;
		default:
			break;
	}
	return true;
}

// ---------------------------------------------------------------------------
// iOS touch -> mouse gesture translation
//
// SDL's automatic touch-mouse synthesis is disabled on iOS (SDL3Main.cpp sets
// SDL_HINT_TOUCH_MOUSE_EVENTS=0); every mouse event the game sees on iOS is
// synthesized here, through the same SDL3Mouse::addSDLEvent path real mice use.
//
// iOS touch controls:
//   1 finger short tap    -> synthetic LMB click (select)
//   1 finger movement     -> synthetic RMB drag (camera pan)
//   1 finger hold 3 sec   -> switch to LMB selection-rectangle mode
//   1 finger after 0.5 sec  -> movement expands the selection rectangle
//   2 finger short tap    -> synthetic RMB click (cancel/deselect)
//   2 finger movement     -> zoom
//   2 finger pinch        -> mouse-wheel zoom
// ---------------------------------------------------------------------------
namespace {

struct TouchState {
    enum Phase { IDLE, PENDING, CAMERA_PAN, SELECTING, PINCH, TWO_FINGER_CANCEL };

    Phase phase = IDLE;
    SDL_FingerID finger1 = 0;
    SDL_FingerID finger2 = 0;
    bool finger1Active = false;
    bool finger2Active = false;

    float downX = 0.0f, downY = 0.0f;
    float lastX = 0.0f, lastY = 0.0f;
    float pinchDist = 0.0f;
    Uint64 downTicks = 0;

    float f1x = 0.0f, f1y = 0.0f;
    float f2x = 0.0f, f2y = 0.0f;

    bool twoFingerTapCandidate = false;
    float twoFingerStart1X = 0.0f, twoFingerStart1Y = 0.0f;
    float twoFingerStart2X = 0.0f, twoFingerStart2Y = 0.0f;
    float twoFingerMaxMove = 0.0f;
    float twoFingerStartDist = 0.0f;

    // The game camera consumes MouseIO deltaPos. Synthetic motion therefore
    // must populate SDL xrel/yrel instead of leaving them at zero.
    float syntheticX = 0.0f;
    float syntheticY = 0.0f;

    // Track synthetic mouse buttons so iOS touch cancellation can never leave
    // the camera RMB latched after a two-finger gesture.
    bool syntheticRightHeld = false;
    bool syntheticLeftHeld = false;
};

TouchState s_touch;

const Uint64 LONG_PRESS_MS = 500;
const float PINCH_STEP_RATIO = 0.06f;
const float TAP_DEAD_ZONE_PX = 8.0f;
const float TWO_FINGER_TAP_MAX_MOVE_PX = 12.0f;
const float TWO_FINGER_TAP_MAX_DISTANCE_CHANGE_PX = 12.0f;

void sendSyntheticMouse(SDL3Mouse *mouse, SDL_Window *window, Uint32 type,
                        float x, float y, Uint8 button = 0, float wheelY = 0.0f)
{
    SDL_Event ev;
    SDL_zero(ev);
    ev.type = type;
    const SDL_WindowID windowID = SDL_GetWindowID(window);

    switch (type) {
        case SDL_EVENT_MOUSE_MOTION:
            ev.motion.windowID = windowID;
            ev.motion.which = 0;
            ev.motion.x = x;
            ev.motion.y = y;
            ev.motion.xrel = x - s_touch.syntheticX;
            ev.motion.yrel = y - s_touch.syntheticY;
            ev.motion.state = 0;
            ev.motion.timestamp = 0;
            s_touch.syntheticX = x;
            s_touch.syntheticY = y;
            break;

        case SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EVENT_MOUSE_BUTTON_UP:
            ev.button.windowID = windowID;
            ev.button.which = 0;
            ev.button.button = button;
            ev.button.down = (type == SDL_EVENT_MOUSE_BUTTON_DOWN);
            ev.button.clicks = 1;
            ev.button.x = x;
            ev.button.y = y;
            ev.button.timestamp = 0;
            break;

        case SDL_EVENT_MOUSE_WHEEL:
            ev.wheel.windowID = windowID;
            ev.wheel.which = 0;
            ev.wheel.x = 0.0f;
            ev.wheel.y = wheelY;
            ev.wheel.mouse_x = x;
            ev.wheel.mouse_y = y;
            ev.wheel.timestamp = 0;
            break;
    }

    mouse->addSDLEvent(&ev);

    if (type == SDL_EVENT_MOUSE_BUTTON_DOWN && button == SDL_BUTTON_RIGHT)
        s_touch.syntheticRightHeld = true;
    else if (type == SDL_EVENT_MOUSE_BUTTON_DOWN && button == SDL_BUTTON_LEFT)
        s_touch.syntheticLeftHeld = true;
    else if (type == SDL_EVENT_MOUSE_BUTTON_UP && button == SDL_BUTTON_RIGHT)
        s_touch.syntheticRightHeld = false;
    else if (type == SDL_EVENT_MOUSE_BUTTON_UP && button == SDL_BUTTON_LEFT)
        s_touch.syntheticLeftHeld = false;
}

void releaseSyntheticButtons(SDL3Mouse *mouse, SDL_Window *window, float x, float y)
{
    if (s_touch.syntheticRightHeld)
        sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP, x, y, SDL_BUTTON_RIGHT);
    if (s_touch.syntheticLeftHeld)
        sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP, x, y, SDL_BUTTON_LEFT);

    s_touch.syntheticRightHeld = false;
    s_touch.syntheticLeftHeld = false;
}

void resetSyntheticPosition(float x, float y)
{
    s_touch.syntheticX = x;
    s_touch.syntheticY = y;
}

void beginPinch(SDL3Mouse *mouse, SDL_Window *window, int winW, int winH)
{
    const float dx = (s_touch.f1x - s_touch.f2x) * (float)winW;
    const float dy = (s_touch.f1y - s_touch.f2y) * (float)winH;
    s_touch.pinchDist = SDL_sqrtf(dx * dx + dy * dy);

    // A second finger permanently terminates the one-finger gesture.
    // Release any synthetic button, then keep the mouse position frozen while
    // the two-finger gesture owns the input. This prevents a hidden xrel delta
    // from turning a two-finger tap into a camera pan.
    releaseSyntheticButtons(mouse, window, s_touch.lastX, s_touch.lastY);

    s_touch.twoFingerTapCandidate = true;
    s_touch.twoFingerStart1X = s_touch.f1x;
    s_touch.twoFingerStart1Y = s_touch.f1y;
    s_touch.twoFingerStart2X = s_touch.f2x;
    s_touch.twoFingerStart2Y = s_touch.f2y;
    s_touch.twoFingerMaxMove = 0.0f;
    s_touch.twoFingerStartDist = s_touch.pinchDist;
    s_touch.phase = TouchState::PINCH;

    // Do not synthesize ANY mouse motion when the second finger arrives.
    // A zero-delta SDL mouse-motion event is still an absolute touch-to-mouse
    // conversion on some iOS paths and can rotate the camera to the right.
    // The pinch owns both fingers from this point; only wheel events are sent.

    // Do not synthesize a mouse move to the pinch center. The game can treat
    // that xrel/yrel jump as camera motion even though RMB was released.
    // Keep the current synthetic cursor position stable while the two-finger
    // gesture owns the input.
    resetSyntheticPosition(s_touch.lastX, s_touch.lastY);
}

void beginCameraPan(SDL3Mouse *mouse, SDL_Window *window)
{
    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION,
                       s_touch.downX, s_touch.downY);
    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_DOWN,
                       s_touch.downX, s_touch.downY, SDL_BUTTON_RIGHT);
    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION,
                       s_touch.lastX, s_touch.lastY);
    s_touch.phase = TouchState::CAMERA_PAN;
}

void beginSelection(SDL3Mouse *mouse, SDL_Window *window)
{
    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION,
                       s_touch.downX, s_touch.downY);
    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_DOWN,
                       s_touch.downX, s_touch.downY, SDL_BUTTON_LEFT);
    s_touch.phase = TouchState::SELECTING;
}

void resetToSingleFingerPending(SDL_FingerID finger, float x, float y)
{
    s_touch.finger1 = finger;
    s_touch.finger2 = 0;
    s_touch.finger1Active = true;
    s_touch.finger2Active = false;
    s_touch.downX = s_touch.lastX = x;
    s_touch.downY = s_touch.lastY = y;
    s_touch.f1x = x;
    s_touch.f1y = y;
    s_touch.f2x = s_touch.f2y = 0.0f;
    s_touch.downTicks = SDL_GetTicks();
    s_touch.twoFingerTapCandidate = false;
    s_touch.phase = TouchState::PENDING;
    resetSyntheticPosition(x, y);
}

void updateTwoFingerCandidate(int winW, int winH)
{
    if (!s_touch.twoFingerTapCandidate) {
        return;
    }

    const float dx1 = (s_touch.f1x - s_touch.twoFingerStart1X) * (float)winW;
    const float dy1 = (s_touch.f1y - s_touch.twoFingerStart1Y) * (float)winH;
    const float dx2 = (s_touch.f2x - s_touch.twoFingerStart2X) * (float)winW;
    const float dy2 = (s_touch.f2y - s_touch.twoFingerStart2Y) * (float)winH;
    const float move1 = SDL_sqrtf(dx1 * dx1 + dy1 * dy1);
    const float move2 = SDL_sqrtf(dx2 * dx2 + dy2 * dy2);

    if (move1 > s_touch.twoFingerMaxMove) s_touch.twoFingerMaxMove = move1;
    if (move2 > s_touch.twoFingerMaxMove) s_touch.twoFingerMaxMove = move2;

    const float dx = (s_touch.f1x - s_touch.f2x) * (float)winW;
    const float dy = (s_touch.f1y - s_touch.f2y) * (float)winH;
    const float dist = SDL_sqrtf(dx * dx + dy * dy);

    if (s_touch.twoFingerMaxMove > TWO_FINGER_TAP_MAX_MOVE_PX ||
        SDL_fabsf(dist - s_touch.twoFingerStartDist) >
            TWO_FINGER_TAP_MAX_DISTANCE_CHANGE_PX) {
        s_touch.twoFingerTapCandidate = false;
    }
}

void handleTouchEvent(SDL3Mouse *mouse, SDL_Window *window, const SDL_Event &event)
{
    int winW = 0, winH = 0;
    SDL_GetWindowSize(window, &winW, &winH);
    const float px = event.tfinger.x * (float)winW;
    const float py = event.tfinger.y * (float)winH;

    switch (event.type) {
    case SDL_EVENT_FINGER_DOWN:
        if (s_touch.phase == TouchState::IDLE) {
            resetToSingleFingerPending(event.tfinger.fingerID, px, py);
            sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, px, py);
        } else if (s_touch.phase == TouchState::PENDING ||
                   s_touch.phase == TouchState::CAMERA_PAN ||
                   s_touch.phase == TouchState::SELECTING) {
            // Second finger cancels one-finger camera/selection state and starts
            // the real two-finger pinch. The previous cancel-only path disabled
            // zoom completely.
            releaseSyntheticButtons(mouse, window, s_touch.lastX, s_touch.lastY);

            s_touch.finger2 = event.tfinger.fingerID;
            s_touch.finger2Active = true;
            s_touch.f2x = event.tfinger.x;
            s_touch.f2y = event.tfinger.y;
            beginPinch(mouse, window, winW, winH);
        }
        break;

    case SDL_EVENT_FINGER_MOTION:
        if (s_touch.phase == TouchState::TWO_FINGER_CANCEL) {
            // Ignore all movement while the two-finger cancel gesture owns the touch.
            break;
        }
        if (s_touch.phase == TouchState::PINCH) {
            // PINCH owns both fingers completely. Do not update lastX/lastY:
            // those coordinates belong to one-finger camera control and must
            // not leak a delta back into the mouse/camera path.
            if (s_touch.finger1Active && event.tfinger.fingerID == s_touch.finger1) {
                s_touch.f1x = event.tfinger.x;
                s_touch.f1y = event.tfinger.y;
            } else if (s_touch.finger2Active && event.tfinger.fingerID == s_touch.finger2) {
                s_touch.f2x = event.tfinger.x;
                s_touch.f2y = event.tfinger.y;
            } else {
                break;
            }

            updateTwoFingerCandidate(winW, winH);

            const float dx = (s_touch.f1x - s_touch.f2x) * (float)winW;
            const float dy = (s_touch.f1y - s_touch.f2y) * (float)winH;
            const float dist = SDL_sqrtf(dx * dx + dy * dy);
            const float cx = (s_touch.f1x + s_touch.f2x) * 0.5f * (float)winW;
            const float cy = (s_touch.f1y + s_touch.f2y) * 0.5f * (float)winH;

            if (s_touch.pinchDist > 1.0f) {
                const float ratio = dist / s_touch.pinchDist;
                if (ratio > 1.0f + PINCH_STEP_RATIO) {
                    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_WHEEL,
                                       cx, cy, 0, 1.0f);
                    s_touch.pinchDist = dist;
                    s_touch.twoFingerTapCandidate = false;
                } else if (ratio < 1.0f - PINCH_STEP_RATIO) {
                    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_WHEEL,
                                       cx, cy, 0, -1.0f);
                    s_touch.pinchDist = dist;
                    s_touch.twoFingerTapCandidate = false;
                }
            }
            break;
        }

        if (s_touch.finger1Active && event.tfinger.fingerID == s_touch.finger1) {
            s_touch.f1x = event.tfinger.x;
            s_touch.f1y = event.tfinger.y;
            s_touch.lastX = px;
            s_touch.lastY = py;
        } else if (s_touch.finger2Active && event.tfinger.fingerID == s_touch.finger2) {
            s_touch.f2x = event.tfinger.x;
            s_touch.f2y = event.tfinger.y;
        } else {
            break;
        }

        if (s_touch.phase == TouchState::PENDING &&
            event.tfinger.fingerID == s_touch.finger1) {
            const float dx = px - s_touch.downX;
            const float dy = py - s_touch.downY;
            if (SDL_sqrtf(dx * dx + dy * dy) >= TAP_DEAD_ZONE_PX) {
                beginCameraPan(mouse, window);
            }
        } else if (s_touch.phase == TouchState::CAMERA_PAN &&
                   event.tfinger.fingerID == s_touch.finger1) {
            sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, px, py);
        } else if (s_touch.phase == TouchState::SELECTING &&
                   event.tfinger.fingerID == s_touch.finger1) {
            sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, px, py);
        }
        break;

    case SDL_EVENT_FINGER_UP:
    case SDL_EVENT_FINGER_CANCELED:
        if (event.tfinger.fingerID != s_touch.finger1 &&
            event.tfinger.fingerID != s_touch.finger2) {
            break;
        }

        if (s_touch.phase == TouchState::TWO_FINGER_CANCEL) {
            // Never promote the other finger to PENDING/CAMERA_PAN.
            if (event.tfinger.fingerID == s_touch.finger1) {
                s_touch.finger1Active = false;
            }
            if (event.tfinger.fingerID == s_touch.finger2) {
                s_touch.finger2Active = false;
            }

            if (!s_touch.finger1Active && !s_touch.finger2Active) {
                // End of a real pinch: flush the last one-finger delta and do not
                // promote either finger back into camera control.
                sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION,
                                   s_touch.syntheticX, s_touch.syntheticY);
                s_touch.phase = TouchState::IDLE;
                s_touch.finger1 = 0;
                s_touch.finger2 = 0;
                s_touch.twoFingerTapCandidate = false;
                s_touch.pinchDist = 0.0f;
                releaseSyntheticButtons(mouse, window, px, py);
                resetSyntheticPosition(px, py);
            }
            break;
        }

        if (s_touch.phase == TouchState::PINCH) {
            if (event.type == SDL_EVENT_FINGER_CANCELED) {
                // Cancel any synthetic drag state before dropping the touch state.
                sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP,
                                   s_touch.syntheticX, s_touch.syntheticY, SDL_BUTTON_RIGHT);
                sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP,
                                   s_touch.syntheticX, s_touch.syntheticY, SDL_BUTTON_LEFT);
                s_touch.phase = TouchState::IDLE;
                s_touch.finger1 = 0;
                s_touch.finger2 = 0;
                s_touch.finger1Active = false;
                s_touch.finger2Active = false;
                s_touch.twoFingerTapCandidate = false;
                resetSyntheticPosition(px, py);
                break;
            }

            const bool firstReleased =
                s_touch.finger1Active && event.tfinger.fingerID == s_touch.finger1;
            const bool secondReleased =
                s_touch.finger2Active && event.tfinger.fingerID == s_touch.finger2;

            if (s_touch.twoFingerTapCandidate && (firstReleased || secondReleased)) {
                if (firstReleased) {
                    s_touch.finger1Active = false;
                } else {
                    s_touch.finger2Active = false;
                }

                if (!s_touch.finger1Active && !s_touch.finger2Active) {
                    const float cx =
                        (s_touch.twoFingerStart1X + s_touch.twoFingerStart2X) *
                        0.5f * (float)winW;
                    const float cy =
                        (s_touch.twoFingerStart1Y + s_touch.twoFingerStart2Y) *
                        0.5f * (float)winH;
                    // A short two-finger tap is the game's RMB cancel/deselect.
                    // It is a CLICK only: no drag, no camera pan. Pinch zoom remains
                    // enabled because any meaningful finger movement clears the tap
                    // candidate and stays in PINCH.
                    releaseSyntheticButtons(mouse, window,
                                            s_touch.syntheticX, s_touch.syntheticY);
                    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_DOWN,
                                       cx, cy, SDL_BUTTON_RIGHT);
                    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP,
                                       cx, cy, SDL_BUTTON_RIGHT);
                    // Never inject a mouse-motion event at the end of a
                    // two-finger tap. The next one-finger touch starts fresh.
                    s_touch.phase = TouchState::IDLE;
                    s_touch.finger1 = 0;
                    s_touch.finger2 = 0;
                    s_touch.finger1Active = false;
                    s_touch.finger2Active = false;
                    s_touch.twoFingerTapCandidate = false;
                    s_touch.pinchDist = 0.0f;
                    resetSyntheticPosition(s_touch.syntheticX, s_touch.syntheticY);
                }
                break;
            }

            // Для двухпальцевого tap ждём ОБА FINGER_UP. Нельзя переводить
            // оставшийся палец в PENDING: именно это раньше запускало самопроизвольный
            // RMB-pan вправо после обычного двухпальцевого cancel/deselect.
            if (s_touch.twoFingerTapCandidate) {
                if (firstReleased) {
                    s_touch.finger1Active = false;
                }
                if (secondReleased) {
                    s_touch.finger2Active = false;
                }

                if (!s_touch.finger1Active && !s_touch.finger2Active) {
                    // Fallback for the same short two-finger tap state:
                    // generate exactly one RMB click, never a drag.
                    const cx =
                        (s_touch.twoFingerStart1X + s_touch.twoFingerStart2X) *
                        0.5f * (float)winW;
                    const cy =
                        (s_touch.twoFingerStart1Y + s_touch.twoFingerStart2Y) *
                        0.5f * (float)winH;
                    releaseSyntheticButtons(mouse, window,
                                            s_touch.syntheticX, s_touch.syntheticY);
                    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_DOWN,
                                       cx, cy, SDL_BUTTON_RIGHT);
                    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP,
                                       cx, cy, SDL_BUTTON_RIGHT);
                    // Never inject a mouse-motion event at the end of a
                    // two-finger tap. The next one-finger touch starts fresh.
                    s_touch.phase = TouchState::IDLE;
                    s_touch.finger1 = 0;
                    s_touch.finger2 = 0;
                    s_touch.finger1Active = false;
                    s_touch.finger2Active = false;
                    s_touch.twoFingerTapCandidate = false;
                    s_touch.pinchDist = 0.0f;
                    resetSyntheticPosition(s_touch.syntheticX, s_touch.syntheticY);
                }
                break;
            }

            // После любого двухпальцевого жеста НИКОГДА не превращаем
            // оставшийся палец в PENDING/CAMERA_PAN. Иначе обычный двухпальцевый
            // cancel заканчивается самопроизвольным движением камеры вправо/влево.
            // Пользователь должен отпустить оба пальца и сделать новый
            // однопальцевый touch, чтобы снова управлять камерой.
            if (firstReleased) {
                s_touch.finger1Active = false;
            }
            if (secondReleased) {
                s_touch.finger2Active = false;
            }

            if (!s_touch.finger1Active && !s_touch.finger2Active) {
                s_touch.phase = TouchState::IDLE;
                s_touch.finger1 = 0;
                s_touch.finger2 = 0;
                s_touch.finger1Active = false;
                s_touch.finger2Active = false;
                s_touch.twoFingerTapCandidate = false;
                s_touch.pinchDist = 0.0f;
                resetSyntheticPosition(px, py);
            }
            break;
        }

        if (!s_touch.finger1Active || event.tfinger.fingerID != s_touch.finger1) {
            break;
        }

        switch (s_touch.phase) {
            case TouchState::PENDING:
                if (event.type != SDL_EVENT_FINGER_CANCELED) {
                    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION,
                                       s_touch.downX, s_touch.downY);
                    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_DOWN,
                                       s_touch.downX, s_touch.downY, SDL_BUTTON_LEFT);
                    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP,
                                       s_touch.downX, s_touch.downY, SDL_BUTTON_LEFT);
                }
                break;

            case TouchState::CAMERA_PAN:
            case TouchState::SELECTING:
                releaseSyntheticButtons(mouse, window, s_touch.lastX, s_touch.lastY);
                break;

            default:
                break;
        }

        s_touch.phase = TouchState::IDLE;
        s_touch.finger1 = 0;
        s_touch.finger2 = 0;
        s_touch.finger1Active = false;
        s_touch.finger2Active = false;
        resetSyntheticPosition(s_touch.lastX, s_touch.lastY);
        break;
    }
}

void updateTouchLongPress(SDL3Mouse *mouse, SDL_Window *window)
{
    if (s_touch.phase == TouchState::PENDING &&
        (SDL_GetTicks() - s_touch.downTicks) >= LONG_PRESS_MS) {
        beginSelection(mouse, window);
    }
}

} // anonymous namespace
#endif // TARGET_OS_IPHONE

namespace {

Bool DecodeNextUtf8Codepoint(const char* text, size_t length, size_t& offset, UnsignedInt& outCodepoint)
{
	outCodepoint = 0;
	if (!text || offset >= length) {
		return false;
	}

	const unsigned char first = static_cast<unsigned char>(text[offset]);
	if (first == 0) {
		return false;
	}

	if (first < 0x80) {
		outCodepoint = first;
		offset += 1;
		return true;
	}

	if ((first & 0xE0) == 0xC0 && offset + 1 < length) {
		const unsigned char second = static_cast<unsigned char>(text[offset + 1]);
		if ((second & 0xC0) == 0x80) {
			outCodepoint = ((first & 0x1F) << 6) | (second & 0x3F);
			offset += 2;
			return true;
		}
	}

	if ((first & 0xF0) == 0xE0 && offset + 2 < length) {
		const unsigned char second = static_cast<unsigned char>(text[offset + 1]);
		const unsigned char third = static_cast<unsigned char>(text[offset + 2]);
		if ((second & 0xC0) == 0x80 && (third & 0xC0) == 0x80) {
			outCodepoint = ((first & 0x0F) << 12) | ((second & 0x3F) << 6) | (third & 0x3F);
			offset += 3;
			return true;
		}
	}

	if ((first & 0xF8) == 0xF0 && offset + 3 < length) {
		const unsigned char second = static_cast<unsigned char>(text[offset + 1]);
		const unsigned char third = static_cast<unsigned char>(text[offset + 2]);
		const unsigned char fourth = static_cast<unsigned char>(text[offset + 3]);
		if ((second & 0xC0) == 0x80 && (third & 0xC0) == 0x80 && (fourth & 0xC0) == 0x80) {
			outCodepoint = ((first & 0x07) << 18) | ((second & 0x3F) << 12) | ((third & 0x3F) << 6) | (fourth & 0x3F);
			offset += 4;
			return true;
		}
	}

	// Invalid UTF-8 sequence: skip one byte and keep processing.
	offset += 1;
	return false;
}

}

/**
 * Constructor: Initialize SDL3 game engine state
 */
SDL3GameEngine::SDL3GameEngine()
	: GameEngine(),
	  m_SDLWindow(nullptr),
	  m_IsInitialized(false),
	  m_IsActive(false),
	  m_IsTextInputActive(false),
	  m_TextInputFocusWindow(nullptr),
  m_TextInputSuppressedFocusWindow(nullptr)
{
	fprintf(stderr, "DEBUG: SDL3GameEngine::SDL3GameEngine() created\n");
}

/**
 * Destructor: Cleanup SDL3 resources
 */
SDL3GameEngine::~SDL3GameEngine()
{
	if (m_SDLWindow && m_IsTextInputActive) {
		SDL_StopTextInput(m_SDLWindow);
		m_IsTextInputActive = false;
		m_TextInputFocusWindow = nullptr;
	}

	if (m_IsInitialized) {
		// Window cleanup is done in reset/shutdown
	}
	fprintf(stderr, "DEBUG: SDL3GameEngine::~SDL3GameEngine() destroyed\n");
}

/**
 * From GameEngine: init() - initialize subsystems
 * 
 * GeneralsX @bugfix felipebraz 16/02/2026
 * Simplified to follow fighter19 pattern - SDL3/Vulkan initialized in SDL3Main.cpp
 * before GameEngine is created. This init() only delegates to parent GameEngine::init().
 * ApplicationHWnd and TheSDL3Window are already set by main() before this is called.
 */
void SDL3GameEngine::init(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::init() starting\n");

	if (TheGlobalData && TheGlobalData->m_headless) {
		// GeneralsX @bugfix Copilot 17/05/2026 Allow headless replay path to initialize engine subsystems without an SDL window.
		fprintf(stderr, "INFO: SDL3GameEngine::init() headless mode - skipping SDL window binding\n");
		m_SDLWindow = nullptr;
		m_IsInitialized = true;
		m_IsActive = true;
		GameEngine::init();
		return;
	}

	// Verify window was created by SDL3Main.cpp
	extern SDL_Window* TheSDL3Window;
	extern HWND ApplicationHWnd;
	
	if (!TheSDL3Window || !ApplicationHWnd) {
		fprintf(stderr, "FATAL: SDL3 window not initialized before GameEngine::init()\n");
		fprintf(stderr, "FATAL: TheSDL3Window=%p, ApplicationHWnd=%p\n", TheSDL3Window, ApplicationHWnd);
		return;
	}

	// Store window reference locally
	m_SDLWindow = TheSDL3Window;
	m_IsInitialized = true;
	m_IsActive = true;

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
	// Lifecycle events can fire outside the poll cycle on iOS; catch them
	// immediately so rendering halts before the process is suspended.
	SDL_AddEventWatch(iosLifecycleWatcher, nullptr);
#endif

	fprintf(stderr, "INFO: SDL3GameEngine using pre-initialized window\n");

	// Call parent init to initialize game subsystems
	GameEngine::init();
}

/**
 * From GameEngine: reset() - reset system to starting state
 */
void SDL3GameEngine::reset(void)
{
	fprintf(stderr, "DEBUG: SDL3GameEngine::reset()\n");
	if (m_SDLWindow && m_IsTextInputActive) {
		SDL_StopTextInput(m_SDLWindow);
		m_IsTextInputActive = false;
		m_TextInputFocusWindow = nullptr;
	}
	m_TextInputSuppressedFocusWindow = nullptr;
	GameEngine::reset();
}

/**
 * From GameEngine: update() - per-frame update
 */
void SDL3GameEngine::update(void)
{
	pollSDL3Events();
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
	// Pause sim + render while backgrounded OR inactive (see iosLifecycleWatcher).
	// Acquiring a Metal drawable in these windows fights iOS for the layer and,
	// across repeated suspend/switcher cycles, crashes MoltenVK. Keep polling so
	// we still catch the resume events; just don't touch the GPU.
	if (iosShouldPauseRendering()) {
		SDL_Delay(50);
		return;
	}
#endif
	GameEngine::update();
}

/**
 * From GameEngine: execute() - main game loop
 */
void SDL3GameEngine::execute(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::execute() - entering main loop\n");
	GameEngine::execute();
	fprintf(stderr, "INFO: SDL3GameEngine::execute() - exited main loop\n");
}

/**
 * From GameEngine: serviceWindowsOS() - native OS service
 * On Linux, process SDL3 events
 */
void SDL3GameEngine::serviceWindowsOS(void)
{
	pollSDL3Events();
}

/**
 * Check if game has OS focus
 */
Bool SDL3GameEngine::isActive(void)
{
	return m_IsActive;
}

/**
 * Set OS focus status
 */
void SDL3GameEngine::setIsActive(Bool isActive)
{
	m_IsActive = isActive;
}

/**
 * Poll and process SDL3 events
 * Handles keyboard, mouse, window, and quit events
 */
void SDL3GameEngine::pollSDL3Events(void)
{
	if (!m_SDLWindow) {
		return;
	}

	updateTextInputState();

	SDL_Event event;
	while (SDL_PollEvent(&event)) {
		switch (event.type) {
			case SDL_EVENT_QUIT:
				m_quitting = true;
				break;

			case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
				m_quitting = true;
				break;

			case SDL_EVENT_WINDOW_FOCUS_GAINED:
				m_IsActive = true;
				if (TheMouse) {
					TheMouse->regainFocus();
					TheMouse->refreshCursorCapture();
				}
				break;
