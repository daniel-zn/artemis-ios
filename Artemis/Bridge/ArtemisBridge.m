//
//  ArtemisBridge.m
//  Artemis
//
//  Moved from MainFrameViewController (upstream Moonlight); behavior unchanged.
//

#import "ArtemisBridge.h"
#import "HttpManager.h"
#import "HttpRequest.h"
#import "HttpResponse.h"
#import "ServerInfoResponse.h"
#import "DiscoveryWorker.h"
#import "AppListResponse.h"
#import "ConnectionHelper.h"
#import "DataManager.h"
#import "TemporarySettings.h"
#import "ControllerSupport.h"
#import "Connection.h"
#import "StreamFrameViewController.h"
#import "Moonlight-Swift.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include <Limelight.h>

@implementation ArtemisBridge

+ (NSString*) refreshServerInfoForHost:(TemporaryHost*)host discovery:(DiscoveryManager*)discovery {
    HttpManager* hMan = [[HttpManager alloc] initWithHost:host];
    ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];

    // Exempt this host from discovery while handling the serverinfo request
    [discovery pauseDiscoveryForHost:host];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                                        fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
    [discovery resumeDiscoveryForHost:host];

    if (![serverInfoResp isStatusOk]) {
        Log(LOG_W, @"Failed to get server info: %@", serverInfoResp.statusMessage);
        return serverInfoResp.statusMessage ?: @"The PC didn't answer.";
    }

    // The rule discovery's polls follow: a paired PC that answers only without authenticating
    // isn't taken as unpaired (or as up) until it has refused for a while
    if (![DiscoveryWorker acceptResponse:serverInfoResp forHost:host]) {
        return [NSString stringWithFormat:@"%@ didn't accept a secure connection from this iPhone. If it's just waking up or going to sleep, try again in a moment.", host.name];
    }
    return nil;
}

+ (NSString*) refreshAppListForHost:(TemporaryHost*)host discovery:(DiscoveryManager*)discovery {
    // Exempt this host from discovery while handling the applist query
    [discovery pauseDiscoveryForHost:host];
    AppListResponse* appListResp = [ConnectionHelper getAppListForHost:host];
    [discovery resumeDiscoveryForHost:host];

    if (![appListResp isStatusOk] || [appListResp getAppList] == nil) {
        Log(LOG_W, @"Failed to get applist: %@", appListResp.statusMessage);
        return appListResp.statusMessage ?: @"The PC didn't send its apps.";
    }

    [self updateApplist:[appListResp getAppList] forHost:host];
    return nil;
}

+ (void) updateApplist:(NSSet*) newList forHost:(TemporaryHost*)host {
    DataManager* database = [[DataManager alloc] init];
    NSMutableSet* newHostAppList = [NSMutableSet setWithSet:host.appList];

    for (TemporaryApp* app in newList) {
        BOOL appAlreadyInList = NO;
        for (TemporaryApp* savedApp in newHostAppList) {
            if ([app.id isEqualToString:savedApp.id]) {
                savedApp.name = app.name;
                savedApp.hdrSupported = app.hdrSupported;
                // Don't propagate hidden, because we want the local data to prevail
                appAlreadyInList = YES;
                break;
            }
        }
        if (!appAlreadyInList) {
            app.host = host;
            [newHostAppList addObject:app];
        }
    }

    BOOL appWasRemoved;
    do {
        appWasRemoved = NO;

        for (TemporaryApp* app in newHostAppList) {
            appWasRemoved = YES;
            for (TemporaryApp* mergedApp in newList) {
                if ([mergedApp.id isEqualToString:app.id]) {
                    appWasRemoved = NO;
                    break;
                }
            }
            if (appWasRemoved) {
                // Removing the app mutates the list we're iterating (which isn't legal).
                // We need to jump out of this loop and restart enumeration.
                [newHostAppList removeObject:app];

                // It's important to remove the app record from the database
                // since we'll have a constraint violation now that appList
                // doesn't have this app in it.
                [database removeApp:app];
                break;
            }
        }

        // Keep looping until the list is no longer being mutated
    } while (appWasRemoved);

    host.appList = newHostAppList;
    [database updateAppsForExistingHost:host];
}

