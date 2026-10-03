#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

#include "SDL3TouchInput.h"
#include "SDL3Device/GameClient/SDL3Mouse.h"
#include "GameClient/Mouse.h"
#include <cstdio>
#include <cmath>

extern Mouse *TheMouse;

TouchInput &TouchInput::instance() { static TouchInput s; return s; }
void TouchInput::setWindow(SDL_Window *w) { m_window = w; }

bool TouchInput::buildingActive() const
{
    return TheInGameUI && TheInGameUI->getPendingPlaceType() != nullptr;
}

void TouchInput::sendMotion(float x, float y)
{
    auto *m = TheMouse ? dynamic_cast<SDL3Mouse*>(TheMouse) : nullptr;
    if (!m) return;
    SDL_Event e; SDL_zero(e);
    e.type = SDL_EVENT_MOUSE_MOTION;
    e.motion.windowID = SDL_GetWindowID(m_window);
    e.motion.x = x; e.motion.y = y;
    e.motion.xrel = x - m_lastX;
    e.motion.yrel = y - m_lastY;
    m->addSDLEvent(&e);
}

void TouchInput::sendButton(Uint32 type, float x, float y, Uint8 btn, Uint8 clicks)
{
    auto *m = TheMouse ? dynamic_cast<SDL3Mouse*>(TheMouse) : nullptr;
    if (!m) return;
    SDL_Event e; SDL_zero(e);
    e.type = type;
    e.button.windowID = SDL_GetWindowID(m_window);
    e.button.button = btn;
    e.button.down   = (type == SDL_EVENT_MOUSE_BUTTON_DOWN);
    e.button.clicks = clicks;
    e.button.x = x; e.button.y = y;
    m->addSDLEvent(&e);
    if (btn == SDL_BUTTON_LEFT)
        m_leftHeld = (type == SDL_EVENT_MOUSE_BUTTON_DOWN);
}

void TouchInput::sendClick(float x, float y, Uint8 clicks)
{
    sendMotion(x, y);
    sendButton(SDL_EVENT_MOUSE_BUTTON_DOWN, x, y, SDL_BUTTON_LEFT, clicks);
    sendButton(SDL_EVENT_MOUSE_BUTTON_UP,   x, y, SDL_BUTTON_LEFT, clicks);
}

void TouchInput::applyPan(float dxPx, float dyPx)
{
    if (!TheTacticalView) return;

    ICoord2D a, b;
    a.x = int(m_lastX);              a.y = int(m_lastY);
    b.x = int(m_lastX + dxPx);       b.y = int(m_lastY + dyPx);

    Coord3D wa, wb;
    Bool oa = TheTacticalView->screenToTerrain(&a, &wa);
    Bool ob = TheTacticalView->screenToTerrain(&b, &wb);

    Coord2D delta;
    if (oa && ob) { delta.x = wa.x - wb.x; delta.y = wa.y - wb.y; }
    else          { delta.x = -dxPx * 0.5f; delta.y = -dyPx * 0.5f; }

    TheTacticalView->userScrollBy(&delta);
}

void TouchInput::applyZoom(float distDeltaPx)
{
    if (m_state != TWO_FINGER || !TheTacticalView) return;
    TheTacticalView->userZoom(-distDeltaPx * PINCH_ZOOM_SCALE);
}

void TouchInput::cancelOrDeselect()
{
    const float cx = W() * 0.5f;
    const float cy = H() * 0.5f;

    if (buildingActive() && TheInGameUI) {
        TheInGameUI->placeBuildAvailable(nullptr, nullptr);
        TheInGameUI->setScrolling(FALSE);
    }
    sendMotion(cx, cy);
    sendButton(SDL_EVENT_MOUSE_BUTTON_DOWN, cx, cy, SDL_BUTTON_RIGHT);
    sendButton(SDL_EVENT_MOUSE_BUTTON_UP,   cx, cy, SDL_BUTTON_RIGHT);
}

void TouchInput::beginSelect()
{
    sendMotion(m_downX, m_downY);
    sendButton(SDL_EVENT_MOUSE_BUTTON_DOWN, m_downX, m_downY, SDL_BUTTON_LEFT);
    m_state = SELECTING;
}

void TouchInput::beginPlace(float x, float y)
{
    m_state = PLACING;
    m_buildFixed = false;
    m_buildHoldTicks = 0;
    m_buildX = x; m_buildY = y;
    sendMotion(x, y);
}

void TouchInput::fixPreview()
{
    m_buildFixed = true;
    m_buildHoldTicks = SDL_GetTicks();
}

void TouchInput::beginRotate()
{
    if (m_state != PLACING || !TheInGameUI) return;
    m_state = ROTATING;
    m_buildLastRotX = m_lastX;
    m_buildRot = float(TheInGameUI->getPlacementAngle());
    ICoord2D a{ int(m_buildX), int(m_buildY) };
    TheInGameUI->setPlacementStart(&a);
}

