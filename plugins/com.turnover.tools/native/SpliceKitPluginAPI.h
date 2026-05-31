//
// Minimal SpliceKit native plugin API header.
// Source-compatible with SpliceKit apiVersion 1.
//

#ifndef TurnoverToolsSpliceKitPluginAPI_h
#define TurnoverToolsSpliceKitPluginAPI_h

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

typedef NSDictionary *(^SpliceKitMethodHandler)(NSDictionary *params);

typedef struct {
    int apiVersion;
    const char *pluginId;
    const char *dataPath;
    void (*registerMethod)(NSString *method, SpliceKitMethodHandler handler, NSDictionary *metadata);
    void (*unregisterMethod)(NSString *method);
    void (*log)(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
    void (*executeOnMainThread)(dispatch_block_t block);
    void (*executeOnMainThreadAsync)(dispatch_block_t block);
    void (*broadcastEvent)(NSDictionary *event);
    NSString *(*storeHandle)(id object);
    id (*resolveHandle)(NSString *handleId);
    void (*releaseHandle)(NSString *handleId);
    IMP (*swizzleMethod)(Class cls, SEL selector, IMP newImpl);
    BOOL (*unswizzleMethod)(Class cls, SEL selector);
    NSDictionary *(*callMethod)(NSDictionary *request);
} SpliceKitPluginAPI;

typedef void (*SpliceKitPluginInitFunc)(SpliceKitPluginAPI *api);

#endif
