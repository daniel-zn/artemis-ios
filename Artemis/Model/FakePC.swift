//
//  FakePC.swift
//  Artemis
//
//  A stand-in PC on the real code path, for UI tests (-ArtemisTestFakePC YES): ComputerStore,
//  DiscoveryManager's polls, HttpManager and the bridge run as with a real PC; only the network
//  answers come from here (a URL protocol in place of the PC's HTTP and HTTPS servers).
//  TOWER is a paired Apollo PC that's awake and answers every request; DEN is a paired PC
//  that's asleep (no answer). Nothing is searched for on the network and nothing is sent to it.
//
//    -ArtemisTestFakePCHold <s>       TOWER holds the answer to an open's serverinfo (the
//                                     request under the "Connecting…" card) for up to <s> s,
//                                     and answers half a second after Cancel when that comes
//                                     first: a PC whose answer arrives after Cancel.
//    -ArtemisTestFakePCAlone YES      TOWER only, so the app opens it by itself at launch
//    -ArtemisTestFakePCAppsCached YES TOWER's apps are known from before (tapping it opens
//                                     them at once, without the card)
//

import Foundation

enum FakePC {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "ArtemisTestFakePC") && !DemoData.isEnabled
    }

    static let towerName = "TOWER"
    static let towerUUID = "fake-pc-tower"
    static let denUUID = "fake-pc-den"
    static let towerAddress = "tower.fake.invalid"
    static let denAddress = "den.fake.invalid"
    static let uuids: Set<String> = [towerUUID, denUUID]

    private static var hold: Double { max(0, UserDefaults.standard.double(forKey: "ArtemisTestFakePCHold")) }
    private static var alone: Bool { UserDefaults.standard.bool(forKey: "ArtemisTestFakePCAlone") }
    private static var appsCached: Bool { UserDefaults.standard.bool(forKey: "ArtemisTestFakePCAppsCached") }

    /// Answers every request HttpManager makes from now on.
    static func install() {
        HttpManager.setTestProtocolClasses([FakePCProtocol.self])
        NotificationCenter.default.addObserver(forName: .artemisConnectingCancelled, object: nil, queue: nil) { _ in
            lock.withLock { lastCancel = Date() }
        }
    }

    static func makeHosts() -> [TemporaryHost] {
        let tower = host(towerName, uuid: towerUUID, address: towerAddress, mac: "02:00:5e:00:00:01")
        if appsCached {
            let desktop = TemporaryApp()
            desktop.id = "1"
            desktop.name = "Desktop"
            desktop.host = tower
            tower.appList = [desktop]
        }
        if alone { return [tower] }
        return [tower, host("DEN", uuid: denUUID, address: denAddress, mac: "02:00:5e:00:00:02")]
    }

    private static func host(_ name: String, uuid: String, address: String, mac: String) -> TemporaryHost {
        let host = TemporaryHost()
        host.name = name
        host.uuid = uuid
        host.localAddress = address
        host.activeAddress = address
        host.httpsPort = 47984
        host.mac = mac
        host.pairState = .paired
        // Pairing pinned its certificate (the stand-in's HTTPS takes it as matching)
        host.serverCert = Data("fake certificate".utf8)
        return host
    }

    fileprivate static let lock = NSLock()
    /// When Cancel was last pressed on the "Connecting…" card.
    fileprivate static var lastCancel: Date?

    /// When TOWER answers a request that started at `start`: polls (2 s time limit) at once,
    /// an open's serverinfo (5 s) after the hold or half a second after Cancel.
    fileprivate static func answerTime(for request: URLRequest, start: Date) -> Date? {
        guard request.url?.path == "/serverinfo", request.timeoutInterval > 2, hold > 0 else { return start }
        if let cancel = lock.withLock({ lastCancel }), cancel >= start {
            return min(cancel.addingTimeInterval(0.5), start.addingTimeInterval(hold))
        }
        return start.addingTimeInterval(hold) > Date() ? nil : start
    }

    fileprivate static func body(for url: URL) -> String? {
        switch url.path {
        case "/serverinfo":
            // Apollo's answer: over HTTPS (our pinned certificate) it knows this client is paired
            let https = url.scheme == "https"
            return """
            <?xml version="1.0" encoding="utf-8"?>
            <root status_code="200"><hostname>\(towerName)</hostname><appversion>7.1.431.-1</appversion>\
            <GfeVersion>3.23.0.74</GfeVersion><uniqueid>\(towerUUID)</uniqueid><HttpsPort>47984</HttpsPort>\
            <ExternalPort>47989</ExternalPort><mac>\(https ? "02:00:5e:00:00:01" : "00:00:00:00:00:00")</mac>\
            <LocalIP>\(towerAddress)</LocalIP><PairStatus>\(https ? 1 : 0)</PairStatus><currentgame>0</currentgame>\
            <state>SUNSHINE_SERVER_FREE</state><ServerCodecModeSupport>3</ServerCodecModeSupport></root>
            """
        case "/applist":
            return """
            <?xml version="1.0" encoding="utf-8"?>
            <root status_code="200"><App><AppTitle>Desktop</AppTitle><ID>1</ID><IsHdrSupported>0</IsHdrSupported></App>\
            <App><AppTitle>Steam Big Picture</AppTitle><ID>2</ID><IsHdrSupported>0</IsHdrSupported></App></root>
            """
        default:
            return nil
        }
    }
}

extension Notification.Name {
    /// Posted (main thread) when Cancel stops opening a PC.
    static let artemisConnectingCancelled = Notification.Name("ArtemisConnectingCancelled")
}

/// The stand-in PCs' network: TOWER answers, DEN and anything else doesn't.
final class FakePCProtocol: URLProtocol {
    private var stopped = false
    private var thread: Thread?
    private let start = Date()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        thread = Thread.current
        logInfo("Fake PC: \(request.url?.scheme ?? "") \(request.url?.host ?? "") \(request.url?.path ?? "") (time limit \(Int(request.timeoutInterval)) s)")
        check()
    }

    override func stopLoading() {
        FakePC.lock.withLock { stopped = true }
    }

    private func check() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            if FakePC.lock.withLock({ stopped }) { return }
            let deadline = start.addingTimeInterval(request.timeoutInterval)
            guard request.url?.host == FakePC.towerAddress, let url = request.url, let body = FakePC.body(for: url) else {
                // Asleep or unknown: no answer within the time limit
                if Date() >= deadline { deliver(nil) } else { check() }
                return
            }
            guard let at = FakePC.answerTime(for: request, start: start), at <= Date() else {
                if Date() >= deadline { deliver(nil) } else { check() }
                return
            }
            deliver(Data(body.utf8))
        }
    }

    private func deliver(_ data: Data?) {
        guard let thread else { return }
        perform(#selector(finish(_:)), on: thread, with: data, waitUntilDone: false)
    }

    @objc private func finish(_ data: Data?) {
        if FakePC.lock.withLock({ stopped }) { return }
        guard let data, let url = request.url else {
            logInfo("Fake PC: no answer to \(request.url?.path ?? "")")
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        logInfo("Fake PC: answered \(url.path)")
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
