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
// Gestures (matching the game's stock control scheme, which is LMB-centric):
//   1 finger tap/drag     -> left button click / drag (select, command, drag-box)
//   1 finger long-press   -> right button click (deselect), if finger stays put
//   2 finger drag         -> right-button drag at the centroid (camera scroll)
//   2 finger pinch        -> mouse wheel (camera zoom)
// ---------------------------------------------------------------------------
namespace {

struct TouchState {
    enum Phase { IDLE, PENDING, CAMERA_PAN, SELECTING, PINCH };

    Phase phase = IDLE;
    SDL_FingerID finger1 = 0;
    SDL_FingerID finger2 = 0;

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
};

TouchState s_touch;

const Uint64 LONG_PRESS_MS = 3000;
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

    if (s_touch.phase == TouchState::CAMERA_PAN) {
        sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP,
                           s_touch.lastX, s_touch.lastY, SDL_BUTTON_RIGHT);
    } else if (s_touch.phase == TouchState::SELECTING) {
        sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP,
                           s_touch.lastX, s_touch.lastY, SDL_BUTTON_LEFT);
    }

    s_touch.twoFingerTapCandidate = true;
    s_touch.twoFingerStart1X = s_touch.f1x;
    s_touch.twoFingerStart1Y = s_touch.f1y;
    s_touch.twoFingerStart2X = s_touch.f2x;
    s_touch.twoFingerStart2Y = s_touch.f2y;
    s_touch.twoFingerMaxMove = 0.0f;
    s_touch.twoFingerStartDist = s_touch.pinchDist;
    s_touch.phase = TouchState::PINCH;

    resetSyntheticPosition(
        (s_touch.f1x + s_touch.f2x) * 0.5f * (float)winW,
        (s_touch.f1y + s_touch.f2y) * 0.5f * (float)winH);
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
            s_touch.finger2 = event.tfinger.fingerID;
            s_touch.f2x = event.tfinger.x;
            s_touch.f2y = event.tfinger.y;
            beginPinch(mouse, window, winW, winH);
        }
        break;

    case SDL_EVENT_FINGER_MOTION:
        if (event.tfinger.fingerID == s_touch.finger1) {
            s_touch.f1x = event.tfinger.x;
            s_touch.f1y = event.tfinger.y;
            s_touch.lastX = px;
            s_touch.lastY = py;
        } else if (event.tfinger.fingerID == s_touch.finger2) {
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
        } else if (s_touch.phase == TouchState::PINCH) {
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
        }
        break;

    case SDL_EVENT_FINGER_UP:
    case SDL_EVENT_FINGER_CANCELED:
        if (event.tfinger.fingerID != s_touch.finger1 &&
            event.tfinger.fingerID != s_touch.finger2) {
            break;
        }

        if (s_touch.phase == TouchState::PINCH) {
            if (event.type == SDL_EVENT_FINGER_CANCELED) {
                s_touch.phase = TouchState::IDLE;
                s_touch.finger1 = 0;
                s_touch.finger2 = 0;
                s_touch.twoFingerTapCandidate = false;
                break;
            }

            const bool firstReleased = event.tfinger.fingerID == s_touch.finger1;
            const bool secondReleased = event.tfinger.fingerID == s_touch.finger2;

            if (s_touch.twoFingerTapCandidate && (firstReleased || secondReleased)) {
                if (firstReleased) {
                    s_touch.finger1 = 0;
                } else {
                    s_touch.finger2 = 0;
                }

                if (s_touch.finger1 == 0 && s_touch.finger2 == 0) {
                    const float cx =
                        (s_touch.twoFingerStart1X + s_touch.twoFingerStart2X) *
                        0.5f * (float)winW;
                    const float cy =
                        (s_touch.twoFingerStart1Y + s_touch.twoFingerStart2Y) *
                        0.5f * (float)winH;
                    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_MOTION, cx, cy);
                    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_DOWN,
                                       cx, cy, SDL_BUTTON_RIGHT);
                    sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP,
                                       cx, cy, SDL_BUTTON_RIGHT);
                    s_touch.phase = TouchState::IDLE;
                    s_touch.twoFingerTapCandidate = false;
                }
                break;
            }

            if (firstReleased && s_touch.finger2 != 0) {
                resetToSingleFingerPending(
                    s_touch.finger2,
                    s_touch.f2x * (float)winW,
                    s_touch.f2y * (float)winH);
            } else if (secondReleased && s_touch.finger1 != 0) {
                resetToSingleFingerPending(
                    s_touch.finger1,
                    s_touch.f1x * (float)winW,
                    s_touch.f1y * (float)winH);
            } else {
                s_touch.phase = TouchState::IDLE;
                s_touch.finger1 = 0;
                s_touch.finger2 = 0;
            }
            break;
        }

        if (event.tfinger.fingerID != s_touch.finger1) {
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
                sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP,
                                   s_touch.lastX, s_touch.lastY, SDL_BUTTON_RIGHT);
                break;

            case TouchState::SELECTING:
                sendSyntheticMouse(mouse, window, SDL_EVENT_MOUSE_BUTTON_UP,
                                   s_touch.lastX, s_touch.lastY, SDL_BUTTON_LEFT);
                break;

            default:
                break;
        }

        s_touch.phase = TouchState::IDLE;
        s_touch.finger1 = 0;
        s_touch.finger2 = 0;
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

			case SDL_EVENT_WINDOW_FOCUS_LOST:
				m_IsActive = false;
				if (m_IsTextInputActive) {
					SDL_StopTextInput(m_SDLWindow);
					m_IsTextInputActive = false;
					m_TextInputFocusWindow = nullptr;
				}
				m_TextInputSuppressedFocusWindow = nullptr;
				if (TheMouse) {
					TheMouse->loseFocus();
				}
				break;

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
			// App suspension/resume: mirror the desktop focus handling so audio
			// and mouse state pause cleanly (the render gate lives in update()).
			case SDL_EVENT_DID_ENTER_BACKGROUND:
				m_IsActive = false;
				if (TheMouse) {
					TheMouse->loseFocus();
				}
				break;

			case SDL_EVENT_DID_ENTER_FOREGROUND:
				m_IsActive = true;
				if (TheMouse) {
					TheMouse->regainFocus();
					TheMouse->refreshCursorCapture();
				}
				break;
