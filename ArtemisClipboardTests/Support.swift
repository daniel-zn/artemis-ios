//
//  Support.swift
//  ArtemisClipboardTests
//
//  Stand-ins for what ClipboardSync talks to in the app: Apollo's /actions/clipboard
//  (HttpManager), UIPasteboard.general and UserDefaults.
//

import Foundation

/// Apollo's clipboard endpoint: GET answers the PC's clipboard (CRLF line ends), POST sets it.
/// Called on ClipboardSync's worker queue, like the real requests.
final class FakeHost: ClipboardHostLink {
    private let lock = NSLock()
    private var _clipboard: String
    private var _gets = 0
    private var _posts: [String] = []
    private var _hang = false
    let getStatus: Int
    let postStatus: Int

    init(clipboard: String, getStatus: Int = 200, postStatus: Int = 200) {
        _clipboard = clipboard
        self.getStatus = getStatus
        self.postStatus = postStatus
    }

    var clipboard: String {
        get { lock.withLock { _clipboard } }
        set { lock.withLock { _clipboard = newValue } }
    }
    var gets: Int { lock.withLock { _gets } }
    var posts: [String] { lock.withLock { _posts } }
    /// No answer: each request takes its whole time limit and fails.
    var hang: Bool {
        get { lock.withLock { _hang } }
        set { lock.withLock { _hang = newValue } }
    }

    func getClipboard(timeout: TimeInterval) -> (status: Int, body: Data?) {
        if hang {
            Thread.sleep(forTimeInterval: timeout)
            return (-1, nil)
        }
        return lock.withLock {
            _gets += 1
            return getStatus == 200 ? (200, Data(_clipboard.utf8)) : (getStatus, Data())
        }
    }

    func setClipboard(_ body: Data, timeout: TimeInterval) -> Int {
        if hang {
            Thread.sleep(forTimeInterval: timeout)
            return -1
        }
        return lock.withLock {
            let text = String(decoding: body, as: UTF8.self)
            _posts.append(text)
            if postStatus == 200 { _clipboard = text }
            return postStatus
        }
    }
}

/// UIPasteboard.general: changeCount goes up with every copy (ours too).
final class FakePasteboard: LocalPasteboard {
    private(set) var text: String?
    private(set) var changeCount: Int
    private(set) var reads = 0
    private(set) var writes = 0

    init(text: String?) {
        self.text = text
        changeCount = text == nil ? 0 : 1
    }

    var hasStrings: Bool { text != nil }

    func readString() -> String? {
        reads += 1
        return text
    }

    func write(_ string: String) {
        writes += 1
        text = string
        changeCount += 1
    }

    /// Copied in another app.
    func copy(_ string: String) {
        text = string
        changeCount += 1
    }
}

final class FakeStore: ClipboardKnownCountStore {
    private var counts: [String: Int] = [:]
    func knownCount(for hostID: String) -> Int? { counts[hostID] }
    func setKnownCount(_ count: Int, for hostID: String) { counts[hostID] = count }
}
