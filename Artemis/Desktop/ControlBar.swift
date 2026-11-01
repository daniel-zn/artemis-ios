//
//  ControlBar.swift
//  Artemis
//
//  The connected screen's Liquid Glass controls: the control bar (floating and movable in
//  landscape, foldable into a round button; centred at the bottom when upright). The key row
//  above the keyboard is in KeyRow.swift.
//

import SwiftUI

struct ControlBar: View {
    let session: DesktopSession

    /// Folding and unfolding (the bar's glass and its place on the screen together); ten times
    /// slower in the UI tests' slow motion (-ArtemisDemoSlowMotion YES).
    static var foldAnimation: Animation {
        let spring = Animation.spring(duration: 0.45, bounce: 0.2)
        return UserDefaults.standard.bool(forKey: "ArtemisDemoSlowMotion") ? spring.speed(0.1) : spring
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            if session.isPortrait {
                // Upright: the bar's icons alone, centred under the desktop
                HStack(spacing: 2) { BarButtons(session: session) }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
            } else {
                FloatingBar(session: session)
            }
        }
        .buttonStyle(.plain)
        .animation(Self.foldAnimation, value: session.barExpanded)
        .animation(.snappy(duration: 0.25), value: session.isZoomed)
    }
}

/// Landscape: one piece of glass over the desktop, open (a capsule of icons, dragged by its
/// grip) or folded (a round button: dragged anywhere, a tap opens it). Folding shrinks the
/// capsule into the circle and unfolding grows it back out of it: the same glass, its width
/// animating, the icons fading inside it. (Two shapes swapped under one
/// glassEffectID don't morph, not even bare: they jump.) Folded and left untouched for a few
/// seconds, it fades to a faint button so it hides over the desktop; a touch brings the glass
/// back at once (and still does what it does), and the wait starts again after each.
private struct FloatingBar: View {
    let session: DesktopSession
    /// How long the folded bar stays glass after a touch.
    static var fadeDelay: Duration { .seconds(5) }
    /// The folded bar's size.
    static let button: CGFloat = 52

    @State private var faded = false
    /// Bumped by each touch: restarts the wait.
    @State private var touches = 0

    private var open: Bool { session.barExpanded }

    var body: some View {
        HStack(spacing: 2) {
            grip
            BarButtons(session: session)
            Button {
                session.actions.setBarExpanded(false)
            } label: {
                BarIcon(symbol: "chevron.compact.right")
            }
            .accessibilityLabel("Fold Control Bar")
            .accessibilityIdentifier("bar.fold")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .fixedSize()
        // Folded, the icons are still there, faded out and out of reach, so the glass around
        // them can shrink smoothly to the button and grow back, showing them as it goes
        .opacity(open ? 1 : 0)
        .allowsHitTesting(open)
        .accessibilityHidden(!open)
        .frame(width: open ? nil : Self.button, height: open ? nil : Self.button)
        .overlay {
            if !open {
                // Out quickly when it opens, so it isn't drawn over the icons coming back
                folded.transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.6)),
                                              removal: .opacity.animation(.easeOut(duration: 0.15))))
            }
        }
        .clipShape(.capsule)
        .glassEffect(!open && faded ? .clear : .regular, in: .capsule)
        .opacity(!open && faded ? 0.45 : 1)
        .onChange(of: open) { faded = false }
    }

    /// The folded button's face: its icon, the gestures and what VoiceOver finds.
    private var folded: some View {
        Image(systemName: "menubar.rectangle")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(faded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // Faded: a muted disc in the faint glass
                Circle().fill(Color(white: 0.5).opacity(faded ? 0.35 : 0))
            }
            .contentShape(.circle)
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged {
                    wake()
                    session.actions.moveBar($0.translation)
                }
                .onEnded { _ in
                    wake()
                    session.actions.endMoveBar()
                })
            .onTapGesture(perform: unfold)
            .task(id: touches) {
                guard (try? await Task.sleep(for: Self.fadeDelay)) != nil else { return }
                withAnimation(.easeInOut(duration: 0.8)) { faded = true }
            }
            .accessibilityElement()
            .accessibilityLabel("Control Bar")
            .accessibilityValue(faded ? "Faded" : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { unfold() }
            .accessibilityIdentifier("bar.unfold")
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(90))
            .frame(width: 22, height: 44)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { session.actions.moveBar($0.translation) }
                .onEnded { _ in session.actions.endMoveBar() })
            .accessibilityLabel("Move Control Bar")
            .accessibilityIdentifier("bar.grip")
    }

    private func wake() {
        if faded {
            withAnimation(.easeOut(duration: 0.15)) { faded = false }
        }
        touches &+= 1
    }

    private func unfold() {
        wake()
        session.actions.setBarExpanded(true)
    }
}

