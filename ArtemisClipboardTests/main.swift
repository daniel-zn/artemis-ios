//
//  main.swift
//  ArtemisClipboardTests
//
//  The shared clipboard with Apollo (Artemis/Clipboard): the decisions in ClipboardSyncState,
//  then ClipboardSync driven against a stand-in PC and pasteboard (FakeHost, FakePasteboard in
//  Support.swift), the way a session drives it. No Simulator. Run: Scripts/clipboard-tests.sh
//

import Foundation

var failures = 0
var count = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    count += 1
    if condition {
        print("ok    \(name)")
    } else {
        failures += 1
        print("FAIL  \(name): \(detail())")
    }
}

typealias State = ClipboardSyncState

// MARK: - Decisions

do {
    // Reads the pasteboard only when it changed since we last knew it, and has text
    var state = State(localKnownCount: 5)
    var reads = 0
    let read: () -> String? = { reads += 1; return "hello" }
    check("unchanged pasteboard isn't read", state.localToSend(changeCount: 5, hasStrings: true, read: read) == nil && reads == 0, "reads \(reads)")
    check("changed pasteboard without text isn't read", state.localToSend(changeCount: 6, hasStrings: false, read: read) == nil && reads == 0, "reads \(reads)")
    check("…and isn't looked at again", state.localKnownCount == 6, "\(String(describing: state.localKnownCount))")
    let sent = state.localToSend(changeCount: 7, hasStrings: true, read: read)
    check("changed pasteboard with text is read and sent", sent == "hello" && reads == 1, "\(String(describing: sent)) reads \(reads)")
    check("the same copy isn't sent twice while it's on the way", state.localToSend(changeCount: 7, hasStrings: true, read: read) == nil && reads == 1, "reads \(reads)")
    state.endSend("hello", result: .ok)
    check("after it's sent the PC is known to have it", state.hostSeen == "hello")
    check("…and the same copy isn't read again", state.localToSend(changeCount: 7, hasStrings: true, read: read) == nil && reads == 1, "reads \(reads)")
    check("copied again with the same text: read but not sent", state.localToSend(changeCount: 8, hasStrings: true, read: read) == nil && reads == 2, "reads \(reads)")
}

do {
    // A never-seen pasteboard (first session since install) is read once
    var state = State(localKnownCount: nil)
    var reads = 0
    check("first session reads the pasteboard", state.localToSend(changeCount: 1, hasStrings: true, read: { reads += 1; return "a" }) == "a" && reads == 1)
}

do {
    // Empty, refused (the "Allow Paste" question answered no) or too big: read once, never sent
    var state = State(localKnownCount: 0)
    check("refused read sends nothing", state.localToSend(changeCount: 1, hasStrings: true, read: { nil }) == nil)
    check("…and isn't asked again for the same copy", state.localToSend(changeCount: 1, hasStrings: true, read: { "x" }) == nil)
    check("empty text isn't sent", state.localToSend(changeCount: 2, hasStrings: true, read: { "" }) == nil)
    let big = String(repeating: "é", count: State.maxBytes / 2 + 1) // 2 bytes each in UTF-8
    check("text over 1 MiB isn't sent", state.localToSend(changeCount: 3, hasStrings: true, read: { big }) == nil)
    let fits = String(repeating: "a", count: State.maxBytes)
    check("text of exactly 1 MiB is sent", state.localToSend(changeCount: 4, hasStrings: true, read: { fits }) == fits)
}

do {
    // A failed send is tried again at the next trigger without reading the pasteboard again
    var state = State(localKnownCount: 0)
    var reads = 0
    let read: () -> String? = { reads += 1; return "retry me" }
    _ = state.localToSend(changeCount: 1, hasStrings: true, read: read)
    state.endSend("retry me", result: .failed)
    check("failed send isn't known to be on the PC", state.hostSeen == nil)
    let again = state.localToSend(changeCount: 1, hasStrings: true, read: read)
    check("failed send goes again unread", again == "retry me" && reads == 1, "\(String(describing: again)) reads \(reads)")
}

do {
    // Text the PC already has isn't sent
    var state = State(localKnownCount: 0)
    _ = state.endFetch(.ok, wire: "same", changeCountAtRequest: 0, changeCountNow: 0)
    check("text the PC has isn't sent", state.localToSend(changeCount: 1, hasStrings: true, read: { "same" }) == nil)
}

