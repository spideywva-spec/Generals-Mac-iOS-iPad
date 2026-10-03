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
#include "GameClient/CommandXlat.h"
#include "GameClient/SelectionXlat.h"
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

    void SetWindow(SDL_Window *window) { m_window = window; }

    void Reset()
    {
        ReleaseSelectionMouse();
        m_fingers[0] = Finger();
        m_fingers[1] = Finger();
        m_state = STATE_CAMERA_PAN;
        m_stateBeforeMulti = STATE_CAMERA_PAN;
        m_selectionFinger = -1;
        m_buildFixed = false;
        m_buildConfirm = false;
        m_buildRotating = false;
        m_buildHoldStart = 0;
        m_buildX = m_buildY = 0.0f;
        m_buildRotation = 0.0f;
        m_multiA = m_multiB = -1;
        m_multiStartTicks = 0;
        m_multiMoved = false;
        m_lastPinchDistance = 0.0f;
        m_lastPairAngle = 0.0f;
        m_multiAccumulatedRotation = 0.0f;
        m_multiRotationActive = false;
    }

    void ProcessEvent(const SDL_Event &event)
    {
        if (!m_window) return;
        switch (event.type)
        {
            case SDL_EVENT_FINGER_DOWN: FingerDown(event); break;
            case SDL_EVENT_FINGER_MOTION: FingerMotion(event); break;
            case SDL_EVENT_FINGER_UP: FingerUp(event, false); break;
            case SDL_EVENT_FINGER_CANCELED: FingerUp(event, true); break;
            default: break;
        }
    }

    void Update()
    {
        const Uint64 now = SDL_GetTicks();

        // A finger held still for 0.1s becomes selection mode.
        // If it moved before that point, it remains a camera swipe.
        if (m_state == STATE_CAMERA_PAN &&
            ActiveFingerCount() == 1 &&
            m_fingers[0].active &&
            now - m_fingers[0].downTicks > SELECTION_HOLD_MS &&
            m_fingers[0].travelPixels <= SELECTION_START_TRAVEL_PX)
        {
            BeginSelection(0);
        }

        // Building rotation is the only timed building transition.
        if (m_state == STATE_BUILDING &&
            m_buildFixed &&
            m_buildConfirm &&
            !m_buildRotating &&
            m_buildHoldStart != 0 &&
            now - m_buildHoldStart >= BUILD_ROTATE_HOLD_MS)
        {
            BeginBuildingRotation();
        }
    }

