#pragma once

#include <TargetConditionals.h>

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

#include <SDL3/SDL.h>

void IOSGameOverlayInit(SDL_Window *window);
void IOSGameOverlayShutdown();
void IOSGameOverlayNoteActivity();
void IOSGameOverlayHandleSDLKeyEvent(const SDL_Event *event);

#endif
