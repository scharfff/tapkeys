// Types from Apple's private MultitouchSupport.framework.
// The framework has no public headers; this layout is the one used by
// open source tools that read raw trackpad touches. Functions are loaded
// at runtime with dlsym (see Engine.swift), so only the types live here.

#include <CoreFoundation/CoreFoundation.h>

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

typedef struct {
    int frame;
    double timestamp;
    int pathIndex;
    int state;
    int fingerID;
    int handID;
    MTVector normalized;   // 0...1 across the trackpad surface
    float zTotal;
    int field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;     // millimetres
    int field14;
    int field15;
    float zDensity;
} MTTouch;

typedef void *MTDeviceRef;

typedef int (*MTFrameCallbackFunction)(MTDeviceRef device,
                                       MTTouch *touches,
                                       int numTouches,
                                       double timestamp,
                                       int frame);
