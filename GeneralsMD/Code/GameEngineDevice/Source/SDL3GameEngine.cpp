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
#include "GameClient/View.h"
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
#include <cmath>
#if __has_include("GameNetwork/NetworkInterface.h")
#include "GameNetwork/NetworkInterface.h"
#endif
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
 //   1 finger short tap    -> native single-click/raycast path
 //   1 finger swipe       -> linear camera pan
 //   1 finger deliberate drag -> native unit-only selection rectangle
 //   building placement    -> locked preview movement / optional 0.2s rotation
 //   2 finger short tap    -> immediate building cancellation (when applicable)
 //   2 finger distance     -> continuous zoom
 //   2 finger angle        -> camera rotation after a 40° dead-zone
 //   IMPORTANT: two-finger movement is NOT a camera-pan gesture.
 //   Distance + angle      -> zoom and rotation simultaneously
// ---------------------------------------------------------------------------
namespace {

class MobileInputManager
{
public:
    enum State
    {
        STATE_CAMERA_PAN,
        STATE_SELECTION,
        STATE_BUILDING,
        STATE_MULTI_TOUCH
    };

    State GetState() const
    {
        return m_state;
    }

    void SetWindow(SDL_Window *window)
    {
        m_window = window;
    }

    void Reset()
    {
        ReleaseSelectionMouse();
        UnlockCamera();

        m_fingers[0] = Finger();
        m_fingers[1] = Finger();

        m_state = STATE_CAMERA_PAN;
        m_stateBeforeMulti = STATE_CAMERA_PAN;

        m_selectionMouseDown = false;

        m_buildFixed = false;
        m_buildConfirm = false;
        m_buildRotating = false;
        m_buildHoldStart = 0;
        m_buildX = 0.0f;
        m_buildY = 0.0f;
        m_buildRotation = 0.0f;

        m_multiStarted = false;
        m_multiMoved = false;
        m_multiStartTicks = 0;
        m_multiA = -1;
        m_multiB = -1;
        m_lastPinchDistancePixels = 0.0f;
        m_lastPairAngle = 0.0f;
        m_multiAccumulatedRotation = 0.0f;
        m_multiRotationActive = false;
    }

    void ProcessEvent(const SDL_Event &event)
    {
        if (!m_window)
            return;

        switch (event.type)
        {
            case SDL_EVENT_FINGER_DOWN:
                FingerDown(event);
                break;

            case SDL_EVENT_FINGER_MOTION:
                FingerMotion(event);
                break;

            case SDL_EVENT_FINGER_UP:
                FingerUp(event, false);
                break;

            case SDL_EVENT_FINGER_CANCELED:
                FingerUp(event, true);
                break;

            default:
                break;
        }
    }

    void Update()
    {
        if (m_state == STATE_BUILDING &&
            m_buildConfirm &&
            !m_buildRotating &&
            m_buildHoldStart != 0 &&
            SDL_GetTicks() - m_buildHoldStart >= BUILD_ROTATE_HOLD_MS)
        {
            BeginBuildingRotation();
        }
    }

private:
    struct Finger
    {
        SDL_FingerID id = 0;
        bool active = false;

        // These values are always physical screen pixels after conversion
        // at the SDL event boundary.
        float xPixels = 0.0f;
        float yPixels = 0.0f;
        float downXPixels = 0.0f;
        float downYPixels = 0.0f;
        float lastXPixels = 0.0f;
        float lastYPixels = 0.0f;

        Uint64 downTicks = 0;
        float travelPixels = 0.0f;
    };

    // Gesture thresholds. These classify gestures; they never create
    // movement speed or acceleration.
    static constexpr Uint64 SELECTION_HOLD_MS = 100;
    static constexpr Uint64 BUILD_ROTATE_HOLD_MS = 200;
    static constexpr Uint64 TWO_FINGER_TAP_MS = 150;

    static constexpr float SELECTION_TRAVEL_PX = 20.0f;
    static constexpr float TAP_MAX_TRAVEL_PX = 10.0f;
    static constexpr float BUILD_TAP_RADIUS_PX = 24.0f;

    // Exactly 40 degrees.
    static constexpr float ROTATION_DEAD_ZONE = 0.6981317007977318f;

    static constexpr float MOBILE_PI = 3.14159265358979323846f;
    static constexpr float MOBILE_TWO_PI = 6.28318530717958647692f;

    State m_state = STATE_CAMERA_PAN;
    State m_stateBeforeMulti = STATE_CAMERA_PAN;

    SDL_Window *m_window = nullptr;

