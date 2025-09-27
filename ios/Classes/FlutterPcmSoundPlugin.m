#import "FlutterPcmSoundPlugin.h"
#import <AudioToolbox/AudioToolbox.h>

#if TARGET_OS_IOS
#import <AVFoundation/AVFoundation.h>
#endif

#define kOutputBus 0
#define NAMESPACE @"flutter_pcm_sound"

typedef NS_ENUM(NSUInteger, LogLevel) {
    none = 0,
    error = 1,
    standard = 2,
    verbose = 3,
};

@interface FlutterPcmSoundPlugin ()
@property(nonatomic) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic) FlutterMethodChannel *mMethodChannel;
@property(nonatomic) LogLevel mLogLevel;
@property(nonatomic) AudioComponentInstance mAudioUnit;
@property(nonatomic) NSMutableData *mSamples;
@property(nonatomic) int mNumChannels; 
@property(nonatomic) int mFeedThreshold; 
@property(nonatomic) bool mDidInvokeFeedCallback; 
@property(nonatomic) bool mDidSetup; 

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
    instance.mSamples = [NSMutableData new];
    instance.mFeedThreshold = 8000;
    instance.mDidInvokeFeedCallback = false;
    instance.mDidSetup = false;
    instance.hasSpeakerOverride = NO;

    [registrar addMethodCallDelegate:instance channel:methodChannel];
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

            self.mDidSetup = true;
            
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

            @synchronized (self.mSamples) {
                [self.mSamples appendData:buffer.data];
            }

            // reset
            self.mDidInvokeFeedCallback = false;

            // start
            OSStatus status = AudioOutputUnitStart(_mAudioUnit);
            if (status != noErr) {
                NSString* message = [NSString stringWithFormat:@"AudioOutputUnitStart failed. OSStatus: %@", @(status)];
                result([FlutterError errorWithCode:@"AudioUnitError" message:message details:nil]);
                return;
            }

            result(@(true));
        }
        else if ([@"setFeedThreshold" isEqualToString:call.method])
        {
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSNumber *feedThreshold = args[@"feed_threshold"];

            self.mFeedThreshold = [feedThreshold intValue];

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
        [self stopAudioUnit];
        AudioUnitUninitialize(_mAudioUnit);
        AudioComponentInstanceDispose(_mAudioUnit);
        _mAudioUnit = nil;
        self.mDidSetup = false;
    }
    @synchronized (self.mSamples) {
        self.mSamples = [NSMutableData new]; 
    }
}

- (void)stopAudioUnit
{
    if (_mAudioUnit != nil) {
        UInt32 isRunning = 0;
        UInt32 size = sizeof(isRunning);
        OSStatus status = AudioUnitGetProperty(_mAudioUnit,
                                            kAudioOutputUnitProperty_IsRunning,
                                            kAudioUnitScope_Global,
                                            0,
                                            &isRunning,
                                            &size);
        if (status != noErr) {
            NSLog(@"AudioUnitGetProperty IsRunning failed. OSStatus: %@", @(status));
            return;
        }
        if (isRunning) {
            status = AudioOutputUnitStop(_mAudioUnit);
            if (status != noErr) {
                NSLog(@"AudioOutputUnitStop failed. OSStatus: %@", @(status));
            } else {
                NSLog(@"AudioUnit stopped because no more samples");
            }
        }
    }
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

static OSStatus RenderCallback(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList *ioData)
{
    FlutterPcmSoundPlugin *instance = (__bridge FlutterPcmSoundPlugin *)(inRefCon);

    NSUInteger remainingFrames;
    BOOL shouldRequestMore = false;

    @synchronized (instance.mSamples) {

        // clear
        memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);

        NSUInteger bytesToCopy = MIN(ioData->mBuffers[0].mDataByteSize, [instance.mSamples length]);
        
        // provide samples
        memcpy(ioData->mBuffers[0].mData, [instance.mSamples bytes], bytesToCopy);

        // pop front bytes
        NSRange range = NSMakeRange(0, bytesToCopy);
        [instance.mSamples replaceBytesInRange:range withBytes:NULL length:0];

        remainingFrames = [instance.mSamples length] / (instance.mNumChannels * sizeof(short));

        // should request more frames?
        shouldRequestMore = remainingFrames <= instance.mFeedThreshold && !instance.mDidInvokeFeedCallback;
    }

    // stop running, if needed
    if (remainingFrames == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [instance stopAudioUnit];
        });
    }

    if (shouldRequestMore) {
        instance.mDidInvokeFeedCallback = true;
        NSDictionary *response = @{@"remaining_frames": @(remainingFrames)};
        dispatch_async(dispatch_get_main_queue(), ^{
            [instance.mMethodChannel invokeMethod:@"OnFeedSamples" arguments:response];
        });
    }

    return noErr;
}

@end
