//
//  ComputerStore.swift
//  Artemis
//
//  What MainFrameViewController used to do, for SwiftUI: discovery, pairing,
//  wake-on-LAN, app lists and box art, quitting games, starting streams and the
//  home-screen quick actions. The Obj-C network classes do the work; this keeps
//  their TemporaryHost objects and publishes value snapshots of them.
//

import SwiftUI
import UIKit

@Observable
final class ComputerStore {
    // MARK: Published state

    private(set) var computers: [Computer] = []
    private(set) var gamesByHost: [String: [Game]] = [:]
    var path: [Route] = []
    /// A full-screen "working" card (connecting, stopping an app, testing the network).
    var busyMessage: String?
    var alert: AlertInfo?
    var pairing: PairingInfo?
    /// Hosts whose apps list shows hidden apps too ("Show All Apps, Including Hidden").
    var showingHiddenGames: Set<String> = []
    private(set) var loadingGames: Set<String> = []
    /// Bumped when new box art arrives, so the rows load it again.
    private(set) var boxArtRevision = 0
    private(set) var isStreaming = false
    /// Names given with Rename…, by host UUID (the PC's own name comes back with every poll).
    private(set) var customNames: [String: String] = [:]
    /// The app each PC connects to by itself when opened ("Connect Automatically"), by host UUID.
    private(set) var directLaunch: [String: String] = [:]

    /// The host whose games are on screen.
    var selectedHostID: String? {
        if case .games(let id)? = path.last { return id }
        return nil
    }

    // MARK: Plumbing

    @ObservationIgnored let isDemo: Bool
    @ObservationIgnored private var hosts: [String: TemporaryHost] = [:]
    @ObservationIgnored private var discovery: DiscoveryManager?
    @ObservationIgnored private var assetManager: AppAssetManager?
    @ObservationIgnored private let opQueue = OperationQueue()
    @ObservationIgnored private var clientCert: Data?
    @ObservationIgnored private var callbacks: HostCallbacks!
    /// PCs being woken: until when, and whether they open once they're up (a tap woke them).
    @ObservationIgnored private var waking: [String: WakeAttempt] = [:]
    @ObservationIgnored private var wakeTimer: Timer?
    @ObservationIgnored private var pairingHostID: String?
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The PC of the session on screen.
    @ObservationIgnored private var streamingHostID: String?

    private enum Keys {
        static let names = "ArtemisPCNames"
        static let directLaunch = "ArtemisDirectLaunch"
    }
    /// Presents the stream view; calls the closure once it has been dismissed.
    @ObservationIgnored var presentStream: ((StreamConfiguration, @escaping (_ connected: Bool) -> Void) -> Void)?

    init(demo: Bool) {
        isDemo = demo
        callbacks = HostCallbacks(store: self)
        // The demo keeps these for the session only, like the rest of its PCs
        if !demo {
            customNames = UserDefaults.standard.dictionary(forKey: Keys.names) as? [String: String] ?? [:]
            directLaunch = UserDefaults.standard.dictionary(forKey: Keys.directLaunch) as? [String: String] ?? [:]
        }
    }

    // MARK: Startup and lifecycle

