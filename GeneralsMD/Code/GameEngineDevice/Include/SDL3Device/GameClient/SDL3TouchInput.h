#pragma once

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

#include <SDL3/SDL.h>
#include "GameClient/GameWindowManager.h"
#include "GameClient/InGameUI.h"
#include "GameClient/View.h"

class TouchInput
{
public:
    static TouchInput &instance();

    void setWindow(SDL_Window *w);
    void processEvent(const SDL_Event &e);
    void update();

private:
    TouchInput() = default;
    TouchInput(const TouchInput &) = delete;
    TouchInput &operator=(const TouchInput &) = delete;

    enum State {
        IDLE,
        PAN,
        MOMENTUM,
        SELECTING,
        PLACING,
        ROTATING,
        TWO_FINGER
    };

    static constexpr Uint64 TAP_MS            = 200;
    static constexpr Uint64 DOUBLE_TAP_MS     = 350;
    static constexpr Uint64 SELECT_HOLD_MS    = 100;
    static constexpr Uint64 BUILD_HOLD_MS     = 200;
    static constexpr Uint64 TWO_TAP_MS        = 150;

    static constexpr float  TAP_DEAD_PX       = 16.0f;
    static constexpr float  SELECT_DEAD_PX    = 16.0f;
    static constexpr float  TWO_TAP_DEAD_PX   = 12.0f;
    static constexpr float  BUILD_ROT_RAD_PX  = 0.006f;
    static constexpr float  PINCH_ZOOM_SCALE  = 0.05f;
    static constexpr float  MOMENTUM_FRICTION = 0.92f;
    static constexpr float  MOMENTUM_MIN_VEL  = 0.4f;

    SDL_Window  *m_window = nullptr;
    State        m_state  = IDLE;
    State        m_stateBeforeTwo = IDLE;

    SDL_FingerID m_primary = 0;
    bool         m_primaryActive = false;
    float        m_downX = 0, m_downY = 0;
    float        m_lastX = 0, m_lastY = 0;
    Uint64       m_downTicks = 0;

    SDL_FingerID m_secondary = 0;
    bool         m_secondaryActive = false;
    float        m_f1x = 0, m_f1y = 0;
    float        m_f2x = 0, m_f2y = 0;
    float        m_lastPinchDist = 0;

    float        m_velX = 0, m_velY = 0;

    Uint64       m_lastTapTicks = 0;
    float        m_lastTapX = 0, m_lastTapY = 0;
    bool         m_hasLastTap = false;

    Uint64       m_twoStartTicks = 0;
    bool         m_twoMoved = false;
    float        m_twoDownX1 = 0, m_twoDownY1 = 0;
    float        m_twoDownX2 = 0, m_twoDownY2 = 0;

    bool         m_leftHeld = false;

    float        m_buildX = 0, m_buildY = 0;
    float        m_buildRot = 0;
    float        m_buildLastRotX = 0;
    Uint64       m_buildHoldTicks = 0;
    bool         m_buildFixed = false;

    int   W() const { int w=1,h=1; SDL_GetWindowSize(m_window,&w,&h); return w>0?w:1; }
    int   H() const { int w=1,h=1; SDL_GetWindowSize(m_window,&w,&h); return h>0?h:1; }
    float SX(float n) const { return n * float(W()); }
    float SY(float n) const { return n * float(H()); }

    bool buildingActive() const;
    void sendMotion(float x, float y);
    void sendButton(Uint32 type, float x, float y, Uint8 btn, Uint8 clicks = 1);
    void sendClick(float x, float y, Uint8 clicks = 1);

    void applyPan(float dxPx, float dyPx);
    void applyZoom(float distDeltaPx);
    void cancelOrDeselect();

    void beginSelect();
    void beginPlace(float x, float y);
    void fixPreview();
    void beginRotate();
    void updateRotate(float x, float y);
    void buildNow();

    void startTwo(const SDL_Event &e);
    void updateTwo(const SDL_Event &e);
    void finishTwo();

    void onDown(const SDL_Event &e);
    void onMove(const SDL_Event &e);
    void onUp(const SDL_Event &e);
};

#endif // TARGET_OS_IPHONE