do {
    // Refused permission (401) turns that direction off; a PC without the endpoint, both
    var state = State(localKnownCount: 0)
    _ = state.localToSend(changeCount: 1, hasStrings: true, read: { "a" })
    state.endSend("a", result: .denied)
    var reads = 0
    check("no clipboard_set: nothing read or sent after", state.localToSend(changeCount: 2, hasStrings: true, read: { reads += 1; return "b" }) == nil && reads == 0)
    check("no clipboard_set: fetching still goes on", state.canFetch)

    var reading = State(localKnownCount: 0)
    _ = reading.endFetch(.denied, wire: nil, changeCountAtRequest: 0, changeCountNow: 0)
    check("no clipboard_read: no more fetches", !reading.canFetch)
    check("no clipboard_read: sending still goes on", reading.localToSend(changeCount: 1, hasStrings: true, read: { "a" }) == "a")

    var old = State(localKnownCount: 0)
    _ = old.endFetch(.unsupported, wire: nil, changeCountAtRequest: 0, changeCountNow: 0)
    check("PC without the endpoint: no fetches", !old.canFetch)
    check("PC without the endpoint: nothing read or sent", old.localToSend(changeCount: 1, hasStrings: true, read: { "a" }) == nil)
}

do {
    // PC → iPhone: only what's copied on the PC during the session comes over
    var state = State(localKnownCount: 3)
    check("what the PC had before the session stays there",
          state.endFetch(.ok, wire: "old", changeCountAtRequest: 3, changeCountNow: 3) == nil)
    check("unchanged PC clipboard isn't written", state.endFetch(.ok, wire: "old", changeCountAtRequest: 3, changeCountNow: 3) == nil)
    check("a copy on the PC is written here", state.endFetch(.ok, wire: "new", changeCountAtRequest: 3, changeCountNow: 3) == "new")
    state.didWriteLocal(changeCount: 4)
    check("…and our own write isn't read back", state.localToSend(changeCount: 4, hasStrings: true, read: { "new" }) == nil)
    check("…nor written again", state.endFetch(.ok, wire: "new", changeCountAtRequest: 4, changeCountNow: 4) == nil)
    check("CRLF on the wire, LF here", state.endFetch(.ok, wire: "a\r\nb", changeCountAtRequest: 4, changeCountNow: 4) == "a\nb")
    check("copied here while the fetch was out: the newer copy here wins",
          state.endFetch(.ok, wire: "later", changeCountAtRequest: 4, changeCountNow: 5) == nil)
    check("empty PC clipboard isn't written", state.endFetch(.ok, wire: "", changeCountAtRequest: 5, changeCountNow: 5) == nil)
    let big = String(repeating: "a", count: State.maxBytes + 1)
    check("over 1 MiB from the PC isn't written", state.endFetch(.ok, wire: big, changeCountAtRequest: 5, changeCountNow: 5) == nil)
    check("a failed fetch writes nothing", state.endFetch(.failed, wire: nil, changeCountAtRequest: 5, changeCountNow: 5) == nil && state.canFetch)
}

do {
    // What we sent comes back on the next fetch: not written back (no echo)
    var state = State(localKnownCount: 0)
    _ = state.endFetch(.ok, wire: "before", changeCountAtRequest: 0, changeCountNow: 0)
    let sent = state.localToSend(changeCount: 1, hasStrings: true, read: { "line1\nline2" })
    check("sent text goes as CRLF", sent.map(State.toWire) == "line1\r\nline2")
    state.endSend(sent!, result: .ok)
    check("what we sent isn't written back", state.endFetch(.ok, wire: "line1\r\nline2", changeCountAtRequest: 1, changeCountNow: 1) == nil)
}

