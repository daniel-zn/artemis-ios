# Touch controls for the remote desktop

Artemis is a remote desktop app: the iPhone controls a PC's desktop through Apollo. This is the spec for the touch
controls of the connected screen (`Artemis/Desktop/`). It follows the conventions of the established iOS remote
desktop apps (Microsoft's Remote Desktop / Windows App, Jump Desktop, Screens): a trackpad mode by default, a direct
touch mode, two-finger tap or press-and-hold for right click, three-finger tap for the keyboard, pinch to zoom with
pan, and a movable connection bar.

## Pointer modes

**Trackpad (default).** The screen is a laptop trackpad. Artemis keeps the pointer's position itself and sends it
as an absolute position (`LiSendMousePositionEvent`), so the zoomed view can follow it exactly. A new session starts
with the pointer in the middle of the desktop.

| Gesture | Result |
|---|---|
| One finger drag | Moves the pointer, with acceleration (slow = precise, fast = far); the pointer speed setting scales it |
| Tap | Left click (the release follows 0.2 s later, so a tap then a drag can still become a drag) |
| Double tap | Double click |
| Tap, then touch again and drag | Left drag (select text, move windows) |
| Press and hold (0.45 s, haptic), then drag | Left drag |
| Press and hold, then lift without moving | Right click |
| Two-finger tap | Right click (when zoomed in, it waits 0.25 s for a second two-finger tap) |
| Two-finger drag | Scroll, both directions, high-resolution, with momentum after the fingers lift; Natural moves the PC's content with the fingers: fingers up = wheel up, fingers left = wheel left (the opposite of a Mac trackpad's wheel signs, which scrolled backwards on the PC as seen from a real phone, 2026-11-02) |
| Pinch | Zooms the view on the iPhone (1× to 5×); moving the fingers while pinching pans |
| Two-finger double tap | Resets the zoom |
| Three-finger tap | Shows or hides the keyboard |
| Three-finger drag | Pans the zoomed view |

**Direct.** The desktop is touched where it shows. Tap = move there and left click; drag = left drag from where the
finger went down; press and hold (haptic) = right click there; two-finger tap = right click between the fingers. Two
fingers scroll and pinch as in trackpad mode; three fingers tap and pan the same.

Switch modes from the control bar (this session) or Settings › Touch & Pointer (the default).

A gesture is decided by the most fingers it had: lifting one of two fingers doesn't turn a scroll into a pointer
move. Two fingers become a zoom when their spread changes more than their centre moves, otherwise a scroll; the
choice holds until they lift. Movement under 8 points is a tap. A scroll's momentum takes the fingers' speed over the last 0.1 s
before the lift, and only the way they were going: real fingers land and lift a few frames apart and their contact
rolls back a few points as they come off the glass, which as one frame's speed is a fast swipe the other way (it used to
reverse the momentum, and with it short scrolls). `Scripts/touch-tests.sh` plays those timings to the
interpreter on the Mac (no Simulator).

## Zoom

The zoom is local (the PC's resolution doesn't change). Pinch zooms around the fingers; while zoomed the view can't
leave the desktop's edges. In trackpad mode the view follows the pointer: it scrolls when the pointer comes within 40
points of an edge. The control bar shows a reset button (`1×`) while zoomed; a two-finger double tap resets too.

## The control bar

A Liquid Glass capsule over the desktop in landscape; in portrait the same capsule of icons (same size and
spacing, without the grip and fold button), centred at the bottom of the screen under the trackpad, above the home
indicator (`DesktopTests/testUprightBarSpacedLikeLandscape`).

- Icons only, no captions (VoiceOver reads each button's name; each is at least 44 points;
  `DesktopTests/testBarShowsIconsOnly`): keyboard, pointer mode (trackpad / direct), controller (shows or hides the on-screen controller), shortcuts, zoom
  reset (while zoomed), disconnect (one tap ends the session, no confirming menu). There's no right-click
  button: a two-finger tap or a press and hold right-clicks. With the microphone on (Settings › Audio &
  Microphone) and the PC taking it, a microphone button mutes and unmutes it (struck through and red when muted).
