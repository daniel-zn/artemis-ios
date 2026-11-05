//
//  DemoData.swift
//  Artemis
//
//  Stand-in PCs for screenshots, UI tests (launch argument -ArtemisDemo YES) and Try the Demo
//  on the empty Computers screen (for someone without a PC at hand, App Review too):
//  a paired PC with apps, one active; an offline PC; a PC that isn't paired.
//  Connecting opens a picture of a desktop that records the input (DemoDesktopViewController);
//  with -ArtemisDemoRealStream YES it opens the real stream screen, which can't reach the PC.
//  Nothing touches the network or the saved PCs in this mode.
//

import UIKit

enum DemoData {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "ArtemisDemo") || isTrying
    }

    /// The demo opened with Try the Demo on the empty Computers screen, until Exit Demo.
    static var isTrying = false

    /// The demo's paired PC with apps.
    static let workstationName = "WORKSTATION"

    static var usesRealStream: Bool {
        UserDefaults.standard.bool(forKey: "ArtemisDemoRealStream")
    }

    /// Seconds until a woken demo PC answers (-ArtemisDemoWakeDelay; a large number for one that never does).
    static var wakeDelay: Double {
        // double(forKey:) also reads the launch argument's text
        UserDefaults.standard.object(forKey: "ArtemisDemoWakeDelay") == nil ? 3 : UserDefaults.standard.double(forKey: "ArtemisDemoWakeDelay")
    }

    /// A woken demo PC comes up the way discovery sees a real one: its poll (on a background
    /// thread) changes the host's state and posts ArtemisHostUpdated.
    static func simulateWake(_ host: TemporaryHost) {
        let delay = wakeDelay
        guard delay >= 0 else { return }
        queue.asyncAfter(deadline: .now() + delay) {
            woken.insert(host.uuid)
            host.state = .online
            NotificationCenter.default.post(name: .artemisHostUpdated, object: host)
        }
    }

    /// UI tests that type into an alert at the largest text size turn UIKit's animations off
    /// (-ArtemisNoAnimations YES): each keystroke XCTest sends hides or brings back the keyboard,
    /// the scrolling alert relays out with it, and now and then UIKit reports one of those
    /// animations starting but never stopping. XCTest then never sees the app idle and waits
    /// 60 s before every later step.
    static var disablesAnimations: Bool {
        isEnabled && UserDefaults.standard.bool(forKey: "ArtemisNoAnimations")
    }

    /// WORKSTATION goes to sleep a moment after launch (-ArtemisDemoSleep YES).
    static var sleepsAfterLaunch: Bool {
        UserDefaults.standard.bool(forKey: "ArtemisDemoSleep")
    }

    /// A paired PC going to sleep, as discovery sees one (every second, through the same check
    /// discovery's polls use): an answer only over plain HTTP, as when its HTTPS refused this
    /// client while it went down (PairStatus 0 and the MAC hidden, as Apollo answers there),
    /// then no answer at all, again and again. It stays that way until a wake brings it up.
    static func simulateSleep(_ host: TemporaryHost) {
        var poll = 0
        func next() {
            queue.asyncAfter(deadline: .now() + 1) {
                // Woken (simulateWake): it answers properly again
                if woken.contains(host.uuid) { return }
                let answered: Bool
                if poll % 2 == 0 {
                    answered = DiscoveryWorker.accept(plainHttpServerInfo(of: host), for: host)
                } else {
                    answered = false
                }
                poll += 1
                let state: State = answered ? .online : .offline
                if host.state != state {
                    host.state = state
                }
                NotificationCenter.default.post(name: .artemisHostUpdated, object: host)
                next()
            }
        }
        next()
    }

    /// Hosts a wake brought up (the sleep simulation stops for them); used on `queue` only.
    private static var woken: Set<String> = []
    /// The demo's stand-in for discovery's background threads.
    private static let queue = DispatchQueue(label: "Artemis demo discovery")

    /// What Apollo answers on plain HTTP: no pairing status for this client, no MAC address.
    private static func plainHttpServerInfo(of host: TemporaryHost) -> ServerInfoResponse {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200"><hostname>\(host.name ?? "")</hostname><appversion>7.1.431.-1</appversion>\
        <GfeVersion>3.23.0.74</GfeVersion><uniqueid>\(host.uuid ?? "")</uniqueid><HttpsPort>47984</HttpsPort>\
        <ExternalPort>47989</ExternalPort><mac>00:00:00:00:00:00</mac><LocalIP>127.0.0.1</LocalIP>\
        <PairStatus>0</PairStatus><currentgame>0</currentgame><state>SUNSHINE_SERVER_FREE</state></root>
        """
        let response = ServerInfoResponse()
        response.populate(with: Data(xml.utf8))
        response.authenticated = false
        return response
    }

    static func makeHosts() -> [TemporaryHost] {
        let workstation = host(workstationName, uuid: "demo-workstation", state: .online, paired: true, mac: "02:00:5e:12:34:56")
        let games: [(String, String, Bool)] = [
            ("1", "Desktop", false), ("2", "Visual Studio Code", false), ("3", "Blender", false),
            ("4", "Photoshop", false), ("5", "Terminal", false), ("6", "File Explorer", false),
            ("7", "Steam Big Picture", false), ("8", "Old Virtual Display", true), ("9", "Virtual Display", false),
        ]
        workstation.appList = Set(games.map { app($0.0, $0.1, hidden: $0.2, host: workstation) })
        workstation.currentGame = "1"

        let livingRoom = host("Living Room PC", uuid: "demo-living-room", state: .offline, paired: true, mac: "02:00:5e:65:43:21")
        livingRoom.appList = Set([app("1", "Desktop", hidden: false, host: livingRoom)])

        let studio = host("STUDIO", uuid: "demo-studio", state: .online, paired: false, mac: nil)
        return [workstation, livingRoom, studio]
    }

    private static func host(_ name: String, uuid: String, state: State, paired: Bool, mac: String?) -> TemporaryHost {
        let host = TemporaryHost()
        host.name = name
        host.uuid = uuid
        host.state = state
        host.pairState = paired ? .paired : .unpaired
        // Pairing pins the PC's certificate
        host.serverCert = paired ? Data("demo certificate".utf8) : nil
        host.mac = mac
        host.activeAddress = "127.0.0.1"
        host.address = "127.0.0.1"
        host.httpsPort = 47984
        host.appList = Set()
        return host
    }

    private static func app(_ id: String, _ name: String, hidden: Bool, host: TemporaryHost) -> TemporaryApp {
        let app = TemporaryApp()
        app.id = id
        app.name = name
        app.hidden = hidden
        app.host = host
        return app
    }

    private static let palettes: [(UIColor, UIColor)] = [
        (#colorLiteral(red: 0.98, green: 0.85, blue: 0.1, alpha: 1), #colorLiteral(red: 0.85, green: 0.1, blue: 0.35, alpha: 1)),
        (#colorLiteral(red: 0.75, green: 0.6, blue: 0.3, alpha: 1), #colorLiteral(red: 0.12, green: 0.1, blue: 0.08, alpha: 1)),
        (#colorLiteral(red: 0.95, green: 0.35, blue: 0.2, alpha: 1), #colorLiteral(red: 0.3, green: 0.05, blue: 0.15, alpha: 1)),
        (#colorLiteral(red: 0.2, green: 0.75, blue: 0.95, alpha: 1), #colorLiteral(red: 0.1, green: 0.2, blue: 0.5, alpha: 1)),
        (#colorLiteral(red: 0.9, green: 0.2, blue: 0.3, alpha: 1), #colorLiteral(red: 0.15, green: 0.35, blue: 0.75, alpha: 1)),
        (#colorLiteral(red: 0.35, green: 0.5, blue: 0.95, alpha: 1), #colorLiteral(red: 0.1, green: 0.12, blue: 0.3, alpha: 1)),
        (#colorLiteral(red: 0.2, green: 0.25, blue: 0.35, alpha: 1), #colorLiteral(red: 0.05, green: 0.08, blue: 0.12, alpha: 1)),
        (#colorLiteral(red: 0.55, green: 0.3, blue: 0.75, alpha: 1), #colorLiteral(red: 0.1, green: 0.05, blue: 0.2, alpha: 1)),
    ]

    /// Apps whose artwork arrives late, as Apollo's own apps' does (Steam Big Picture, Virtual
    /// Display): none at first, then a few arrivals while the list is open, each bumping the
    /// store's box art revision like AppAssetManager's callbacks.
    static let lateArtApps: Set<String> = ["7", "9"]
    static var lateArtArrived = false

    /// Stand-in artwork: a gradient with the name on it (nil until a late one arrives).
    static func boxArt(for game: Game) -> UIImage? {
        if lateArtApps.contains(game.appID) && !lateArtArrived { return nil }
        return drawnBoxArt(for: game)
    }

    private static func drawnBoxArt(for game: Game) -> UIImage {
        let (top, bottom) = palettes[(Int(game.appID) ?? 0) % palettes.count]
        let size = CGSize(width: 300, height: 400)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let text = game.name.uppercased() as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40, weight: .heavy),
                .foregroundColor: UIColor.white,
                .paragraphStyle: style,
            ]
            text.draw(in: CGRect(x: 20, y: size.height - 160, width: size.width - 40, height: 150), withAttributes: attributes)
        }
    }
}