    // Real SDL_FingerID -> stable local slot mapping.
    // No assumption is made about the numeric value of SDL_FingerID.
    Finger m_fingers[2];

    bool m_selectionMouseDown = false;

    // Building state.
    bool m_buildFixed = false;
    bool m_buildConfirm = false;
    bool m_buildRotating = false;
    Uint64 m_buildHoldStart = 0;

    // Absolute screen-pixel position of the fixed/preview building.
    float m_buildX = 0.0f;
    float m_buildY = 0.0f;

    // Current placement angle in radians.
    float m_buildRotation = 0.0f;

    // Multi-touch state.
    bool m_multiStarted = false;
    bool m_multiMoved = false;
    Uint64 m_multiStartTicks = 0;
    int m_multiA = -1;
    int m_multiB = -1;

    float m_lastPinchDistancePixels = 0.0f;
    float m_lastPairAngle = 0.0f;
    float m_multiAccumulatedRotation = 0.0f;
    bool m_multiRotationActive = false;

    SDL3Mouse *Mouse() const
    {
        return TheMouse ? dynamic_cast<SDL3Mouse *>(TheMouse) : nullptr;
    }

    int WindowW() const
    {
        int w = 1;
        int h = 1;

        if (m_window)
            SDL_GetWindowSizeInPixels(m_window, &w, &h);

        return w > 0 ? w : 1;
    }

    int WindowH() const
    {
        int w = 1;
        int h = 1;

        if (m_window)
            SDL_GetWindowSizeInPixels(m_window, &w, &h);

        return h > 0 ? h : 1;
    }

    float XPixels(float normalized) const
    {
        return normalized * static_cast<float>(WindowW());
    }

    float YPixels(float normalized) const
    {
        return normalized * static_cast<float>(WindowH());
    }

    float DXPixels(float normalizedDelta) const
    {
        return normalizedDelta * static_cast<float>(WindowW());
    }

    float DYPixels(float normalizedDelta) const
    {
        return normalizedDelta * static_cast<float>(WindowH());
    }

    static float NormalizeAngle(float angle)
    {
        while (angle > MOBILE_PI)
            angle -= MOBILE_TWO_PI;

        while (angle < -MOBILE_PI)
            angle += MOBILE_TWO_PI;

        return angle;
    }

    static float DistancePixels(float x1, float y1, float x2, float y2)
    {
        const float dx = x2 - x1;
        const float dy = y2 - y1;
        return SDL_sqrtf(dx * dx + dy * dy);
    }

    static float AngleBetweenPixels(float x1, float y1, float x2, float y2)
    {
        return SDL_atan2f(y2 - y1, x2 - x1);
    }

    int FindFinger(SDL_FingerID id) const
    {
        for (int i = 0; i < 2; ++i)
        {
            if (m_fingers[i].active && m_fingers[i].id == id)
                return i;
        }

        return -1;
    }

    int FindFreeFingerSlot() const
    {
        for (int i = 0; i < 2; ++i)
        {
            if (!m_fingers[i].active)
                return i;
        }

        return -1;
    }

    int ActiveFingerCount() const
    {
        int count = 0;

        for (int i = 0; i < 2; ++i)
        {
            if (m_fingers[i].active)
                ++count;
        }

        return count;
    }

    bool BuildingPending() const
    {
        return TheInGameUI &&
               TheInGameUI->getPendingPlaceType() != nullptr;
    }

    bool IsNearFixedBuilding(float xPixels, float yPixels) const
    {
        if (!m_buildFixed)
            return false;

        return DistancePixels(
                   xPixels,
                   yPixels,
                   m_buildX,
                   m_buildY) <= BUILD_TAP_RADIUS_PX;
    }

    void LockCamera()
    {
        if (TheTacticalView)
            TheTacticalView->setMouseLock(TRUE);
    }

    void UnlockCamera()
    {
        if (TheTacticalView)
            TheTacticalView->setMouseLock(FALSE);
    }

    void SendMouseMotionPixels(
        float xPixels,
        float yPixels,
        float dxPixels = 0.0f,
        float dyPixels = 0.0f)
    {
        SDL3Mouse *mouse = Mouse();
        if (!mouse)
            return;

        SDL_Event e;
        SDL_zero(e);

        e.type = SDL_EVENT_MOUSE_MOTION;
        e.motion.windowID = SDL_GetWindowID(m_window);
        e.motion.which = 0;

        // Absolute physical screen-pixel position.
        e.motion.x = xPixels;
        e.motion.y = yPixels;

        // Exact physical screen-pixel movement for this event.
        e.motion.xrel = dxPixels;
        e.motion.yrel = dyPixels;

        mouse->addSDLEvent(&e);
    }