+ (BOOL) quitAppOnHost:(TemporaryHost*)host discovery:(DiscoveryManager*)discovery {
    HttpManager* hMan = [[HttpManager alloc] initWithHost:host];
    HttpResponse* quitResponse = [[HttpResponse alloc] init];
    HttpRequest* quitRequest = [HttpRequest requestForResponse: quitResponse withUrlRequest:[hMan newQuitAppRequest]];

    // Exempt this host from discovery while handling the quit operation
    [discovery pauseDiscoveryForHost:host];
    [hMan executeRequestSynchronously:quitRequest];
    if (quitResponse.statusCode == 200) {
        ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                                            fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
        if (![serverInfoResp isStatusOk] || [[serverInfoResp getStringTag:@"state"] hasSuffix:@"_SERVER_BUSY"] ||
            [DiscoveryWorker isRefusal:serverInfoResp forHost:host]) {
            // On newer GFE versions, the quit request succeeds even though the app doesn't
            // really quit if another client tries to kill your app. We'll patch the response
            // to look like the old error in that case, so the UI behaves.
            quitResponse.statusCode = 599;
        }
        else {
            // Update the host object with this info
            [serverInfoResp populateHost:host];
        }
    }
    [discovery resumeDiscoveryForHost:host];

    if (quitResponse.statusCode == 200) {
        host.currentGame = @"0";
        return YES;
    }
    return NO;
}

+ (void) setApp:(TemporaryApp*)app hidden:(BOOL)hidden {
    TemporaryHost* host = app.host;
    if (host == nil) {
        return;
    }
    for (TemporaryApp* savedApp in host.appList) {
        if ([app.id isEqualToString:savedApp.id]) {
            savedApp.hidden = hidden;
            [[[DataManager alloc] init] updateAppsForExistingHost:host];
            return;
        }
    }
}

+ (NSString*) runNetworkTest {
    // This may take a while.
    unsigned int portTestResult = LiTestClientConnectivity(CONN_TEST_SERVER, 443, ML_PORT_FLAG_ALL);
    if (portTestResult == 0) {
        return @"This network does not appear to be blocking Artemis. If you still have trouble connecting, check your PC's firewall settings.";
    }
    else if (portTestResult == ML_TEST_RESULT_INCONCLUSIVE) {
        return @"The network test could not be performed because none of the connection testing servers were reachable. Check your Internet connection or try again later.";
    }
    else {
        char blockedPorts[512];
        LiStringifyPortFlags(portTestResult, "\n", blockedPorts, sizeof(blockedPorts));
        return [NSString stringWithFormat:@"Your current network connection seems to be blocking Artemis. Connecting may not work while you're on this network.\n\nThe following network ports were blocked:\n%s", blockedPorts];
    }
}

+ (NSString*) addHostErrorMessage:(NSString*)error {
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443,
                                                            ML_PORT_FLAG_TCP_47984 | ML_PORT_FLAG_TCP_47989);
    if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
        return [error stringByAppendingString:@"\n\nYour device's network connection is blocking Artemis. Connecting may not work while you're on this network."];
    }
    return error;
}

+ (void) prepareSavedHost:(TemporaryHost*)host {
    // Initialize the non-persistent host state
    if (host.activeAddress == nil) {
        host.activeAddress = host.localAddress;
    }
    if (host.activeAddress == nil) {
        host.activeAddress = host.externalAddress;
    }
    if (host.activeAddress == nil) {
        host.activeAddress = host.address;
    }
    if (host.activeAddress == nil) {
        host.activeAddress = host.ipv6Address;
    }
}

+ (UIViewController*) streamViewControllerWithConfiguration:(StreamConfiguration*)config onExit:(void (^)(BOOL connected))onExit {
    StreamFrameViewController* stream = [[StreamFrameViewController alloc] init];
    stream.streamConfig = config;
    stream.onExit = onExit;
    stream.modalPresentationStyle = UIModalPresentationFullScreen;
    return stream;
}

