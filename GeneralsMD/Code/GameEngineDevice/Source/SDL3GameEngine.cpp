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

    void SetBuildConfirmationMode(bool useHoldToRotate)
    {
        m_useHoldToRotate = useHoldToRotate;
    }

    State GetState() const
    {
        return m_state;
    }

    void SetWindow(SDL_Window *window)
    {
        m_window = window;
    }

    // Drop any in-flight gesture (app backgrounded, engine reset, touch cancelled).
    void Reset()
    {
        if (m_leftHeld)
        {
            // A held LMB during building rotation would BUILD on release: cancel first.
            if (m_buildRotating && TheInGameUI)
                TheInGameUI->placeBuildAvailable(nullptr, nullptr);

            SendMouse(SDL_EVENT_MOUSE_BUTTON_UP, m_lastX, m_lastY, SDL_BUTTON_LEFT);
        }

        m_leftHeld = false;
        m_selectionMouseDown = false;
        m_primaryActive = false;
        m_secondaryActive = false;
        m_buildConfirmationPending = false;
        m_buildConfirmTapActive = false;
        m_buildRotating = false;
        m_buildRotationStarted = false;
        m_buildHoldStartTicks = 0;
        m_multiRotationActive = false;
        m_accumulatedRotation = 0.0f;
        m_twoFingerCancelCandidate = false;
        m_twoFingerMoved = false;
        m_twoFingerStartTicks = 0;
        m_state = STATE_CAMERA_PAN;
        m_stateBeforeMultiTouch = STATE_CAMERA_PAN;
    }

    void ProcessEvent(const SDL_Event &event)
    {
        if (!m_window)
            return;

        switch (event.type)
        {
            case SDL_EVENT_FINGER_DOWN:
                OnFingerDown(event);
                break;

            case SDL_EVENT_FINGER_MOTION:
                OnFingerMotion(event);
                break;

            case SDL_EVENT_FINGER_UP:
            case SDL_EVENT_FINGER_CANCELED:
                OnFingerUp(event);
                break;

            default:
                break;
        }
    }

    void Update()
    {
        if (!m_primaryActive)
            return;

        const Uint64 now = SDL_GetTicks();

        if (m_state == STATE_BUILDING &&
            m_useHoldToRotate &&
            !m_buildRotating &&
            m_buildHoldStartTicks != 0 &&
            now - m_buildHoldStartTicks >= BUILD_ROTATION_HOLD_MS)
        {
            BeginBuildingRotation();
        }
    }