#endif

			case SDL_EVENT_WINDOW_MOUSE_ENTER:
				if (TheMouse) {
					TheMouse->onCursorMovedInside();
				}
				break;

			case SDL_EVENT_WINDOW_MOUSE_LEAVE:
				if (TheMouse) {
					TheMouse->onCursorMovedOutside();
				}
				break;

			case SDL_EVENT_SCREEN_KEYBOARD_SHOWN:
				m_IsTextInputActive = true;
				break;

			case SDL_EVENT_SCREEN_KEYBOARD_HIDDEN:
				if (m_TextInputFocusWindow &&
				    BitIsSet(m_TextInputFocusWindow->winGetStyle(), GWS_ENTRY_FIELD)) {
					m_IsTextInputActive = false;
					m_TextInputSuppressedFocusWindow = m_TextInputFocusWindow;
				}
				break;

			case SDL_EVENT_KEY_DOWN:
			case SDL_EVENT_KEY_UP:
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
				// iOS Return handling: force the IME closed and suppress any
				// immediate SDL_StartTextInput() while this same entry field
				// remains focused. Do this even if SDL already reports text input
				// as inactive; the native iOS IME can still be in the process of
				// dismissing/reconfiguring after Return.
				if (event.type == SDL_EVENT_KEY_DOWN &&
				    (event.key.key == SDLK_RETURN || event.key.key == SDLK_KP_ENTER)) {
					GameWindow* returnFocus = m_TextInputFocusWindow;
					if (!returnFocus && TheWindowManager) {
						returnFocus = TheWindowManager->winGetFocus();
					}
					if (returnFocus &&
					    BitIsSet(returnFocus->winGetStyle(), GWS_ENTRY_FIELD)) {
						SDL_StopTextInput(m_SDLWindow);
						m_IsTextInputActive = false;
						m_TextInputFocusWindow = returnFocus;
						m_TextInputSuppressedFocusWindow = returnFocus;
						fprintf(stderr, "INFO: iOS text input: Return dismissed keyboard; IME suppressed until entry focus changes\\n");
					}
				}
