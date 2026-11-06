//
//  RootView.swift
//  Artemis
//

import SwiftUI

struct RootView: View {
    @Environment(ComputerStore.self) private var store
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.path) {
            ComputersView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .games(let hostID):
                        GamesView(hostID: hostID)
                    }
                }
        }
        .overlay {
            if let message = store.busyMessage {
                BusyOverlay(message: message, cancel: store.connecting == nil ? nil : { store.cancelConnecting() })
                    .transition(.opacity)
            }
        }
        .animation(.default, value: store.busyMessage)
        .sheet(item: $store.pairing, onDismiss: { store.cancelPairing() }) { pairing in
            PairingView(pairing: pairing)
        }
        .alert(store.alert?.title ?? "", isPresented: Binding(
            get: { store.alert != nil },
            set: { if !$0 { store.alert = nil } }
        ), presenting: store.alert) { alert in
            if alert.showsHelp {
                Button("Help") { openURL(Links.troubleshooting) }
            }
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }
}

/// A "working on it" card over the whole screen; touches don't go through. With `cancel`,
/// it has a Cancel button (connecting to a PC).
struct BusyOverlay: View {
    let message: String
    var cancel: (() -> Void)?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.2))
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(message)
                    .artemisFont(.headline)
                    .multilineTextAlignment(.center)
                if let cancel {
                    Button("Cancel", role: .destructive, action: cancel)
                        .artemisFont(.body)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .padding(.top, 4)
                        .accessibilityIdentifier("busy.cancel")
                }
            }
            .padding(28)
            .frame(minWidth: 200, maxWidth: 360)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .padding(32)
        }
        .accessibilityElement(children: cancel == nil ? .combine : .contain)
        .accessibilityIdentifier("busy")
    }
}