private:
    struct Finger
    {
        SDL_FingerID id = 0;
        bool active = false;
        float xPixels = 0.0f;
        float yPixels = 0.0f;
        float downXPixels = 0.0f;
        float downYPixels = 0.0f;
        float lastXPixels = 0.0f;
        float lastYPixels = 0.0f;
        float travelPixels = 0.0f;
        Uint64 downTicks = 0;
    };

    static constexpr Uint64 SELECTION_HOLD_MS = 100;
    static constexpr Uint64 BUILD_ROTATE_HOLD_MS = 200;
    static constexpr Uint64 TWO_FINGER_TAP_MS = 150;

    static constexpr float SELECTION_START_TRAVEL_PX = 20.0f;
    static constexpr float TAP_MAX_TRAVEL_PX = 12.0f;
    static constexpr float TWO_FINGER_TAP_TRAVEL_PX = 15.0f;
    static constexpr float BUILD_TAP_RADIUS_PX = 30.0f;
    static constexpr float ROTATION_DEAD_ZONE = 0.6981317008f;
    static constexpr float MOBILE_PI = 3.14159265358979323846f;
    static constexpr float MOBILE_TWO_PI = 6.28318530717958647692f;

    State m_state = STATE_CAMERA_PAN;
    State m_stateBeforeMulti = STATE_CAMERA_PAN;
    SDL_Window *m_window = nullptr;
    Finger m_fingers[2];

    int m_selectionFinger = -1;
    bool m_selectionMouseDown = false;

    bool m_buildFixed = false;
    bool m_buildConfirm = false;
    bool m_buildRotating = false;
    Uint64 m_buildHoldStart = 0;
    float m_buildX = 0.0f;
    float m_buildY = 0.0f;
    float m_buildRotation = 0.0f;

    int m_multiA = -1;
    int m_multiB = -1;
    Uint64 m_multiStartTicks = 0;
    bool m_multiMoved = false;
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
        int w = 1, h = 1;
        if (m_window) SDL_GetWindowSizeInPixels(m_window, &w, &h);
        return w > 0 ? w : 1;
    }

    int WindowH() const
    {
        int w = 1, h = 1;
        if (m_window) SDL_GetWindowSizeInPixels(m_window, &w, &h);
        return h > 0 ? h : 1;
    }

    float XPixels(float v) const { return v * static_cast<float>(WindowW()); }
    float YPixels(float v) const { return v * static_cast<float>(WindowH()); }
    float DXPixels(float v) const { return v * static_cast<float>(WindowW()); }
    float DYPixels(float v) const { return v * static_cast<float>(WindowH()); }

    static float NormalizeAngle(float a)
    {
        while (a > MOBILE_PI) a -= MOBILE_TWO_PI;
        while (a < -MOBILE_PI) a += MOBILE_TWO_PI;
        return a;
    }

    static float DistancePixels(float x1, float y1, float x2, float y2)
    {
        const float dx = x2 - x1, dy = y2 - y1;
        return SDL_sqrtf(dx * dx + dy * dy);
    }

    static float PairAngle(float x1, float y1, float x2, float y2)
    {
        return SDL_atan2f(y2 - y1, x2 - x1);
    }

    int FindFinger(SDL_FingerID id) const
    {
        for (int i = 0; i < 2; ++i)
            if (m_fingers[i].active && m_fingers[i].id == id) return i;
        return -1;
    }

    int FindFreeFinger() const
    {
        for (int i = 0; i < 2; ++i)
            if (!m_fingers[i].active) return i;
        return -1;
    }

    int ActiveFingerCount() const
    {
        int n = 0;
        for (int i = 0; i < 2; ++i)
            if (m_fingers[i].active) ++n;
        return n;
    }

    bool BuildingPending() const
    {
        return TheInGameUI && TheInGameUI->getPendingPlaceType() != nullptr;
    }

    bool IsNearFixedBuilding(float x, float y) const
    {
        return m_buildFixed &&
            DistancePixels(x, y, m_buildX, m_buildY) <= BUILD_TAP_RADIUS_PX;
    }

    void LockCamera()
    {
        if (TheTacticalView) TheTacticalView->setMouseLock(TRUE);
    }

    void UnlockCamera()
    {
        if (TheTacticalView) TheTacticalView->setMouseLock(FALSE);
    }

    void SendMouseMotion(float x, float y, float dx = 0.0f, float dy = 0.0f)
    {
        SDL3Mouse *mouse = Mouse();
        if (!mouse) return;

        SDL_Event e;
        SDL_zero(e);
        e.type = SDL_EVENT_MOUSE_MOTION;
        e.motion.windowID = SDL_GetWindowID(m_window);
        e.motion.which = 0;
        e.motion.x = x;
        e.motion.y = y;
        e.motion.xrel = dx;
        e.motion.yrel = dy;
        mouse->addSDLEvent(&e);
    }

    void SendMouseButton(Uint32 type, float x, float y, Uint8 button = SDL_BUTTON_LEFT)
    {
        SDL3Mouse *mouse = Mouse();
        if (!mouse) return;

        SDL_Event e;
        SDL_zero(e);
        e.type = type;
        e.button.windowID = SDL_GetWindowID(m_window);
        e.button.which = 0;
        e.button.button = button;
        e.button.down = (type == SDL_EVENT_MOUSE_BUTTON_DOWN);
        e.button.clicks = 1;
        e.button.x = x;
        e.button.y = y;
        mouse->addSDLEvent(&e);
    }

    void ReleaseSelectionMouse()
    {
        if (!m_selectionMouseDown) return;

        int index = m_selectionFinger;
        if (index < 0 || index >= 2 || !m_fingers[index].active)
            index = 0;

        SendMouseButton(SDL_EVENT_MOUSE_BUTTON_UP,
                        m_fingers[index].xPixels,
                        m_fingers[index].yPixels);

        m_selectionMouseDown = false;
        m_selectionFinger = -1;
        if (TheInGameUI) TheInGameUI->setSelecting(FALSE);
    }

    // MYSOREZ reference architecture: move the map by projecting the
    // previous/current finger positions onto the terrain. This keeps the
    // finger-to-ground relationship exact at every zoom/camera angle instead
    // of guessing a pixels->world multiplier.
    void ApplyCameraPan(float fromX, float fromY, float toX, float toY)
    {
        if (m_state != STATE_CAMERA_PAN || !TheTacticalView)
            return;

        if (TheShell && TheShell->isShellActive())
            return;

        ICoord2D from;
        from.x = static_cast<Int>(fromX);
        from.y = static_cast<Int>(fromY);

        ICoord2D to;
        to.x = static_cast<Int>(toX);
        to.y = static_cast<Int>(toY);

        Coord3D worldFrom;
        Coord3D worldTo;
        if (!TheTacticalView->screenToTerrain(&from, &worldFrom) ||
            !TheTacticalView->screenToTerrain(&to, &worldTo))
            return;

        Coord3D pos = TheTacticalView->getPosition();
        pos.x += worldFrom.x - worldTo.x;
        pos.y += worldFrom.y - worldTo.y;
        TheTacticalView->userSetPosition(pos);
        TheTacticalView->forceRedraw();
    }

    void HandleTap(float x, float y)
    {
        if (!TheTacticalView || !TheInGameUI)
            return;

        ICoord2D pixel;
        pixel.x = static_cast<Int>(x);
        pixel.y = static_cast<Int>(y);

        // Armed abilities/special powers own the tap.
        if (TheInGameUI->getGUICommand() != nullptr)
        {
            Coord3D pos;
            if (TheTacticalView->screenToTerrain(&pixel, &pos) && TheGameClient)
                TheGameClient->evaluateContextCommand(nullptr, &pos,
                    CommandTranslator::DO_COMMAND);
            return;
        }

        Coord3D pos;
        const Bool onTerrain = TheTacticalView->screenToTerrain(&pixel, &pos);
        Drawable *picked = TheTacticalView->pickDrawable(
            &pixel, FALSE, PICK_TYPE_SELECTABLE);

        if (picked && picked->getObject() &&
            picked->getObject()->isLocallyControlled())
        {
            TheInGameUI->deselectAllDrawables();
            TheInGameUI->selectDrawable(picked);
            return;
        }

        if (onTerrain && TheInGameUI->areSelectedObjectsControllable() && TheGameClient)
        {
            TheGameClient->evaluateContextCommand(picked, &pos,
                CommandTranslator::DO_COMMAND);
            return;
        }

        if (!picked)
            TheInGameUI->deselectAllDrawables();
    }

    void BeginSelection(int index)
    {
        if (m_state != STATE_CAMERA_PAN || index < 0 || !m_fingers[index].active)
            return;

        m_state = STATE_SELECTION;
        m_selectionFinger = index;
        LockCamera();

        if (TheInGameUI) TheInGameUI->setSelecting(TRUE);

        const Finger &f = m_fingers[index];
        SendMouseMotion(f.downXPixels, f.downYPixels);
        SendMouseButton(SDL_EVENT_MOUSE_BUTTON_DOWN,
                        f.downXPixels, f.downYPixels);
        m_selectionMouseDown = true;
    }

    void StartBuildingPreview(float x, float y)
    {
        m_state = STATE_BUILDING;
        m_buildFixed = false;
        m_buildConfirm = false;
        m_buildRotating = false;
        m_buildHoldStart = 0;
        m_buildX = x;
        m_buildY = y;
        LockCamera();
        SendMouseMotion(x, y);
    }

    void FixBuildingPreview(float x, float y)
    {
        m_buildX = x;
        m_buildY = y;
        m_buildFixed = true;
        m_buildConfirm = false;
        m_buildRotating = false;
        m_buildHoldStart = 0;

        LockCamera();

        if (TheInGameUI)
        {
            ICoord2D point;
            point.x = static_cast<Int>(x);
            point.y = static_cast<Int>(y);
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
        if (m_state != STATE_BUILDING || !m_buildFixed ||
            !m_buildConfirm || m_buildRotating) return;

        m_buildRotating = true;
        m_buildHoldStart = 0;
        m_buildRotation = TheInGameUI ? TheInGameUI->getPlacementAngle() : 0.0f;
        LockCamera();
    }

    void UpdateBuildingRotation(float dxPixels)
    {
        if (!m_buildRotating || !TheInGameUI) return;

        // Map horizontal finger travel to a full turn using the actual
        // physical width. There is no arbitrary speed coefficient.
        m_buildRotation = NormalizeAngle(
            m_buildRotation +
            dxPixels * MOBILE_TWO_PI / static_cast<float>(WindowW()));

        ICoord2D start;
        start.x = static_cast<Int>(m_buildX);
        start.y = static_cast<Int>(m_buildY);

        const float radius =
            static_cast<float>(WindowW() < WindowH() ? WindowW() : WindowH()) * 0.10f;

        ICoord2D end;
        end.x = start.x + static_cast<Int>(SDL_cosf(m_buildRotation) * radius);
        end.y = start.y + static_cast<Int>(SDL_sinf(m_buildRotation) * radius);

        TheInGameUI->setPlacementStart(&start);
        TheInGameUI->setPlacementEnd(&end);
    }

    void BuildNow()
    {
        if (m_state != STATE_BUILDING || !m_buildFixed) return;

        SendMouseMotion(m_buildX, m_buildY);
        SendMouseButton(SDL_EVENT_MOUSE_BUTTON_DOWN, m_buildX, m_buildY);
        SendMouseButton(SDL_EVENT_MOUSE_BUTTON_UP, m_buildX, m_buildY);

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
        int first = -1, second = -1;
        for (int i = 0; i < 2; ++i)
        {
            if (!m_fingers[i].active) continue;
            if (first < 0) first = i;
            else { second = i; break; }
        }
        if (first < 0 || second < 0) return;

        m_multiA = first;
        m_multiB = second;

        if (m_state == STATE_SELECTION)
        {
            ReleaseSelectionMouse();
            m_stateBeforeMulti = STATE_CAMERA_PAN;
        }
        else
        {
            m_stateBeforeMulti = m_state;
        }

        // A second finger always freezes the one-finger gesture immediately.
        m_state = STATE_MULTI_TOUCH;
        m_multiStartTicks = SDL_GetTicks();
        m_multiMoved = false;

        const float x1 = m_fingers[first].xPixels;
        const float y1 = m_fingers[first].yPixels;
        const float x2 = m_fingers[second].xPixels;
        const float y2 = m_fingers[second].yPixels;

        m_lastPinchDistance = DistancePixels(x1, y1, x2, y2);
        m_lastPairAngle = PairAngle(x1, y1, x2, y2);
        m_multiAccumulatedRotation = 0.0f;
        m_multiRotationActive = false;
        // No mouse lock here: two-finger gestures own the camera.
    }

    void MultiTouchMotion(const SDL_Event &event)
    {
        const int index = FindFinger(event.tfinger.fingerID);
        if (index < 0 || m_multiA < 0 || m_multiB < 0) return;

        const float dx = DXPixels(event.tfinger.dx);
        const float dy = DYPixels(event.tfinger.dy);

        Finger &f = m_fingers[index];
        f.xPixels = XPixels(event.tfinger.x);
        f.yPixels = YPixels(event.tfinger.y);
        f.travelPixels += DistancePixels(0.0f, 0.0f, dx, dy);

        if (f.travelPixels >= TWO_FINGER_TAP_TRAVEL_PX)
            m_multiMoved = true;

        const Finger &a = m_fingers[m_multiA];
        const Finger &b = m_fingers[m_multiB];

        const float pairDX = b.xPixels - a.xPixels;
        const float pairDY = b.yPixels - a.yPixels;
        const float distance = SDL_sqrtf(pairDX * pairDX + pairDY * pairDY);
        const float angle = SDL_atan2f(pairDY, pairDX);

        // Exact pinch delta in physical pixels, normalized only by screen
        // width as requested. No arbitrary zoom gain/divisor.
        const float pinchDelta = distance - m_lastPinchDistance;
        if (pinchDelta != 0.0f && TheTacticalView)
            TheTacticalView->userZoom(
                -pinchDelta / static_cast<float>(WindowW()));

        const float angleDelta = NormalizeAngle(angle - m_lastPairAngle);
        m_multiAccumulatedRotation += angleDelta;

        if (!m_multiRotationActive)
        {
            if (SDL_fabsf(m_multiAccumulatedRotation) > ROTATION_DEAD_ZONE)
            {
                m_multiRotationActive = true;
                const float sign = m_multiAccumulatedRotation >= 0.0f ? 1.0f : -1.0f;
                const float excess = SDL_fabsf(m_multiAccumulatedRotation) - ROTATION_DEAD_ZONE;
                if (excess > 0.0f && TheTacticalView)
                    TheTacticalView->userSetAngle(
                        NormalizeAngle(TheTacticalView->getAngle() + sign * excess));
            }
        }
        else if (angleDelta != 0.0f && TheTacticalView)
        {
            TheTacticalView->userSetAngle(
                NormalizeAngle(TheTacticalView->getAngle() + angleDelta));
        }

        f.lastXPixels = f.xPixels;
        f.lastYPixels = f.yPixels;
        m_lastPinchDistance = distance;
        m_lastPairAngle = angle;
    }

    void FinishMultiTouch()
    {
        if (ActiveFingerCount() != 0) return;

        const Uint64 firstDown =
            m_fingers[m_multiA].downTicks < m_fingers[m_multiB].downTicks ?
            m_fingers[m_multiA].downTicks : m_fingers[m_multiB].downTicks;

        const Uint64 duration = SDL_GetTicks() - firstDown;
        const bool shortTap =
            duration <= TWO_FINGER_TAP_MS &&
            !m_multiMoved &&
            m_fingers[m_multiA].travelPixels < TWO_FINGER_TAP_TRAVEL_PX &&
            m_fingers[m_multiB].travelPixels < TWO_FINGER_TAP_TRAVEL_PX;

        if (shortTap)
        {
            // Two-finger tap is the mobile equivalent of RMB: cancel
            // building/selection/action, or send an actual right-click.
            if (m_stateBeforeMulti == STATE_BUILDING && BuildingPending())
                CancelBuilding();
            else
            {
                const float x = (m_fingers[m_multiA].xPixels + m_fingers[m_multiB].xPixels) * 0.5f;
                const float y = (m_fingers[m_multiA].yPixels + m_fingers[m_multiB].yPixels) * 0.5f;
                SendMouseMotion(x, y);
                SendMouseButton(SDL_EVENT_MOUSE_BUTTON_DOWN, x, y, SDL_BUTTON_RIGHT);
                SendMouseButton(SDL_EVENT_MOUSE_BUTTON_UP, x, y, SDL_BUTTON_RIGHT);
                m_state = STATE_CAMERA_PAN;
                UnlockCamera();
            }
        }
        else
        {
            m_state = m_stateBeforeMulti;
            if (m_state == STATE_BUILDING) LockCamera();
            else UnlockCamera();
        }

        m_multiA = m_multiB = -1;
        m_multiStartTicks = 0;
        m_multiMoved = false;
        m_lastPinchDistance = 0.0f;
        m_lastPairAngle = 0.0f;
        m_multiAccumulatedRotation = 0.0f;
        m_multiRotationActive = false;
    }

    void FingerDown(const SDL_Event &event)
    {
        if (FindFinger(event.tfinger.fingerID) >= 0) return;
        const int slot = FindFreeFinger();
        if (slot < 0) return;

        Finger &f = m_fingers[slot];
        f = Finger();
        f.id = event.tfinger.fingerID;
        f.active = true;
        f.xPixels = XPixels(event.tfinger.x);
        f.yPixels = YPixels(event.tfinger.y);
        f.downXPixels = f.xPixels;
        f.downYPixels = f.yPixels;
        f.lastXPixels = f.xPixels;
        f.lastYPixels = f.yPixels;
        f.downTicks = SDL_GetTicks();

        if (ActiveFingerCount() >= 2)
        {
            StartMultiTouch();
            return;
        }

        if (BuildingPending())
        {
            if (m_buildFixed)
            {
                if (IsNearFixedBuilding(f.xPixels, f.yPixels))
                    StartBuildingConfirmation();
                else
                {
                    m_state = STATE_BUILDING;
                    LockCamera();
                }
            }
            else
                StartBuildingPreview(f.xPixels, f.yPixels);
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
        if (index < 0) return;

        Finger &f = m_fingers[index];
        const float dx = DXPixels(event.tfinger.dx);
        const float dy = DYPixels(event.tfinger.dy);
        const float x = XPixels(event.tfinger.x);
        const float y = YPixels(event.tfinger.y);

        f.xPixels = x;
        f.yPixels = y;
        f.travelPixels += DistancePixels(0.0f, 0.0f, dx, dy);

        if (m_state == STATE_BUILDING)
        {
            if (!m_buildFixed)
            {
                m_buildX = x;
                m_buildY = y;
                LockCamera();
                SendMouseMotion(x, y, dx, dy);
            }
            else if (m_buildConfirm && m_buildRotating)
            {
                UpdateBuildingRotation(dx);
            }

            f.lastXPixels = x;
            f.lastYPixels = y;
            return;
        }

        if (m_state == STATE_SELECTION)
        {
            LockCamera();
            SendMouseMotion(x, y, dx, dy);
            f.lastXPixels = x;
            f.lastYPixels = y;
            return;
        }

        if (m_state == STATE_CAMERA_PAN)
        {
            // Before the 0.1s hold is established, movement is a pure
            // finger-driven camera swipe.
            if (SDL_GetTicks() - f.downTicks <= SELECTION_HOLD_MS ||
                f.travelPixels > SELECTION_START_TRAVEL_PX)
            {
                ApplyCameraPan(f.lastXPixels, f.lastYPixels, x, y);
            }
        }

        f.lastXPixels = x;
        f.lastYPixels = y;
    }

    void FingerUp(const SDL_Event &event, bool canceled)
    {
        const int index = FindFinger(event.tfinger.fingerID);
        if (index < 0) return;

        Finger &f = m_fingers[index];
        const float x = XPixels(event.tfinger.x);
        const float y = YPixels(event.tfinger.y);
        const float dx = x - f.lastXPixels;
        const float dy = y - f.lastYPixels;
        const Uint64 held = SDL_GetTicks() - f.downTicks;

        f.xPixels = x;
        f.yPixels = y;

        if (m_state == STATE_MULTI_TOUCH)
        {
            if (canceled) m_multiMoved = true;
            f.active = false;
            FinishMultiTouch();
            return;
        }

        if (m_state == STATE_SELECTION && m_selectionFinger == index)
        {
            SendMouseMotion(x, y, dx, dy);
            SendMouseButton(SDL_EVENT_MOUSE_BUTTON_UP, x, y);
            m_selectionMouseDown = false;
            m_selectionFinger = -1;
            if (TheInGameUI) TheInGameUI->setSelecting(FALSE);
            f.active = false;
            m_state = STATE_CAMERA_PAN;
            UnlockCamera();
            return;
        }

        if (m_state == STATE_BUILDING)
        {
            if (!m_buildFixed)
            {
                FixBuildingPreview(x, y);
            }
            else if (m_buildConfirm)
            {
                BuildNow();
            }
            f.active = false;
            return;
        }

        // MYSOREZ-style native battlefield tap: resolve selection/order
        // directly from the finger position instead of synthesizing a mouse.
        if (!canceled &&
            held < SELECTION_HOLD_MS &&
            f.travelPixels <= TAP_MAX_TRAVEL_PX)
        {
            HandleTap(x, y);
        }

        f.active = false;
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