private:
    static constexpr Uint64 TAP_MAX_DURATION_MS = 100;
    static constexpr Uint64 BUILD_ROTATION_HOLD_MS = 200;
    static constexpr Uint64 TWO_FINGER_CANCEL_WINDOW_MS = 150;

    static constexpr float TAP_MAX_DISTANCE_PX = 10.0f;
    static constexpr float SELECTION_DISTANCE_PX = 12.0f;
    static constexpr float TWO_FINGER_CANCEL_DISTANCE_PX = 12.0f;
    static constexpr float BUILD_CONFIRM_DISTANCE_PX = 48.0f;
    static constexpr float BUILD_STATIONARY_DISTANCE_PX = 3.0f;

    static constexpr float CAMERA_PAN_WORLD_PER_PIXEL = 0.020f;
    static constexpr float PINCH_ZOOM_WORLD_PER_PIXEL = 0.05f;
    static constexpr float ROTATION_DEAD_ZONE_RAD = 0.6981317008f;
    static constexpr float MOBILE_TWO_PI = 6.28318530717958647692f;
    static constexpr float BUILD_ROTATE_RAD_PER_PIXEL = 0.012f;

    State m_state = STATE_CAMERA_PAN;
    State m_stateBeforeMultiTouch = STATE_CAMERA_PAN;

    SDL_Window *m_window = nullptr;

    SDL_FingerID m_primaryFinger = 0;
    SDL_FingerID m_secondaryFinger = 0;
    bool m_primaryActive = false;
    bool m_secondaryActive = false;

    float m_downX = 0.0f;
    float m_downY = 0.0f;
    float m_lastX = 0.0f;
    float m_lastY = 0.0f;
    Uint64 m_downTicks = 0;

    bool m_selectionMouseDown = false;
    bool m_leftHeld = false;

    bool m_useHoldToRotate = false;
    bool m_buildConfirmationPending = false;
    bool m_buildConfirmTapActive = false;
    bool m_buildRotating = false;
    bool m_buildRotationStarted = false;
    Uint64 m_buildHoldStartTicks = 0;
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

    Uint64 m_twoFingerStartTicks = 0;
    bool m_twoFingerCancelCandidate = false;
    bool m_twoFingerMoved = false;
    float m_twoFingerPrimaryDownX = 0.0f;
    float m_twoFingerPrimaryDownY = 0.0f;
    float m_twoFingerSecondaryDownX = 0.0f;
    float m_twoFingerSecondaryDownY = 0.0f;

    SDL3Mouse *Mouse() const
    {
        return TheMouse ? dynamic_cast<SDL3Mouse *>(TheMouse) : nullptr;
    }

    bool BuildingActive() const
    {
        return TheInGameUI != nullptr &&
               TheInGameUI->getPendingPlaceType() != nullptr;
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

    float ScreenX(float normalized) const
    {
        return normalized * static_cast<float>(WindowW());
    }

    float ScreenY(float normalized) const
    {
        return normalized * static_cast<float>(WindowH());
    }

    static float NormalizeAngle(float angle)
    {
        while (angle > 3.14159265358979323846f)
            angle -= MOBILE_TWO_PI;

        while (angle < -3.14159265358979323846f)
            angle += MOBILE_TWO_PI;

        return angle;
    }

    void SendMouse(Uint32 type, float x, float y, Uint8 button = 0, bool suppressRelativeMotion = false)
    {
        SDL3Mouse *mouse = Mouse();
        if (!mouse)
            return;

        SDL_Event event;
        SDL_zero(event);
        event.type = type;

        if (type == SDL_EVENT_MOUSE_MOTION)
        {
            event.motion.windowID = SDL_GetWindowID(m_window);
            event.motion.which = 0;
            event.motion.x = x;
            event.motion.y = y;
            event.motion.xrel = suppressRelativeMotion ? 0.0f : (x - m_lastX);
            event.motion.yrel = suppressRelativeMotion ? 0.0f : (y - m_lastY);
        }
        else if (type == SDL_EVENT_MOUSE_BUTTON_DOWN ||
                 type == SDL_EVENT_MOUSE_BUTTON_UP)
        {
            event.button.windowID = SDL_GetWindowID(m_window);
            event.button.which = 0;
            event.button.button = button;
            event.button.down = (type == SDL_EVENT_MOUSE_BUTTON_DOWN);
            event.button.clicks = 1;
            event.button.x = x;
            event.button.y = y;
        }
        else
        {
            return;
        }

        mouse->addSDLEvent(&event);

        if (type == SDL_EVENT_MOUSE_BUTTON_DOWN && button == SDL_BUTTON_LEFT)
            m_leftHeld = true;
        else if (type == SDL_EVENT_MOUSE_BUTTON_UP && button == SDL_BUTTON_LEFT)
            m_leftHeld = false;
    }

    void ReleaseSelectionMouse()
    {
        if (m_leftHeld)
            SendMouse(SDL_EVENT_MOUSE_BUTTON_UP, m_lastX, m_lastY, SDL_BUTTON_LEFT);

        m_leftHeld = false;
        m_selectionMouseDown = false;
    }

    void ApplyCameraPan(float dxNormalized, float dyNormalized)
    {
        if (m_state != STATE_CAMERA_PAN || !TheTacticalView)
            return;

        // SDL3 tfinger.dx/tfinger.dy are normalized per-event deltas.
        // Convert to pixels first, then apply a linear world-space scale.
        // Therefore faster/larger finger motion produces proportionally larger
        // camera motion, with no acceleration curve or fixed-step movement.
        Coord2D delta;
        delta.x = -dxNormalized * static_cast<float>(WindowW()) * CAMERA_PAN_WORLD_PER_PIXEL;
        delta.y = -dyNormalized * static_cast<float>(WindowH()) * CAMERA_PAN_WORLD_PER_PIXEL;

        TheTacticalView->userScrollBy(&delta);
    }

    void ApplyZoom(float distanceDeltaPixels)
    {
        if (m_state != STATE_MULTI_TOUCH || !TheTacticalView)
            return;

        // Fingers moving apart -> positive distance delta -> zoom in.
        TheTacticalView->userZoom(-distanceDeltaPixels * PINCH_ZOOM_WORLD_PER_PIXEL);
    }

    void ApplyCameraRotation(float angleDelta)
    {
        if (m_state != STATE_MULTI_TOUCH || !TheTacticalView)
            return;

        TheTacticalView->userSetAngle(TheTacticalView->getAngle() + angleDelta);
    }

    void BeginSelection()
    {
        if (m_state != STATE_CAMERA_PAN ||
            !m_primaryActive ||
            !Mouse())
            return;

        // The native SelectionTranslator already uses CanSelectDrawable(...,
        // dragSelecting=true), which explicitly rejects KINDOF_STRUCTURE.
        // The camera is hard-locked by STATE_SELECTION: no pan operation is
        // issued while this state is active.
        SendMouse(SDL_EVENT_MOUSE_MOTION, m_downX, m_downY);
        SendMouse(SDL_EVENT_MOUSE_BUTTON_DOWN, m_downX, m_downY, SDL_BUTTON_LEFT);

        m_selectionMouseDown = true;
        m_state = STATE_SELECTION;
    }

    void BeginBuilding(float x, float y)
    {
        m_state = STATE_BUILDING;
        m_buildConfirmationPending = false;
        m_buildConfirmTapActive = false;
        m_buildRotating = false;
        m_buildHoldStartTicks = SDL_GetTicks();

        m_buildX = x;
        m_buildY = y;
        m_lastX = x;
        m_lastY = y;

        // Moving the preview uses the existing Generals placement path.
        // No camera pan is ever emitted in STATE_BUILDING.
        SendMouse(SDL_EVENT_MOUSE_MOTION, x, y);
    }

    void BeginBuildingRotation()
    {
        if (m_state != STATE_BUILDING ||
            !m_useHoldToRotate ||
            !TheInGameUI)
            return;

        // Rotation mode is anchored to the current building position.
        // From this point the building MUST NOT move: only its placement angle
        // changes. The camera is also hard-locked by STATE_BUILDING.
        m_buildRotating = true;
        m_buildRotationStarted = false;
        m_buildRotation = 0.0f;

        SendMouse(SDL_EVENT_MOUSE_MOTION, m_buildX, m_buildY, 0, true);
        SendMouse(SDL_EVENT_MOUSE_BUTTON_DOWN, m_buildX, m_buildY, SDL_BUTTON_LEFT);

        fprintf(stderr, "[iOS-INPUT] STATE_BUILDING -> ROTATION after 200ms hold\n");
    }

    void UpdateBuildingRotation(float dxPixels)
    {
        if (m_state != STATE_BUILDING || !m_buildRotating)
            return;

        // Continuous angle accumulation proportional to finger speed:
        // no 45/90 degree snapping, full 360 degrees.
        m_buildRotation = NormalizeAngle(m_buildRotation + dxPixels * BUILD_ROTATE_RAD_PER_PIXEL);
        m_buildRotationStarted = true;

        // The building position stays at m_buildX/m_buildY. The drag endpoint
        // changes only its facing through the native placement path.
        SendMouse(SDL_EVENT_MOUSE_MOTION,
                  m_buildX + SDL_cosf(m_buildRotation) * m_buildRotationRadius,
                  m_buildY + SDL_sinf(m_buildRotation) * m_buildRotationRadius,
                  0, true);
    }

    void ConfirmBuilding()
    {
        if (m_state != STATE_BUILDING)
            return;

        if (m_buildRotating)
        {
            // The building stays at the fixed anchor. Its angle was already
            // updated through InGameUI placement points. Release at the anchor
            // to build immediately without moving the building.
            SendMouse(SDL_EVENT_MOUSE_BUTTON_UP, m_buildX, m_buildY, SDL_BUTTON_LEFT);
        }
        else
        {
            SendMouse(SDL_EVENT_MOUSE_BUTTON_DOWN, m_buildX, m_buildY, SDL_BUTTON_LEFT);
            SendMouse(SDL_EVENT_MOUSE_BUTTON_UP, m_buildX, m_buildY, SDL_BUTTON_LEFT);
        }

        m_buildConfirmationPending = false;
        m_buildConfirmTapActive = false;
        m_buildRotating = false;
        m_buildRotationStarted = false;
        m_buildHoldStartTicks = 0;
    }

    void CancelBuilding()
    {
        if (!BuildingActive())
            return;

        // This is the engine's native placement cancellation path. It removes
        // the preview without moving the camera or deselecting unrelated units.
        TheInGameUI->placeBuildAvailable(nullptr, nullptr);
        TheInGameUI->setScrolling(FALSE);

        m_buildConfirmationPending = false;
        m_buildRotating = false;
        m_buildRotationStarted = false;
        m_buildHoldStartTicks = 0;

        m_state = STATE_CAMERA_PAN;

        fprintf(stderr, "[iOS-INPUT] BUILDING canceled by two-finger tap\n");
    }

    void StartMultiTouch(const SDL_Event &event)
    {
        ReleaseSelectionMouse();

        m_stateBeforeMultiTouch = m_state;
        m_secondaryFinger = event.tfinger.fingerID;
        m_secondaryActive = true;

        m_f2x = event.tfinger.x;
        m_f2y = event.tfinger.y;

        // Re-sample the primary finger from the last event position.
        m_f1x = m_lastX / static_cast<float>(WindowW());
        m_f1y = m_lastY / static_cast<float>(WindowH());

        m_state = STATE_MULTI_TOUCH;

        // Rotation is locked at the start of every two-finger gesture.
        m_multiRotationActive = false;
        m_accumulatedRotation = 0.0f;

        const float dx = (m_f1x - m_f2x) * static_cast<float>(WindowW());
        const float dy = (m_f1y - m_f2y) * static_cast<float>(WindowH());

        m_lastPinchDistance = SDL_sqrtf(dx * dx + dy * dy);
        m_lastPairAngle = SDL_atan2f(dy, dx);

        m_twoFingerStartTicks = SDL_GetTicks();
        m_twoFingerCancelCandidate = (m_stateBeforeMultiTouch == STATE_BUILDING);
        m_twoFingerMoved = false;

        m_twoFingerPrimaryDownX = m_f1x * static_cast<float>(WindowW());
        m_twoFingerPrimaryDownY = m_f1y * static_cast<float>(WindowH());
        m_twoFingerSecondaryDownX = m_f2x * static_cast<float>(WindowW());
        m_twoFingerSecondaryDownY = m_f2y * static_cast<float>(WindowH());
    }

    void UpdateMultiTouch(const SDL_Event &event)
    {
        if (m_state != STATE_MULTI_TOUCH)
            return;

        if (event.tfinger.fingerID == m_primaryFinger)
        {
            m_f1x = event.tfinger.x;
            m_f1y = event.tfinger.y;
        }
        else if (event.tfinger.fingerID == m_secondaryFinger)
        {
            m_f2x = event.tfinger.x;
            m_f2y = event.tfinger.y;
        }
        else
        {
            return;
        }

        // One finger already lifted: the gesture is winding down, no more zoom/rotation.
        if (!m_primaryActive || !m_secondaryActive)
            return;

        const float w = static_cast<float>(WindowW());
        const float h = static_cast<float>(WindowH());

        const float f1px = m_f1x * w;
        const float f1py = m_f1y * h;
        const float f2px = m_f2x * w;
        const float f2py = m_f2y * h;

        if (m_twoFingerCancelCandidate)
        {
            const float p1dx = f1px - m_twoFingerPrimaryDownX;
            const float p1dy = f1py - m_twoFingerPrimaryDownY;
            const float p2dx = f2px - m_twoFingerSecondaryDownX;
            const float p2dy = f2py - m_twoFingerSecondaryDownY;

            const float p1travel = SDL_sqrtf(p1dx * p1dx + p1dy * p1dy);
            const float p2travel = SDL_sqrtf(p2dx * p2dx + p2dy * p2dy);

            if (p1travel > TWO_FINGER_CANCEL_DISTANCE_PX ||
                p2travel > TWO_FINGER_CANCEL_DISTANCE_PX)
            {
                m_twoFingerMoved = true;
                m_twoFingerCancelCandidate = false;
            }
        }

        const float dx = (m_f1x - m_f2x) * w;
        const float dy = (m_f1y - m_f2y) * h;
        const float distance = SDL_sqrtf(dx * dx + dy * dy);

        // Zoom starts immediately; it has no rotation dead-zone.
        const float distanceDelta = distance - m_lastPinchDistance;
        if (SDL_fabsf(distanceDelta) > 0.000001f)
            ApplyZoom(distanceDelta);

        // atan2f gives the signed angle between the two fingers.
        const float pairAngle = SDL_atan2f(dy, dx);
        const float angleDelta = NormalizeAngle(pairAngle - m_lastPairAngle);

        // Accumulate rotation until the absolute signed angle exceeds 40°.
        // Nothing is sent to the camera before the dead-zone is crossed.
        if (!m_multiRotationActive)
        {
            m_accumulatedRotation += angleDelta;

            if (SDL_fabsf(m_accumulatedRotation) >= ROTATION_DEAD_ZONE_RAD)
            {
                m_multiRotationActive = true;

                // The dead-zone is intentionally consumed. Rotation begins
                // from the current pair angle, preventing an artificial jump.
                m_lastPairAngle = pairAngle;
            }
        }
        else if (SDL_fabsf(angleDelta) > 0.000001f)
        {
            ApplyCameraRotation(angleDelta);
            m_lastPairAngle = pairAngle;
        }

        m_lastPinchDistance = distance;
    }

    bool TwoFingerTapCanCancel() const
    {
        if (!m_twoFingerCancelCandidate ||
            m_twoFingerMoved ||
            m_twoFingerStartTicks == 0)
            return false;

        return SDL_GetTicks() - m_twoFingerStartTicks <= TWO_FINGER_CANCEL_WINDOW_MS;
    }

    void FinishMultiTouch()
    {
        if (m_primaryActive || m_secondaryActive)
            return;

        const bool cancelBuild = TwoFingerTapCanCancel();

        if (cancelBuild)
            CancelBuilding();
        else
            m_state = (m_stateBeforeMultiTouch == STATE_BUILDING &&
                       BuildingActive())
                          ? STATE_BUILDING
                          : STATE_CAMERA_PAN;

        m_multiRotationActive = false;
        m_accumulatedRotation = 0.0f;
        m_twoFingerCancelCandidate = false;
        m_twoFingerMoved = false;
        m_twoFingerStartTicks = 0;
    }

    void OnFingerDown(const SDL_Event &event)
    {
        const float x = ScreenX(event.tfinger.x);
        const float y = ScreenY(event.tfinger.y);

        // A two-finger gesture is still winding down: ignore new contacts.
        if (m_state == STATE_MULTI_TOUCH)
            return;

        if (!m_primaryActive)
        {
            m_primaryFinger = event.tfinger.fingerID;
            m_primaryActive = true;

            m_downX = x;
            m_downY = y;
            m_lastX = x;
            m_lastY = y;
            m_downTicks = SDL_GetTicks();

            m_f1x = event.tfinger.x;
            m_f1y = event.tfinger.y;

            if (BuildingActive())
            {
                // Mode A: the preview was fixed by the previous release.
                // A second tap on that preview confirms construction.
                if (m_buildConfirmationPending &&
                    !m_useHoldToRotate)
                {
                    const float dx = x - m_buildX;
                    const float dy = y - m_buildY;

                    if (SDL_sqrtf(dx * dx + dy * dy) <= BUILD_CONFIRM_DISTANCE_PX)
                    {
                        m_state = STATE_BUILDING;
                        m_buildConfirmTapActive = true;
                        m_downTicks = SDL_GetTicks();
                        return;
                    }
                }

                BeginBuilding(x, y);
                return;
            }

            m_state = STATE_CAMERA_PAN;
            return;
        }

        // Any second distinct finger immediately switches to multi-touch.
        // This is deliberately not delayed and does not depend on finger 0/1
        // numbering, because SDL3 identifies each contact by SDL_FingerID.
        // While the building is being rotated (LMB held) a 2nd finger is ignored:
        // releasing the mouse there would start construction.
        if (!m_secondaryActive &&
            !m_buildRotating &&
            event.tfinger.fingerID != m_primaryFinger)
        {
            StartMultiTouch(event);
        }
    }

    void OnFingerMotion(const SDL_Event &event)
    {
        const float x = ScreenX(event.tfinger.x);
        const float y = ScreenY(event.tfinger.y);

        if (m_state == STATE_MULTI_TOUCH)
        {
            UpdateMultiTouch(event);
            return;
        }

        if (event.tfinger.fingerID != m_primaryFinger ||
            !m_primaryActive)
            return;

        const float dxPixels = x - m_lastX;
        const float dyPixels = y - m_lastY;

        const float totalDx = x - m_downX;
        const float totalDy = y - m_downY;
        const float travel = SDL_sqrtf(totalDx * totalDx + totalDy * totalDy);

        if (m_state == STATE_BUILDING)
        {
            if (m_buildRotating)
            {
                // After the 0.2s hold, the same finger exclusively rotates
                // the building. Camera input remains locked.
                UpdateBuildingRotation(dxPixels);
            }
            else
            {
                // Before rotation, the same finger only moves the building preview.
                // The 0.2s hold timer starts at initial touch and is NOT reset by movement.
                SendMouse(SDL_EVENT_MOUSE_MOTION, x, y, 0, true);
                m_buildX = x;
                m_buildY = y;
            }

            m_lastX = x;
            m_lastY = y;
            return;
        }

        if (m_state == STATE_SELECTION)
        {
            // The selection rectangle follows the finger exactly.
            // No camera operation is permitted in this state.
            SendMouse(SDL_EVENT_MOUSE_MOTION, x, y);

            m_lastX = x;
            m_lastY = y;
            return;
        }

        if (m_state == STATE_CAMERA_PAN)
        {
            // Deliberate movement beyond the drag threshold becomes a native
            // selection-box gesture. A quick movement before the threshold
            // remains a direct camera pan.
            const Uint64 heldMs = SDL_GetTicks() - m_downTicks;

            // A fast swipe remains camera navigation. Once the finger has been
            // held for the short 100ms tap window, crossing the drag threshold
            // becomes the selection-box gesture. This avoids any 0.5s delay.
            if (heldMs >= TAP_MAX_DURATION_MS && travel >= SELECTION_DISTANCE_PX)
            {
                BeginSelection();
                if (m_state == STATE_SELECTION)
                    SendMouse(SDL_EVENT_MOUSE_MOTION, x, y);
            }
            else
            {
                // Strictly linear camera movement from SDL3 tfinger.dx/dy.
                ApplyCameraPan(event.tfinger.dx, event.tfinger.dy);
            }

            m_lastX = x;
            m_lastY = y;
            return;
        }
    }

    void OnFingerUp(const SDL_Event &event)
    {
        const float x = ScreenX(event.tfinger.x);
        const float y = ScreenY(event.tfinger.y);

        if (m_state == STATE_MULTI_TOUCH)
        {
            if (event.tfinger.fingerID == m_primaryFinger)
                m_primaryActive = false;

            if (event.tfinger.fingerID == m_secondaryFinger)
                m_secondaryActive = false;

            FinishMultiTouch();
            return;
        }

        if (event.tfinger.fingerID != m_primaryFinger ||
            !m_primaryActive)
            return;

        if (m_state == STATE_SELECTION)
        {
            SendMouse(SDL_EVENT_MOUSE_BUTTON_UP, x, y, SDL_BUTTON_LEFT);
            m_selectionMouseDown = false;
            m_primaryActive = false;
            m_state = STATE_CAMERA_PAN;
            return;
        }

        if (m_state == STATE_BUILDING)
        {
            const Uint64 heldMs = SDL_GetTicks() - m_downTicks;
            const float dx = x - m_buildX;
            const float dy = y - m_buildY;
            const float travel = SDL_sqrtf(dx * dx + dy * dy);

            if (m_useHoldToRotate)
            {
                // 0.2s is ONLY the hold threshold for entering rotation.
                // Releasing before the threshold always builds at the current
                // preview position. There is no separate movement window.
                if (m_buildRotating)
                {
                    ConfirmBuilding();
                }
                else
                {
                    ConfirmBuilding();
                }
            }
            else
            {
                // Mode A: simple tap/release immediately builds.
                ConfirmBuilding();
            }

            m_primaryActive = false;
            m_buildRotating = false;
            m_buildHoldStartTicks = 0;
            m_state = STATE_CAMERA_PAN;
            return;
        }

        const float totalDx = x - m_downX;
        const float totalDy = y - m_downY;
        const float travel = SDL_sqrtf(totalDx * totalDx + totalDy * totalDy);
        const Uint64 heldMs = SDL_GetTicks() - m_downTicks;

        // Fast single tap: immediately feed a single mouse click to the native
        // selection/raycast path. There is no 0.5s hold delay.
        if (travel <= TAP_MAX_DISTANCE_PX &&
            heldMs <= TAP_MAX_DURATION_MS)
        {
            SendMouse(SDL_EVENT_MOUSE_MOTION, x, y);
            SendMouse(SDL_EVENT_MOUSE_BUTTON_DOWN, x, y, SDL_BUTTON_LEFT);
            SendMouse(SDL_EVENT_MOUSE_BUTTON_UP, x, y, SDL_BUTTON_LEFT);
        }

        m_primaryActive = false;
        m_state = STATE_CAMERA_PAN;
    }
};

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
	s_mobileInput.SetBuildConfirmationMode(true);    // Automatic A/B: tap builds, 0.2s hold rotates then release builds
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