void TouchInput::updateRotate(float x, float)
{
    if (m_state != ROTATING || !TheInGameUI) return;
    const float dx = x - m_buildLastRotX;
    m_buildLastRotX = x;
    m_buildRot += dx * BUILD_ROT_RAD_PX;

    ICoord2D s{ int(m_buildX), int(m_buildY) };
    ICoord2D e{ int(m_buildX + SDL_cosf(m_buildRot) * 64.0f),
                int(m_buildY + SDL_sinf(m_buildRot) * 64.0f) };
    TheInGameUI->setPlacementStart(&s);
    TheInGameUI->setPlacementEnd(&e);
}

void TouchInput::buildNow()
{
    sendClick(m_buildX, m_buildY);
    m_buildFixed = false;
    m_buildHoldTicks = 0;
    m_state = IDLE;
}

void TouchInput::startTwo(const SDL_Event &e)
{
    if (m_leftHeld) {
        sendButton(SDL_EVENT_MOUSE_BUTTON_UP, m_lastX, m_lastY, SDL_BUTTON_LEFT);
        m_leftHeld = false;
    }
    m_stateBeforeTwo = m_state;
    m_secondary = e.tfinger.fingerID;
    m_secondaryActive = true;

    m_f1x = m_lastX / float(W());
    m_f1y = m_lastY / float(H());
    m_f2x = e.tfinger.x;
    m_f2y = e.tfinger.y;

    const float dx = (m_f1x - m_f2x) * W();
    const float dy = (m_f1y - m_f2y) * H();
    m_lastPinchDist = SDL_sqrtf(dx*dx + dy*dy);

    m_twoStartTicks = SDL_GetTicks();
    m_twoMoved = false;
    m_twoDownX1 = m_f1x * W(); m_twoDownY1 = m_f1y * H();
    m_twoDownX2 = m_f2x * W(); m_twoDownY2 = m_f2y * H();

    m_state = TWO_FINGER;
}

void TouchInput::updateTwo(const SDL_Event &e)
{
    if (e.tfinger.fingerID == m_primary)         { m_f1x = e.tfinger.x; m_f1y = e.tfinger.y; }
    else if (e.tfinger.fingerID == m_secondary)  { m_f2x = e.tfinger.x; m_f2y = e.tfinger.y; }
    else return;

    const float w = float(W()), h = float(H());
    const float f1px = m_f1x * w, f1py = m_f1y * h;
    const float f2px = m_f2x * w, f2py = m_f2y * h;

    if (!m_twoMoved) {
        const float d1x = f1px - m_twoDownX1, d1y = f1py - m_twoDownY1;
        const float d2x = f2px - m_twoDownX2, d2y = f2py - m_twoDownY2;
        if (SDL_sqrtf(d1x*d1x + d1y*d1y) > TWO_TAP_DEAD_PX ||
            SDL_sqrtf(d2x*d2x + d2y*d2y) > TWO_TAP_DEAD_PX)
            m_twoMoved = true;
    }

    const float dx = (m_f1x - m_f2x) * w;
    const float dy = (m_f1y - m_f2y) * h;
    const float dist = SDL_sqrtf(dx*dx + dy*dy);

    const float d = dist - m_lastPinchDist;
    if (SDL_fabsf(d) > 1e-6f) applyZoom(d);
    m_lastPinchDist = dist;
}

void TouchInput::finishTwo()
{
    if (m_primaryActive || m_secondaryActive) return;

    const bool tap = !m_twoMoved &&
                     m_twoStartTicks &&
                     (SDL_GetTicks() - m_twoStartTicks) <= TWO_TAP_MS;
    if (tap) cancelOrDeselect();

    m_twoStartTicks = 0;
    m_twoMoved = false;

    if (m_stateBeforeTwo == PLACING && buildingActive())
        m_state = PLACING;
    else
        m_state = IDLE;
}

void TouchInput::onDown(const SDL_Event &e)
{
    const float x = SX(e.tfinger.x);
    const float y = SY(e.tfinger.y);

    if (m_state == MOMENTUM) { m_velX = m_velY = 0; m_state = IDLE; }

    if (!m_primaryActive) {
        m_primary = e.tfinger.fingerID;
        m_primaryActive = true;
        m_downX = m_lastX = x;
        m_downY = m_lastY = y;
        m_downTicks = SDL_GetTicks();
        m_f1x = e.tfinger.x; m_f1y = e.tfinger.y;

        if (buildingActive()) { beginPlace(x, y); return; }
        m_state = PAN;
        return;
    }

    if (!m_secondaryActive && e.tfinger.fingerID != m_primary)
        startTwo(e);
}