    void SendMouseButtonPixels(Uint32 type, float xPixels, float yPixels)
    {
        SDL3Mouse *mouse = Mouse();
        if (!mouse)
            return;

        SDL_Event e;
        SDL_zero(e);

        e.type = type;
        e.button.windowID = SDL_GetWindowID(m_window);
        e.button.which = 0;
        e.button.button = SDL_BUTTON_LEFT;
        e.button.down = (type == SDL_EVENT_MOUSE_BUTTON_DOWN);
        e.button.clicks = 1;

        // Absolute physical screen-pixel position.
        e.button.x = xPixels;
        e.button.y = yPixels;

        mouse->addSDLEvent(&e);
    }

    void ReleaseSelectionMouse()
    {
        if (!m_selectionMouseDown)
            return;

        int index = FindFinger(m_fingers[0].id);
        if (index < 0)
            index = 0;

        SendMouseButtonPixels(
            SDL_EVENT_MOUSE_BUTTON_UP,
            m_fingers[index].lastXPixels,
            m_fingers[index].lastYPixels);

        m_selectionMouseDown = false;

        if (TheInGameUI)
            TheInGameUI->setSelecting(FALSE);
    }

    // Camera movement is a direct world-space application of the exact
    // physical screen-pixel finger delta. No acceleration, interpolation,
    // velocity cap, minimum step or fixed speed is introduced here.
    void ApplyCameraPanPixels(float dxPixels, float dyPixels)
    {
        if (m_state != STATE_CAMERA_PAN || !TheTacticalView)
            return;

        Coord2D delta;
        delta.x = -dxPixels;
        delta.y = -dyPixels;

        TheTacticalView->userScrollBy(&delta);
    }

    void BeginSelection(int fingerIndex)
    {
        if (m_state != STATE_CAMERA_PAN)
            return;

        if (fingerIndex < 0 || fingerIndex >= 2 ||
            !m_fingers[fingerIndex].active)
            return;

        m_state = STATE_SELECTION;

        // Selection must never move the camera.
        LockCamera();

        if (TheInGameUI)
            TheInGameUI->setSelecting(TRUE);

        const Finger &finger = m_fingers[fingerIndex];

        // Start the native selection rectangle at the original finger-down
        // position. Subsequent motion events use exact pixel deltas.
        SendMouseMotionPixels(
            finger.downXPixels,
            finger.downYPixels,
            0.0f,
            0.0f);

        SendMouseButtonPixels(
            SDL_EVENT_MOUSE_BUTTON_DOWN,
            finger.downXPixels,
            finger.downYPixels);

        m_selectionMouseDown = true;
    }

    void StartBuildingPreview(float xPixels, float yPixels)
    {
        m_state = STATE_BUILDING;

        m_buildFixed = false;
        m_buildConfirm = false;
        m_buildRotating = false;
        m_buildHoldStart = 0;
        m_buildRotation = 0.0f;

        // REQUIRED: absolute finger position, never += and never offset.
        m_buildX = xPixels;
        m_buildY = yPixels;

        // Building placement freezes camera movement.
        LockCamera();

        SendMouseMotionPixels(
            m_buildX,
            m_buildY,
            0.0f,
            0.0f);
    }

    void FixBuildingPreview()
    {
        m_buildFixed = true;
        m_buildConfirm = false;
        m_buildRotating = false;
        m_buildHoldStart = 0;

        LockCamera();

        if (TheInGameUI)
        {
            ICoord2D point;
            point.x = static_cast<Int>(m_buildX);
            point.y = static_cast<Int>(m_buildY);

            TheInGameUI->setPlacementStart(&point);
            TheInGameUI->setPlacementEnd(&point);
        }
    }

    void StartBuildingConfirmation()
    {
        m_state = STATE_BUILDING;
        m_buildConfirm = true;
        m_buildRotating = false;
        m_buildHoldStart = SDL_GetTicks();

        LockCamera();
    }

    void BeginBuildingRotation()
    {
        if (m_state != STATE_BUILDING ||
            !m_buildFixed ||
            !m_buildConfirm ||
            m_buildRotating)
        {
            return;
        }

        m_buildRotating = true;
        m_buildHoldStart = 0;
        m_buildRotation = 0.0f;

        LockCamera();

        if (TheInGameUI)
        {
            ICoord2D start;
            start.x = static_cast<Int>(m_buildX);
            start.y = static_cast<Int>(m_buildY);

            TheInGameUI->setPlacementStart(&start);
            TheInGameUI->setPlacementEnd(&start);
        }
    }