#endif
				// Fighter19 pattern: direct addSDLEvent() call
				// GeneralsX @refactor felipebraz 16/02/2026 Simplified event routing
				if (TheKeyboard) {
					SDL3Keyboard* keyboard = dynamic_cast<SDL3Keyboard*>(TheKeyboard);
					if (keyboard) {
						keyboard->addSDLEvent(&event);
					}
				}
				break;

			case SDL_EVENT_TEXT_INPUT:
				forwardTextInputEvent(event.text.text);
				break;

			case SDL_EVENT_MOUSE_MOTION:
			case SDL_EVENT_MOUSE_BUTTON_DOWN:
			case SDL_EVENT_MOUSE_BUTTON_UP:
			case SDL_EVENT_MOUSE_WHEEL:
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
				// Belt-and-braces: drop SDL's own touch-synthesized mouse events.
				// The gesture translator owns all touch->mouse conversion; double
				// delivery would produce phantom second clicks.
				if (event.motion.which == SDL_TOUCH_MOUSEID) {
					break;
				}
#endif
				// Fighter19 pattern: direct addSDLEvent() call with raw SDL_Event
				// GeneralsX @refactor felipebraz 16/02/2026 Simplified event routing
				if (TheMouse) {
					SDL3Mouse* mouse = dynamic_cast<SDL3Mouse*>(TheMouse);
					if (mouse) {
						mouse->addSDLEvent(&event);
					}
				}
				break;

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
			case SDL_EVENT_FINGER_DOWN:
			case SDL_EVENT_FINGER_MOTION:
			case SDL_EVENT_FINGER_UP:
			case SDL_EVENT_FINGER_CANCELED:
				if (TheMouse && m_SDLWindow) {
					SDL3Mouse* mouse = dynamic_cast<SDL3Mouse*>(TheMouse);
					if (mouse) {
						handleTouchEvent(mouse, m_SDLWindow, event);
					}
				}
				break;
#endif

			case SDL_EVENT_WINDOW_RESIZED:
				handleWindowEvent(event.window);
				break;

			default:
				// Ignore other events for now
				break;
		}

		updateTextInputState();
	}

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
	// Poll the long-press timer every frame; a stationary finger emits no events.
	if (TheMouse && m_SDLWindow) {
		SDL3Mouse* touchMouse = dynamic_cast<SDL3Mouse*>(TheMouse);
		if (touchMouse) {
			updateTouchLongPress(touchMouse, m_SDLWindow);
		}
	}
#endif
}

// GeneralsX @bugfix felipebraz 01/04/2026 Enable SDL text input only while an entry gadget owns focus.
void SDL3GameEngine::updateTextInputState(void)
{
	if (!m_SDLWindow || !TheWindowManager) {
		return;
	}

	GameWindow* focusedWindow = TheWindowManager->winGetFocus();
	const Bool wantsTextInput =
		focusedWindow != nullptr && BitIsSet(focusedWindow->winGetStyle(), GWS_ENTRY_FIELD);

	if (wantsTextInput) {
		// The Return key hides the iOS keyboard but the game may intentionally
		// keep the entry field focused. Do not reopen the keyboard until focus
		// moves to another window (or the field is closed).
		if (m_TextInputSuppressedFocusWindow != nullptr &&
		    focusedWindow != m_TextInputSuppressedFocusWindow) {
			m_TextInputSuppressedFocusWindow = nullptr;
		}

		if (focusedWindow == m_TextInputSuppressedFocusWindow) {
			if (m_IsTextInputActive) {
				SDL_StopTextInput(m_SDLWindow);
				m_IsTextInputActive = false;
			}
			m_TextInputFocusWindow = focusedWindow;
			return;
		}

		if (!m_IsTextInputActive) {
			SDL_PropertiesID textProps = SDL_CreateProperties();
			bool started = false;
			if (textProps != 0) {
				SDL_SetBooleanProperty(textProps,
				                       SDL_PROP_TEXTINPUT_MULTILINE_BOOLEAN,
				                       false);
				started = SDL_StartTextInputWithProperties(m_SDLWindow, textProps);
				SDL_DestroyProperties(textProps);
			} else {
				started = SDL_StartTextInput(m_SDLWindow);
			}
			if (started) {
				m_IsTextInputActive = true;
			}
		}
		m_TextInputFocusWindow = focusedWindow;
	} else {
		if (m_IsTextInputActive) {
			SDL_StopTextInput(m_SDLWindow);
			m_IsTextInputActive = false;
		}
		m_TextInputFocusWindow = nullptr;
		m_TextInputSuppressedFocusWindow = nullptr;
	}
}

