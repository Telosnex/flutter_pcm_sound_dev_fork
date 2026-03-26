#import "FlutterPcmSoundPlugin.h"
#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>

#if TARGET_OS_IOS
#import <AVFoundation/AVFoundation.h>
#endif

#define kOutputBus 0
#define NAMESPACE @"flutter_pcm_sound"

// Ring buffer capacity: 2 MB ≈ 10.9 s of 48 kHz stereo int16.
// Must be a power of two so we can mask instead of modulo.
#define RING_CAPACITY (1u << 21)  // 2 097 152
#define RING_MASK     (RING_CAPACITY - 1u)

typedef NS_ENUM(NSUInteger, LogLevel) {
    none = 0,
    error = 1,
    standard = 2,
    verbose = 3,
};

// ────────────────────────────────────────────────────────────────────────────
// Lock-free ring-buffer helpers.
//
// Single-producer (main thread writes via `feed`) /
// single-consumer  (RT audio thread reads via `RenderCallback`).
//
// The positions are free-running uint32_t counters.  Wrapping is harmless
// because (writePos − readPos) always gives the correct fill level as long
// as the buffer is < 2³² bytes (it's 2²¹).
// ────────────────────────────────────────────────────────────────────────────

/// Bytes available to read (called from RT thread).
static inline uint32_t ring_readable(const _Atomic(uint32_t) *rdP,
                                     const _Atomic(uint32_t) *wrP) {
    uint32_t wp = atomic_load_explicit(wrP, memory_order_acquire);
    uint32_t rp = atomic_load_explicit(rdP, memory_order_relaxed);
    return wp - rp;
}

/// Write up to `len` bytes into the ring.  Returns bytes actually written.
/// Called from the main thread only.
static inline uint32_t ring_write(uint8_t *buf,
                                  _Atomic(uint32_t) *rdP,
                                  _Atomic(uint32_t) *wrP,
                                  const uint8_t *src, uint32_t len) {
    uint32_t rp    = atomic_load_explicit(rdP, memory_order_acquire);
    uint32_t wp    = atomic_load_explicit(wrP, memory_order_relaxed);
    uint32_t space = RING_CAPACITY - (wp - rp);
    uint32_t n     = len < space ? len : space;
    if (n == 0) return 0;

    uint32_t off   = wp & RING_MASK;
    uint32_t head  = RING_CAPACITY - off;       // room before wrap
    if (head > n) head = n;

    memcpy(buf + off, src, head);
    if (n > head) {
        memcpy(buf, src + head, n - head);      // wrapped portion
    }

    atomic_store_explicit(wrP, wp + n, memory_order_release);
    return n;
}

/// Read up to `len` bytes from the ring into `dst`.  Returns bytes read.
/// Called from the RT audio thread only — no locks, no ObjC, no allocations.
static inline uint32_t ring_read(uint8_t *buf,
                                 _Atomic(uint32_t) *rdP,
                                 _Atomic(uint32_t) *wrP,
                                 uint8_t *dst, uint32_t len) {
    uint32_t wp = atomic_load_explicit(wrP, memory_order_acquire);
    uint32_t rp = atomic_load_explicit(rdP, memory_order_relaxed);
    uint32_t avail = wp - rp;
    uint32_t n = len < avail ? len : avail;
    if (n == 0) return 0;

    uint32_t off  = rp & RING_MASK;
    uint32_t head = RING_CAPACITY - off;
    if (head > n) head = n;

    memcpy(dst, buf + off, head);
    if (n > head) {
        memcpy(dst + head, buf, n - head);      // wrapped portion
    }

    atomic_store_explicit(rdP, rp + n, memory_order_release);
    return n;
}

// ────────────────────────────────────────────────────────────────────────────

@interface FlutterPcmSoundPlugin () {
    // Lock-free ring buffer (replaces NSMutableData + @synchronized).
    uint8_t *_ringBuf;
    _Atomic(uint32_t) _ringRd;
    _Atomic(uint32_t) _ringWr;

