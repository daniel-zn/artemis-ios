//
//  MicrophoneEncoder.h
//  Artemis
//
//  The microphone's Opus encoder (as the Mac app's: 48 kHz mono, VoIP, 64 kbit/s, 20 ms frames,
//  in-band FEC) and the hand-off to moonlight-common-c, which encrypts and sends each packet.
//  Opus's settings are variadic C calls, which Swift can't make: hence Objective-C.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MicrophoneEncoder : NSObject

/// 960: one 20 ms frame at 48 kHz.
@property (class, readonly) int frameSamples;

/// Nil if Opus couldn't make an encoder. `sendsToHost` NO only encodes (the demo mode's session).
- (nullable instancetype)initSendingToHost:(BOOL)sendsToHost;

/// Encodes one frame of `frameSamples` samples and sends it to the PC.
/// Returns the Opus packet's size, or a negative number if encoding or sending failed.
- (int)encodeAndSend:(const int16_t*)samples;

/// Packets encoded, and the duration of the last one in 48 kHz samples (Opus's own reading).
@property (readonly) NSInteger packetsEncoded;
@property (readonly) int lastPacketSamples;
/// Packets the PC was sent (sendto succeeded).
@property (readonly) NSInteger packetsSent;

@end

NS_ASSUME_NONNULL_END