void TouchInput::onMove(const SDL_Event &e)
{
    const float x = SX(e.tfinger.x);
    const float y = SY(e.tfinger.y);

    if (m_state == TWO_FINGER) { updateTwo(e); return; }
    if (e.tfinger.fingerID != m_primary || !m_primaryActive) return;

    const float dxPx = x - m_lastX;
    const float dyPx = y - m_lastY;
    const float tDx  = x - m_downX;
    const float tDy  = y - m_downY;
    const float travel = SDL_sqrtf(tDx*tDx + tDy*tDy);

    if (m_state == PLACING || m_state == ROTATING) {
        if (m_state == ROTATING) {
            updateRotate(x, y);
        } else {
            sendMotion(x, y);
            m_buildX = x; m_buildY = y;
            if (SDL_sqrtf(dxPx*dxPx + dyPx*dyPx) > 3.0f)
                m_buildHoldTicks = 0;
        }
        m_lastX = x; m_lastY = y;
        return;
    }

    if (m_state == SELECTING) {
        sendMotion(x, y);
        m_lastX = x; m_lastY = y;
        return;
    }

    const Uint64 held = SDL_GetTicks() - m_downTicks;
    if (held >= SELECT_HOLD_MS && travel >= SELECT_DEAD_PX) {
        beginSelect();
        sendMotion(x, y);
    } else {
        applyPan(dxPx, dyPx);
        m_velX = m_velX * 0.6f + dxPx * 0.4f;
        m_velY = m_velY * 0.6f + dyPx * 0.4f;
    }
    m_lastX = x; m_lastY = y;
}

void TouchInput::onUp(const SDL_Event &e)
{
    const float x = SX(e.tfinger.x);
    const float y = SY(e.tfinger.y);

    if (m_state == TWO_FINGER) {
        if (e.tfinger.fingerID == m_primary)   m_primaryActive = false;
        if (e.tfinger.fingerID == m_secondary) m_secondaryActive = false;
        finishTwo();
        return;
    }

    if (e.tfinger.fingerID != m_primary || !m_primaryActive) return;

    const float tDx = x - m_downX, tDy = y - m_downY;
    const float travel = SDL_sqrtf(tDx*tDx + tDy*tDy);
    const Uint64 held = SDL_GetTicks() - m_downTicks;

    if (m_state == SELECTING) {
        sendButton(SDL_EVENT_MOUSE_BUTTON_UP, x, y, SDL_BUTTON_LEFT);
        m_leftHeld = false;
        m_primaryActive = false;
        m_state = IDLE;
        return;
    }

    if (m_state == PLACING || m_state == ROTATING) {
        if (m_state == ROTATING) {
            buildNow();
        } else {
            fixPreview();
            if (m_buildFixed && held <= TAP_MS && travel <= TAP_DEAD_PX)
                buildNow();
        }
        m_primaryActive = false;
        return;
    }

    if (m_state == PAN)
    {
        if (travel <= TAP_DEAD_PX && held <= TAP_MS)
        {
            const bool dbl = m_hasLastTap &&
                             (SDL_GetTicks() - m_lastTapTicks) <= DOUBLE_TAP_MS &&
                             SDL_sqrtf((x - m_lastTapX)*(x - m_lastTapX) +
                                       (y - m_lastTapY)*(y - m_lastTapY)) <= TAP_DEAD_PX;
            if (dbl) {
                sendClick(x, y, 2);
                m_hasLastTap = false;
            } else {
                sendClick(x, y, 1);
                m_lastTapTicks = SDL_GetTicks();
                m_lastTapX = x; m_lastTapY = y;
                m_hasLastTap = true;
            }
        }
        else
        {
            if (SDL_fabsf(m_velX) > MOMENTUM_MIN_VEL ||
                SDL_fabsf(m_velY) > MOMENTUM_MIN_VEL)
                m_state = MOMENTUM;
            else
                m_state = IDLE;
        }
    }

    m_primaryActive = false;
}

void TouchInput::processEvent(const SDL_Event &e)
{
    if (!m_window) return;
    switch (e.type) {
        case SDL_EVENT_FINGER_DOWN:      onDown(e); break;
        case SDL_EVENT_FINGER_MOTION:    onMove(e); break;
        case SDL_EVENT_FINGER_UP:
        case SDL_EVENT_FINGER_CANCELED:  onUp(e);   break;
        default: break;
    }
}

void TouchInput::update()
{
    if (m_state == MOMENTUM) {
        if (SDL_fabsf(m_velX) < MOMENTUM_MIN_VEL &&
            SDL_fabsf(m_velY) < MOMENTUM_MIN_VEL) {
            m_velX = m_velY = 0;
            m_state = IDLE;
        } else {
            applyPan(m_velX, m_velY);
            m_velX *= MOMENTUM_FRICTION;
            m_velY *= MOMENTUM_FRICTION;
        }
    }

    if (m_state == PLACING && m_buildFixed &&
        m_buildHoldTicks && SDL_GetTicks() - m_buildHoldTicks >= BUILD_HOLD_MS)
    {
        beginRotate();
    }
}

#endif // TARGET_OS_IPHONE