    void UpdateBuildingRotationPixels(float dxPixels)
    {
        if (!m_buildRotating || !TheInGameUI)
            return;

        // One full screen width corresponds to one complete 360-degree
        // rotation. Therefore rotation is still driven directly by the
        // current finger's pixel speed, with no arbitrary fixed speed.
        const float screenFraction =
            dxPixels / static_cast<float>(WindowW());

        const float angleDelta = screenFraction * MOBILE_TWO_PI;

        m_buildRotation = NormalizeAngle(
            m_buildRotation + angleDelta);

        ICoord2D start;
        start.x = static_cast<Int>(m_buildX);
        start.y = static_cast<Int>(m_buildY);

        // The radius is only the visual direction-vector length. It does not
        // determine rotation speed or movement speed.
        const float directionRadius =
            static_cast<float>(
                WindowW() < WindowH() ? WindowW() : WindowH()) * 0.10f;

        ICoord2D end;
        end.x = start.x + static_cast<Int>(
            SDL_cosf(m_buildRotation) * directionRadius);
        end.y = start.y + static_cast<Int>(
            SDL_sinf(m_buildRotation) * directionRadius);

        TheInGameUI->setPlacementStart(&start);
        TheInGameUI->setPlacementEnd(&end);
    }

    void BuildNow()
    {
        if (m_state != STATE_BUILDING || !m_buildFixed)
            return;

        // Commit exactly the fixed screen-pixel building position.
        SendMouseMotionPixels(
            m_buildX,
            m_buildY,
            0.0f,
            0.0f);

        SendMouseButtonPixels(
            SDL_EVENT_MOUSE_BUTTON_DOWN,
            m_buildX,
            m_buildY);

        SendMouseButtonPixels(
            SDL_EVENT_MOUSE_BUTTON_UP,
            m_buildX,
            m_buildY);

        m_buildFixed = false;
        m_buildConfirm = false;
        m_buildRotating = false;
        m_buildHoldStart = 0;
        m_buildRotation = 0.0f;

        m_state = STATE_CAMERA_PAN;
        UnlockCamera();
    }

    void CancelBuilding()
    {
        if (TheInGameUI && BuildingPending())
            TheInGameUI->placeBuildAvailable(nullptr, nullptr);

        m_buildFixed = false;
        m_buildConfirm = false;
        m_buildRotating = false;
        m_buildHoldStart = 0;
        m_buildRotation = 0.0f;

        m_state = STATE_CAMERA_PAN;
        UnlockCamera();
    }

    void StartMultiTouch()
    {
        if (m_multiA >= 0 && m_multiB >= 0)
            return;

        int first = -1;
        int second = -1;

        for (int i = 0; i < 2; ++i)
        {
            if (!m_fingers[i].active)
                continue;

            if (first < 0)
                first = i;
            else
            {
                second = i;
                break;
            }
        }

        if (first < 0 || second < 0)
            return;

        // Any active one-finger operation is frozen immediately.
        // In particular, camera pan is never allowed to continue while
        // two fingers are down.
        m_multiA = first;
        m_multiB = second;

        m_stateBeforeMulti = m_state;
        m_state = STATE_MULTI_TOUCH;

        m_multiStarted = true;
        m_multiMoved = false;
        m_multiStartTicks = SDL_GetTicks();

        const float x1 = m_fingers[m_multiA].xPixels;
        const float y1 = m_fingers[m_multiA].yPixels;
        const float x2 = m_fingers[m_multiB].xPixels;
        const float y2 = m_fingers[m_multiB].yPixels;

        m_lastPinchDistancePixels =
            DistancePixels(x1, y1, x2, y2);

        m_lastPairAngle =
            AngleBetweenPixels(x1, y1, x2, y2);

        m_multiAccumulatedRotation = 0.0f;
        m_multiRotationActive = false;

        // Multi-touch always freezes the camera's normal single-finger pan.
        LockCamera();
    }

    void UpdateMultiFingerFromEvent(const SDL_Event &event)
    {
        const int index = FindFinger(event.tfinger.fingerID);

        if (index < 0)
            return;

        m_fingers[index].xPixels = XPixels(event.tfinger.x);
        m_fingers[index].yPixels = YPixels(event.tfinger.y);

        if (index == m_multiA || index == m_multiB)
            return;
    }