    func start() {
        guard !started else { return }
        started = true
        StreamSettings.adoptNativeDefaultIfUnchanged()
        PointerSettings.applyTestState()
        PointerSettings.adoptNaturalScrollingOnce()

        // Discovery's polls change the hosts on background threads; each change posts this
        observers.append(NotificationCenter.default.addObserver(forName: .artemisHostUpdated, object: nil, queue: .main) { [weak self] _ in
            self?.hostsPolled()
        })

        if isDemo {
            for host in DemoData.makeHosts() {
                hosts[host.uuid] = host
                if DemoData.sleepsAfterLaunch && host.name == "ENCHILADA" {
                    DemoData.simulateSleep(host)
                }
            }
            rebuild()
            return
        }

        // Set up crypto
        CryptoManager.generateKeyPairUsingSSL()
        _ = IdManager.getUniqueId()
        clientCert = CryptoManager.readCertFromFile()

        assetManager = AppAssetManager(callback: callbacks)
        opQueue.maxConcurrentOperationCount = 1

        let saved = (DataManager().getHosts() as? [TemporaryHost]) ?? []
        for host in saved {
            ArtemisBridge.prepareSavedHost(host)
            hosts[host.uuid] = host
        }
        discovery = DiscoveryManager(hosts: Array(hosts.values), andCallback: callbacks)
        rebuild()
        updateShortcuts()
        preloadBoxArt()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.returnedToForeground()
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.enteredBackground()
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            BoxArtCache.shared.removeAll()
        })

        // One PC: open it straight away, as upstream did
        if hosts.count == 1, let only = hosts.keys.first {
            open(only, userInitiated: false)
        }
        beginForegroundRefresh()
    }

    private func returnedToForeground() {
        inBackground = false
        extendWakeDeadlines()
        beginForegroundRefresh()
    }

    private func enteredBackground() {
        inBackground = true
        discovery?.stopDiscovery()
    }

    private func beginForegroundRefresh() {
        guard !inBackground, !isStreaming, !isDemo else { return }
        // Reset state first so we can rediscover hosts that were deleted before
        discovery?.resetDiscoveryState()
        discovery?.startDiscovery()

        // Refresh the app list when a paired host is open
        if let id = selectedHostID, let host = hosts[id], Self.isPaired(host) {
            open(id, userInitiated: false)
        }
    }

    // MARK: Snapshots

    fileprivate func discoveryUpdated(_ newHosts: [TemporaryHost]) {
        var updated: [String: TemporaryHost] = [:]
        for host in newHosts {
            updated[host.uuid] = host
        }
        hosts = updated
        rebuild()
        updateShortcuts()
    }

    /// A poll changed a host (its state, name, pairing or running app).
    private func hostsPolled() {
        rebuild()
        updateShortcuts()
    }

    private func rebuild() {
        let now = Date()
        var opening = false
        // A woken PC that's up: done waking, and opened if a tap woke it. One that hasn't
        // come up in time is offline again.
        for (id, attempt) in waking {
            guard let host = hosts[id] else {
                waking[id] = nil
                continue
            }
            if host.state == .online {
                waking[id] = nil
                logInfo("\(host.name) is awake")
                // One at a time: a second PC that came up in the same pass stays on the list
                if attempt.opensWhenUp && !opening && path.isEmpty && pairing == nil && busyMessage == nil && !isStreaming {
                    opening = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.path.isEmpty, self.busyMessage == nil, self.pairing == nil else { return }
                        self.open(id)
                    }
                }
            } else if attempt.deadline <= now && !isStreaming && !inBackground {
                waking[id] = nil
                let name = customNames[id] ?? host.name
                logInfo("\(host.name) didn't wake up within \(Int(Self.wakeTimeout)) s")
                alert = AlertInfo(title: "Couldn't Wake \(name)",
                                  message: "Artemis sent the wake-up signal, but \(name) didn't come online within \(Int(Self.wakeTimeout)) seconds. Check that this iPhone is on the PC's network and that the PC is asleep, not shut down, then try again.",
                                  showsHelp: true)
            }
        }
        if waking.isEmpty {
            wakeTimer?.invalidate()
            wakeTimer = nil
        }

        var newComputers: [Computer] = []
        var newGames: [String: [Game]] = [:]
        for host in hosts.values {
            let apps = Self.apps(of: host)
            let running = Self.runningApp(of: host)
            let status: ComputerStatus
            switch host.state {
            case .online: status = .online
            case .offline: status = .offline
            default: status = .unknown
            }
            newComputers.append(Computer(
                id: host.uuid,
                name: customNames[host.uuid] ?? host.name,
                status: status,
                isPaired: Self.isPaired(host),
                isWaking: waking[host.uuid] != nil,
                canWake: Self.canWake(host),
                // What a PC was running before it went to sleep isn't running now
                runningGameName: status == .online ? running?.name : nil,
                gameCount: apps.count,
                isNvidia: host.isNvidiaServerSoftware))
            newGames[host.uuid] = apps.map { app in
                Game(hostID: host.uuid, appID: app.id ?? "", name: app.name ?? "",
                     isHidden: app.hidden, isRunning: running?.id == app.id && running != nil,
                     isDirectLaunch: directLaunch[host.uuid] == app.id)
            }
        }
        newComputers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if newComputers != computers { computers = newComputers }
        if newGames != gamesByHost { gamesByHost = newGames }
    }

    func computer(_ id: String) -> Computer? {
        computers.first { $0.id == id }
    }

    /// The games on a PC, sorted by name; hidden ones only when asked for.
    func games(for hostID: String) -> [Game] {
        let all = gamesByHost[hostID] ?? []
        return showingHiddenGames.contains(hostID) ? all : all.filter { !$0.isHidden }
    }

    func runningGame(on hostID: String) -> Game? {
        gamesByHost[hostID]?.first { $0.isRunning }
    }

    private static func apps(of host: TemporaryHost) -> [TemporaryApp] {
        host.appList.compactMap { $0 as? TemporaryApp }
            .sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
    }

    private static func runningApp(of host: TemporaryHost) -> TemporaryApp? {
        guard let current = host.currentGame else { return nil }
        return apps(of: host).first { $0.id == current }
    }

    /// Paired: the PC said so over HTTPS, or it hasn't said either way yet and we have its
    /// certificate (pinned when pairing). Only an authenticated "not paired" undoes that
    /// (DiscoveryWorker acceptResponse:), never a PC that's asleep or out of reach.
    private static func isPaired(_ host: TemporaryHost) -> Bool {
        host.pairState == .paired || (host.pairState == .unknown && host.serverCert != nil)
    }

    private static func canWake(_ host: TemporaryHost) -> Bool {
        guard let mac = host.mac else { return false }
        return mac != "00:00:00:00:00:00"
    }

    private func app(_ game: Game) -> TemporaryApp? {
        guard let host = hosts[game.hostID] else { return nil }
        return Self.apps(of: host).first { $0.id == game.appID }
    }

    // MARK: Opening a PC

    /// Opens a PC the way the Mac app does: its games when paired, pairing when not,
    /// waking it when it's offline. `userInitiated` false is a refresh (coming back from
    /// a stream or the background, a quick action): no pairing and no error alerts.
    /// `launchesAutomatically` false: show the apps without connecting to the PC's
    /// "Connect Automatically" app (View All Apps, Including Hidden).
    func open(_ id: String, userInitiated: Bool = true, launchesAutomatically: Bool = true) {
        guard let host = hosts[id] else { return }
        let autoLaunch = userInitiated && launchesAutomatically

        if userInitiated && host.state == .offline {
            wake(id, opensWhenUp: true)
            return
        }

        if isDemo {
            openDemo(host, userInitiated: userInitiated, autoLaunch: autoLaunch)
            return
        }

        // The fast path: online, paired and a cached app list. Not after a stream,
        // where serverinfo has to be fetched again for the running game.
        if userInitiated && host.state == .online && Self.isPaired(host) && host.appList.count > 0 {
            showGames(id, autoLaunch: autoLaunch)
            refreshApps(host)
            return
        }

        if userInitiated {
            busyMessage = "Connecting to \(host.name)…"
        }
        let discovery = self.discovery
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Wait for the PC's status to be known
            var waited = 0
            while host.state == .unknown && waited < 20 {
                sleep(1)
                waited += 1
            }
            if host.state != .online {
                DispatchQueue.main.async {
                    self?.busyMessage = nil
                    self?.leaveGames(of: id)
                }
                return
            }

            if let error = ArtemisBridge.refreshServerInfo(for: host, discovery: discovery) {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyMessage = nil
                    host.state = .offline
                    self.rebuild()
                    self.leaveGames(of: id)
                    // Only display an alert if this was the result of a real user action
                    if userInitiated {
                        self.alert = AlertInfo(title: "Connection Failed", message: error, showsHelp: true)
                    }
                }
                return
            }

            if Self.isPaired(host) {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyMessage = nil
                    self.rebuild()
                    if userInitiated || self.selectedHostID == id || self.path.isEmpty {
                        self.showGames(id, autoLaunch: autoLaunch)
                    }
                    self.refreshApps(host)
                }
            }
            else if userInitiated {
                logInfo("Trying to pair")
                DispatchQueue.main.async { self?.pairingHostID = id }
                // Polling the server while pairing causes the server to screw up
                discovery?.stopDiscoveryBlocking()
                guard let self else { return }
                let manager = PairManager(manager: HttpManager(host: host), clientCert: self.clientCert, callback: self.callbacks)
                self.opQueue.addOperation(manager!)
            }
            else {
                DispatchQueue.main.async {
                    self?.busyMessage = nil
                    self?.rebuild()
                }
            }
        }
    }

    private func showGames(_ id: String, autoLaunch: Bool = false) {
        if selectedHostID != id {
            path = [.games(id)]
        }
        // Connect to the PC's "Connect Automatically" app, unless another one is active
        guard autoLaunch, let appID = directLaunch[id] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            // Still on this PC with nothing else going on, and the app still there
            guard let self, self.selectedHostID == id, !self.isStreaming, self.busyMessage == nil,
                  self.pairing == nil, self.alert == nil,
                  let game = self.gamesByHost[id]?.first(where: { $0.appID == appID }) else { return }
            if let running = self.runningGame(on: id), running.appID != appID { return }
            logInfo("Connecting automatically to \(game.name)")
            self.play(game)
        }
    }

    private func leaveGames(of id: String) {
        if selectedHostID == id {
            path.removeAll()
        }
    }

    /// Fetches the app list; the cached one shows meanwhile.
    func refreshApps(_ host: TemporaryHost) {
        let id: String = host.uuid
        if isDemo { return }
        loadingGames.insert(id)
        let discovery = self.discovery
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = ArtemisBridge.refreshAppList(for: host, discovery: discovery)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingGames.remove(id)
                if let error {
                    host.state = .offline
                    self.rebuild()
                    if self.selectedHostID == id {
                        self.path.removeAll()
                        self.alert = AlertInfo(title: "Connection Interrupted", message: error, showsHelp: true)
                    }
                    return
                }
                self.rebuild()
                // This host may be eligible for a shortcut now that the app list has been populated
                self.updateShortcuts()
                self.preloadBoxArt(for: host)
                self.assetManager?.stopRetrieving()
                self.assetManager?.retrieveAssets(from: host)
            }
        }
    }

    func refreshGames(_ hostID: String) {
        open(hostID, userInitiated: false)
    }

    // MARK: Pairing

    fileprivate func pairingStarted(pin: String) {
        guard let id = pairingHostID, let host = hosts[id] else { return }
        busyMessage = nil
        pairing = PairingInfo(hostID: id, hostName: customNames[id] ?? host.name, pin: pin)
    }

    fileprivate func pairingFailed(_ message: String) {
        guard pairingHostID != nil else { return }
        pairingHostID = nil
        pairing = nil
        busyMessage = nil
        discovery?.startDiscovery()
        alert = AlertInfo(title: "Pairing Failed", message: message, showsHelp: true)
    }

    fileprivate func pairingSucceeded(serverCert: Data?) {
        guard let id = pairingHostID, let host = hosts[id] else { return }
        pairingHostID = nil
        pairing = nil
        busyMessage = nil
        if let serverCert {
            // Store the cert from pairing with the host
            host.serverCert = serverCert
        }
        host.pairState = .paired
        DataManager().update(host)
        discovery?.startDiscovery()
        rebuild()
        showGames(id)
        refreshApps(host)
    }

    /// Cancel on the PIN sheet. The host gives up on the attempt by itself.
    func cancelPairing() {
        guard pairingHostID != nil || pairing != nil else { return }
        pairingHostID = nil
        pairing = nil
        if !isDemo {
            discovery?.startDiscovery()
        }
    }

    // MARK: Waking, removing, adding

    /// Polling was paused (a session, the background): give woken PCs a few polls before
    /// calling them asleep.
    private func extendWakeDeadlines() {
        let soonest = Date().addingTimeInterval(10)
        for (id, attempt) in waking where attempt.deadline < soonest {
            waking[id]?.deadline = soonest
        }
    }

    /// How long a woken PC has to come up (-ArtemisWakeTimeout for the tests), as on the Mac.
    static var wakeTimeout: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "ArtemisWakeTimeout")
        return value > 0 ? value : 90
    }

    /// Sends Wake-on-LAN; the row shows "Waking up…" until the PC answers a poll or the time
    /// runs out. `opensWhenUp`: open it once it's up (a tap on the PC, like a double-click on the Mac).
    func wake(_ id: String, opensWhenUp: Bool = false) {
        guard let host = hosts[id] else { return }
        guard Self.canWake(host) else {
            alert = AlertInfo(title: "Wake PC", message: "\(host.name) is offline, and Artemis can't wake it because it doesn't know the PC's network address yet. Turn the PC on and pair with it, and Artemis will be able to wake it next time.")
            return
        }
        if isDemo {
            DemoData.simulateWake(host)
        } else {
            DispatchQueue.global().async {
                WakeOnLanManager.wake(host)
            }
        }
        let previous = waking[id]
        waking[id] = WakeAttempt(deadline: Date().addingTimeInterval(Self.wakeTimeout),
                                 opensWhenUp: opensWhenUp || (previous?.opensWhenUp ?? false))
        if !isDemo {
            // Discovery may be stopped (a failed pairing, the background): the polls bring the state
            discovery?.resetDiscoveryState()
            discovery?.startDiscovery()
        }
        rebuild()
        // Checks the deadline; the polls bring the PC's state in between
        if wakeTimer == nil {
            wakeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.rebuild()
            }
        }
    }

    /// Rename…: an empty name goes back to the PC's own.
    func rename(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        customNames[id] = name.isEmpty || name == hosts[id]?.name ? nil : name
        saveNamesAndDirectLaunch()
        rebuild()
        updateShortcuts()
    }

    private func saveNamesAndDirectLaunch() {
        guard !isDemo else { return }
        UserDefaults.standard.set(customNames, forKey: Keys.names)
        UserDefaults.standard.set(directLaunch, forKey: Keys.directLaunch)
    }

    /// Get Info: the Mac app's fields.
    func info(for id: String) -> [(label: String, value: String)] {
        guard let host = hosts[id] else { return [] }
        func text(_ value: String?) -> String { (value?.isEmpty ?? true) ? "None" : value! }
        let state: String
        switch host.state {
        case .online: state = "Online"
        case .offline: state = waking[id] != nil ? "Waking up" : "Offline"
        default: state = "Unknown"
        }
        let pairState: String
        switch host.pairState {
        case .paired: pairState = "Paired"
        case .unpaired: pairState = "Unpaired"
        default: pairState = "Unknown"
        }
        let game = host.currentGame.flatMap { $0 == "0" ? nil : $0 }
        var rows: [(String, String)] = [("Name", customNames[id] ?? host.name)]
        if customNames[id] != nil { rows.append(("PC's own name", host.name)) }
        rows += [
            ("Status", state),
            ("Active Address", text(host.activeAddress)),
            ("UUID", host.uuid),
            ("Local Address", text(host.localAddress)),
            ("Remote Address", text(host.externalAddress)),
            ("IPv6 Address", text(host.ipv6Address)),
            ("Manual Address", text(host.address)),
            ("MAC Address", Self.canWake(host) ? host.mac! : "Unknown"),
            ("Pair State", pairState),
            ("Running App", game.map { id in Self.runningApp(of: host)?.name.map { "\($0) (\(id))" } ?? id } ?? "None"),
            ("HTTPS Port", host.httpsPort > 0 ? String(host.httpsPort) : "Unknown"),
        ]
        return rows
    }

    func remove(_ id: String) {
        guard let host = hosts[id] else { return }
        leaveGames(of: id)
        if !isDemo {
            discovery?.removeHost(fromDiscovery: host)
            DataManager().remove(host)
        }
        hosts[id] = nil
        waking[id] = nil
        customNames[id] = nil
        directLaunch[id] = nil
        saveNamesAndDirectLaunch()
        rebuild()
        updateShortcuts()
    }

    /// Adds a PC by address; the completion gets nil, or the error to show.
    func addComputer(address: String, completion: @escaping (String?) -> Void) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDemo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion("Could not connect to host.\n\nIf you're hosting using Sunshine, ensure it is running properly. If you're using a non-default port, you will need to include that here.")
            }
            return
        }
        guard let discovery else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            discovery.discoverHost(address) { host, error in
                if let host {
                    DispatchQueue.main.async {
                        self?.hosts[host.uuid] = host
                        self?.rebuild()
                        completion(nil)
                    }
                } else {
                    let message = ArtemisBridge.addHostErrorMessage(error ?? "Unable to connect to the specified PC.")
                    DispatchQueue.main.async { completion(message) }
                }
            }
        }
    }

    func testNetwork() {
        busyMessage = "Testing your network…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let message = ArtemisBridge.runNetworkTest()
            DispatchQueue.main.async {
                self?.busyMessage = nil
                self?.alert = AlertInfo(title: "Network Test Complete", message: message)
            }
        }
    }

    // MARK: Games

    func setHidden(_ game: Game, hidden: Bool) {
        guard let app = app(game) else { return }
        if isDemo {
            app.hidden = hidden
        } else {
            ArtemisBridge.setApp(app, hidden: hidden)
        }
        rebuild()
    }

    /// Launches a game, or resumes it when it's the one running.
    func play(_ game: Game) {
        // The microphone is on but nobody has decided about it yet (permission reset in iOS
        // Settings, say): iOS asks once, before connecting. Denied: the session goes without it.
        if MicSettings.current.enabled, !SessionAudio.usesTestTone, MicPermissionGate.shared.wouldAsk {
            MicPermissionGate.shared.ensureAccess { [weak self] _ in self?.play(game) }
            return
        }
        guard let app = app(game) else { return }
        streamingHostID = game.hostID
        assetManager?.stopRetrieving()
        logInfo(game.isRunning ? "Resuming application: \(game.name)" : "Launching application: \(game.name)")
        let config = ArtemisBridge.streamConfiguration(for: app)
        guard let presentStream else { return }
        isStreaming = true
        discovery?.stopDiscovery()
        presentStream(config) { [weak self] connected in
            self?.streamEnded(connected: connected)
        }
    }

    private func streamEnded(connected: Bool) {
        isStreaming = false
        BoxArtCache.shared.removeAll()
        let hostID = streamingHostID
        streamingHostID = nil
        extendWakeDeadlines()
        // Only a session that connected: a failed one may have hit another client's session
        if let hostID, connected, AppPreferences.quitAppAfterSession {
            // The app list refreshes once the app has ended
            endSessionAfterDisconnect(on: hostID)
            if !inBackground && !isDemo {
                discovery?.resetDiscoveryState()
                discovery?.startDiscovery()
            }
            return
        }
        // Fetch serverinfo again so the running game is right
        if let id = selectedHostID {
            open(id, userInitiated: false)
        }
        beginForegroundRefresh()
    }

    /// Quits the running game on the PC, then starts `next` if given.
    func endGame(on hostID: String, thenStart next: Game? = nil) {
        guard let host = hosts[hostID], let running = runningGame(on: hostID) else { return }
        logInfo("Quitting application: \(running.name)")
        busyMessage = "Stopping \(running.name)…"
        if isDemo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                host.currentGame = "0"
                self?.busyMessage = nil
                self?.rebuild()
                if let next { self?.play(next) }
            }
            return
        }
        let discovery = self.discovery
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let quit = ArtemisBridge.quitApp(on: host, discovery: discovery)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busyMessage = nil
                self.rebuild()
                if !quit {
                    self.alert = AlertInfo(title: "Couldn't Stop the App", message: "If it was started from another device, stop it from that device.")
                } else if let next, let fresh = self.games(for: hostID).first(where: { $0.appID == next.appID }) {
                    self.play(fresh)
                }
            }
        }
    }

    /// Settings › Host PC › Stop the app on the PC after a session (the Mac's "Quit app on host
    /// PC after ending stream").
    private func endSessionAfterDisconnect(on hostID: String) {
        guard let host = hosts[hostID] else { return }
        logInfo("Stopping the app on \(host.name) after disconnecting")
        busyMessage = "Stopping the app…"
        if isDemo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                host.currentGame = "0"
                self?.busyMessage = nil
                self?.rebuild()
            }
            return
        }
        let discovery = self.discovery
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let quit = ArtemisBridge.quitApp(on: host, discovery: discovery)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busyMessage = nil
                if !quit {
                    self.alert = AlertInfo(title: "Couldn't Stop the App", message: "The app is still open on \(self.customNames[hostID] ?? host.name).")
                }
                if self.selectedHostID == hostID {
                    self.open(hostID, userInitiated: false)
                } else {
                    self.rebuild()
                }
            }
        }
    }

    /// "Connect Automatically When Opening PC": one app per PC.
    func setDirectLaunch(_ game: Game, enabled: Bool) {
        if enabled {
            directLaunch[game.hostID] = game.appID
        } else if directLaunch[game.hostID] == game.appID {
            directLaunch[game.hostID] = nil
        }
        saveNamesAndDirectLaunch()
        rebuild()
    }

    // MARK: Box art

    fileprivate func receivedAsset(for app: TemporaryApp) {
        boxArtRevision += 1
    }

    func boxArtPath(for game: Game) -> String? {
        if isDemo { return nil }
        guard let app = app(game) else { return nil }
        return AppAssetManager.boxArtPath(for: app)
    }

    /// Decodes box art ahead of the list, as upstream did.
    private func preloadBoxArt(for host: TemporaryHost? = nil) {
        guard !isDemo else { return }
        let targets = host.map { [$0] } ?? Array(hosts.values)
        for host in targets {
            for app in Self.apps(of: host) {
                DispatchQueue.global(qos: .utility).async {
                    _ = BoxArtCache.shared.image(atPath: AppAssetManager.boxArtPath(for: app))
                }
            }
        }
    }

    // MARK: Quick actions

    private func updateShortcuts() {
        guard !isDemo else { return }
        // Pair state may be unknown if we haven't polled it yet, but the app list
        // count will persist from paired PCs
        UIApplication.shared.shortcutItems = computers.filter { $0.gameCount > 0 }.map { computer in
            UIApplicationShortcutItem(type: "PC", localizedTitle: computer.name, localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "desktopcomputer"),
                                      userInfo: ["UUID": computer.id as NSString])
        }
    }

    /// A home-screen quick action: opens that PC's apps.
    @discardableResult
    func handleShortcut(_ item: UIApplicationShortcutItem) -> Bool {
        guard let uuid = item.userInfo?["UUID"] as? String, hosts[uuid] != nil else { return false }
        if selectedHostID != uuid {
            path.removeAll()
            open(uuid, userInitiated: false)
            if isDemo { showGames(uuid) }
        }
        return true
    }

    // MARK: Demo

    private func openDemo(_ host: TemporaryHost, userInitiated: Bool, autoLaunch: Bool) {
        let id: String = host.uuid
        if Self.isPaired(host) {
            showGames(id, autoLaunch: autoLaunch)
            // Artwork arriving while the list is open: the first arrival brings the late ones
            DemoData.lateArtArrived = false
            for step in 1...8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.75) { [weak self] in
                    DemoData.lateArtArrived = true
                    self?.boxArtRevision += 1
                }
            }
        } else if userInitiated {
            pairingHostID = id
            pairingStarted(pin: "4821")
        }
    }
}

