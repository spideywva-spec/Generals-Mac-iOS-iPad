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

    State GetState() const { return m_state; }

    void SetWindow(SDL_Window *window)
    {
        m_window = window;
    }

    void Reset()
    {
        ReleaseSelectionMouse();
        UnlockCamera();

        m_primary = Finger();
        m_secondary = Finger();

        m_state = STATE_CAMERA_PAN;
        m_stateBeforeMulti = STATE_CAMERA_PAN;

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
        m_multiAccumulatedRotation = 0.0f;
        m_multiRotationActive = false;
        m_lastPinchDistance = 0.0f;
        m_lastPairAngle = 0.0f;
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
            m_buildHoldStart != 0)
        {
            if (SDL_GetTicks() - m_buildHoldStart >= BUILD_ROTATE_HOLD_MS)
                BeginBuildingRotation();
        }
    }

private:
    struct Finger
    {
        SDL_FingerID id = 0;
        bool active = false;
        float x = 0.0f;
        float y = 0.0f;
        float downX = 0.0f;
        float downY = 0.0f;
        float lastX = 0.0f;
        float lastY = 0.0f;
        Uint64 downTicks = 0;
        float travel = 0.0f;
    };

    static constexpr Uint64 SELECTION_HOLD_MS = 100;
    static constexpr Uint64 BUILD_ROTATE_HOLD_MS = 200;
    static constexpr Uint64 TWO_FINGER_TAP_MS = 150;

    static constexpr float TAP_MAX_DISTANCE_PX = 10.0f;
    static constexpr float SELECTION_START_DISTANCE_PX = 12.0f;
    static constexpr float BUILD_CONFIRM_RADIUS_PX = 48.0f;
    static constexpr float TWO_FINGER_TAP_DISTANCE_PX = 14.0f;

    static constexpr float CAMERA_PAN_SCALE = 0.020f;
    static constexpr float PINCH_ZOOM_SCALE = 0.050f;
    static constexpr float BUILD_ROTATION_SCALE = 0.012f;
    static constexpr float ROTATION_DEAD_ZONE = 0.6981317008f;
    static constexpr float MOBILE_TWO_PI = 6.28318530717958647692f;

    State m_state = STATE_CAMERA_PAN;
    State m_stateBeforeMulti = STATE_CAMERA_PAN;

    SDL_Window *m_window = nullptr;

    Finger m_primary;
    Finger m_secondary;

    bool m_selectionMouseDown = false;

    bool m_buildFixed = false;
    bool m_buildConfirm = false;
    bool m_buildRotating = false;
    Uint64 m_buildHoldStart = 0;
    float m_buildX = 0.0f;
    float m_buildY = 0.0f;
    float m_buildRotation = 0.0f;

    bool m_multiStarted = false;
    bool m_multiMoved = false;
    Uint64 m_multiStartTicks = 0;
    float m_lastPinchDistance = 0.0f;
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
        SDL_GetWindowSize(m_window, &w, &h);
        return w > 0 ? w : 1;
    }

    int WindowH() const
    {
        int w = 1;
        int h = 1;
        SDL_GetWindowSize(m_window, &w, &h);
        return h > 0 ? h : 1;
    }

    static float NormalizeAngle(float a)
    {
        while (a > 3.14159265358979323846f)
            a -= MOBILE_TWO_PI;
        while (a < -3.14159265358979323846f)
            a += MOBILE_TWO_PI;
        return a;
    }

    static float Distance(float x1, float y1, float x2, float y2)
    {
        const float dx = x2 - x1;
        const float dy = y2 - y1;
        return SDL_sqrtf(dx * dx + dy * dy);
    }

    bool BuildingPending() const
    {
        return TheInGameUI && TheInGameUI->getPendingPlaceType() != nullptr;
    }

    float SX(float normalized) const
    {
        return normalized * static_cast<float>(WindowW());
    }

    float SY(float normalized) const
    {
        return normalized * static_cast<float>(WindowH());
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

    void SendMouseMotion(float x, float y)
    {
        SDL3Mouse *mouse = Mouse();
        if (!mouse)
            return;

        SDL_Event e;
        SDL_zero(e);
        e.type = SDL_EVENT_MOUSE_MOTION;
        e.motion.windowID = SDL_GetWindowID(m_window);
        e.motion.which = 0;
        e.motion.x = x;
        e.motion.y = y;
        e.motion.xrel = 0.0f;
        e.motion.yrel = 0.0f;
        mouse->addSDLEvent(&e);
    }

    void SendMouseButton(Uint32 type, float x, float y)
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
        e.button.x = x;
        e.button.y = y;
        mouse->addSDLEvent(&e);
    }

    void ReleaseSelectionMouse()
    {
        if (!m_selectionMouseDown)
            return;

        SendMouseButton(SDL_EVENT_MOUSE_BUTTON_UP,
                        m_primary.lastX,
                        m_primary.lastY);
        m_selectionMouseDown = false;

        if (TheInGameUI)
            TheInGameUI->setSelecting(FALSE);
    }

    void ApplyCameraPan(float dx, float dy)
    {
        if (m_state != STATE_CAMERA_PAN || !TheTacticalView)
            return;

        Coord2D delta;
        delta.x = -dx * static_cast<float>(WindowW()) * CAMERA_PAN_SCALE;
        delta.y = -dy * static_cast<float>(WindowH()) * CAMERA_PAN_SCALE;

        // No fixed step, acceleration, interpolation or velocity cap:
        // SDL3 finger delta is passed directly to the camera action.
        TheTacticalView->userScrollBy(&delta);
    }

    void BeginSelection()
    {
        if (m_state != STATE_CAMERA_PAN || !m_primary.active)
            return;

        m_state = STATE_SELECTION;
        LockCamera();

        if (TheInGameUI)
            TheInGameUI->setSelecting(TRUE);

        SendMouseMotion(m_primary.downX, m_primary.downY);
        SendMouseButton(SDL_EVENT_MOUSE_BUTTON_DOWN,
                        m_primary.downX,
                        m_primary.downY);

        m_selectionMouseDown = true;
    }

    void StartBuildingPreview(float x, float y)
    {
        m_state = STATE_BUILDING;
        m_buildFixed = false;
        m_buildConfirm = false;
        m_buildRotating = false;
        m_buildHoldStart = 0;
        m_buildRotation = 0.0f;
        m_buildX = x;
        m_buildY = y;

        LockCamera();
        SendMouseMotion(x, y);
    }

    void FixBuildingPreview()
    {
        m_buildFixed = true;
        m_buildConfirm = false;
        m_buildRotating = false;
        m_buildHoldStart = 0;

        LockCamera();

        // The normal Generals placement path uses the placement start/end
        // points to keep the selected building preview anchored on the map.
        if (TheInGameUI)
        {
            ICoord2D p;
            p.x = static_cast<Int>(m_buildX);
            p.y = static_cast<Int>(m_buildY);
            TheInGameUI->setPlacementStart(&p);
            TheInGameUI->setPlacementEnd(&p);
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
            return;

        m_buildRotating = true;
        m_buildHoldStart = 0;
        m_buildRotation = 0.0f;
        LockCamera();
    }

    void UpdateBuildingRotation(float dx, float dy)
    {
        if (!m_buildRotating || !TheInGameUI)
            return;

        // Use the dominant finger-axis movement. There is no angle snapping.
        // The magnitude is still exactly proportional to SDL3 dx/dy.
        const float input = SDL_fabsf(dx) >= SDL_fabsf(dy) ? dx : -dy;
        const float pixels = input * static_cast<float>(WindowW());

        m_buildRotation = NormalizeAngle(
            m_buildRotation + pixels * BUILD_ROTATION_SCALE);

        const float radius = 64.0f;

        ICoord2D start;
        start.x = static_cast<Int>(m_buildX);
        start.y = static_cast<Int>(m_buildY);

        ICoord2D end;
        end.x = start.x + static_cast<Int>(SDL_cosf(m_buildRotation) * radius);
        end.y = start.y + static_cast<Int>(SDL_sinf(m_buildRotation) * radius);

        TheInGameUI->setPlacementStart(&start);
        TheInGameUI->setPlacementEnd(&end);
    }

    void BuildNow()
    {
        if (m_state != STATE_BUILDING || !m_buildFixed)
            return;

        SendMouseMotion(m_buildX, m_buildY);
        SendMouseButton(SDL_EVENT_MOUSE_BUTTON_DOWN, m_buildX, m_buildY);
        SendMouseButton(SDL_EVENT_MOUSE_BUTTON_UP, m_buildX, m_buildY);

        m_buildFixed = false;
        m_buildConfirm = false;
        m_buildRotating = false;
        m_buildHoldStart = 0;
        m_state = STATE_CAMERA_PAN;
        UnlockCamera();
    }

    void CancelBuilding()
    {
        // Remove the pending placement through the game's existing placement
        // API. Do not synthesize a click: cancellation must never build.
        if (TheInGameUI && BuildingPending())
            TheInGameUI->placeBuildAvailable(nullptr, nullptr);

        m_buildFixed = false;
        m_buildConfirm = false;
        m_buildRotating = false;
        m_buildHoldStart = 0;
        m_state = STATE_CAMERA_PAN;
        UnlockCamera();
    }

    void StartMultiTouch(const SDL_Event &event)
    {
        ReleaseSelectionMouse();

        m_stateBeforeMulti = m_state;
        m_state = STATE_MULTI_TOUCH;

        m_secondary.id = event.tfinger.fingerID;
        m_secondary.active = true;
        m_secondary.x = event.tfinger.x;
        m_secondary.y = event.tfinger.y;
        m_secondary.downX = event.tfinger.x;
        m_secondary.downY = event.tfinger.y;
        m_secondary.lastX = event.tfinger.x;
        m_secondary.lastY = event.tfinger.y;
        m_secondary.downTicks = SDL_GetTicks();
        m_secondary.travel = 0.0f;

        const float p1x = m_primary.x * static_cast<float>(WindowW());
        const float p1y = m_primary.y * static_cast<float>(WindowH());
        const float p2x = m_secondary.x * static_cast<float>(WindowW());
        const float p2y = m_secondary.y * static_cast<float>(WindowH());

        const float dx = p2x - p1x;
        const float dy = p2y - p1y;

        m_lastPinchDistance = SDL_sqrtf(dx * dx + dy * dy);
        m_lastPairAngle = SDL_atan2f(dy, dx);
        m_multiAccumulatedRotation = 0.0f;
        m_multiRotationActive = false;
        m_multiStarted = true;
        m_multiMoved = false;
        m_multiStartTicks = SDL_GetTicks();

        LockCamera();
    }

    void MultiTouchMotion(const SDL_Event &event)
    {
        if (!m_primary.active || !m_secondary.active)
            return;

        if (event.tfinger.fingerID == m_primary.id)
        {
            m_primary.x = event.tfinger.x;
            m_primary.y = event.tfinger.y;
        }
        else if (event.tfinger.fingerID == m_secondary.id)
        {
            m_secondary.x = event.tfinger.x;
            m_secondary.y = event.tfinger.y;
        }
        else
        {
            return;
        }

        const float w = static_cast<float>(WindowW());
        const float h = static_cast<float>(WindowH());

        const float x1 = m_primary.x * w;
        const float y1 = m_primary.y * h;
        const float x2 = m_secondary.x * w;
        const float y2 = m_secondary.y * h;

        const float pairDX = x2 - x1;
        const float pairDY = y2 - y1;
        const float distance = SDL_sqrtf(pairDX * pairDX + pairDY * pairDY);
        const float angle = SDL_atan2f(pairDY, pairDX);

        const float pinchDelta = distance - m_lastPinchDistance;
        const float angleDelta = NormalizeAngle(angle - m_lastPairAngle);

        const float primaryTravel =
            Distance(m_primary.downX * w, m_primary.downY * h, x1, y1);
        const float secondaryTravel =
            Distance(m_secondary.downX * w, m_secondary.downY * h, x2, y2);

        if (primaryTravel > TWO_FINGER_TAP_DISTANCE_PX ||
            secondaryTravel > TWO_FINGER_TAP_DISTANCE_PX ||
            SDL_fabsf(pinchDelta) > 0.5f ||
            SDL_fabsf(angleDelta) > 0.005f)
        {
            m_multiMoved = true;
        }

        // Zoom is always available during a two-finger gesture.
        if (SDL_fabsf(pinchDelta) > 0.0f && TheTacticalView)
        {
            TheTacticalView->userZoom(
                -pinchDelta * PINCH_ZOOM_SCALE);
        }

        // Accumulate wrapped angular deltas, so rotation can pass through
        // 360 degrees without a discontinuity at +/- PI.
        m_multiAccumulatedRotation += angleDelta;

        if (!m_multiRotationActive)
        {
            if (SDL_fabsf(m_multiAccumulatedRotation) >= ROTATION_DEAD_ZONE)
            {
                m_multiRotationActive = true;

                // Consume only the part beyond the 40-degree dead zone.
                const float sign =
                    m_multiAccumulatedRotation >= 0.0f ? 1.0f : -1.0f;
                const float excess =
                    SDL_fabsf(m_multiAccumulatedRotation) - ROTATION_DEAD_ZONE;

                if (excess > 0.0f && TheTacticalView)
                {
                    TheTacticalView->userSetAngle(
                        NormalizeAngle(TheTacticalView->getAngle() +
                                       sign * excess));
                }
            }
        }
        else if (TheTacticalView && SDL_fabsf(angleDelta) > 0.0f)
        {
            // From activation onward, every SDL3 angular delta is applied
            // directly. Slow finger rotation = slow camera rotation.
            TheTacticalView->userSetAngle(
                NormalizeAngle(TheTacticalView->getAngle() + angleDelta));
        }

        m_lastPinchDistance = distance;
        m_lastPairAngle = angle;
    }

    void FinishMultiTouch()
    {
        if (m_primary.active || m_secondary.active)
            return;

        const Uint64 duration =
            SDL_GetTicks() - m_multiStartTicks;

        const bool shortTwoFingerTap =
            m_multiStarted &&
            !m_multiMoved &&
            duration <= TWO_FINGER_TAP_MS;

        if (shortTwoFingerTap &&
            m_stateBeforeMulti == STATE_BUILDING &&
            BuildingPending())
        {
            CancelBuilding();
        }
        else
        {
            // Restore the logical mode that was active before the second
            // finger arrived. No single-finger movement is synthesized.
            m_state = m_stateBeforeMulti;

            if (m_state == STATE_BUILDING)
                LockCamera();
            else
                UnlockCamera();
        }

        m_multiStarted = false;
        m_multiMoved = false;
        m_multiStartTicks = 0;
        m_multiAccumulatedRotation = 0.0f;
        m_multiRotationActive = false;
        m_lastPinchDistance = 0.0f;
        m_lastPairAngle = 0.0f;
    }

    void FingerDown(const SDL_Event &event)
    {
        const float x = event.tfinger.x;
        const float y = event.tfinger.y;

        // First active finger.
        if (!m_primary.active)
        {
            m_primary = Finger();
            m_primary.id = event.tfinger.fingerID;
            m_primary.active = true;
            m_primary.x = x;
            m_primary.y = y;
            m_primary.downX = x;
            m_primary.downY = y;
            m_primary.lastX = x;
            m_primary.lastY = y;
            m_primary.downTicks = SDL_GetTicks();

            if (m_state == STATE_MULTI_TOUCH)
                return;

            if (BuildingPending())
            {
                const float sx = SX(x);
                const float sy = SY(y);

                if (m_buildFixed)
                {
                    const float d =
                        Distance(sx, sy, m_buildX, m_buildY);

                    if (d <= BUILD_CONFIRM_RADIUS_PX)
                    {
                        // Fixed building: start the <200ms tap vs >200ms
                        // rotation decision.
                        StartBuildingConfirmation();
                    }
                    else
                    {
                        // A pending preview exists but this finger did not
                        // touch it. Keep the camera locked.
                        LockCamera();
                    }
                }
                else
                {
                    StartBuildingPreview(sx, sy);
                }

                return;
            }

            m_state = STATE_CAMERA_PAN;
            UnlockCamera();
            return;
        }

        // Second active finger: immediately enter multi-touch, regardless of
        // its numeric finger ID. SDL3 finger IDs are not guaranteed to be 0/1.
        if (!m_secondary.active &&
            event.tfinger.fingerID != m_primary.id)
        {
            StartMultiTouch(event);
        }
    }

    void FingerMotion(const SDL_Event &event)
    {
        if (m_state == STATE_MULTI_TOUCH)
        {
            MultiTouchMotion(event);
            return;
        }

        if (!m_primary.active ||
            event.tfinger.fingerID != m_primary.id)
            return;

        const float x = SX(event.tfinger.x);
        const float y = SY(event.tfinger.y);

        const float dxPixels =
            event.tfinger.dx * static_cast<float>(WindowW());
        const float dyPixels =
            event.tfinger.dy * static_cast<float>(WindowH());

        m_primary.travel += SDL_sqrtf(dxPixels * dxPixels +
                                      dyPixels * dyPixels);
        m_primary.x = event.tfinger.x;
        m_primary.y = event.tfinger.y;

        if (m_state == STATE_BUILDING)
        {
            if (!m_buildFixed)
            {
                // STEP 1: direct SDL3 dx/dy -> preview motion.
                m_buildX += dxPixels;
                m_buildY += dyPixels;
                SendMouseMotion(m_buildX, m_buildY);
            }
            else if (m_buildConfirm && m_buildRotating)
            {
                // STEP 2: direct SDL3 dx/dy -> continuous rotation.
                UpdateBuildingRotation(event.tfinger.dx,
                                       event.tfinger.dy);
            }

            m_primary.lastX = x;
            m_primary.lastY = y;
            return;
        }

        if (m_state == STATE_SELECTION)
        {
            // The camera is locked. The selection rectangle follows the exact
            // current finger position, so its speed is the finger speed.
            SendMouseMotion(x, y);
            m_primary.lastX = x;
            m_primary.lastY = y;
            return;
        }

        if (m_state == STATE_CAMERA_PAN)
        {
            const Uint64 held =
                SDL_GetTicks() - m_primary.downTicks;

            // A selection gesture requires the finger to survive the 100ms
            // hold threshold before the drag becomes a selection box.
            if (held >= SELECTION_HOLD_MS &&
                m_primary.travel >= SELECTION_START_DISTANCE_PX)
            {
                BeginSelection();
                SendMouseMotion(x, y);
            }
            else
            {
                // Camera speed is directly proportional to SDL3 dx/dy.
                ApplyCameraPan(event.tfinger.dx, event.tfinger.dy);
            }
        }

        m_primary.lastX = x;
        m_primary.lastY = y;
    }

    void FingerUp(const SDL_Event &event, bool canceled)
    {
        if (m_state == STATE_MULTI_TOUCH)
        {
            if (event.tfinger.fingerID == m_primary.id)
                m_primary.active = false;

            if (event.tfinger.fingerID == m_secondary.id)
                m_secondary.active = false;

            if (canceled)
                m_multiMoved = true;

            FinishMultiTouch();
            return;
        }

        if (!m_primary.active ||
            event.tfinger.fingerID != m_primary.id)
            return;

        const float x = SX(event.tfinger.x);
        const float y = SY(event.tfinger.y);
        const Uint64 held =
            SDL_GetTicks() - m_primary.downTicks;

        if (m_state == STATE_SELECTION)
        {
            SendMouseMotion(x, y);
            SendMouseButton(SDL_EVENT_MOUSE_BUTTON_UP, x, y);
            m_selectionMouseDown = false;

            if (TheInGameUI)
                TheInGameUI->setSelecting(FALSE);

            UnlockCamera();
            m_primary.active = false;
            m_state = STATE_CAMERA_PAN;
            return;
        }

        if (m_state == STATE_BUILDING)
        {
            if (!m_buildFixed)
            {
                // STEP 1 release: fix only. Never build here.
                m_buildX = x;
                m_buildY = y;
                FixBuildingPreview();
            }
            else if (m_buildConfirm)
            {
                // Short tap (<200ms) builds immediately.
                // A rotation gesture builds immediately on release too.
                if (m_buildRotating ||
                    held < BUILD_ROTATE_HOLD_MS)
                {
                    BuildNow();
                }
                else
                {
                    // Safety path if the frame update was delayed exactly at
                    // the threshold.
                    BeginBuildingRotation();
                    BuildNow();
                }
            }

            m_primary.active = false;
            return;
        }

        // Normal single-finger tap -> native mouse click/raycast.
        if (!canceled &&
            m_primary.travel <= TAP_MAX_DISTANCE_PX &&
            held < SELECTION_HOLD_MS)
        {
            SendMouseMotion(x, y);
            SendMouseButton(SDL_EVENT_MOUSE_BUTTON_DOWN, x, y);
            SendMouseButton(SDL_EVENT_MOUSE_BUTTON_UP, x, y);
        }

        m_primary.active = false;
        m_state = STATE_CAMERA_PAN;
    }
};static MobileInputManager s_mobileInput;

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