    void MultiTouchMotion(const SDL_Event &event)
    {
        if (m_multiA < 0 || m_multiB < 0)
            return;

        const int index = FindFinger(event.tfinger.fingerID);
        if (index < 0)
            return;

        // The event's x/y and dx/dy are converted to physical screen pixels
        // immediately. The stored state never uses normalized coordinates.
        const float dxPixels = DXPixels(event.tfinger.dx);
        const float dyPixels = DYPixels(event.tfinger.dy);

        m_fingers[index].xPixels = XPixels(event.tfinger.x);
        m_fingers[index].yPixels = YPixels(event.tfinger.y);

        m_fingers[index].travelPixels +=
            DistancePixels(
                0.0f,
                0.0f,
                dxPixels,
                dyPixels);

        const float x1 = m_fingers[m_multiA].xPixels;
        const float y1 = m_fingers[m_multiA].yPixels;
        const float x2 = m_fingers[m_multiB].xPixels;
        const float y2 = m_fingers[m_multiB].yPixels;

        const float pairDX = x2 - x1;
        const float pairDY = y2 - y1;

        const float currentDistance =
            SDL_sqrtf(pairDX * pairDX + pairDY * pairDY);

        const float currentAngle =
            SDL_atan2f(pairDY, pairDX);

        // Exact per-event distance change in physical pixels.
        const float pinchDeltaPixels =
            currentDistance - m_lastPinchDistancePixels;

        // Exact per-event angular change.
        const float angleDelta =
            NormalizeAngle(currentAngle - m_lastPairAngle);

        if (SDL_fabsf(dxPixels) > 0.0f ||
            SDL_fabsf(dyPixels) > 0.0f)
        {
            m_multiMoved = true;
        }

        // Pinch: requested direct pixel-distance delta divided by the
        // physical screen width. No fixed zoom step is used.
        if (pinchDeltaPixels != 0.0f && TheTacticalView)
        {
            const float zoomDelta =
                pinchDeltaPixels / static_cast<float>(WindowW());

            TheTacticalView->userZoom(-zoomDelta);
        }

        // Accumulate only for deciding whether the 40-degree rotation
        // dead-zone has actually been crossed.
        m_multiAccumulatedRotation += angleDelta;

        if (!m_multiRotationActive)
        {
            if (SDL_fabsf(m_multiAccumulatedRotation) >
                ROTATION_DEAD_ZONE)
            {
                m_multiRotationActive = true;

                // Apply only the part beyond the dead-zone. The dead-zone
                // itself never rotates the camera.
                const float sign =
                    m_multiAccumulatedRotation >= 0.0f
                        ? 1.0f
                        : -1.0f;

                const float excess =
                    SDL_fabsf(m_multiAccumulatedRotation) -
                    ROTATION_DEAD_ZONE;

                if (excess > 0.0f && TheTacticalView)
                {
                    TheTacticalView->userSetAngle(
                        NormalizeAngle(
                            TheTacticalView->getAngle() +
                            sign * excess));
                }
            }
        }
        else if (angleDelta != 0.0f && TheTacticalView)
        {
            // After activation the camera follows the exact angular delta.
            // No rotation rate, acceleration or frame-based step exists.
            TheTacticalView->userSetAngle(
                NormalizeAngle(
                    TheTacticalView->getAngle() + angleDelta));
        }

        m_fingers[index].lastXPixels =
            m_fingers[index].xPixels;

        m_fingers[index].lastYPixels =
            m_fingers[index].yPixels;

        m_lastPinchDistancePixels = currentDistance;
        m_lastPairAngle = currentAngle;
    }

    void FinishMultiTouch()
    {
        if (ActiveFingerCount() != 0)
            return;

        const Uint64 duration =
            SDL_GetTicks() - m_multiStartTicks;

        bool shortTwoFingerTap =
            m_multiStarted &&
            !m_multiMoved &&
            duration <= TWO_FINGER_TAP_MS &&
            m_fingers[m_multiA].travelPixels < TAP_MAX_TRAVEL_PX &&
            m_fingers[m_multiB].travelPixels < TAP_MAX_TRAVEL_PX;

        if (shortTwoFingerTap &&
            m_stateBeforeMulti == STATE_BUILDING &&
            BuildingPending())
        {
            CancelBuilding();
        }
        else
        {
            m_state = m_stateBeforeMulti;

            if (m_state == STATE_BUILDING)
                LockCamera();
            else
                UnlockCamera();
        }

        m_multiStarted = false;
        m_multiMoved = false;
        m_multiStartTicks = 0;
        m_multiA = -1;
        m_multiB = -1;
        m_lastPinchDistancePixels = 0.0f;
        m_lastPairAngle = 0.0f;
        m_multiAccumulatedRotation = 0.0f;
        m_multiRotationActive = false;
    }