// GeneralsX @bugfix felipebraz 01/04/2026 Forward SDL UTF-8 text input through existing GWM_IME_CHAR path.
void SDL3GameEngine::forwardTextInputEvent(const char* utf8Text)
{
	if (!utf8Text || !TheWindowManager) {
		return;
	}

	// GeneralsX @bugfix felipebraz 01/04/2026 Use tracked text-input focus window to keep SDL text delivery stable.
	GameWindow* targetWindow = m_TextInputFocusWindow;
	if (!targetWindow || !BitIsSet(targetWindow->winGetStyle(), GWS_ENTRY_FIELD)) {
		return;
	}

	const size_t textLength = strlen(utf8Text);
	size_t offset = 0;
	while (offset < textLength) {
		UnsignedInt codepoint = 0;
		if (!DecodeNextUtf8Codepoint(utf8Text, textLength, offset, codepoint)) {
			continue;
		}

		// GeneralsX @bugfix felipebraz 01/04/2026 Clamp IME char forwarding to BMP and reject UTF-16 surrogate range.
		if (codepoint == 0 || codepoint > 0x10FFFFU) {
			continue;
		}

		if (codepoint >= 0xD800U && codepoint <= 0xDFFFU) {
			continue;
		}

		if (codepoint > 0xFFFFU) {
			continue;
		}

		const WideChar wideCharacter = static_cast<WideChar>(codepoint);
		TheWindowManager->winSendInputMsg(targetWindow, GWM_IME_CHAR, static_cast<WindowMsgData>(wideCharacter), 0);
	}
}

/**
 * Handle keyboard event -dispatch to Keyboard manager
 * TheSuperHackers @build 10/02/2026 BenderAI - Phase 1.5 event wiring
 */
void SDL3GameEngine::handleKeyboardEvent(const SDL_KeyboardEvent& event)
{
	// Dispatch to SDL3Keyboard if available
	if (TheKeyboard) {
		SDL3Keyboard* sdlKeyboard = dynamic_cast<SDL3Keyboard*>(TheKeyboard);
		if (sdlKeyboard) {
			sdlKeyboard->addSDL3KeyEvent(event);
		}
	}
}

/**
 * Handle mouse motion event - dispatch to Mouse manager
 * TheSuperHackers @build 10/02/2026 BenderAI - Phase 1.5 event wiring
 */
void SDL3GameEngine::handleMouseMotionEvent(const SDL_MouseMotionEvent& event)
{
	// Dispatch to SDL3Mouse if available
	if (TheMouse) {
		SDL3Mouse* sdlMouse = dynamic_cast<SDL3Mouse*>(TheMouse);
		if (sdlMouse) {
			sdlMouse->addSDL3MouseMotionEvent(event);
		}
	}
}

/**
 * Handle mouse button event - dispatch to Mouse manager
 * TheSuperHackers @build 10/02/2026 BenderAI - Phase 1.5 event wiring
 */
void SDL3GameEngine::handleMouseButtonEvent(const SDL_MouseButtonEvent& event)
{
	// Dispatch to SDL3Mouse if available
	if (TheMouse) {
		SDL3Mouse* sdlMouse = dynamic_cast<SDL3Mouse*>(TheMouse);
		if (sdlMouse) {
			sdlMouse->addSDL3MouseButtonEvent(event);
		}
	}
}

/**
 * Handle mouse wheel event - dispatch to Mouse manager
 * TheSuperHackers @build 10/02/2026 BenderAI - Phase 1.5 event wiring
 */
void SDL3GameEngine::handleMouseWheelEvent(const SDL_MouseWheelEvent& event)
{
	// Dispatch to SDL3Mouse if available
	if (TheMouse) {
		SDL3Mouse* sdlMouse = dynamic_cast<SDL3Mouse*>(TheMouse);
		if (sdlMouse) {
			sdlMouse->addSDL3MouseWheelEvent(event);
		}
	}
}

/**
 * Handle window event (resize, etc.)
 */
void SDL3GameEngine::handleWindowEvent(const SDL_WindowEvent& event)
{
	// TODO: Phase 2 - Handle window resize, notify graphics subsystem
	// fprintf(stderr, "DEBUG: Window event (type=%d)\n", event.type);
}