    // Cached copies of ObjC properties, safe to read from the RT thread.
    int _rtNumChannels;
    int _rtFeedThreshold;
    _Atomic(bool) _rtFeedCallbackSent;
    __unsafe_unretained FlutterMethodChannel *_rtMethodChannel;
}
@property(nonatomic) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic) FlutterMethodChannel *mMethodChannel;
@property(nonatomic) LogLevel mLogLevel;
@property(nonatomic) AudioComponentInstance mAudioUnit;
@property(nonatomic) int mNumChannels; 
@property(nonatomic) int mFeedThreshold; 
@property(nonatomic) bool mDidSetup; 
@property(nonatomic) bool mIsRunning;

// We’ll track the chosen audio category to know if we should override the speaker
@property(nonatomic, copy) NSString *chosenCategory;
@property(nonatomic) BOOL hasSpeakerOverride;

@end

@implementation FlutterPcmSoundPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar
{
    FlutterMethodChannel *methodChannel = [FlutterMethodChannel methodChannelWithName:NAMESPACE @"/methods"
                                                                    binaryMessenger:[registrar messenger]];

    FlutterPcmSoundPlugin *instance = [[FlutterPcmSoundPlugin alloc] init];
    instance.mMethodChannel = methodChannel;
    instance.mLogLevel = verbose;
    instance.mFeedThreshold = 8000;
    instance.mDidSetup = false;
    instance.mIsRunning = false;
    instance.hasSpeakerOverride = NO;

    [registrar addMethodCallDelegate:instance channel:methodChannel];
}

- (void)allocRing {
    [self freeRing];
    _ringBuf = (uint8_t *)malloc(RING_CAPACITY);
    atomic_store_explicit(&_ringRd, 0, memory_order_relaxed);
    atomic_store_explicit(&_ringWr, 0, memory_order_relaxed);
}