    void FingerDown(const SDL_Event &event)
    {
        if (FindFinger(event.tfinger.fingerID) >= 0)
            return;

        const int slot = FindFreeFingerSlot();

        if (slot < 0)
            return;

        Finger &finger = m_fingers[slot];

        finger = Finger();
        finger.id = event.tfinger.fingerID;
        finger.active = true;

        // SDL3 x/y are normalized. Convert exactly once at the boundary.
        finger.xPixels = XPixels(event.tfinger.x);
        finger.yPixels = YPixels(event.tfinger.y);

        finger.downXPixels = finger.xPixels;
        finger.downYPixels = finger.yPixels;

        finger.lastXPixels = finger.xPixels;
        finger.lastYPixels = finger.yPixels;

        finger.downTicks = SDL_GetTicks();
        finger.travelPixels = 0.0f;

        if (ActiveFingerCount() >= 2)
        {
            StartMultiTouch();
            return;
        }

        // The first finger begins the appropriate one-finger state.
        if (BuildingPending())
        {
            if (m_buildFixed)
            {
                // Step 2 only starts when the second tap is actually on
                // the fixed preview.
                if (IsNearFixedBuilding(
                        finger.xPixels,
                        finger.yPixels))
                {
                    StartBuildingConfirmation();
                }
                else
                {
                    // The fixed building remains untouched. Camera remains
                    // locked because construction mode is still active.
                    m_state = STATE_BUILDING;
                    LockCamera();
                }
            }
            else
            {
                StartBuildingPreview(
                    finger.xPixels,
                    finger.yPixels);
            }

            return;
        }

        m_state = STATE_CAMERA_PAN;
        UnlockCamera();
    }

    void FingerMotion(const SDL_Event &event)
    {
        if (m_state == STATE_MULTI_TOUCH)
        {
            MultiTouchMotion(event);
            return;
        }

        const int index = FindFinger(event.tfinger.fingerID);

        if (index < 0)
            return;

        Finger &finger = m_fingers[index];

        const float dxPixels =
            DXPixels(event.tfinger.dx);

        const float dyPixels =
            DYPixels(event.tfinger.dy);

        const float xPixels =
            XPixels(event.tfinger.x);

        const float yPixels =
            YPixels(event.tfinger.y);

        // Travel is always accumulated from actual physical screen pixels.
        finger.travelPixels +=
            DistancePixels(
                0.0f,
                0.0f,
                dxPixels,
                dyPixels);

        finger.xPixels = xPixels;
        finger.yPixels = yPixels;

        if (m_state == STATE_BUILDING)
        {
            if (!m_buildFixed)
            {
                // STEP 1: exact absolute screen-pixel position.
                m_buildX = xPixels;
                m_buildY = yPixels;

                LockCamera();

                SendMouseMotionPixels(
                    m_buildX,
                    m_buildY,
                    dxPixels,
                    dyPixels);
            }
            else if (m_buildConfirm && m_buildRotating)
            {
                // STEP 2: current horizontal pixel speed directly controls
                // the angular change for this event.
                UpdateBuildingRotationPixels(dxPixels);
            }

            finger.lastXPixels = xPixels;
            finger.lastYPixels = yPixels;
            return;
        }

        if (m_state == STATE_SELECTION)
        {
            // Camera stays locked while the native selection rectangle
            // follows the current finger position exactly.
            LockCamera();

            SendMouseMotionPixels(
                xPixels,
                yPixels,
                dxPixels,
                dyPixels);

            finger.lastXPixels = xPixels;
            finger.lastYPixels = yPixels;
            return;
        }

        if (m_state == STATE_CAMERA_PAN)
        {
            const Uint64 held =
                SDL_GetTicks() - finger.downTicks;

            // Selection requires BOTH conditions:
            // strictly more than 100 ms AND strictly more than 20 pixels.
            if (held > SELECTION_HOLD_MS &&
                finger.travelPixels > SELECTION_TRAVEL_PX)
            {
                BeginSelection(index);

                SendMouseMotionPixels(
                    xPixels,
                    yPixels,
                    dxPixels,
                    dyPixels);
            }
            else
            {
                // Direct finger-speed camera response.
                ApplyCameraPanPixels(
                    dxPixels,
                    dyPixels);
            }
        }

        finger.lastXPixels = xPixels;
        finger.lastYPixels = yPixels;
    }

