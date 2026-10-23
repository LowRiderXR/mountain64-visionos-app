//
//  Kit-Bridging-Header.h
//  AvpCeleste64
//
//  Macht die C-Testszene des SDL_GPU-Kits (Kit/sdl-gpu-kit) und die C-Schnittstelle des
//  Spiels (Celeste64.VisionOS.framework, Wrapper/Celeste64.VisionOS/celeste.h) für Swift
//  sichtbar. SDL selbst wird nicht nach Swift importiert; der Host spricht nur mit dem Kit
//  und mit dem Wrapper.
//

#ifndef Kit_Bridging_Header_h
#define Kit_Bridging_Header_h

#include "kit_testscene.h"
#include "kit_import.h"
#include "kit_multiview.h"

// Relativ zu dieser Datei, damit project.pbxproj keinen weiteren Suchpfad braucht.
#include "../Wrapper/Celeste64.VisionOS/celeste.h"

#endif /* Kit_Bridging_Header_h */
