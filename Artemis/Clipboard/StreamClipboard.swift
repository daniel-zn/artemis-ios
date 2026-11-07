//
//  StreamClipboard.swift
//  Artemis
//
//  The session's shared clipboard (ClipboardSync) with the app's real pasteboard and PC, for
//  StreamFrameViewController. Off with Settings › Host PC › "Share copied text with the PC",
//  and with GeForce Experience (it has no such thing).
//

import UIKit

extension Notification.Name {
    /// Ctrl+C or Ctrl+X went to the PC (MoonlightDesktopInput).
    static let artemisCopyKeySent = Notification.Name("ArtemisCopyKeySent")
}

@objc(ArtemisStreamClipboard)
final class StreamClipboard: NSObject {
    private let sync: ClipboardSync
    private var observer: NSObjectProtocol?

    @objc init?(config: StreamConfiguration) {
        guard AppPreferences.shareClipboard else { return nil }
        guard !config.isNvidiaServerSoftware, let cert = config.serverCert, let address = config.host, config.httpsPort != 0 else {
            logInfo("Clipboard: off for this session (GeForce Experience, or no certificate or HTTPS port)")
            return nil
        }
        let link = HttpClipboardLink(manager: HttpManager(address: address, httpsPort: config.httpsPort, serverCert: cert))
        sync = ClipboardSync(hostID: config.hostUUID ?? address, link: link, pasteboard: GeneralPasteboard(),
                             store: DefaultsKnownCountStore())
        super.init()
        sync.log = logInfo
        logInfo("Clipboard: shared with \(address) for this session")
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// UI tests (-ArtemisTestFakePCSession YES): the stand-in PC's session counts as up at once.
    @objc static var startsWithoutStream: Bool { FakePC.sessionForClipboard }

    @objc func streamStarted() {
        sync.streamStarted()
        observer = NotificationCenter.default.addObserver(forName: .artemisCopyKeySent, object: nil, queue: .main) { [weak self] _ in
            self?.sync.copyKeySent()
        }
    }

    @objc func becameActive() { sync.becameActive() }
    @objc func resignedActive() { sync.resignedActive() }

    /// The last fetch before the session goes; `completion` on the main queue (within 2 s).
    @objc func streamEnding(_ completion: @escaping () -> Void) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        // Leaving for the home screen: finish the fetch in the background
        let task = UIApplication.shared.beginBackgroundTask(withName: "Clipboard")
        sync.streamEnding {
            completion()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }
}

private final class HttpClipboardLink: ClipboardHostLink {
    let manager: HttpManager
    init(manager: HttpManager) { self.manager = manager }

    func getClipboard(timeout: TimeInterval) -> (status: Int, body: Data?) {
        var body: NSData?
        let status = manager.clipboardRequest(withBody: nil, responseBody: &body, timeout: timeout)
        return (status, body as Data?)
    }

    func setClipboard(_ body: Data, timeout: TimeInterval) -> Int {
        manager.clipboardRequest(withBody: body, responseBody: nil, timeout: timeout)
    }
}

/// changeCount and hasStrings don't bring up "Allow Paste" or the "pasted from" notice; only
/// readString does, and ClipboardSyncState calls it only for a new copy with text.
private final class GeneralPasteboard: LocalPasteboard {
    var changeCount: Int { UIPasteboard.general.changeCount }
    var hasStrings: Bool { UIPasteboard.general.hasStrings }
    func readString() -> String? { UIPasteboard.general.string }
    func write(_ string: String) { UIPasteboard.general.string = string }
}

private final class DefaultsKnownCountStore: ClipboardKnownCountStore {
    private let key = "ArtemisClipboardKnownCounts"
    func knownCount(for hostID: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int])?[hostID]
    }
    func setKnownCount(_ count: Int, for hostID: String) {
        var counts = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        guard counts[hostID] != count else { return }
        counts[hostID] = count
        UserDefaults.standard.set(counts, forKey: key)
    }
}