    void FingerUp(const SDL_Event &event, bool canceled)
    {
        if (m_state == STATE_MULTI_TOUCH)
        {
            const int index = FindFinger(event.tfinger.fingerID);

            if (index < 0)
                return;

            Finger &finger = m_fingers[index];

            // FINGER_UP still carries the exact final x/y.
            finger.xPixels = XPixels(event.tfinger.x);
            finger.yPixels = YPixels(event.tfinger.y);

            if (canceled)
                m_multiMoved = true;

            finger.active = false;

            FinishMultiTouch();
            return;
        }

        const int index = FindFinger(event.tfinger.fingerID);

        if (index < 0)
            return;

        Finger &finger = m_fingers[index];

        const float xPixels =
            XPixels(event.tfinger.x);

        const float yPixels =
            YPixels(event.tfinger.y);

        const float finalDX =
            xPixels - finger.lastXPixels;

        const float finalDY =
            yPixels - finger.lastYPixels;

        const Uint64 held =
            SDL_GetTicks() - finger.downTicks;

        if (m_state == STATE_SELECTION)
        {
            // Finish the native selection box at the exact release position.
            LockCamera();

            SendMouseMotionPixels(
                xPixels,
                yPixels,
                finalDX,
                finalDY);

            SendMouseButtonPixels(
                SDL_EVENT_MOUSE_BUTTON_UP,
                xPixels,
                yPixels);

            m_selectionMouseDown = false;

            if (TheInGameUI)
                TheInGameUI->setSelecting(FALSE);

            UnlockCamera();

            finger.active = false;
            m_state = STATE_CAMERA_PAN;
            return;
        }

        if (m_state == STATE_BUILDING)
        {
            if (!m_buildFixed)
            {
                // STEP 1 ends here. Capture the exact release pixel.
                m_buildX = xPixels;
                m_buildY = yPixels;

                SendMouseMotionPixels(
                    m_buildX,
                    m_buildY,
                    finalDX,
                    finalDY);

                // Release fixes the preview only. It does NOT build.
                FixBuildingPreview();
            }
            else if (m_buildConfirm)
            {
                // Short tap (< 0.2s) builds immediately.
                // A hold >= 0.2s enables rotation, then release builds.
                if (!m_buildRotating &&
                    held >= BUILD_ROTATE_HOLD_MS)
                {
                    BeginBuildingRotation();
                }

                BuildNow();
            }

            finger.active = false;
            return;
        }

        // Ordinary single tap:
        // no delay and no movement means one immediate native click/raycast.
        if (!canceled &&
            finger.travelPixels <= TAP_MAX_TRAVEL_PX &&
            held < SELECTION_HOLD_MS)
        {
            SendMouseMotionPixels(
                xPixels,
                yPixels,
                finalDX,
                finalDY);

            SendMouseButtonPixels(
                SDL_EVENT_MOUSE_BUTTON_DOWN,
                xPixels,
                yPixels);

            SendMouseButtonPixels(
                SDL_EVENT_MOUSE_BUTTON_UP,
                xPixels,
                yPixels);
        }

        finger.active = false;
        m_state = STATE_CAMERA_PAN;
    }
};
    static MobileInputManager s_mobileInput;
    static MobileInputManager s_mobileInput;

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
	s_mobileInput.SetWindow(m_SDLWindow);
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
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
	s_mobileInput.Reset();
#endif
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
				if (TheMouse) {
					TheMouse->loseFocus();
				}
				break;

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
			// App suspension/resume: mirror the desktop focus handling so audio
			// and mouse state pause cleanly (the render gate lives in update()).
			case SDL_EVENT_DID_ENTER_BACKGROUND:
				m_IsActive = false;
				s_mobileInput.Reset();
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

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
			// The on-screen keyboard was dismissed by the user: do not pop it up again
			// for the same focused widget until focus moves elsewhere.
			case SDL_EVENT_SCREEN_KEYBOARD_HIDDEN:
				if (m_IsTextInputActive) {
					SDL_StopTextInput(m_SDLWindow);
					m_IsTextInputActive = false;
					m_TextInputSuppressedFocusWindow = m_TextInputFocusWindow;
					m_TextInputFocusWindow = nullptr;
				}
				break;

			// Touch -> game gestures (camera, selection, building, zoom/rotate).
			case SDL_EVENT_FINGER_DOWN:
			case SDL_EVENT_FINGER_MOTION:
			case SDL_EVENT_FINGER_UP:
			case SDL_EVENT_FINGER_CANCELED:
				s_mobileInput.ProcessEvent(event);
				break;
#endif

			case SDL_EVENT_KEY_DOWN:
			case SDL_EVENT_KEY_UP:
				if (TheKeyboard) {
					SDL3Keyboard *keyboard = dynamic_cast<SDL3Keyboard *>(TheKeyboard);
					if (keyboard) {
						keyboard->addSDLEvent(&event);
					}
				}
				break;