+ (int) codecPreferenceOfSettings:(TemporarySettings*)settings {
    return (int)settings.preferredCodec;
}

+ (BOOL) isHevcSupported {
    return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
}

+ (BOOL) isAv1Supported {
    return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);
}

+ (BOOL) isHdrSupported {
    return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0;
}

+ (StreamConfiguration*) streamConfigurationForApp:(TemporaryApp*)app {
    StreamConfiguration* streamConfig = [[StreamConfiguration alloc] init];
    streamConfig.host = app.host.activeAddress;
    streamConfig.httpsPort = app.host.httpsPort;
    streamConfig.appID = app.id;
    streamConfig.appName = app.name;
    streamConfig.serverCert = app.host.serverCert;

    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];

    streamConfig.frameRate = [streamSettings.framerate intValue];
    // Don't stream more FPS than the display can show
    if (streamConfig.frameRate > [UIScreen mainScreen].maximumFramesPerSecond) {
        streamConfig.frameRate = (int)[UIScreen mainScreen].maximumFramesPerSecond;
        Log(LOG_W, @"Clamping FPS to maximum refresh rate: %d", streamConfig.frameRate);
    }

    streamConfig.height = [streamSettings.height intValue];
    streamConfig.width = [streamSettings.width intValue];

    streamConfig.bitRate = [streamSettings.bitrate intValue];
    streamConfig.optimizeGameSettings = streamSettings.optimizeGames;
    streamConfig.playAudioOnPC = streamSettings.playAudioOnPC;
    streamConfig.useFramePacing = streamSettings.useFramePacing;
    streamConfig.swapABXYButtons = streamSettings.swapABXYButtons;

    // multiController must be set before calling getConnectedGamepadMask
    streamConfig.multiController = streamSettings.multiController;
    streamConfig.gamepadMask = [ControllerSupport getConnectedGamepadMask:streamConfig];

    // Probe for supported channel configurations
    int physicalOutputChannels = (int)[AVAudioSession sharedInstance].maximumOutputNumberOfChannels;
    Log(LOG_I, @"Audio device supports %d channels", physicalOutputChannels);

    int numberOfChannels = MIN([streamSettings.audioConfig intValue], physicalOutputChannels);
    // The microphone's voice processing plays stereo at most
    streamConfig.enableMic = ArtemisSessionAudio.microphoneWanted;
    if (streamConfig.enableMic) {
        numberOfChannels = MIN(numberOfChannels, 2);
        Log(LOG_I, @"Microphone streaming on for this session");
    }
    Log(LOG_I, @"Selected number of audio channels %d", numberOfChannels);
    if (numberOfChannels >= 8) {
        streamConfig.audioConfiguration = AUDIO_CONFIGURATION_71_SURROUND;
    }
    else if (numberOfChannels >= 6) {
        streamConfig.audioConfiguration = AUDIO_CONFIGURATION_51_SURROUND;
    }
    else {
        streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    }

    streamConfig.serverCodecModeSupport = app.host.serverCodecModeSupport;

    switch (streamSettings.preferredCodec) {
        case CODEC_PREF_AV1:
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
                streamConfig.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN8;
            }
            // Fall-through

        case CODEC_PREF_AUTO:
        case CODEC_PREF_HEVC:
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
                streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265;
            }
            // Fall-through

        case CODEC_PREF_H264:
            streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H264;
            break;
    }

    // HEVC is supported if the user wants it (or it's required by the chosen resolution) and the SoC supports it
    if ((streamConfig.width > 4096 || streamConfig.height > 4096 || streamSettings.enableHdr) && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265;

        // HEVC Main10 is supported if the user wants it and the display supports it
        if (streamSettings.enableHdr && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
            streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265_MAIN10;
        }
    }

    // Add the AV1 Main10 format if AV1 and HDR are both enabled and supported
    if ((streamConfig.supportedVideoFormats & VIDEO_FORMAT_MASK_AV1) && streamSettings.enableHdr &&
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
        streamConfig.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN10;
    }

    return streamConfig;
}

@end
