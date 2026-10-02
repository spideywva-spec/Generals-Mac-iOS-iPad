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
#include "GameClient/InGameUI.h"
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
	switch (event->type) {		case SDL_EVENT_WILL_ENTER_BACKGROUND:		case SDL_EVENT_DID_ENTER_BACKGROUND:
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
 //   1 finger movement     -> camera pan
 //   1 finger hold 0.2 sec -> selection rectangle / build gesture
 //   2 finger short tap    -> synthetic RMB click (cancel/deselect)
 //   2 finger distance     -> continuous zoom
 //   2 finger angle        -> camera rotation
 //   IMPORTANT: two-finger movement is NOT a camera-pan gesture.
 //   Distance + angle      -> zoom and rotation simultaneously
// ---------------------------------------------------------------------------
namespace {

class MobileInputManager {
public:
    enum State {
        STATE_CAMERA_PAN,
        STATE_SELECTION,
        STATE_BUILDING,
        STATE_MULTI_TOUCH
    };

    void SetBuildConfirmationMode(bool autoBuildAfterRotation)
    {
        m_autoBuildAfterRotation = autoBuildAfterRotation;
    }

    State GetState() const { return m_state; }

    void SetWindow(SDL_Window* window) { m_window = window; }

    void ProcessInput(const SDL_Event& event)
    {
        if (!m_window)
            return;

        switch (event.type) {
        case SDL_EVENT_FINGER_DOWN:
            onFingerDown(event);
            break;
        case SDL_EVENT_FINGER_MOTION:
            onFingerMotion(event);
            break;
        case SDL_EVENT_FINGER_UP:
        case SDL_EVENT_FINGER_CANCELED:
            onFingerUp(event);
            break;
        default:
            break;
        }
    }

    void Update()
    {
        if (!m_primaryActive || m_state == STATE_MULTI_TOUCH)
            return;

        const Uint64 now = SDL_GetTicks();

        if (m_state == STATE_CAMERA_PAN &&
            m_selectionArmed &&
            (now - m_downTicks) >= SELECTION_HOLD_MS) {
            // A finger that was deliberately held for 0.1 s and then dragged
            // becomes the selection gesture. Camera remains locked after this.
            const float travel = SDL_sqrtf(
                (m_lastX - m_downX) * (m_lastX - m_downX) +
                (m_lastY - m_downY) * (m_lastY - m_downY));

            if (travel >= SELECTION_DISTANCE_PX)
                beginSelection();
        }
        if (m_state == STATE_BUILDING &&
            m_buildConfirmationPending &&
            m_autoBuildAfterRotation &&
            !m_buildRotating &&
            (now - m_holdStartTicks) >= BUILD_ROTATION_HOLD_MS) {
            beginBuildingRotation(m_lastX, m_lastY);
        }
    }

private:
    static constexpr Uint64 SELECTION_HOLD_MS = 100;
    static constexpr Uint64 BUILD_ROTATION_HOLD_MS = 200;
    static constexpr float TAP_MAX_DISTANCE_PX = 10.0f;
    static constexpr float SELECTION_DISTANCE_PX = 12.0f;
    static constexpr float BUILD_CONFIRM_DISTANCE_PX = 48.0f;
    static constexpr float CAMERA_PAN_WORLD_PER_PIXEL = 0.020f;
    static constexpr float PINCH_ZOOM_WORLD_PER_PIXEL = 0.05f;
    static constexpr float ROTATION_DEAD_ZONE_RAD = 0.6981317008f;
    static constexpr float PI = 3.14159265358979323846f;

    State m_state = STATE_CAMERA_PAN;
    SDL_Window* m_window = nullptr;

    SDL_FingerID m_primaryFinger = 0;
    SDL_FingerID m_secondaryFinger = 0;
    bool m_primaryActive = false;
    bool m_secondaryActive = false;

    float m_downX = 0.0f;
    float m_downY = 0.0f;
    float m_lastX = 0.0f;
    float m_lastY = 0.0f;
    Uint64 m_downTicks = 0;

    bool m_selectionArmed = false;
    bool m_selectionMouseDown = false;
    bool m_leftHeld = false;

    bool m_autoBuildAfterRotation = false;
    bool m_buildConfirmationPending = false;
    bool m_buildRotating = false;
    Uint64 m_holdStartTicks = 0;
    float m_buildX = 0.0f;
    float m_buildY = 0.0f;
    float m_buildRotation = 0.0f;
    float m_buildLastAngle = 0.0f;
    float m_buildRotationRadius = 64.0f;

    float m_f1x = 0.0f;
    float m_f1y = 0.0f;
    float m_f2x = 0.0f;
    float m_f2y = 0.0f;
    float m_lastPinchDistance = 0.0f;
    float m_lastPairAngle = 0.0f;
    float m_accumulatedRotation = 0.0f;
    bool m_multiRotationActive = false;

    SDL3Mouse* mouse() const
    {
        return TheMouse ? dynamic_cast<SDL3Mouse*>(TheMouse) : nullptr;
    }

    bool buildingActive() const
    {
        return TheInGameUI != nullptr &&
               TheInGameUI->getPendingPlaceType() != nullptr;
    }

    int windowW() const
    {
        int w = 1, h = 1;
        SDL_GetWindowSize(m_window, &w, &h);
        return w > 0 ? w : 1;
    }

    int windowH() const
    {
        int w = 1, h = 1;
        SDL_GetWindowSize(m_window, &w, &h);
        return h > 0 ? h : 1;
    }

    float screenX(float normalized) const
    {
        return normalized * static_cast<float>(windowW());
    }

    float screenY(float normalized) const
    {
        return normalized * static_cast<float>(windowH());
    }

    void sendMouse(Uint32 type, float x, float y, Uint8 button = 0)
    {
        SDL3Mouse* m = mouse();
        if (!m)
            return;

        SDL_Event ev;
        SDL_zero(ev);        ev.type = type;

        if (type == SDL_EVENT_MOUSE_MOTION) {
            ev.motion.windowID = SDL_GetWindowID(m_window);
            ev.motion.which = 0;
            ev.motion.x = x;
            ev.motion.y = y;
            ev.motion.xrel = x - m_lastX;
            ev.motion.yrel = y - m_lastY;
        } else if (type == SDL_EVENT_MOUSE_BUTTON_DOWN ||
                   type == SDL_EVENT_MOUSE_BUTTON_UP) {
            ev.button.windowID = SDL_GetWindowID(m_window);
            ev.button.which = 0;
            ev.button.button = button;
            ev.button.down = (type == SDL_EVENT_MOUSE_BUTTON_DOWN);
            ev.button.clicks = 1;
            ev.button.x = x;
            ev.button.y = y;
        } else {
            return;
        }

        m->addSDLEvent(&ev);

        if (type == SDL_EVENT_MOUSE_BUTTON_DOWN && button == SDL_BUTTON_LEFT)
            m_leftHeld = true;
        else if (type == SDL_EVENT_MOUSE_BUTTON_UP && button == SDL_BUTTON_LEFT)
            m_leftHeld = false;
    }

    void releaseSelectionMouse()
    {
        if (m_leftHeld)
            sendMouse(SDL_EVENT_MOUSE_BUTTON_UP, m_lastX, m_lastY, SDL_BUTTON_LEFT);
        m_leftHeld = false;
        m_selectionMouseDown = false;
    }

    static float normalizeAngle(float angle)
    {
        while (angle > PI) angle -= 2.0f * PI;
        while (angle < -PI) angle += 2.0f * PI;
        return angle;
    }

    void applyCameraPan(float dxPixels, float dyPixels)
    {
        // HARD CAMERA LOCK: only STATE_CAMERA_PAN can reach this function.
        if (m_state != STATE_CAMERA_PAN || !TheTacticalView)
            return;

        Coord2D delta;
        delta.x = -dxPixels * CAMERA_PAN_WORLD_PER_PIXEL;
        delta.y = -dyPixels * CAMERA_PAN_WORLD_PER_PIXEL;
        TheTacticalView->userScrollBy(&delta);
    }

    void applyZoom(float distanceDelta)
    {
        if (m_state != STATE_MULTI_TOUCH || !TheTacticalView)
            return;

        TheTacticalView->userZoom(-distanceDelta * PINCH_ZOOM_WORLD_PER_PIXEL);
    }

    void applyCameraRotation(float angleDelta)
    {
        if (m_state != STATE_MULTI_TOUCH || !TheTacticalView)
            return;

        TheTacticalView->userSetAngle(
            TheTacticalView->getAngle() + angleDelta);
    }

    void beginSelection()
    {
        if (m_state != STATE_CAMERA_PAN || !m_primaryActive)
            return;

        if (!mouse())
            return;

        // Existing Generals drag-selection path is used for the rectangle.
        // There is deliberately no camera operation while STATE_SELECTION.
        sendMouse(SDL_EVENT_MOUSE_MOTION, m_downX, m_downY);
        sendMouse(SDL_EVENT_MOUSE_BUTTON_DOWN, m_downX, m_downY, SDL_BUTTON_LEFT);
        m_selectionMouseDown = true;
        m_selectionArmed = false;
        m_state = STATE_SELECTION;
    }

    void beginBuilding(float x, float y)
    {
        m_state = STATE_BUILDING;
        m_buildConfirmationPending = false;
        m_buildRotating = false;
        m_holdStartTicks = SDL_GetTicks();
        m_buildX = x;
        m_buildY = y;
        m_lastX = x;        m_lastY = y;

        // Building preview follows the finger; camera is never touched.
        sendMouse(SDL_EVENT_MOUSE_MOTION, x, y);
    }

    void beginBuildingRotation(float x, float y)
    {
        if (m_state != STATE_BUILDING ||
            !m_buildConfirmationPending ||
            !m_autoBuildAfterRotation ||
            !TheInGameUI)
            return;

        m_buildRotating = true;
        m_buildLastAngle = SDL_atan2f(y - m_buildY, x - m_buildX);
        m_buildRotation =
            static_cast<float>(TheInGameUI->getPlacementAngle());

        float dx = x - m_buildX;
        float dy = y - m_buildY;
        m_buildRotationRadius = SDL_sqrtf(dx * dx + dy * dy);
        if (m_buildRotationRadius < 16.0f)
            m_buildRotationRadius = 64.0f;

        ICoord2D anchor;
        anchor.x = static_cast<Int>(m_buildX);
        anchor.y = static_cast<Int>(m_buildY);
        TheInGameUI->setPlacementStart(&anchor);
    }

    void updateBuildingRotation(float x, float y)
    {
        if (m_state != STATE_BUILDING || !m_buildRotating || !TheInGameUI)
            return;

        const float angle = SDL_atan2f(y - m_buildY, x - m_buildX);
        m_buildRotation += normalizeAngle(angle - m_buildLastAngle);
        m_buildLastAngle = angle;

        ICoord2D start;
        start.x = static_cast<Int>(m_buildX);
        start.y = static_cast<Int>(m_buildY);

        ICoord2D end;
        end.x = static_cast<Int>(
            m_buildX + SDL_cosf(m_buildRotation) * m_buildRotationRadius);
        end.y = static_cast<Int>(
            m_buildY + SDL_sinf(m_buildRotation) * m_buildRotationRadius);

        // Continuous 360-degree rotation; no 45/90-degree snapping.
        TheInGameUI->setPlacementStart(&start);
        TheInGameUI->setPlacementEnd(&end);
    }

    void confirmBuilding()
    {
        if (m_state != STATE_BUILDING)
            return;

        sendMouse(SDL_EVENT_MOUSE_BUTTON_DOWN, m_buildX, m_buildY, SDL_BUTTON_LEFT);
        sendMouse(SDL_EVENT_MOUSE_BUTTON_UP, m_buildX, m_buildY, SDL_BUTTON_LEFT);
        m_buildConfirmationPending = false;
        m_buildRotating = false;
    }

    void enterMultiTouch(const SDL_Event& event)
    {
        // Second finger wins immediately. Release any synthetic selection
        // button and freeze all single-finger operations.
        releaseSelectionMouse();

        m_secondaryFinger = event.tfinger.fingerID;
        m_secondaryActive = true;
        m_f2x = event.tfinger.x;
        m_f2y = event.tfinger.y;

        m_state = STATE_MULTI_TOUCH;
        m_multiRotationActive = false;
        m_accumulatedRotation = 0.0f;

        const float dx = (m_f1x - m_f2x) * static_cast<float>(windowW());
        const float dy = (m_f1y - m_f2y) * static_cast<float>(windowH());

        m_lastPinchDistance = SDL_sqrtf(dx * dx + dy * dy);
        m_lastPairAngle = SDL_atan2f(dy, dx);
    }

    void updateMultiTouch(const SDL_Event& event)
    {
        if (m_state != STATE_MULTI_TOUCH)
            return;

        if (event.tfinger.fingerID == m_primaryFinger) {
            m_f1x = event.tfinger.x;
            m_f1y = event.tfinger.y;
        } else if (event.tfinger.fingerID == m_secondaryFinger) {
            m_f2x = event.tfinger.x;
            m_f2y = event.tfinger.y;
        } else {            return;
        }

        const float w = static_cast<float>(windowW());
        const float h = static_cast<float>(windowH());
        const float dx = (m_f1x - m_f2x) * w;
        const float dy = (m_f1y - m_f2y) * h;
        const float distance = SDL_sqrtf(dx * dx + dy * dy);

        // Zoom is continuous and independent of rotation.
        const float distanceDelta = distance - m_lastPinchDistance;
        if (SDL_fabsf(distanceDelta) > 0.0001f)
            applyZoom(distanceDelta);

        const float pairAngle = SDL_atan2f(dy, dx);
        const float angleDelta = normalizeAngle(pairAngle - m_lastPairAngle);

        // Accumulate the signed angular delta until 40 degrees is crossed.
        if (!m_multiRotationActive) {
            m_accumulatedRotation += angleDelta;
            if (SDL_fabsf(m_accumulatedRotation) >= ROTATION_DEAD_ZONE_RAD) {
                m_multiRotationActive = true;
                // Do not apply the activation dead-zone itself: no initial jump.
                m_lastPairAngle = pairAngle;
            }
        } else {
            // Once active, every delta is applied, including full 360-degree
            // continuous turns across the -pi/+pi boundary.
            if (SDL_fabsf(angleDelta) > 0.000001f)
                applyCameraRotation(angleDelta);
            m_lastPairAngle = pairAngle;
        }

        m_lastPinchDistance = distance;
    }

    void onFingerDown(const SDL_Event& event)
    {
        const float x = screenX(event.tfinger.x);
        const float y = screenY(event.tfinger.y);

        if (!m_primaryActive) {
            m_primaryFinger = event.tfinger.fingerID;
            m_primaryActive = true;
            m_secondaryActive = false;
            m_downX = x;
            m_downY = y;
            m_lastX = x;
            m_lastY = y;
            m_downTicks = SDL_GetTicks();
            m_f1x = event.tfinger.x;
            m_f1y = event.tfinger.y;
            m_selectionArmed = true;
            m_selectionMouseDown = false;

            if (buildingActive()) {
                // Variant A: a second tap on the fixed preview confirms it.
                if (m_buildConfirmationPending) {
                    const float dx = x - m_buildX;
                    const float dy = y - m_buildY;
                    if (SDL_sqrtf(dx * dx + dy * dy) <= BUILD_CONFIRM_DISTANCE_PX) {
                        m_state = STATE_BUILDING;
                        m_holdStartTicks = SDL_GetTicks();
                        m_buildRotating = false;
                        return;
                    }
                }

                // First placement gesture.
                beginBuilding(x, y);
                return;
            }

            m_state = STATE_CAMERA_PAN;
            return;
        }

        // Never assume fingerID == 1. SDL3 finger IDs are Uint64 identifiers.
        if (!m_secondaryActive && event.tfinger.fingerID != m_primaryFinger) {
            m_f1x = m_downX / static_cast<float>(windowW());
            m_f1y = m_downY / static_cast<float>(windowH());
            enterMultiTouch(event);
        }
    }

    void onFingerMotion(const SDL_Event& event)
    {
        const float x = screenX(event.tfinger.x);
        const float y = screenY(event.tfinger.y);

        if (m_state == STATE_MULTI_TOUCH) {
            updateMultiTouch(event);
            return;
        }

        if (event.tfinger.fingerID != m_primaryFinger || !m_primaryActive)
            return;

        m_f1x = event.tfinger.x;
        m_f1y = event.tfinger.y;
        const float dxPixels = event.tfinger.dx * static_cast<float>(windowW());
        const float dyPixels = event.tfinger.dy * static_cast<float>(windowH());
        const float travel = SDL_sqrtf(
            (x - m_downX) * (x - m_downX) +
            (y - m_downY) * (y - m_downY));

        if (m_state == STATE_BUILDING) {
            if (m_buildConfirmationPending &&
                m_autoBuildAfterRotation &&
                !m_buildRotating &&
                (SDL_GetTicks() - m_holdStartTicks) >= BUILD_ROTATION_HOLD_MS) {
                beginBuildingRotation(x, y);
            }

            if (m_buildRotating)
                updateBuildingRotation(x, y);
            else {
                // HARD LOCK: placement preview only; no camera call.
                sendMouse(SDL_EVENT_MOUSE_MOTION, x, y);
                m_buildX = x;
                m_buildY = y;
            }

            m_lastX = x;
            m_lastY = y;
            return;
        }

        if (m_state == STATE_SELECTION) {
            // HARD LOCK: selection rectangle only.
            sendMouse(SDL_EVENT_MOUSE_MOTION, x, y);
            m_lastX = x;
            m_lastY = y;
            return;
        }

        if (m_state == STATE_CAMERA_PAN) {
            const Uint64 held = SDL_GetTicks() - m_downTicks;

            // Deliberate hold + drag = selection. Fast drag = camera pan.
            if (held >= SELECTION_HOLD_MS && travel >= SELECTION_DISTANCE_PX) {
                beginSelection();
                sendMouse(SDL_EVENT_MOUSE_MOTION, x, y);
                m_lastX = x;
                m_lastY = y;
                return;
            }

            if (travel >= SELECTION_DISTANCE_PX) {
                m_selectionArmed = false;
                // Finger dx/dy directly determines movement magnitude, so
                // faster swipes produce larger camera motion.
                applyCameraPan(dxPixels, dyPixels);
            }

            m_lastX = x;
            m_lastY = y;
        }
    }

    void onFingerUp(const SDL_Event& event)
    {
        const float x = screenX(event.tfinger.x);
        const float y = screenY(event.tfinger.y);

        if (m_state == STATE_MULTI_TOUCH) {
            if (event.tfinger.fingerID == m_primaryFinger)
                m_primaryActive = false;
            if (event.tfinger.fingerID == m_secondaryFinger)
                m_secondaryActive = false;

            if (!m_primaryActive && !m_secondaryActive) {
                m_state = STATE_CAMERA_PAN;
                m_multiRotationActive = false;
                m_accumulatedRotation = 0.0f;
            }
            return;
        }

        if (event.tfinger.fingerID != m_primaryFinger || !m_primaryActive)
            return;

        if (m_state == STATE_SELECTION) {
            sendMouse(SDL_EVENT_MOUSE_BUTTON_UP, x, y, SDL_BUTTON_LEFT);
            m_selectionMouseDown = false;
            m_primaryActive = false;
            m_state = STATE_CAMERA_PAN;
            return;
        }

        if (m_state == STATE_BUILDING) {
            m_buildX = m_lastX;
            m_buildY = m_lastY;

            if (m_buildConfirmationPending) {
                if (m_autoBuildAfterRotation && m_buildRotating) {
                    // Variant B: release after rotation builds immediately.
                    confirmBuilding();
                } else if (!m_autoBuildAfterRotation) {                    // Variant A: second tap confirms only if it was actually a tap.
                    const float travel = SDL_sqrtf(
                        (x - m_downX) * (x - m_downX) +
                        (y - m_downY) * (y - m_downY));
                    if (travel <= TAP_MAX_DISTANCE_PX)
                        confirmBuilding();
                }
                // Variant B release before 0.2 s only leaves the preview fixed.
            } else {
                // First placement release: fix preview, never auto-build.
                m_buildConfirmationPending = true;
            }

            m_primaryActive = false;
            m_state = STATE_CAMERA_PAN;
            return;
        }

        // Fast single tap: immediate existing Generals click/raycast path.
        const float travel = SDL_sqrtf(
            (x - m_downX) * (x - m_downX) +
            (y - m_downY) * (y - m_downY));

        if (travel <= TAP_MAX_DISTANCE_PX &&
            (SDL_GetTicks() - m_downTicks) < SELECTION_HOLD_MS) {
            sendMouse(SDL_EVENT_MOUSE_MOTION, x, y);
            sendMouse(SDL_EVENT_MOUSE_BUTTON_DOWN, x, y, SDL_BUTTON_LEFT);
            sendMouse(SDL_EVENT_MOUSE_BUTTON_UP, x, y, SDL_BUTTON_LEFT);
        }

        m_primaryActive = false;
        m_state = STATE_CAMERA_PAN;
        m_selectionArmed = false;
    }
};

static MobileInputManager s_mobileInput;

} // anonymous namespace


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
	offset += 1;	return false;
}

}