- In landscape it can be dragged anywhere on the screen, up to 12 points from each edge (clear of the rounded
  corners), except beside the camera (the Dynamic Island or notch, on one side halfway up), where it stops at the
  safe area; it remembers where, keeps that after a rotation (turned over, the camera's side changes and the bar
  moves out of it), and unfolded next to an edge it shifts back inside (`testBarReachesEveryEdge`,
  `testBarEdgeAfterRotation`). It can be folded into a small round
  button; Settings › Touch & Pointer › Show control bar decides whether a session starts unfolded. Folded and
  left untouched for 5 seconds, the button fades from Liquid Glass to a flat, faint disc so it hides over the
  desktop (its accessibility value says "Faded"); a touch brings the glass back at once and the 5 seconds start
  again (`testFoldedBarFades`). While the on-screen controller is up the bar moves to the top centre, between the
  controller's shoulders (under them where it doesn't fit there, as on an iPhone SE); dragging it there is
  remembered separately.

## Keyboard

The iOS keyboard, with a key row above it that sends real key events (`LiSendKeyboardEvent`):

- Esc, Tab, Ctrl, Alt, Win, Shift, the arrows, Del, Home, End, Page Up / Down, and a second page with F1–F12.
  Fn (Back on the second page) is the first key in the row and scrolls sideways with the others
  (`DesktopTests/testKeyRowScrolls`).
- A key lights up and fires only on a tap: a finger that lands on a key and swipes the row sideways scrolls it,
  and that key neither lights up nor sends anything (the row's scroll view delays and cancels the key's touch,
  as UIKit's own scroll views do; `DesktopTests/testKeyRowScrolls`). The keys' glass isn't interactive (its own
  press effect reacts to any touch, swipes too, and draws past the key when tapped fast): a key grows as it lights
  up instead, and nothing of it is ever drawn outside it (`DesktopTests/testRapidKeyTapsLeaveNoGhost`).
- The hide-keyboard button (`keyboard.chevron.compact.down`) stays at the right end of the row on its own glass.
  The keys scroll on underneath it, fading out from just before it to its middle (a gradient mask on the row's
  scroll view, which runs the full width), and the row ends far enough to its left that the last key scrolls fully
  into view beside it. A swipe down on the row does nothing (`DesktopTests/testHideButtonClosesKeyboard`, upright
  and in landscape: the keys reach under the button, the last one ends beside it, the button stays put, a swipe
  down leaves the keyboard up, the button closes it and nothing else moves). The control bar's keyboard button and
  the three-finger tap open and close it too.
- Ctrl, Alt, Win and Shift are sticky: tap = held for the next key or click (then released), double tap = locked
  until tapped again. A typed letter with Ctrl held sends Ctrl+letter; a click with a modifier held sends e.g.
  Ctrl+click.
- Typed text: letters (Shift for capitals), digits, space, Tab and US punctuation (with Shift where a US keyboard
  needs it) as key events, the way upstream's `KeyboardSupport` translates them; other characters (accents, emoji) as
  Unicode text (`LiSendUtf8TextEvent`). Backspace and Return are keys. Keys matter on Windows' sign-in screen, UAC
  and Ctrl+Alt+Del screens (the secure desktop): they ignore Unicode text, so a password typed there must be keys.
  A password with characters that have no US key (é, £, €) can't be typed there.
- Hardware keyboards work as in upstream Moonlight (`KeyboardSupport`), with or without the on-screen keyboard.

Shortcuts menu (control bar): Copy, Paste, Undo, Select All; More Editing (Cut, Redo, Find, Save); Windows: Switch Apps (Alt+Tab), Start
(Win), Show Desktop (Win+D), File Explorer (Win+E), Task Manager (Ctrl+Shift+Esc), Close Window (Alt+F4),
Screenshot (Win+Shift+S); Type Clipboard (types the iPhone's clipboard text, as keys like typed text, so a copied
password works on the sign-in screen; the sticky modifiers don't apply). Not offered: Ctrl+Alt+Del and Win+L —
Windows reserves them (the secure attention sequence) and ignores them when they come from injected input, which is
how Apollo types.

## Layout

- **Landscape:** the desktop fills the screen (letterboxed to its aspect ratio, inside the safe area horizontally),
  with the floating control bar.
- **Portrait:** the desktop fits the top of the screen. Below it a trackpad area (always trackpad; no click buttons:
  tap to click, two-finger tap or press and hold to right-click), then the control bar at the bottom. In direct mode
  there's no trackpad area: the desktop moves (animated) to the middle between the top of the safe area and the bar,
  and back to the top with the trackpad in trackpad mode or with the on-screen controller up
  (`DesktopTests/testDirectModeUprightCentresDesktop`). The desktop moves in front of the fading trackpad,
  both ways (`DesktopTests/testModeSwitchMovesDesktopInFrontOfTrackpad`).
- The keyboard and its key row lie on top: the desktop, the trackpad area and the control bar keep their size and
  place when it opens or closes, even where it covers them (`DesktopTests/testKeyboardOverlays`).
- Haptics: light on clicks, medium when a press and hold starts, selection ticks on modifier keys.
- **System gestures** need a second swipe during a session, so the sticks, the trackpad and the desktop can be used
  right up to the edges (iOS reserves strips at the top and bottom): the first swipe from the top only shows the tab,
  a second opens Notification or Control Centre; the first swipe up from the bottom only shows the home indicator, a
  second goes home. The session's presented controller (StreamFrameViewController, or the demo's) defers every edge
  (`preferredScreenEdgesDeferringSystemGestures` = all, asked again on appear and after a rotation; the desktop's
  state line reads `edges all`) and hides the home indicator. A stick pushed from its bottom next to the screen's
  edge still reaches the stick, and a fast swipe from the bottom edge over it doesn't leave the app
  (`OnScreenGamepadTests/testStickNearBottomEdge`). Outside a session the app behaves as any app. The status bar
  stays hidden.