			// Non-ASCII text (IME / on-screen keyboard). Plain ASCII already reaches
			// the widgets through the key events above, so it is not forwarded twice.
			case SDL_EVENT_TEXT_INPUT:
				if (TheWindowManager && event.text.text) {
					GameWindow *focus = TheWindowManager->winGetFocus();
					if (focus) {
						const char *text = event.text.text;
						const size_t length = strlen(text);
						size_t offset = 0;
						while (offset < length) {
							UnsignedInt codepoint = 0;
							if (!DecodeNextUtf8Codepoint(text, length, offset, codepoint)) {
								continue;
							}
							if (codepoint >= 0x80 && codepoint <= 0xFFFF) {
								TheWindowManager->winSendInputMsg(focus, GWM_IME_CHAR,
									static_cast<WindowMsgData>(codepoint), 0);
							}
						}
					}
				}
				break;

			case SDL_EVENT_MOUSE_MOTION:
			case SDL_EVENT_MOUSE_BUTTON_DOWN:
			case SDL_EVENT_MOUSE_BUTTON_UP:
			case SDL_EVENT_MOUSE_WHEEL:
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
				// Fake mouse events SDL derives from touches: the gesture manager
				// above already feeds the mouse queue itself.
				if (event.motion.which == SDL_TOUCH_MOUSEID) {
					break;
				}
#endif
				if (TheMouse) {
					SDL3Mouse *mouse = dynamic_cast<SDL3Mouse *>(TheMouse);
					if (mouse) {
						mouse->addSDLEvent(&event);
					}
				}
				break;

			default:
				break;
		}
	}

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
	// 0.2s hold timer for building rotation: no event fires while the finger is still.
	s_mobileInput.Update();
#endif
}

/**
 * Show / hide the OS text input (on-screen keyboard on iOS) depending on whether
 * the focused game widget is a text entry field.
 */
void SDL3GameEngine::updateTextInputState(void)
{
	if (!m_SDLWindow || !TheWindowManager) {
		return;
	}

	GameWindow *focus = TheWindowManager->winGetFocus();
	const Bool wantsText = (focus != nullptr) && BitIsSet(focus->winGetStyle(), GWS_ENTRY_FIELD);

	if (!wantsText) {
		if (m_IsTextInputActive) {
			SDL_StopTextInput(m_SDLWindow);
			m_IsTextInputActive = false;
			m_TextInputFocusWindow = nullptr;
		}
		m_TextInputSuppressedFocusWindow = nullptr;
		return;
	}

	if (focus == m_TextInputSuppressedFocusWindow) {
		return;   // user dismissed the keyboard for this widget
	}

	if (!m_IsTextInputActive || m_TextInputFocusWindow != focus) {
		SDL_StartTextInput(m_SDLWindow);
		m_IsTextInputActive = true;
		m_TextInputFocusWindow = focus;
	}
}

// ---------------------------------------------------------------------------
// Subsystem factories (W3D rendering, std file systems, OpenAL audio)
// ---------------------------------------------------------------------------
GameLogic *SDL3GameEngine::createGameLogic(void)
{
	return NEW W3DGameLogic;
}

GameClient *SDL3GameEngine::createGameClient(void)
{
	return NEW W3DGameClient;
}

ModuleFactory *SDL3GameEngine::createModuleFactory(void)
{
	return NEW W3DModuleFactory;
}

ThingFactory *SDL3GameEngine::createThingFactory(void)
{
	return NEW W3DThingFactory;
}

FunctionLexicon *SDL3GameEngine::createFunctionLexicon(void)
{
	return NEW W3DFunctionLexicon;
}

LocalFileSystem *SDL3GameEngine::createLocalFileSystem(void)
{
	return NEW StdLocalFileSystem;
}

ArchiveFileSystem *SDL3GameEngine::createArchiveFileSystem(void)
{
	return NEW StdBIGFileSystem;
}

Radar *SDL3GameEngine::createRadar(Bool dummy)
{
	return NEW W3DRadar;
}

WebBrowser *SDL3GameEngine::createWebBrowser(void)
{
	return NEW W3DWebBrowser;
}

ParticleSystemManager *SDL3GameEngine::createParticleSystemManager(Bool dummy)
{
	return NEW W3DParticleSystemManager;
}

AudioManager *SDL3GameEngine::createAudioManager(Bool dummy)
{
	return NEW OpenALAudioManager;
}

#endif // !_WIN32
