//
//  DiscoveryManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/1/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "MDNSManager.h"
#import "TemporaryHost.h"

/// Posted, on the polling thread, when a poll changes a host's state, name, pair state or
/// running app (object: the host). The host list callback only reports new hosts.
extern NSString* const ArtemisHostUpdatedNotification;

@protocol DiscoveryCallback <NSObject>

- (void) updateAllHosts:(NSArray*)hosts;

@end

@interface DiscoveryManager : NSObject <MDNSCallback>

- (id) initWithHosts:(NSArray*)hosts andCallback:(id<DiscoveryCallback>) callback;
/// NO: only the hosts it was given are polled, no mDNS search (UI tests' stand-in PC).
@property (nonatomic) BOOL searchesNetwork;
- (void) startDiscovery;
- (void) stopDiscovery;
- (void) stopDiscoveryBlocking;
- (void) resetDiscoveryState;
- (BOOL) addHostToDiscovery:(TemporaryHost*)host;
- (void) removeHostFromDiscovery:(TemporaryHost*)host;
- (void) pauseDiscoveryForHost:(TemporaryHost *)host;
- (void) resumeDiscoveryForHost:(TemporaryHost *)host;
- (void) discoverHost:(NSString*)hostAddress withCallback:(void (^)(TemporaryHost*, NSString*))callback;

@end
