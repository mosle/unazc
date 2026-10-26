#import "UnazcObjC.h"

static NSError *ErrorFromException(NSException *exception) {
    return [NSError errorWithDomain:exception.name
                               code:0
                           userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}];
}

BOOL UnazcStartInputTap(AVAudioEngine *engine, AVAudioFormat *format, AVAudioFrameCount bufferSize,
                        AVAudioNodeTapBlock block, NSError **error) {
    @try {
        AVAudioInputNode *input = engine.inputNode;
        [input removeTapOnBus:0];
        [input installTapOnBus:0 bufferSize:bufferSize format:format block:block];
        [engine prepare];
        if (![engine startAndReturnError:error]) {
            [input removeTapOnBus:0];
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        @try {
            [engine.inputNode removeTapOnBus:0];
        } @catch (NSException *ignored) {
        }
        if (error) *error = ErrorFromException(exception);
        return NO;
    }
}

BOOL UnazcStopInput(AVAudioEngine *engine) {
    BOOL ok = YES;
    @try {
        [engine.inputNode removeTapOnBus:0];
    } @catch (NSException *ignored) {
        ok = NO;
    }
    @try {
        [engine stop];
    } @catch (NSException *ignored) {
        ok = NO;
    }
    return ok;
}