## Mapping to Moonlight's input calls

| Action | Call |
|---|---|
| Pointer position | `LiSendMousePositionEvent(x, y, streamWidth, streamHeight)` |
| Buttons | `LiSendMouseButtonEvent(BUTTON_ACTION_PRESS/RELEASE, BUTTON_LEFT/RIGHT/MIDDLE)` |
| Scroll | `LiSendHighResScrollEvent` / `LiSendHighResHScrollEvent` (120 = one notch; one notch per ~24 points at speed 1) |
| Keys | `LiSendKeyboardEvent(vk, KEY_ACTION_DOWN/UP, modifiers)` |
| Typed characters | `LiSendKeyboardEvent2(vk, …, SS_KBE_FLAG_NON_NORMALIZED)` with VK_LSHIFT around shifted ones; `LiSendUtf8TextEvent` for characters with no US key |

The calls run on one serial queue, so a click's press and release (30 ms apart) keep their order with what follows.

## Settings › Touch & Pointer

Default mode (Trackpad / Direct), Pointer speed, Natural scrolling (content follows the fingers, on by default,
as on a Mac's trackpad; off reverses both axes and the momentum; `DesktopTests/testScrollDirectionFollowsFingers`, upright
on the trackpad area and in landscape on the desktop), Show control bar.

## Testing without a PC

