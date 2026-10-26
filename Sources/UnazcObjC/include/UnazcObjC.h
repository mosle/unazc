#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// AVAudioEngine reports some failures (e.g. a tap format that no longer matches the device) by
// raising an Objective-C exception. Swift cannot catch those, and letting one unwind through Swift
// frames is undefined, so these calls are made directly inside @try here and returned as NSError.

/// Replaces the tap on the input node, then prepares and starts the engine.
BOOL UnazcStartInputTap(AVAudioEngine *engine, AVAudioFormat *format, AVAudioFrameCount bufferSize,
                        AVAudioNodeTapBlock block, NSError *_Nullable *_Nullable error);

/// Removes the input tap and stops the engine, each attempted even if the other raises.
/// Returns NO if either raised, so the caller can rebuild the engine before the next use.
BOOL UnazcStopInput(AVAudioEngine *engine);

NS_ASSUME_NONNULL_END
