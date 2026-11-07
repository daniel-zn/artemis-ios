//
//  HttpManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/16/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "HttpResponse.h"
#import "HttpRequest.h"
#import "StreamConfiguration.h"
#import "TemporaryHost.h"

@interface HttpManager : NSObject <NSURLSessionDelegate>

- (id) initWithHost:(TemporaryHost*) host;
- (id) initWithAddress:(NSString*) hostAddressPortString httpsPort:(unsigned short) httpsPort serverCert:(NSData*) serverCert;
- (void) setServerCert:(NSData*) serverCert;
- (NSURLRequest*) newPairRequest:(NSData*)salt clientCert:(NSData*)clientCert;
- (NSURLRequest*) newUnpairRequest;
- (NSURLRequest*) newChallengeRequest:(NSData*)challenge;
- (NSURLRequest*) newChallengeRespRequest:(NSData*)challengeResp;
- (NSURLRequest*) newClientSecretRespRequest:(NSString*)clientPairSecret;
- (NSURLRequest*) newPairChallenge;
- (NSURLRequest*) newAppListRequest;
- (NSURLRequest*) newServerInfoRequest:(bool)fastFail;
- (NSURLRequest*) newHttpServerInfoRequest:(bool)fastFail;
- (NSURLRequest*) newHttpServerInfoRequest;
- (NSURLRequest*) newLaunchOrResumeRequest:(NSString*)verb config:(StreamConfiguration*)config;
- (NSURLRequest*) newQuitAppRequest;
- (NSURLRequest*) newAppAssetRequestWithAppId:(NSString*)appId;
- (void) executeRequestSynchronously:(HttpRequest*)request;

/// Apollo's shared clipboard, /actions/clipboard?type=text over the paired HTTPS connection
/// (blocking): a GET when body is nil, otherwise a POST of it (UTF-8 text). Returns the HTTP
/// status, or -1 without an answer; a GET's answer goes in responseBody.
- (NSInteger) clipboardRequestWithBody:(NSData*)body responseBody:(NSData**)responseBody timeout:(NSTimeInterval)timeout;

/// UI tests' stand-in PC (-ArtemisTestFakePC): these URL protocols answer every request.
+ (void) setTestProtocolClasses:(NSArray*)classes;

@end