private struct WakeAttempt {
    var deadline: Date
    var opensWhenUp: Bool
}

extension Notification.Name {
    /// Posted (on any thread) when discovery's poll changes a host; see DiscoveryWorker.
    static let artemisHostUpdated = NSNotification.Name.ArtemisHostUpdated
}

/// The Obj-C callback protocols, forwarded to the store on the main thread.
private final class HostCallbacks: NSObject, DiscoveryCallback, PairCallback, AppAssetCallback {
    weak var store: ComputerStore?

    init(store: ComputerStore) {
        self.store = store
    }

    func updateAllHosts(_ hosts: [Any]!) {
        // Copied here because discovery can change the array before the main thread runs
        let copy = (hosts ?? []).compactMap { $0 as? TemporaryHost }
        DispatchQueue.main.async { [weak self] in
            self?.store?.discoveryUpdated(copy)
        }
    }

    func startPairing(_ PIN: String!) {
        // Synchronous, so the PIN shows before any failure callback can arrive
        let pin = PIN ?? ""
        DispatchQueue.main.sync {
            store?.pairingStarted(pin: pin)
        }
    }

    func pairSuccessful(_ serverCert: Data!) {
        DispatchQueue.main.async { [weak self] in
            self?.store?.pairingSucceeded(serverCert: serverCert)
        }
    }

    func pairFailed(_ message: String!) {
        let message = message ?? "Pairing failed."
        DispatchQueue.main.async { [weak self] in
            self?.store?.pairingFailed(message)
        }
    }

    func alreadyPaired() {
        DispatchQueue.main.async { [weak self] in
            self?.store?.pairingSucceeded(serverCert: nil)
        }
    }

    func receivedAsset(for app: TemporaryApp!) {
        guard let app else { return }
        // Decode it here so the main thread doesn't have to
        _ = BoxArtCache.shared.image(atPath: AppAssetManager.boxArtPath(for: app), reload: true)
        DispatchQueue.main.async { [weak self] in
            self?.store?.receivedAsset(for: app)
        }
    }
}
