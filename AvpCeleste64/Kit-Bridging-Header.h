//
//  Kit-Bridging-Header.h
//  AvpCeleste64
//
//  Makes the C test scene of the SDL_GPU kit (Kit/sdl-gpu-kit) and the C interface of the
//  game (Celeste64.VisionOS.framework, Wrapper/Celeste64.VisionOS/celeste.h) visible to Swift.
//  SDL itself is not imported into Swift; the host talks only to the kit and to the wrapper.
//

#ifndef Kit_Bridging_Header_h
#define Kit_Bridging_Header_h

#include "kit_testscene.h"
#include "kit_import.h"
#include "kit_multiview.h"

// Relative to this file, so that project.pbxproj needs no further search path.
#include "../Wrapper/Celeste64.VisionOS/celeste.h"

#endif /* Kit_Bridging_Header_h */
