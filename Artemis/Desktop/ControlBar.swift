//
//  ControlBar.swift
//  Artemis
//
//  The connected screen's Liquid Glass controls: the control bar (floating and movable in
//  landscape, foldable into a button; centred at the bottom when upright). The key row above
//  the keyboard is in KeyRow.swift.
//

import SwiftUI

struct ControlBar: View {
    let session: DesktopSession

    var body: some View {
        Group {
            if session.isPortrait {
                docked
            } else if session.barExpanded {
                floating
            } else {
                folded
            }
        }
        .animation(.snappy(duration: 0.25), value: session.barExpanded)
        .animation(.snappy(duration: 0.25), value: session.isZoomed)
    }

    // MARK: Layouts

    /// Upright: the bar's icons alone, centred under the desktop.
    private var docked: some View {
        capsule { buttons() }
    }

    /// Landscape: over the desktop, dragged by its grip.
    private var floating: some View {
        capsule {
            grip
            buttons()
            Button {
                session.actions.setBarExpanded(false)
            } label: {
                BarIcon(symbol: "chevron.compact.right")
            }
            .accessibilityLabel("Fold Control Bar")
            .accessibilityIdentifier("bar.fold")
        }
    }

    /// The glass capsule of icons, the same upright and in landscape.
    private func capsule(@ViewBuilder _ content: () -> some View) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 2, content: content)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    /// Folded into a round button that can be dragged anywhere.
    private var folded: some View {
        FoldedBar(session: session)
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(90))
            .frame(width: 22, height: 44)
            .contentShape(.rect)
            .gesture(moveGesture)
            .accessibilityLabel("Move Control Bar")
            .accessibilityIdentifier("bar.grip")
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { session.actions.moveBar($0.translation) }
            .onEnded { _ in session.actions.endMoveBar() }
    }

    // MARK: Buttons

    @ViewBuilder
    private func buttons() -> some View {
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

/// The folded bar: a round glass button that, left untouched for a few seconds, fades to a flat,
/// faint one so it hides over the desktop. A touch brings the glass back at once (and still
/// does what it does: a tap unfolds the bar, a drag moves it); the wait starts again after each.
private struct FoldedBar: View {
    let session: DesktopSession
    /// How long it stays glass after a touch.
    static var fadeDelay: Duration { .seconds(5) }

    @State private var faded = false
    /// Bumped by each touch: restarts the wait.
    @State private var touches = 0

    var body: some View {
        Image(systemName: "menubar.rectangle")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(faded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(width: 52, height: 52)
            .background {
                // Faded: a flat, muted disc instead of the glass
                Circle().fill(Color(white: 0.5).opacity(faded ? 0.35 : 0))
            }
            .contentShape(.circle)
            .glassEffect(faded ? .identity : .regular.interactive(), in: .circle)
            .opacity(faded ? 0.45 : 1)
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged {
                    wake()
                    session.actions.moveBar($0.translation)
                }
                .onEnded { _ in
                    wake()
                    session.actions.endMoveBar()
                })
            .onTapGesture {
                wake()
                session.actions.setBarExpanded(true)
            }
            .task(id: touches) {
                guard (try? await Task.sleep(for: Self.fadeDelay)) != nil else { return }
                withAnimation(.easeInOut(duration: 0.8)) { faded = true }
            }
            .accessibilityElement()
            .accessibilityLabel("Control Bar")
            .accessibilityValue(faded ? "Faded" : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                wake()
                session.actions.setBarExpanded(true)
            }
            .accessibilityIdentifier("bar.unfold")
    }

    private func wake() {
        if faded {
            withAnimation(.easeOut(duration: 0.15)) { faded = false }
        }
        touches &+= 1
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