- (void)freeRing {
    if (_ringBuf) {
        free(_ringBuf);
        _ringBuf = NULL;
    }
    atomic_store_explicit(&_ringRd, 0, memory_order_relaxed);
    atomic_store_explicit(&_ringWr, 0, memory_order_relaxed);
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result
{
    @try
    {
        if ([@"setLogLevel" isEqualToString:call.method])
        {
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSNumber *logLevelNumber  = args[@"log_level"];

            self.mLogLevel = (LogLevel)[logLevelNumber integerValue];

            result(@(true));
        }
        else if ([@"setup" isEqualToString:call.method])
        {
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSNumber *sampleRate       = args[@"sample_rate"];
            NSNumber *numChannels      = args[@"num_channels"];
#if TARGET_OS_IOS
            NSString *iosAudioCategory = args[@"ios_audio_category"];
            self.chosenCategory = iosAudioCategory;
            self.hasSpeakerOverride = NO;
#endif

            self.mNumChannels = [numChannels intValue];

#if TARGET_OS_IOS
	        // handle background audio in iOS
            // Default to Playback if no matching case is found
            AVAudioSessionCategory category = AVAudioSessionCategoryPlayback;
            AVAudioSessionCategoryOptions options = 0;
            if ([iosAudioCategory isEqualToString:@"ambient"]) {
                category = AVAudioSessionCategoryAmbient;
            } else if ([iosAudioCategory isEqualToString:@"soloAmbient"]) {
                category = AVAudioSessionCategorySoloAmbient;
            } else if ([iosAudioCategory isEqualToString:@"playback"]) {
                category = AVAudioSessionCategoryPlayback;
            } else if ([iosAudioCategory isEqualToString:@"playAndRecord"]) {
                category = AVAudioSessionCategoryPlayAndRecord;
                // Favor the device speaker for "playAndRecord" but still advertise Bluetooth routes
                // so accessories like AirPods remain selectable by the user.
                options |= AVAudioSessionCategoryOptionDefaultToSpeaker;
                options |= AVAudioSessionCategoryOptionAllowBluetooth;
                if (@available(iOS 10.0, *)) {
                    options |= AVAudioSessionCategoryOptionAllowBluetoothA2DP;
                }
            }
            
            // Set the AVAudioSession category based on the string value
            NSError *error = nil;
            [[AVAudioSession sharedInstance] setCategory:category withOptions:options error:&error];
            if (error) {
                NSLog(@"Error setting AVAudioSession category: %@", error);
                result([FlutterError errorWithCode:@"AVAudioSessionError"
                                           message:@"Error setting AVAudioSession category"
                                           details:[error localizedDescription]]);
                return;
            }

            [[AVAudioSession sharedInstance] setActive:YES error:&error];
            if (error) {
                NSLog(@"Error activating AVAudioSession: %@", error);
                result([FlutterError errorWithCode:@"AVAudioSessionError"
                                           message:@"Error activating AVAudioSession"
                                           details:[error localizedDescription]]);
                return;
            }

            // If using playAndRecord, ensure we don't use the earpiece:
            // Check current route. If built-in receiver is present, override to speaker.
            if ([iosAudioCategory isEqualToString:@"playAndRecord"]) {
                [self ensureNotEarpiece];
                
                // Add observer to handle future route changes
                [[NSNotificationCenter defaultCenter] addObserver:self
                                                         selector:@selector(handleRouteChange:)
                                                             name:AVAudioSessionRouteChangeNotification
                                                           object:nil];
            }
#endif

            // cleanup
            if (_mAudioUnit != nil) {
                [self cleanup];
            }

            // create
            [self allocRing];

            AudioComponentDescription desc;
            desc.componentType = kAudioUnitType_Output;
#if TARGET_OS_IOS
            desc.componentSubType = kAudioUnitSubType_RemoteIO;
#else // MacOS
            desc.componentSubType = kAudioUnitSubType_DefaultOutput;
#endif
            desc.componentFlags = 0;
            desc.componentFlagsMask = 0;
            desc.componentManufacturer = kAudioUnitManufacturer_Apple;

            AudioComponent inputComponent = AudioComponentFindNext(NULL, &desc);
            OSStatus status = AudioComponentInstanceNew(inputComponent, &_mAudioUnit);
            if (status != noErr) {
                NSString* message = [NSString stringWithFormat:@"AudioComponentInstanceNew failed. OSStatus: %@", @(status)];
                result([FlutterError errorWithCode:@"AudioUnitError" message:message details:nil]);
                return;
            }

            // set stream format
            AudioStreamBasicDescription audioFormat;
            audioFormat.mSampleRate = [sampleRate intValue];
            audioFormat.mFormatID = kAudioFormatLinearPCM;
            audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
            audioFormat.mFramesPerPacket = 1;
            audioFormat.mChannelsPerFrame = self.mNumChannels;
            audioFormat.mBitsPerChannel = 16;
            audioFormat.mBytesPerFrame = self.mNumChannels * (audioFormat.mBitsPerChannel / 8);
            audioFormat.mBytesPerPacket = audioFormat.mBytesPerFrame * audioFormat.mFramesPerPacket;

            status = AudioUnitSetProperty(_mAudioUnit,
                                    kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Input,
                                    kOutputBus,
                                    &audioFormat,
                                    sizeof(audioFormat));
            if (status != noErr) {
                NSString* message = [NSString stringWithFormat:@"AudioUnitSetProperty StreamFormat failed. OSStatus: %@", @(status)];
                result([FlutterError errorWithCode:@"AudioUnitError" message:message details:nil]);
                return;
            }

            // set callback
            AURenderCallbackStruct callback;
            callback.inputProc = RenderCallback;
            callback.inputProcRefCon = (__bridge void *)(self);

            status = AudioUnitSetProperty(_mAudioUnit,
                                kAudioUnitProperty_SetRenderCallback,
                                kAudioUnitScope_Global,
                                kOutputBus,
                                &callback,
                                sizeof(callback));
            if (status != noErr) {
                NSString* message = [NSString stringWithFormat:@"AudioUnitSetProperty SetRenderCallback failed. OSStatus: %@", @(status)];
                result([FlutterError errorWithCode:@"AudioUnitError" message:message details:nil]);
                return;
            }

            // initialize
            status = AudioUnitInitialize(_mAudioUnit);
            if (status != noErr) {
                NSString* message = [NSString stringWithFormat:@"AudioUnitInitialize failed. OSStatus: %@", @(status)];
                result([FlutterError errorWithCode:@"AudioUnitError" message:message details:nil]);
                return;
            }

            // Cache values the RT thread will read directly (no ObjC messaging).
            _rtNumChannels    = self.mNumChannels;
            _rtFeedThreshold  = self.mFeedThreshold;
            _rtMethodChannel  = self.mMethodChannel;
            atomic_store_explicit(&_rtFeedCallbackSent, false, memory_order_relaxed);

            self.mDidSetup  = true;
            self.mIsRunning = false;

            result(@(true));
        }
        else if ([@"feed" isEqualToString:call.method])
        {
            // setup check
            if (self.mDidSetup == false) {
                result([FlutterError errorWithCode:@"Setup" message:@"must call setup first" details:nil]);
                return;
            }

            NSDictionary *args = (NSDictionary*)call.arguments;
            FlutterStandardTypedData *buffer = args[@"buffer"];

            // Append to the lock-free ring buffer (no lock, no ObjC on RT path).
            const uint8_t *src = (const uint8_t *)buffer.data.bytes;
            uint32_t       len = (uint32_t)buffer.data.length;
            ring_write(_ringBuf, &_ringRd, &_ringWr, src, len);

            // Allow the RT thread to fire the feed-threshold callback again.
            atomic_store_explicit(&_rtFeedCallbackSent, false, memory_order_relaxed);

            // Start the audio unit on the first feed.  After that it stays
            // running (outputting silence when the ring is empty) until
            // `release` is called. Eliminates race between stopAudioUnit dispatched
            // from the RT thread and a concurrent feed() on main
            if (!self.mIsRunning) {
                OSStatus status = AudioOutputUnitStart(_mAudioUnit);
                if (status != noErr) {
                    NSString *msg = [NSString stringWithFormat:
                        @"AudioOutputUnitStart failed. OSStatus: %@", @(status)];
                    result([FlutterError errorWithCode:@"AudioUnitError"
                                               message:msg
                                               details:nil]);
                    return;
                }
                self.mIsRunning = true;
            }

            result(@(true));
        }
        else if ([@"setFeedThreshold" isEqualToString:call.method])
        {
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSNumber *feedThreshold = args[@"feed_threshold"];

            self.mFeedThreshold = [feedThreshold intValue];
            _rtFeedThreshold    = [feedThreshold intValue];

            result(@(true));
        }
        else if([@"release" isEqualToString:call.method])
        {
            [self cleanup];
            result(@(true));
        }
        else
        {
            result([FlutterError errorWithCode:@"functionNotImplemented" message:call.method details:nil]);
        }
    }
    @catch (NSException *e)
    {
        NSString *stackTrace = [[e callStackSymbols] componentsJoinedByString:@"\n"];
        NSDictionary *details = @{@"stackTrace": stackTrace};
        result([FlutterError errorWithCode:@"iosException" message:[e reason] details:details]);
    }
}

// ── Teardown ───────────────────────────────────────────────────────────────

- (void)cleanup
{
#if TARGET_OS_IOS
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionRouteChangeNotification object:nil];
    if (self.hasSpeakerOverride) {
        NSError *error = nil;
        [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:&error];
        if (error) {
            NSLog(@"Error clearing speaker override during cleanup: %@", error);
        }
        self.hasSpeakerOverride = NO;
    }
#endif

    if (_mAudioUnit != nil) {
        AudioOutputUnitStop(_mAudioUnit);
        AudioUnitUninitialize(_mAudioUnit);
        AudioComponentInstanceDispose(_mAudioUnit);
        _mAudioUnit     = nil;
        self.mDidSetup  = false;
        self.mIsRunning = false;
    }

    [self freeRing];
}