/**
 * Constructor: Initialize SDL3 game engine state
 */SDL3GameEngine::SDL3GameEngine()
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
		m_IsTextInputActive = false;		m_TextInputFocusWindow = nullptr;
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
	// Acquiring a Metal drawable in these windows fights iOS for the layer and,	// across repeated suspend/switcher cycles, crashes MoltenVK. Keep polling so
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
				if (TheMouse) {
					TheMouse->loseFocus();
				}
				break;

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
			// App suspension/resume: mirror the desktop focus handling so audio
			// and mouse state pause cleanly (the render gate lives in update()).			case SDL_EVENT_DID_ENTER_BACKGROUND:
				m_IsActive = false;
				if (TheMouse) {
					TheMouse->loseFocus();
				}
				break;

			case SDL_EVENT_DID_ENTER_FOREGROUND:
				m_IsActive = true;
				if (TheMouse) {					TheMouse->regainFocus();
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

			case SDL_EVENT_KEY_DOWN:
			case SDL_EVENT_KEY_UP:
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

			case SDL_EVENT_MOUSE_MOTION:			case SDL_EVENT_MOUSE_BUTTON_DOWN:
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
				s_mobileInput.SetWindow(m_SDLWindow);
				s_mobileInput.ProcessInput(event);
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
	// SDL_GetTicks()-based transitions are processed even while the finger is stationary.
	if (m_SDLWindow) {
		s_mobileInput.SetWindow(m_SDLWindow);
		s_mobileInput.Update();
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
		if (!m_IsTextInputActive) {
			if (SDL_StartTextInput(m_SDLWindow)) {
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
 * TheSuperHackers @build 10/02/2026 BenderAI - Phase 1.5 event wiring */
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

/** * Handle mouse wheel event - dispatch to Mouse manager
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
{	// GeneralsX @bugfix fbraz 04/05/2026 Respect headless mode and create dummy particle manager.
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
	fprintf(stderr, "WARNING: WebBrowser not available on Linux platform\n");	return nullptr;
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