/**
 * Factory Methods for GameEngine subsystems
 * TheSuperHackers @build felipebraz 13/02/2026
 * Implementations in .cpp to provide complete type definitions and avoid circular includes
 */

LocalFileSystem *SDL3GameEngine::createLocalFileSystem(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::createLocalFileSystem() -> StdLocalFileSystem\n");
	return NEW StdLocalFileSystem;
}

ArchiveFileSystem *SDL3GameEngine::createArchiveFileSystem(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::createArchiveFileSystem() -> StdBIGFileSystem\n");
	return NEW StdBIGFileSystem;
}

GameLogic *SDL3GameEngine::createGameLogic(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::createGameLogic() -> W3DGameLogic\n");
	return NEW W3DGameLogic;
}

GameClient *SDL3GameEngine::createGameClient(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::createGameClient() -> W3DGameClient\n");
	return NEW W3DGameClient;
}

ModuleFactory *SDL3GameEngine::createModuleFactory(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::createModuleFactory() -> W3DModuleFactory\n");
	return NEW W3DModuleFactory;
}

ThingFactory *SDL3GameEngine::createThingFactory(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::createThingFactory() -> W3DThingFactory\n");
	return NEW W3DThingFactory;
}

FunctionLexicon *SDL3GameEngine::createFunctionLexicon(void)
{
	fprintf(stderr, "INFO: SDL3GameEngine::createFunctionLexicon() -> W3DFunctionLexicon\n");
	return NEW W3DFunctionLexicon;
}

// GeneralsX @bugfix Copilot 15/04/2026 Match upstream GameEngine pure-virtual signature after sync.
Radar *SDL3GameEngine::createRadar(Bool dummy)
{
	// GeneralsX @bugfix fbraz 04/05/2026 Respect headless mode and create dummy radar.
	// Upstream reference: Win32GameEngine headless factory behavior, TheSuperHackers/GeneralsGameCode
	// https://github.com/TheSuperHackers/GeneralsGameCode
	if (dummy) {
		fprintf(stderr, "INFO: SDL3GameEngine::createRadar() -> RadarDummy (headless)\n");
		return NEW RadarDummy;
	}
	fprintf(stderr, "INFO: SDL3GameEngine::createRadar() -> W3DRadar\n");
	return NEW W3DRadar;
}

// GeneralsX @bugfix Copilot 24/03/2026 Match upstream GameEngine pure-virtual signature after sync.
ParticleSystemManager* SDL3GameEngine::createParticleSystemManager(Bool dummy)
{
	// GeneralsX @bugfix fbraz 04/05/2026 Respect headless mode and create dummy particle manager.
	if (dummy) {
		fprintf(stderr, "INFO: SDL3GameEngine::createParticleSystemManager() -> ParticleSystemManagerDummy (headless)\n");
		return NEW ParticleSystemManagerDummy;
	}
	fprintf(stderr, "INFO: SDL3GameEngine::createParticleSystemManager() -> W3DParticleSystemManager\n");
	return NEW W3DParticleSystemManager;
}

WebBrowser *SDL3GameEngine::createWebBrowser(void)
{
	// WebBrowser uses Windows COM (CComObject<W3DWebBrowser>)
	// Not available on Linux - return nullptr
	fprintf(stderr, "WARNING: WebBrowser not available on Linux platform\n");
	return nullptr;
}

/**
 * Factory method: AudioManager
 * Select audio backend based on compile flags
 * GeneralsX @bugfix Copilot 15/04/2026 Match upstream GameEngine pure-virtual signature after sync.
 */
AudioManager *SDL3GameEngine::createAudioManager(Bool dummy)
{
	(void)dummy;
	fprintf(stderr, "INFO: SDL3GameEngine::createAudioManager()\n");

#ifdef SAGE_USE_OPENAL
	fprintf(stderr, "INFO: Creating OpenAL audio backend\n");
	return new OpenALAudioManager();
#else
	fprintf(stderr, "INFO: Audio backend not available (SAGE_USE_OPENAL not defined)\n");
	fprintf(stderr, "WARNING: Falls back to parent implementation or silent mode\n");
	return GameEngine::createAudioManager();  // Call parent (may return stub)
#endif
}

#endif // !_WIN32