`-ArtemisDemo YES` connects to a picture of a desktop instead of a stream and records the input events the gestures
produce (the desktop's accessibility value). `ArtemisUITests/DesktopTests.swift` performs each gesture and checks
the events, upright and in landscape; `testTypedPassword` types "Pa55word!" on the iOS keyboard and with Type
Clipboard and checks both are key events (Shift+P, A, 5, 5, W, O, R, D, Shift+1).

## On-screen controller

The control bar's controller button (`gamecontroller`) shows an Xbox-style controller of Liquid Glass buttons; the
PC sees an Xbox controller (`Artemis/Desktop/OnScreenGamepad.swift`, adapted from RetroPlay's pad).

- One layout for both orientations (`PadLayout.controls(in:scale:phoneWidth:)`): a column at each side of its area, the left
  stick over the D-pad and A B X Y over the right stick (each pair on one centre line); L3 LT LB at the top left
  corner and RB RT R3 at the top right; Select / Xbox / Start in a row at the bottom centre. **Portrait:** the area
  is the trackpad's place, between the desktop and the control bar, and the row sits under the columns, just above
  the bar. **Landscape:** it lies over the desktop, see-through, inside the safe area (8 points in from the
  notch's inset and from the desktop picture's sides, so nothing hangs out over the black bars beside it, at least 16
  from the edge, clear of the home indicator), with the row between the columns.
- Controls: left and right sticks, D-pad (eight ways), A B X Y, LB RB, LT RT (fully pulled while held), Select (the
  Xbox controller's Back / View), Start (its Start / Menu), the Xbox (Guide) button, and L3 / R3 (the stick clicks).
- The sticks and the D-pad are RetroPlay's PSP pad's: the same touch code (`PadTouch.swift` is RetroPlay's
  `PadTouchView` line for line with a second stick; `PadHitTesting.swift` is its geometry file as it is), drawing,
  sizes and colours (see "Sticks and D-pad: the same as RetroPlay's" below). A stick of 122 points × RetroPlay's
  scale for the phone, its knob 46 % of it and moving 30 % of it; the stick's centre is zero and the knob goes where
  the thumb is (it doesn't float to where the thumb lands), full tilt at 22.5 % of its size from the centre (three
  quarters of the knob's travel), an 8 % dead zone taken out smoothly, clamped to the unit circle, full tilt held
  past the rim, back to the centre when the thumb lifts. The D-pad (144 points × the scale): eight ways, a dead
  middle of 12 % of its size, diagonals where the weaker axis is at least 42 % of the stronger, a thumb slides
  between directions. Upright on the plain background they're dark tinted glass (RetroPlay's PSP colours); over the
  desktop, clear glass. Each control's glass is drawn on its own (no shared container), so a stick's knob is a
  separate glass disc with its shadow over the well.
- Touch: several fingers at once (a stick, a trigger and a face button); a thumb slides between face buttons and
  holds both in the gap; a slightly missed tap goes to the nearest control (14 points); a stick or D-pad touch keeps
  steering off its edge. Light haptic on each new press of a button or D-pad direction (the sticks don't tick).
  VoiceOver: each button presses, the D-pad and sticks have direction actions.
- Touches on the controller don't move the pointer; in landscape, touches between its controls go to the desktop as
  usual. The keyboard lies over it (nothing moves).
- Each session starts with it hidden (not remembered: a remote desktop session usually wants the trackpad first);
  it stays up across rotation.
- To the PC: `connectVirtualGamepad` / `sendVirtualGamepadButtons…` / `disconnectVirtualGamepad` in
  `ControllerSupport`. With Multiple controllers on, it takes the first player number (0–3) no connected controller
  has, controllers connecting later skip it, and the active-gamepad mask includes it (Apollo takes up to 16; with
  four controllers connected it's number 4); with it off it's player 1 like every controller, and its state and the
  connected controllers' are merged (buttons together, the larger trigger and stick), so neither releases what the
  other holds. Arrival (`LiSendControllerArrivalEvent`, `LI_CTYPE_XBOX`, its buttons) goes with its first
  state, sent as soon as it shows (`LiSendMultiControllerEvent`, at rest). Hiding it, disconnecting or leaving the
  session sends it at rest, then without its bit in the mask, so the PC removes it. Fingers lifting with the app
  going away release everything.
- Settings › Controllers › On-Screen Controller: Size (Small / Medium / Large: 80 / 90 / 100 % of RetroPlay's size
  for the phone, Large by default, smaller still where the space is too small: on an iPhone SE upright Large is about
  83 % of the design size) and Opacity (30–100 %, 75 % by default, as RetroPlay's pad), both orientations.
- Tests: `OnScreenGamepadTests` (the demo desktop records `gamepad connect`, `gamepad <buttons> lt rt ls x y rs x y`,
  `gamepad disconnect`): A, RT, Xbox, Start, Select, L3, R3, D-pad, both sticks, A + LT + a stick at once, shown and
  hidden in portrait and landscape, large text; `testGamepadLayout` checks the layout upright and in landscape at
  Small, Medium and Large (columns on one centre line within 1 point and at the sides, the shoulders above them with
  the stick clicks outside, the row centred at the bottom; every control inside the safe area, in landscape over the
  desktop's picture too, and at least 4 points from every other, measured between their real shapes).

### Sticks and D-pad: the same as RetroPlay's

RetroPlay's PSP pad (`RetroPlayApp/Controls/PadTouchSurface.swift`, `PadControls.swift` `PadStick` / `PadDPad`,
`ConsolePad.swift` `.psp`, `RetroPlayCore/Play/PadHitTesting.swift`) against Artemis's as of 1.0 (1276), and what
changed (2026-10-23):

| | RetroPlay PSP | Artemis 1.0 (1276) | Now |
|---|---|---|---|
| Origin | Fixed: the stick's centre is zero, the knob goes where the thumb is (`TouchStick`) | Same | Same code |
| Travel for full tilt | 22.5 % of the stick's size (`touchTravelFraction` = 0.30 × 0.75) | Same | Same code |
| Dead zone, curve | 8 % of the travel, rescaled away linearly (`analogUnit`); clamped to the unit circle | Same | Same code |
| Past the rim / off the graphic | Full tilt toward the thumb; the touch keeps steering until it lifts | Same | Same code |
| Hit area | Circle + 14 pt reach; under the finger first, else the nearest control | Same | Same code |
| Multi-touch | Each finger owns the control it landed on; a stick reads its own finger | Same | Same code |
| D-pad | 12 % dead middle, diagonals at 42 %, the finger keeps steering it | Same | Same code |
| Haptics | Light tick (0.7) on a new button / D-pad press, none for the stick | Same | Same code |
| Value carried | `Float` (rounded from `TouchStick`'s `Double`) | `CGFloat` (not rounded) | `Float`, bit for bit |
| Knob look | 46 % of the stick, moving 30 %, its own glass + a 0.45 shadow over the well's glass | Same sizes, but every control in one `GlassEffectContainer`: the knob's glass melted into the well's | Each control's glass on its own |
| Size on screen | 122 pt × the phone's scale (iPhone 17 Pro: × 1.088 ≈ 133 pt stick, 157 pt D-pad) | 122 pt × 90 % (Medium, the default) ≈ 110 pt, D-pad ≈ 130 pt | RetroPlay's scale × Large by default; less only where it doesn't fit (iPhone 17 Pro: ≈ 124 pt upright, under the desktop; ≈ 127 pt in landscape, kept clear of the home indicator) |
| Opacity | 75 % by default | 85 % by default | 75 % by default |
| To the game / PC | −1…1 to PPSSPP | × 32767 (−1 → −32767) | Xbox range: −1 → −32768, 1 → 32767 (`PadHeld.xboxAxis`) |
| Layout | PSP: D-pad above the stick, one stick | Xbox: left stick above the D-pad, a second stick under A B X Y | Kept (an Xbox controller) |

`Scripts/pad-parity/run.sh` (with `RETROPLAY=<its repository>`) proves it: it checks `PadHitTesting.swift` is still
RetroPlay's, builds RetroPlay's own `PadTouchSurface.swift` and Artemis's `PadTouch.swift` into one Mac Catalyst tool,
plays the same touch traces on both (from the centre and off it, a slow drag past the rim, a flick to the edge,
sliding off the stick and back, landing just outside the well, out of reach, a spiral, stick + D-pad + button at
once, a tap on every point of a 6 pt grid over and around the D-pad, a sweep around it) at four stick sizes
(about 10 000 steps) and fails on any difference in x, y or the buttons at any step; it also checks the Xbox range.
(Two thumbs on one stick isn't compared: both apps then take whichever thumb comes first in a dictionary, which
changes from run to run.)

## Game controllers

A controller connected to the iPhone (Xbox, PlayStation, MFi) goes to the PC as a gamepad (upstream's
`ControllerSupport`; upstream's on-screen controls are never shown, Artemis has its own above). Start, Select, LB
and RB together disconnect. Select (the Xbox controller's View, a PlayStation controller's Share / Create) is the
Xbox Back button; on a controller without an Xbox / Home button, Select with Start is the Guide button (upstream's
stand-in). During a session the controller's buttons go to the GameController framework only (a
`GCEventInteraction` on the session's view), not to UIKit's controller navigation, which the app otherwise opts into
(`GCSupportsControllerUserInteraction`); system gestures on every button are turned off, as upstream does.

The UI tests connect a `GCVirtualController` (`-ArtemisDemoController "<steps>"`) that the real `ControllerSupport`
reads; what it would send goes to the demo's record (`ControllerTests/testConnectedController*`). The virtual
controller has no Home button, and no D-pad next to a left stick.

**As the mouse.** Hold Start (Menu) for 0.75 s to switch the controller to the mouse; a notice says "Controller
mouse on". Hold it again to switch back. While it's the mouse, nothing goes to the PC as a gamepad (Select does
nothing, as in the Mac app).

| Control | Result |
|---|---|
| Left stick | Moves the pointer (squared response past a 15 % dead zone; 1500 px/s at full tilt × the pointer speed) |
| Right stick | Scrolls, both directions (up to 12 notches a second) |
| A / B / X | Left / right / middle button (held while held) |
| LB / RB | Back / forward |
| D-pad | One scroll step |
| Y | Shows or hides the keyboard |

Settings › Controllers › Mouse control with a controller (on by default) allows the long press. The mapping is
`Artemis/Desktop/GamepadMouse.swift`; `ControllerSupport` hands it each controller's state before sending it.

