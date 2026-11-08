//
//  StreamView.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "ControllerSupport.h"
#import "OnScreenControls.h"
#import "Moonlight-Swift.h"
#import "StreamConfiguration.h"

@protocol UserInteractionDelegate <NSObject>

- (void) userInteractionBegan;
- (void) userInteractionEnded;

@end

#if TARGET_OS_TV
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate>
#else
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate, UIPointerInteractionDelegate>
#endif

- (void) setupStreamView:(ControllerSupport*)controllerSupport
     interactionDelegate:(id<UserInteractionDelegate>)interactionDelegate
                  config:(StreamConfiguration*)streamConfig;
- (void) showOnScreenControls;
/// Artemis: finger touches go to the remote desktop controls (DesktopViewController) instead
/// of upstream's touch handlers, on-screen gamepad and three-finger keyboard. Mice, pens and
/// hardware keyboards stay with the StreamView.
- (void) useDesktopTouchHandler:(UIResponder*)handler;
/// Artemis: called with the pointer's position on the desktop (0–1) when a mouse moves it.
@property (nonatomic, copy) void (^pointerMoved)(CGPoint normalized);
// A hardware keyboard's key, before it goes to the PC: YES when it was taken (Ctrl+V, Cmd+V paste)
@property (nonatomic, copy) BOOL (^pasteKey)(UIPress* press, BOOL down) API_AVAILABLE(ios(13.4));
- (OnScreenControlsLevel) getCurrentOscState;

#if !TARGET_OS_TV
- (void) updateCursorLocation:(CGPoint)location isMouse:(BOOL)isMouse;
#endif

@end