#if TARGET_OS_IOS
- (void)handleRouteChange:(NSNotification *)notification {
    [self ensureNotEarpiece];
}

- (void)ensureNotEarpiece {
    // Guard against iOS selecting the built-in receiver when we really want full-volume playback.
    // We still allow other routes (AirPods, AirPlay, wired headphones) by only forcing the speaker
    // while the receiver is active and immediately undoing that override otherwise.
    AVAudioSessionRouteDescription *currentRoute = [AVAudioSession sharedInstance].currentRoute;
    BOOL isEarpiece = NO;
    for (AVAudioSessionPortDescription *output in currentRoute.outputs) {
        // Built-in receiver is the "earpiece"
        if ([output.portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
            isEarpiece = YES;
            break;
        }
    }

    if (isEarpiece) {
        if (!self.hasSpeakerOverride) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *error = nil;
                [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];
                if (error) {
                    NSLog(@"Error overriding to speaker: %@", error);
                } else {
                    self.hasSpeakerOverride = YES;
                    NSLog(@"Earpiece was selected, overriding to speaker.");
                }
            });
        }
    } else if (self.hasSpeakerOverride) {
        // We've previously forced the speaker, but the active route is now something else
        // (e.g. Bluetooth or headphones). Clear the override so iOS can honor that route.
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *error = nil;
            [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:&error];
            if (error) {
                NSLog(@"Error clearing speaker override when new route detected: %@", error);
            } else {
                self.hasSpeakerOverride = NO;
            }
        });
    }
}
#endif

