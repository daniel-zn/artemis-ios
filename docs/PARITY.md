# Artemis for iPhone and the Mac app

What the macOS client ([daniel-zn/danielzn-moonlight-qt](https://github.com/daniel-zn/danielzn-moonlight-qt), its
native Mac interface) does, and how Artemis on the iPhone does the same. Mac labels are quoted from the Mac app
(`app/gui/PcView.qml`, `AppView.qml`, `MacMenuBar.qml`, `SettingsView.qml`); the iPhone words them for a remote
desktop (apps rather than games, a session rather than a stream). Checked against the Mac app's `main` on 2026-10-17.

✅ done · ➖ not on iPhone (why) · 🔜 later · ➕ iPhone only

## Computers

| Feature | Mac | iPhone | |
|---|---|---|---|
| Open a PC | Double-click or Return: apps when paired, pairing when not, wake when offline | Tap: the same | ✅ |
| Wake an asleep PC | Double-click or "Wake PC"; "Waking up…" until it's online or 90 s pass | Tap (then it opens once up) or "Wake PC" in the menu (stays on the list); "Waking up…" with a spinner until a poll sees it online, or 90 s, then back to Offline with "… Didn't Wake Up" | ✅ |
| Opens after waking | No (the list only updates) | Yes, when a tap woke it | ✅ (the iPhone does more) |
| Status line | Waking up… · Connecting… · Offline · Double-click to wake · Offline · Not paired · Double-click to pair · Online | Waking up… · Connecting… · Offline · Tap to wake · Offline · Not paired · Tap to pair · Online (· *app* active) | ✅ |
| Status icon | Spinner, moon (asleep), lock (unpaired), chevron | Spinner, moon, lock badge, chevron | ✅ |
| "Open" / "Pair…" | Menu | Long-press menu | ✅ |
| "Show All Games, Including Hidden" | Menu | "View All Apps, Including Hidden" (doesn't connect automatically) | ✅ |
| "Test Network…" | Menu, Help | Long-press menu, Help menu | ✅ |
| "Rename…" | Dialog | Long-press menu, dialog; empty goes back to the PC's own name (kept on the iPhone, as polls bring the PC's name back) | ✅ |
| "Get Info" | Name, Status, Active/Local/Remote/IPv6/Manual Address, UUID, MAC, Pair State, Running Game ID, HTTPS Port | The same fields in a sheet (plus the PC's own name when renamed); values can be copied | ✅ |
| "Remove…" | Menu, ⌘⌫, confirmation | Long-press menu, swipe, confirmation | ✅ |
| Add Computer | ⌘N, by address | + button, by address | ✅ |
| Looking for computers | Empty-state text | Empty state with Add PC Manually | ✅ |
| NVIDIA GameStream notice | — | Menu item for NVIDIA hosts (upstream's) | ✅ |
| Home-screen quick actions | — | A PC per quick action (upstream's) | ✅ |

## Apps

| Feature | Mac | iPhone | |
|---|---|---|---|
| Launch / resume | Double-click, "Launch Game"/"Resume Game", ⌘R | Tap, "Connect"/"Resume" | ✅ |
| Running badge, inline Resume / Quit | "Running", Resume, Quit | "Active", Resume, Stop | ✅ |
| Opening another app while one runs | Quit dialog, then launch | "… is active": Stop It and Open / Resume / Cancel | ✅ |
| "Quit Game" / "End Game on PC…" | Menu, confirmation | "Stop", confirmation ("Stop *app* on *PC*?"), swipe | ✅ |
| "Launch Automatically When Opening PC" | Checkable, one per PC; disabled for hidden apps | "Connect Automatically When Opening PC", the same rules; the row says "Connects automatically"; skipped when another app is active | ✅ |
| "Hide Game" | Checkable; not for the running or the automatic app | "Hide App" / "Show App", swipe; the same rules | ✅ |
| Search | — | — (removed in Oct 2026: no search field at the bottom of the apps) | ✅ |
| Refresh | Toolbar "Update" | ⋯ › Refresh, pull to refresh | ✅ |

## Menu bar (Mac) → iPhone

| Mac menu | iPhone |
|---|---|
| Computer: Add Computer…, Open, Show All Games, Pair…, Wake, Rename…, Test Network…, Get Info, Remove… | The + button and each PC's long-press menu (all of them) |
| Game: Launch/Resume, End Game on PC…, Launch Automatically, Hide Game | Each app's long-press menu and swipe actions |
| Go: Back, Computers, Settings… | Navigation back, the Settings button |
| Window: Minimize, Zoom | ➖ iPhone apps have no windows |
| Help: Setup Guide, Troubleshooting, About | Help menu (?) and Settings › General (version) |

## Settings

| Mac section › option | iPhone | |
|---|---|---|
| Video › Resolution (Native, Native Excluding Notch, 720p…4K, Custom) | Same list for this iPhone (360p–4K, Native, Native Excluding Notch, Custom); Native by default (settings still at upstream's 720p move to it once, marked done only once it's stored) | ✅ |
| Video › FPS (30, 60, display rates, Custom) | 30, 60, 120 on ProMotion iPhones | ✅ |
| Video › Bitrate slider, default per resolution | Same notches and defaults | ✅ |
| Video › Display mode (fullscreen / windowed) | ➖ always full screen or upright with the trackpad | ➖ |
| Video › V-Sync | ➖ iOS presents in sync with the display | ➖ |
| Video › Frame pacing, Enable HDR | Same | ✅ |
| Audio › Audio configuration (stereo, 5.1, 7.1) | ➖ stereo: the iPhone and AirPods play stereo; upstream iOS only offers surround on Apple TV | ➖ |
| Audio › Mute host PC speakers | "Mute the PC's speakers during a session" | ✅ |
| Audio › Mute when not the active window | ➖ an iPhone session is always the active app | ➖ |
| Audio › Microphone streaming, device, noise suppression, test | Enable microphone streaming (off by default), Input (iPhone / Headset / Bluetooth Microphone), Test microphone with a level meter; noise suppression is Apple's voice processing, always on (echo cancellation too) instead of a switch; a denied permission is one line with Open Settings, no alert | ✅ (noise suppression: no switch) |
| Keyboard & Mouse › Optimize mouse for remote desktop | ➖ always: Artemis sends absolute positions (remote desktop mode) | ✅ (built in) |
| Keyboard & Mouse › Capture system shortcuts | ➖ iOS doesn't let apps capture system shortcuts; the key row sends Win, Alt+Tab etc. | ➖ |
| Keyboard & Mouse › Touchscreen as a virtual trackpad | Touch & Pointer › Trackpad / Direct, pointer speed, natural scrolling, control bar | ✅ |
| Keyboard & Mouse › Swap left and right mouse buttons | Same, for a mouse connected to the iPhone | ✅ |
| Keyboard & Mouse › Reverse mouse scrolling | Touch & Pointer › Natural scrolling for touch; not offered for a connected mouse | ✅ / ➖ |
| — | Citrix X1 mouse support (upstream's) | ✅ |
| Controllers › Swap A/B and X/Y | Same | ✅ |
| Controllers › Force gamepad #1 always connected | "Multiple controllers" off = every controller is player 1, always connected (upstream's) | ✅ |
| Controllers › Mouse control by holding Start | "Mouse control with a controller" (on by default) | ✅ |
| Controllers › Gamepad input in the background | ➖ iOS stops controller input in the background | ➖ |
| Host › Optimize game settings | "Optimize app settings for the session" | ✅ |
| Host › Quit app on host after ending stream | "Stop the app on the PC after a session" | ✅ |
| General › Language | ➖ iOS sets each app's language in the Settings app | ➖ |
| General › GUI display mode | ➖ | ➖ |
| General › Connection quality / configuration warnings | ➖ not in upstream iOS; the stats overlay shows the connection | ➖ |
| General › Discord Rich Presence | ➖ no Discord on iOS for this | ➖ |
| General › Keep the display awake | ➖ always during a session | ✅ (built in) |
| Advanced › Video decoder | ➖ always hardware (VideoToolbox) | ➖ |
| Advanced › Video codec | Same | ✅ |
| Advanced › Renderer (Metal, AVSampleBufferDisplayLayer…) | ➖ upstream's single renderer | ➖ |
| Advanced › YUV 4:4:4, unlock bitrate limit | ➖ not supported by the iOS decoder path / not offered upstream | ➖ |
| Advanced › Find PCs automatically, detect blocked connections | ➖ always on | ✅ (built in) |
| Advanced › Performance stats | Video & Display › Show performance stats | ✅ |

## Dialogs

| Mac | iPhone | |
|---|---|---|
| Pairing PIN (Cancel) | PIN sheet (Cancel) | ✅ |
| Remove PC | Same | ✅ |
| Rename PC | Same | ✅ |
| Get Info | Sheet | ✅ |
| Test Network (testing, result) | Busy card, result | ✅ |
| Add PC | Sheet | ✅ |
| Quit game confirmation | "Stop *app* on *PC*?" with Stop | ✅ |
| Errors with a help link (connect, no MAC to wake, GFE) | Same, with Help; plus "… Didn't Wake Up" | ✅ |
| Quit the app? | ➖ iOS apps don't quit | ➖ |

## During a session

| Mac | iPhone | |
|---|---|---|
| Keyboard, mouse | Touch controls (docs/TOUCH.md), the iOS keyboard with a key row, hardware keyboards and mice | ✅ |
| Gamepads passed to the PC | Xbox, PlayStation and MFi controllers (GameController): buttons, sticks, triggers, rumble, motion, touchpad, battery, LED (upstream's on-screen controls stay off) | ✅ |
| ➖ (no touch screen) | On-screen controller from the control bar: an Xbox controller on the PC (sticks, D-pad, A B X Y, bumpers, triggers, Select, Start, Xbox, L3 / R3); one layout in the trackpad's place upright and over the desktop in landscape; size and opacity in Settings › Controllers | ➕ |
| Gamepad mouse: hold Start 0.75 s; stick moves, A/B/X click, LB/RB back/forward, D-pad scrolls; "Gamepad mouse mode active" notice | Same, plus the right stick scrolls and Y opens the keyboard; "Controller mouse on" notice | ✅ |
| Start+Select+L1+R1 disconnects | Same | ✅ |
| Select+L1+R1+X stats overlay | ➖ not in upstream iOS (setting in Video & Display) | ➖ |
| The app's own screens by controller | ➖ Mac: SDL gamepad navigation | ➖ not done: SwiftUI focus on iPhone isn't moved by a controller (iPad's focus system follows a keyboard, Apple TV's the remote); not verified on a device |
| Microphone | To Apollo (its v2 microphone protocol), 48 kHz mono Opus, 20 ms frames sent as captured | Same; the PC's audio plays through the same voice-processing engine so the iPhone's speaker isn't heard back; a microphone button in the control bar mutes it | ✅ (+ mute) |
