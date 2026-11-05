//
//  ComputersView.swift
//  Artemis
//
//  The PCs list, as the Mac app's Computers window: a row per PC with its status;
//  tapping opens its apps, pairs it or wakes it.
//

import SwiftUI

struct ComputersView: View {
    @Environment(ComputerStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var removing: Computer?
    @State private var renaming: Computer?
    @State private var newName = ""
    @State private var showingInfo: Computer?

    var body: some View {
        List {
            ForEach(store.computers) { computer in
                Button {
                    store.open(computer.id)
                } label: {
                    ComputerRow(computer: computer)
                }
                .tint(.primary)
                .accessibilityIdentifier("computer.\(computer.name)")
                .contextMenu { menu(for: computer) }
                .swipeActions(edge: .trailing) {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        removing = computer
                    }
                }
                .swipeActions(edge: .leading) {
                    if computer.status != .online {
                        Button("Wake PC", systemImage: "power") {
                            store.wake(computer.id)
                        }
                        .tint(.orange)
                    }
                }
            }
        }
        .overlay {
            if store.computers.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("Looking for computers…")
                            .artemisFont(.title2)
                    } icon: {
                        Image(systemName: "desktopcomputer")
                            .symbolEffect(.pulse)
                    }
                } description: {
                    Text("Artemis finds PCs running Apollo or Sunshine on your network. You can also add one with the + button.")
                        .artemisFont(.callout)
                } actions: {
                    Button("Add PC Manually") { showingAdd = true }
                        .buttonStyle(.glassProminent)
                    // No PC yet (or none at hand): the demo PCs and their desktop, nothing on the network
                    if store.switchDemo != nil {
                        Button("Try the Demo") { store.switchDemo?(true) }
                            .artemisFont(.callout)
                            .accessibilityIdentifier("computers.tryDemo")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if store.isTryingDemo {
                Button("Exit Demo") { store.switchDemo?(false) }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("computers.exitDemo")
                    .padding(.bottom, 8)
            }
        }
        .navigationTitle("Computers")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Test Network", systemImage: "network") { store.testNetwork() }
                    Divider()
                    Button("Setup Guide", systemImage: "book") { openURL(Links.setupGuide) }
                    Button("Troubleshooting", systemImage: "questionmark.circle") { openURL(Links.troubleshooting) }
                } label: {
                    Label("Help", systemImage: "questionmark")
                }
                .accessibilityIdentifier("computers.help")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Add PC", systemImage: "plus") { showingAdd = true }
                    .accessibilityIdentifier("computers.add")
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    .accessibilityIdentifier("computers.settings")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddComputerView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(item: $showingInfo) { computer in
            ComputerInfoView(computerID: computer.id)
        }
        .alert("Rename \(renaming?.name ?? "PC")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { computer in
            TextField("Name", text: $newName)
                .accessibilityIdentifier("rename.field")
            Button("Rename") { store.rename(computer.id, to: newName) }
                .accessibilityIdentifier("rename.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Enter the new name for this PC. Leave it empty to use the PC's own name.")
        }
        .alert(
            "Remove \(removing?.name ?? "PC")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { computer in
            Button("Remove", role: .destructive) { store.remove(computer.id) }
            Button("Cancel", role: .cancel) {}
        } message: { computer in
            Text("Are you sure you want to remove '\(computer.name)'? You'll need to pair with it again to connect to it.")
        }
    }

    @ViewBuilder
    private func menu(for computer: Computer) -> some View {
        switch computer.status {
        case .online where computer.isPaired:
            Button("Open", systemImage: "square.grid.2x2") { store.open(computer.id) }
            Button("View All Apps, Including Hidden", systemImage: "eye") {
                store.showingHiddenGames.insert(computer.id)
                store.open(computer.id, launchesAutomatically: false)
            }
        case .online:
            Button("Pair…", systemImage: "lock.open") { store.open(computer.id) }
        default:
            Button("Wake PC", systemImage: "power") { store.wake(computer.id) }
                .disabled(!computer.canWake)
        }
        Divider()
        Button("Test Network…", systemImage: "network") { store.testNetwork() }
        Button("Rename…", systemImage: "pencil") {
            newName = computer.name
            renaming = computer
        }
        Button("Get Info", systemImage: "info.circle") { showingInfo = computer }
        if computer.isNvidia {
            Button("NVIDIA GameStream End-of-Service", systemImage: "info.circle") { openURL(Links.gameStreamEndOfService) }
        }
        if computer.status != .online {
            Button("Connection Help", systemImage: "questionmark.circle") { openURL(Links.troubleshooting) }
        }
        Divider()
        Button("Remove…", systemImage: "trash", role: .destructive) { removing = computer }
    }
}

struct ComputerRow: View {
    let computer: Computer
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // The icon goes above the name at accessibility sizes, so the name keeps the width
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 14))
        HStack(spacing: 8) {
            layout {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(computer.name)
                        .artemisFont(.headline)
                    Text(computer.statusLine)
                        .artemisFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// As on the Mac: a spinner while waking or connecting, a moon when asleep, a chevron to open.
    @ViewBuilder
    private var trailing: some View {
        if computer.isWaking && computer.status != .online || computer.status == .unknown {
            ProgressView()
                .accessibilityHidden(true)
        } else if computer.status == .offline {
            Image(systemName: "moon.zzz.fill")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        } else if computer.status == .online && computer.isPaired && !typeSize.isAccessibilitySize {
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var icon: some View {
        Image(systemName: "desktopcomputer")
            .font(.title2)
            .foregroundStyle(iconColor)
            .frame(width: typeSize.isAccessibilitySize ? 52 : 40, height: typeSize.isAccessibilitySize ? 52 : 40)
            .background(iconColor.opacity(0.15), in: .rect(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                if computer.status == .online && !computer.isPaired {
                    badge("lock.fill", .orange)
                } else if computer.runningGameName != nil {
                    badge("dot.radiowaves.left.and.right", .green)
                }
            }
    }

    private var iconColor: Color {
        switch computer.status {
        case .online: computer.isPaired ? .accentColor : .orange
        case .offline: .secondary
        case .unknown: .secondary
        }
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(4)
            .background(color, in: .circle)
            .offset(x: 5, y: 5)
    }
}
