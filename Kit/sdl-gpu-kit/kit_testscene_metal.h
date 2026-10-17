/*
 * kit_testscene_metal.h — Metal-Hilfen für die Kit-Testszene (K1a, Baustein P1).
 *
 * Für Hosts ohne Objective-C (die C-Kommandozeile auf dem Mac) und für die Prüfung nach
 * SDL_DestroyGPUDevice. Zeiger sind id<MTLDevice> / id<MTLCommandQueue> als void*.
 * Implementierung in kit_testscene_metal.m (ARC).
 */

#ifndef KIT_TESTSCENE_METAL_H
#define KIT_TESTSCENE_METAL_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Systemstandard-Device und eine Queue darauf anlegen. Beide werden mit +1 zurückgegeben
 * (CFBridgingRetain); Freigabe über kit_metal_release_host_objects. */
bool kit_metal_create_host_objects(void **device_out, void **queue_out);

/* Gibt die mit kit_metal_create_host_objects erzeugten Referenzen frei (NULL erlaubt). */
void kit_metal_release_host_objects(void *device, void *queue);

/* Device einer Queue (unretained), für Zeigervergleich und Logzeilen. */
void *kit_metal_queue_device(void *queue);

/* Name eines Devices in buf (UTF-8), gibt buf zurück. */
const char *kit_metal_device_name(void *device, char *buf, size_t cap);

/* Leerer Command Buffer auf der Queue: commit, waitUntilCompleted. Gibt true zurück, wenn der
 * Status MTLCommandBufferStatusCompleted ist und kein Fehler anliegt; status_out erhält eine
 * kurze Beschreibung (Status, Fehlertext). */
bool kit_metal_hostqueue_check(void *queue, char *status_out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* KIT_TESTSCENE_METAL_H */