/// The bar's buttons, the same upright and in landscape.
private struct BarButtons: View {
    let session: DesktopSession

    var body: some View {
        Button {
            session.actions.toggleKeyboard()
        } label: {
            BarIcon(symbol: session.keyboardShown ? "keyboard.chevron.compact.down" : "keyboard",
                    active: session.keyboardShown)
        }
        .accessibilityLabel(session.keyboardShown ? "Hide Keyboard" : "Keyboard")
        .accessibilityIdentifier("bar.keyboard")

        Button {
            session.actions.setMode(session.mode == .trackpad ? .direct : .trackpad)
        } label: {
            BarIcon(symbol: session.mode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left")
        }
        .accessibilityLabel(session.mode == .trackpad ? "Trackpad Mode" : "Direct Mode")
        .accessibilityHint("Switches between moving the pointer like a trackpad and touching the desktop directly")
        .accessibilityIdentifier("bar.mode")

        Button {
            session.actions.toggleGamepad()
        } label: {
            BarIcon(symbol: session.gamepadShown ? "gamecontroller.fill" : "gamecontroller",
                    active: session.gamepadShown)
        }
        .accessibilityLabel(session.gamepadShown ? "Hide Controller" : "Controller")
        .accessibilityHint("Shows a game controller on the screen; the PC sees it as an Xbox controller")
        .accessibilityIdentifier("bar.gamepad")

        Menu {
            // The everyday ones first; the rest in submenus, so the menu fits in landscape
            ForEach(Shortcut.common) { shortcut in
                Button(shortcut.title, systemImage: shortcut.symbol) { session.actions.shortcut(shortcut) }
            }
            Menu("More Editing", systemImage: "pencil") {
                ForEach(Shortcut.moreEditing) { shortcut in
                    Button(shortcut.title, systemImage: shortcut.symbol) { session.actions.shortcut(shortcut) }
                }
            }
            Menu("Windows", systemImage: "macwindow.on.rectangle") {
                ForEach(Shortcut.windows) { shortcut in
                    Button(shortcut.title, systemImage: shortcut.symbol) { session.actions.shortcut(shortcut) }
                }
            }
            Button("Type Clipboard", systemImage: "doc.on.clipboard.fill") { session.actions.typeClipboard() }
        } label: {
            BarIcon(symbol: "command")
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Shortcuts")
        .accessibilityIdentifier("bar.shortcuts")

        // Upright, the reset button sits on the desktop's corner instead (DesktopViewController)
        if session.isZoomed && !session.isPortrait {
            Button {
                session.actions.resetZoom()
            } label: {
                BarIcon(symbol: "arrow.down.right.and.arrow.up.left")
            }
            .accessibilityLabel("Reset Zoom")
            .accessibilityIdentifier("bar.resetZoom")
            .transition(.scale.combined(with: .opacity))
        }

        Button {
            session.actions.disconnect()
        } label: {
            BarIcon(symbol: "xmark", tint: .red)
        }
        .accessibilityLabel("Disconnect")
        .accessibilityIdentifier("bar.disconnect")
    }
}

/// An icon of the bar (no caption: the buttons' accessibility labels name them).
private struct BarIcon: View {
    let symbol: String
    var active = false
    var tint: Color? = nil

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .medium))
            .frame(height: 24)
            .foregroundStyle(tint ?? (active ? Color.accentColor : Color.primary))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
    }
}
