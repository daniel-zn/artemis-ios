//
//  MicrophoneEncoder.m
//  Artemis
//

#import "MicrophoneEncoder.h"
#import "Logger.h"

#include "Limelight.h"
#include "opus.h"

static const int kSampleRate = 48000;
static const int kFrameSamples = 960;
static const int kBitrate = 64000;

@implementation MicrophoneEncoder {
    OpusEncoder* _encoder;
    BOOL _sendsToHost;
    unsigned char _packet[1400];
    int _sendFailures;
}

+ (int)frameSamples {
    return kFrameSamples;
}

- (nullable instancetype)initSendingToHost:(BOOL)sendsToHost {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    int error = OPUS_OK;
    _encoder = opus_encoder_create(kSampleRate, 1, OPUS_APPLICATION_VOIP, &error);
    if (_encoder == NULL || error != OPUS_OK) {
        Log(LOG_W, @"opus_encoder_create() failed for the microphone: %s", opus_strerror(error));
        return nil;
    }
    // The Mac app's settings
    opus_encoder_ctl(_encoder, OPUS_SET_BITRATE(kBitrate));
    opus_encoder_ctl(_encoder, OPUS_SET_VBR(1));
    opus_encoder_ctl(_encoder, OPUS_SET_COMPLEXITY(10));
    opus_encoder_ctl(_encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    opus_encoder_ctl(_encoder, OPUS_SET_LSB_DEPTH(16));
    opus_encoder_ctl(_encoder, OPUS_SET_DTX(0));
    opus_encoder_ctl(_encoder, OPUS_SET_INBAND_FEC(1));
    opus_encoder_ctl(_encoder, OPUS_SET_PACKET_LOSS_PERC(5));
    opus_encoder_ctl(_encoder, OPUS_SET_EXPERT_FRAME_DURATION(OPUS_FRAMESIZE_20_MS));
    _sendsToHost = sendsToHost;
    return self;
}

- (void)dealloc {
    if (_encoder != NULL) {
        opus_encoder_destroy(_encoder);
    }
}

- (int)encodeAndSend:(const int16_t*)samples {
    int bytes = opus_encode(_encoder, samples, kFrameSamples, _packet, (opus_int32)sizeof(_packet));
    if (bytes <= 0) {
        return bytes < 0 ? bytes : -1;
    }
    _packetsEncoded++;
    _lastPacketSamples = opus_packet_get_nb_samples(_packet, bytes, kSampleRate);
    if (!_sendsToHost) {
        return bytes;
    }
    // Sent as soon as it's encoded: pacing frames to 20 ms would keep any backlog as delay;
    // the PC's jitter buffer smooths bursts (as the Mac app)
    int result = LiSendMicrophoneOpusDataEx(_packet, bytes, kFrameSamples);
    if (result < 0) {
        // The first failure, then every 5 seconds' worth
        if (_sendFailures++ % 250 == 0) {
            Log(LOG_W, @"Sending microphone audio failed (%d times so far)", _sendFailures);
        }
        return result;
    }
    if (_packetsSent++ == 0) {
        Log(LOG_I, @"Sent first client microphone packet (%d bytes Opus, %d samples)", bytes, _lastPacketSamples);
    }
    return bytes;
}

@end