do {
    // Sunshine without Apollo's clipboard answers 200 with an XML 404
    check("Sunshine's XML 404 is no clipboard", State.result(status: 200, body: Data(#"<?xml version="1.0" encoding="utf-8"?><root status_code="404" status_message="Not Found"/>"#.utf8)) == .unsupported)
    check("text that looks like XML is text", State.result(status: 200, body: Data("<?xml version=\"1.0\"?><a/>".utf8)) == .ok)
    check("401 is a refused permission", State.result(status: 401, body: Data()) == .denied)
    check("404 is no clipboard", State.result(status: 404, body: Data()) == .unsupported)
    check("403 (not streaming yet) is a failure to retry", State.result(status: 403, body: Data()) == .failed)
    check("no answer is a failure to retry", State.result(status: -1, body: nil) == .failed)
}

// MARK: - A session against a stand-in PC

/// Runs the main queue until `done` or 3 s.
func pump(until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !done() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

/// Runs the main queue for a while (several polls).
func idle(_ seconds: TimeInterval = 0.7) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func makeSync(host: FakeHost, board: FakePasteboard, store: FakeStore, hostID: String = "pc") -> ClipboardSync {
    ClipboardSync(hostID: hostID, link: host, pasteboard: board, store: store, pollInterval: 0.2, copyDelay: 0.05, timeout: 0.5)
}

do {
    // iPhone → PC at the start; PC → iPhone from the polls; nothing echoes
    let host = FakeHost(clipboard: "on the PC before")
    let board = FakePasteboard(text: "copied on the iPhone")
    let store = FakeStore()
    let sync = makeSync(host: host, board: board, store: store)
    sync.streamStarted()
    pump { host.clipboard == "copied on the iPhone" }
    check("session start: the iPhone's text reaches the PC", host.clipboard == "copied on the iPhone", host.clipboard)
    check("session start: the PC's older text doesn't come over", board.text == "copied on the iPhone", board.text ?? "nil")
    check("session start: the pasteboard is read once", board.reads == 1, "\(board.reads)")

    host.clipboard = "copied on the PC\r\nsecond line"
    pump { board.text == "copied on the PC\nsecond line" }
    check("while streaming: a copy on the PC lands on the iPhone", board.text == "copied on the PC\nsecond line", board.text ?? "nil")
    let posts = host.posts.count
    let writes = board.writes
    sync.becameActive()
    idle() // let the polls run a while
    check("back in the session: our own write isn't read or sent back", board.reads == 1 && host.posts.count == posts, "reads \(board.reads) posts \(host.posts.count)")
    check("the same PC text isn't written twice", board.writes == writes, "\(board.writes)")

    board.copy("copied on the iPhone again")
    sync.becameActive()
    pump { host.clipboard == "copied on the iPhone again" }
    check("back in the session: a new copy goes to the PC", host.clipboard == "copied on the iPhone again" && board.reads == 2, "\(host.clipboard) reads \(board.reads)")

    host.clipboard = "last copy on the PC"
    var ended = false
    sync.streamEnding { ended = true }
    pump { ended }
    check("leaving: the PC's last copy comes over", board.text == "last copy on the PC" && ended, board.text ?? "nil")
    let gets = host.gets
    idle()
    check("after leaving: no more polls", host.gets == gets, "\(host.gets) after \(gets)")

    // The next session with the same PC: the unchanged pasteboard isn't read
    let next = makeSync(host: host, board: board, store: store)
    next.streamStarted()
    pump { host.gets > gets }
    idle()
    check("next session: unchanged pasteboard isn't read", board.reads == 2, "\(board.reads)")
    var nextEnded = false
    next.streamEnding { nextEnded = true }
    pump { nextEnded }

    // Another PC hasn't got it: read and sent there
    let other = FakeHost(clipboard: "")
    let third = makeSync(host: other, board: board, store: store, hostID: "other pc")
    third.streamStarted()
    pump { other.clipboard == "last copy on the PC" }
    check("another PC gets the pasteboard's text", other.clipboard == "last copy on the PC" && board.reads == 3, "\(other.clipboard) reads \(board.reads)")
    var thirdEnded = false
    third.streamEnding { thirdEnded = true }
    pump { thirdEnded }
}

do {
    // Without Apollo's permissions: quietly nothing that way, no repeated requests
    let host = FakeHost(clipboard: "pc", getStatus: 401, postStatus: 401)
    let board = FakePasteboard(text: "phone")
    let sync = makeSync(host: host, board: board, store: FakeStore())
    sync.streamStarted()
    pump { host.posts.count == 1 }
    idle()
    check("no permissions: one fetch, one send, then quiet", host.gets == 1 && host.posts.count == 1, "gets \(host.gets) posts \(host.posts.count)")
    check("no permissions: nothing written here", board.text == "phone" && board.writes == 0)
    board.copy("phone 2")
    sync.becameActive()
    idle()
    check("no clipboard_set: a new copy isn't even read", board.reads == 1 && host.posts.count == 1, "reads \(board.reads)")
    var ended = false
    sync.streamEnding { ended = true }
    pump { ended }
    check("no clipboard_read: leaving doesn't ask", host.gets == 1 && ended, "\(host.gets)")
}

do {
    // A PC that doesn't answer: leaving waits no longer than the time limit
    let host = FakeHost(clipboard: "pc")
    host.hang = true
    let board = FakePasteboard(text: nil)
    let sync = makeSync(host: host, board: board, store: FakeStore())
    sync.streamStarted()
    let start = Date()
    var ended = false
    sync.streamEnding { ended = true }
    pump { ended }
    let took = Date().timeIntervalSince(start)
    check("silent PC: leaving goes on after the time limit", ended && took < 1.5, "\(took) s")
    host.hang = false
}

do {
    // Copy on the PC with the bar's Copy (Ctrl+C): fetched shortly after, before the next poll
    let host = FakeHost(clipboard: "before")
    let board = FakePasteboard(text: nil)
    let sync = ClipboardSync(hostID: "pc", link: host, pasteboard: board, store: FakeStore(), pollInterval: 60, copyDelay: 0.05, timeout: 0.5)
    sync.streamStarted()
    pump { host.gets == 1 }
    host.clipboard = "copied with Ctrl+C"
    sync.copyKeySent()
    pump { board.text == "copied with Ctrl+C" }
    check("Ctrl+C on the PC: the copy comes over without waiting for a poll", board.text == "copied with Ctrl+C", board.text ?? "nil")
    var ended = false
    sync.streamEnding { ended = true }
    pump { ended }
}

print("\(count - failures)/\(count) passed")
exit(failures == 0 ? 0 : 1)
