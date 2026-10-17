/*
 * kit_testscene_metal.m — Metal-Hilfen für die Kit-Testszene (K1a). Siehe kit_testscene_metal.h.
 */

#import <Metal/Metal.h>

#include "kit_testscene_metal.h"

#include <stdio.h>

bool kit_metal_create_host_objects(void **device_out, void **queue_out)
{
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            return false;
        }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (queue == nil) {
            return false;
        }
        queue.label = @"kit-host-queue";
        *device_out = (void *)CFBridgingRetain(device);
        *queue_out = (void *)CFBridgingRetain(queue);
        return true;
    }
}

void kit_metal_release_host_objects(void *device, void *queue)
{
    if (queue) {
        CFBridgingRelease(queue);
    }
    if (device) {
        CFBridgingRelease(device);
    }
}

void *kit_metal_queue_device(void *queue)
{
    if (!queue) {
        return NULL;
    }
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
    return (__bridge void *)q.device;
}

const char *kit_metal_device_name(void *device, char *buf, size_t cap)
{
    if (!device || cap == 0) {
        return "-";
    }
    id<MTLDevice> d = (__bridge id<MTLDevice>)device;
    snprintf(buf, cap, "%s", d.name.UTF8String ? d.name.UTF8String : "?");
    return buf;
}

bool kit_metal_hostqueue_check(void *queue, char *status_out, size_t cap)
{
    @autoreleasepool {
        if (!queue) {
            snprintf(status_out, cap, "queue=NULL");
            return false;
        }
        id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        if (cb == nil) {
            snprintf(status_out, cap, "commandBuffer=nil");
            return false;
        }
        cb.label = @"kit-hostqueue-after-destroy";
        [cb commit];
        [cb waitUntilCompleted];
        const bool ok = (cb.status == MTLCommandBufferStatusCompleted) && (cb.error == nil);
        snprintf(status_out, cap, "status=%ld error=%s", (long)cb.status,
                 cb.error ? (cb.error.localizedDescription.UTF8String ?: "?") : "-");
        return ok;
    }
}