// ── CoreAudio render callback (real-time thread) ───────────────────────────
//
// Rules for this function:
//   • No Objective-C message sends (no property dot-syntax on self).
//   • No locks (@synchronized, pthread_mutex, os_unfair_lock).
//   • No memory allocation (malloc, new, [NSObject alloc]).
//   • No file or network I/O.
//
// We access only:
//   • The lock-free ring buffer via plain C helpers + atomics.
//   • Cached int ivars (_rtNumChannels, _rtFeedThreshold) that are
//     written once from the main thread *before* the audio unit starts.
//   • dispatch_async (documented safe from any thread).
// ───────────────────────────────────────────────────────────────────────────

static OSStatus RenderCallback(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList *ioData)
{
    FlutterPcmSoundPlugin *instance =
        (__bridge FlutterPcmSoundPlugin *)(inRefCon);

    uint8_t *outBuf   = (uint8_t *)ioData->mBuffers[0].mData;
    uint32_t outBytes = (uint32_t)ioData->mBuffers[0].mDataByteSize;

    // Pull samples from the ring buffer — pure C, no locks.
    uint32_t filled = ring_read(instance->_ringBuf,
                                &instance->_ringRd,
                                &instance->_ringWr,
                                outBuf, outBytes);

    // Silence-fill any remainder.
    if (filled < outBytes) {
        memset(outBuf + filled, 0, outBytes - filled);
    }

    // ── Feed-threshold callback ────────────────────────────────────────
    int bpf = instance->_rtNumChannels * (int)sizeof(short);
    if (bpf <= 0) return noErr;                       // guard against /0

    uint32_t readable = ring_readable(&instance->_ringRd,
                                      &instance->_ringWr);
    uint32_t remainingFrames = readable / (uint32_t)bpf;

    if ((int)remainingFrames <= instance->_rtFeedThreshold &&
        !atomic_load_explicit(&instance->_rtFeedCallbackSent,
                              memory_order_relaxed)) {
        atomic_store_explicit(&instance->_rtFeedCallbackSent, true,
                              memory_order_relaxed);

        // The NSDictionary + invokeMethod are executed on the main queue,
        // not on this thread.  dispatch_async itself is RT-safe.
        FlutterMethodChannel *ch = instance->_rtMethodChannel;
        dispatch_async(dispatch_get_main_queue(), ^{
            [ch invokeMethod:@"OnFeedSamples"
                   arguments:@{@"remaining_frames" : @(remainingFrames)}];
        });
    }

    return noErr;
}

@end
