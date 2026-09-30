/*
**\tCommand & Conquer Generals Zero Hour(tm)
**\tCopyright 2025 Electronic Arts Inc.
**
**\tThis program is free software: you can redistribute it and/or modify
**\tit under the terms of the GNU General Public License as published by
**\tthe Free Software Foundation, either version 3 of the License, or
**\t(at your option) any later version.
**
**\tThis program is distributed in the hope that it will be useful,
**\tbut WITHOUT ANY WARRANTY; without even the implied warranty of
**\tMERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
**\tGNU General Public License for more details.
**\n**\tYou should have received a copy of the GNU General Public License
**\talong with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

/*
** SDL3GameEngine.h
**
** Linux implementation of GameEngine using SDL3 for windowing/input.
**
** TheSuperHackers @feature CnC_Generals_Linux 07/02/2026
** Provides SDL3-based input and window management for Linux builds.
** Based on fighter19 reference implementation.
*/

#pragma once

#ifndef _WIN32

#include "Common/GameEngine.h"
#include "Common/LocalFileSystem.h"
#include "Common/ArchiveFileSystem.h"
#include <SDL3/SDL.h>

// EXTERNALS
// GeneralsX @feature felipebraz 16/02/2026
// SDL3 window created in SDL3Main.cpp before GameEngine instantiation (fighter19 pattern)
extern SDL_Window* TheSDL3Window;

// Forward declarations - full definitions in SDL3GameEngine.cpp
class StdLocalFileSystem;
class StdBIGFileSystem;
class W3DModuleFactory;
class W3DGameLogic;
class W3DGameClient;
class W3DWebBrowser;
class W3DFunctionLexicon;
class W3DRadar;
class W3DThingFactory;
class W3DParticleSystemManager;

// Forward declarations for base classes
class AudioManager;
class Mouse;
class Keyboard;
class GameWindow;

/**
 * SDL3GameEngine
 *
 * GameEngine subclass that uses SDL3 for windowing and input.
 * Replaces Win32-specific window handling with SDL3 on Linux.
 *
 * Features:
 * - SDL3 window creation with Vulkan support (for DXVK)
 * - SDL3 event polling integrated with game loop
 * - Factory methods for input (Mouse, Keyboard) and audio managers
 * - Compatible with existing GameEngine subsystems
 */
class SDL3GameEngine : public GameEngine
{
public:
\tSDL3GameEngine();
\tvirtual ~SDL3GameEngine();

\t// GameEngine interface
\tvirtual void init(void);
\tvirtual void reset(void);
\tvirtual void update(void);
\tvirtual void execute(void);
\tvirtual void serviceWindowsOS(void);
\tvirtual Bool isActive(void);
\tvirtual void setIsActive(Bool isActive);

\t// Factory methods (override GameEngine)
\tvirtual LocalFileSystem *createLocalFileSystem(void);
\tvirtual ArchiveFileSystem *createArchiveFileSystem(void);
\tvirtual GameLogic *createGameLogic(void);
\tvirtual GameClient *createGameClient(void);
\tvirtual ModuleFactory *createModuleFactory(void);
\tvirtual ThingFactory *createThingFactory(void);
\tvirtual FunctionLexicon *createFunctionLexicon(void);
\t// GeneralsX @bugfix Copilot 15/04/2026 Match upstream GameEngine pure-virtual signatures after sync.
\tvirtual Radar *createRadar(Bool dummy);
\tvirtual WebBrowser *createWebBrowser(void);
\tvirtual ParticleSystemManager* createParticleSystemManager(Bool dummy);
\tvirtual AudioManager *createAudioManager(Bool dummy);

\t// SDL3 specific
\tvirtual SDL_Window* getSDLWindow(void) const { return m_SDLWindow; }

protected:
\tSDL_Window*\t\tm_SDLWindow;
\tBool\t\t\tm_IsInitialized;
\tBool\t\t\tm_IsActive;
\tBool\t\t\tm_IsTextInputActive;
\tGameWindow*\tm_TextInputFocusWindow;
\t// iOS: after Return hides the keyboard, do not immediately restart text input
\t// while the same entry field still owns focus.
\tGameWindow*\tm_TextInputSuppressedFocusWindow;

\t// Event processing
\tvoid pollSDL3Events(void);
\t// GeneralsX @bugfix felipebraz 01/04/2026 Bridge SDL text events to GUI text-entry widgets.
\tvoid updateTextInputState(void);
\t// GeneralsX @bugfix felipebraz 01/04/2026 Forward UTF-8 text input as GWM_IME_CHAR messages.
\tvoid forwardTextInputEvent(const char* utf8Text);
\tvoid handleKeyboardEvent(const SDL_KeyboardEvent& event);
\tvoid handleMouseMotionEvent(const SDL_MouseMotionEvent& event);
\tvoid handleMouseButtonEvent(const SDL_MouseButtonEvent& event);
\tvoid handleMouseWheelEvent(const SDL_MouseWheelEvent& event);  //TheSuperHackers @build 10/02/2026 Bender
\tvoid handleWindowEvent(const SDL_WindowEvent& event);
};

#endif // !_WIN32
