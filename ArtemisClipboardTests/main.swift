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
    // Paste with the text in hand (the Paste control, UIKit's paste): onto the PC, then Ctrl+V
    var state = State(localKnownCount: 5)
    check("paste: the text goes to the PC", state.paste("hello", changeCount: 6) == .send("hello"))
    check("paste: …and the pasteboard counts as known", state.localKnownCount == 6, "\(String(describing: state.localKnownCount))")
    check("paste: on the PC's clipboard, then Ctrl+V", state.endPaste("hello", result: .ok) == .ctrlV)
    check("paste: the PC is known to have it", state.hostSeen == "hello")
    check("paste again: already on the PC, Ctrl+V alone", state.paste("hello", changeCount: 6) == .ctrlV)
    check("paste of nothing does nothing", state.paste("", changeCount: 6) == .nothing)
    let big = String(repeating: "é", count: State.maxBytes / 2 + 1) // 2 bytes each in UTF-8
    check("paste over 1 MiB does nothing", state.paste(big, changeCount: 7) == .nothing)
    let fits = String(repeating: "a", count: State.maxBytes)
    check("paste of exactly 1 MiB goes", state.paste(fits, changeCount: 8) == .send(fits))
}

do {
    // The PC doesn't take it: typed instead, and refusals turn sending off
    var state = State(localKnownCount: 0)
    _ = state.paste("a", changeCount: 1)
    check("no answer: typed", state.endPaste("a", result: .failed) == .type("a"))
    check("no answer: the PC isn't known to have it", state.hostSeen == nil)
    check("no answer: the next paste tries again", state.paste("a", changeCount: 1) == .send("a"))
    check("no clipboard_set: typed", state.endPaste("a", result: .denied) == .type("a"))
    check("no clipboard_set: later pastes are typed without asking", state.paste("b", changeCount: 2) == .type("b"))
    check("no clipboard_set: fetching still goes on", state.canFetch)
    var reads = 0
    check("no clipboard_set: Ctrl+V is the PC's own, unread",
          state.pasteKey(changeCount: 3, hasStrings: true, read: { reads += 1; return "c" }) == .ctrlV && reads == 0, "reads \(reads)")

    var old = State(localKnownCount: 0)
    _ = old.endFetch(.unsupported, wire: nil, changeCountAtRequest: 0, changeCountNow: 0)
    check("PC without the endpoint: no fetches", !old.canFetch)
    check("PC without the endpoint: a paste is typed", old.paste("a", changeCount: 1) == .type("a"))

    var reading = State(localKnownCount: 0)
    _ = reading.endFetch(.denied, wire: nil, changeCountAtRequest: 0, changeCountNow: 0)
    check("no clipboard_read: no more fetches", !reading.canFetch)
    check("no clipboard_read: pasting still goes to the PC", reading.paste("a", changeCount: 1) == .send("a"))
}

do {
    // Ctrl+V reads the pasteboard only when it changed since we last knew it, and has text
    var state = State(localKnownCount: 5)
    var reads = 0
    let read: () -> String? = { reads += 1; return "hello" }
    check("Ctrl+V, unchanged pasteboard: unread, the PC's own paste",
          state.pasteKey(changeCount: 5, hasStrings: true, read: read) == .ctrlV && reads == 0, "reads \(reads)")
    check("Ctrl+V, changed without text: unread", state.pasteKey(changeCount: 6, hasStrings: false, read: read) == .ctrlV && reads == 0)
    check("…and isn't looked at again", state.localKnownCount == 6, "\(String(describing: state.localKnownCount))")
    check("Ctrl+V, a new copy with text: read and sent", state.pasteKey(changeCount: 7, hasStrings: true, read: read) == .send("hello") && reads == 1)
    _ = state.endPaste("hello", result: .ok)
    check("Ctrl+V again: unread", state.pasteKey(changeCount: 7, hasStrings: true, read: read) == .ctrlV && reads == 1, "reads \(reads)")
    check("copied again with the same text: read, Ctrl+V alone", state.pasteKey(changeCount: 8, hasStrings: true, read: read) == .ctrlV && reads == 2)
    check("Ctrl+V, read refused (\"Don't Allow\"): the PC's own paste", state.pasteKey(changeCount: 9, hasStrings: true, read: { nil }) == .ctrlV)
    check("…and isn't asked again for the same copy", state.pasteKey(changeCount: 9, hasStrings: true, read: { "x" }) == .ctrlV)

    var first = State(localKnownCount: nil)
    check("first session ever: Ctrl+V reads the pasteboard", first.pasteKey(changeCount: 1, hasStrings: true, read: { "a" }) == .send("a"))
}

do {
    // What the PC has, and what came from it, isn't sent back
    var state = State(localKnownCount: 0)
    _ = state.endFetch(.ok, wire: "same", changeCountAtRequest: 0, changeCountNow: 0)
    check("pasting text the PC has: Ctrl+V alone", state.paste("same", changeCount: 1) == .ctrlV)
}

do {
    // PC → iPhone: only what's copied on the PC during the session comes over
    var state = State(localKnownCount: 3)
    check("what the PC had before the session stays there",
          state.endFetch(.ok, wire: "old", changeCountAtRequest: 3, changeCountNow: 3) == nil)
    check("unchanged PC clipboard isn't written", state.endFetch(.ok, wire: "old", changeCountAtRequest: 3, changeCountNow: 3) == nil)
    check("a copy on the PC is written here", state.endFetch(.ok, wire: "new", changeCountAtRequest: 3, changeCountNow: 3) == "new")
    state.didWriteLocal(changeCount: 4)
    var reads = 0
    check("…and our own write isn't read back on Ctrl+V", state.pasteKey(changeCount: 4, hasStrings: true, read: { reads += 1; return "new" }) == .ctrlV && reads == 0)
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
    let sent = state.paste("line1\nline2", changeCount: 1)
    check("sent text goes as CRLF", State.toWire("line1\nline2") == "line1\r\nline2" && sent == .send("line1\nline2"))
    _ = state.endPaste("line1\nline2", result: .ok)
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

/// Pastes and waits for the outcome.
func paste(_ sync: ClipboardSync, _ text: String? = nil) -> ClipboardSync.PasteStep? {
    var outcome: ClipboardSync.PasteStep?
    if let text { sync.paste(text) { outcome = $0 } } else { sync.pasteKey { outcome = $0 } }
    pump { outcome != nil }
    return outcome
}

do {
    // The session starts and comes back: the pasteboard isn't read; it is when pasting
    let host = FakeHost(clipboard: "on the PC before")
    let board = FakePasteboard(text: "copied on the iPhone")
    let store = FakeStore()
    let sync = makeSync(host: host, board: board, store: store)
    sync.streamStarted()
    pump { host.gets >= 1 }
    idle() // several polls
    check("session start: the pasteboard isn't read", board.reads == 0, "\(board.reads)")
    check("session start: nothing goes to the PC", host.posts.isEmpty, "\(host.posts)")
    check("session start: the PC's older text doesn't come over", board.text == "copied on the iPhone", board.text ?? "nil")
    sync.resignedActive() // Control Center, another app
    board.copy("copied in another app")
    idle()
    check("back in the session: the pasteboard isn't read", board.reads == 0 && host.posts.isEmpty, "reads \(board.reads) posts \(host.posts)")

    // The Paste control: the text it hands over goes to the PC, then Ctrl+V
    check("Paste: Ctrl+V once the text is on the PC", paste(sync, "copied in another app") == .ctrlV)
    check("Paste: the PC got the text", host.posts == ["copied in another app"], "\(host.posts)")
    check("Paste: the pasteboard isn't read by the app (the control hands the text over)", board.reads == 0, "\(board.reads)")
    check("Paste again: Ctrl+V without sending again", paste(sync, "copied in another app") == .ctrlV && host.posts.count == 1, "\(host.posts)")
    check("Ctrl+V after Paste: the pasteboard isn't read again", paste(sync) == .ctrlV && board.reads == 0, "\(board.reads)")

    // Ctrl+V on a keyboard: a new copy is read then, sent, then Ctrl+V
    board.copy("line 1\nline 2")
    check("Ctrl+V, new copy: Ctrl+V once it's on the PC", paste(sync) == .ctrlV)
    check("Ctrl+V, new copy: read once and sent as CRLF", board.reads == 1 && host.posts.last == "line 1\r\nline 2", "reads \(board.reads) \(host.posts)")

    host.clipboard = "copied on the PC\r\nsecond line"
    pump { board.text == "copied on the PC\nsecond line" }
    check("while streaming: a copy on the PC lands on the iPhone", board.text == "copied on the PC\nsecond line", board.text ?? "nil")
    let writes = board.writes
    idle()
    check("the same PC text isn't written twice", board.writes == writes, "\(board.writes)")
    check("Ctrl+V after the PC's copy came over: not read or sent back", paste(sync) == .ctrlV && board.reads == 1 && host.posts.count == 2,
          "reads \(board.reads) posts \(host.posts.count)")

    host.clipboard = "last copy on the PC"
    var ended = false
    sync.streamEnding { ended = true }
    pump { ended }
    check("leaving: the PC's last copy comes over", board.text == "last copy on the PC" && ended, board.text ?? "nil")
    let gets = host.gets
    idle()
    check("after leaving: no more polls", host.gets == gets, "\(host.gets) after \(gets)")
    check("after leaving: a paste is typed, not sent", paste(sync, "late") == .type("late") && host.posts.count == 2)

    // The next session with the same PC: Ctrl+V doesn't read the unchanged pasteboard
    let next = makeSync(host: host, board: board, store: store)
    next.streamStarted()
    idle()
    check("next session: Ctrl+V, unchanged pasteboard isn't read", paste(next) == .ctrlV && board.reads == 1, "\(board.reads)")
    var nextEnded = false
    next.streamEnding { nextEnded = true }
    pump { nextEnded }

    // Another PC hasn't got it: read and sent there on Ctrl+V
    let other = FakeHost(clipboard: "")
    let third = makeSync(host: other, board: board, store: store, hostID: "other pc")
    third.streamStarted()
    idle()
    check("another PC: nothing read at the start", board.reads == 1, "\(board.reads)")
    check("another PC: Ctrl+V reads and sends the pasteboard's text",
          paste(third) == .ctrlV && other.posts == ["last copy on the PC"] && board.reads == 2, "\(other.posts) reads \(board.reads)")
    var thirdEnded = false
    third.streamEnding { thirdEnded = true }
    pump { thirdEnded }
}

do {
    // Without Apollo's permissions: quietly nothing that way, no repeated requests; Paste types
    let host = FakeHost(clipboard: "pc", getStatus: 401, postStatus: 401)
    let board = FakePasteboard(text: "phone")
    let sync = makeSync(host: host, board: board, store: FakeStore())
    sync.streamStarted()
    pump { host.gets == 1 }
    idle()
    check("no permissions: one fetch, nothing sent, then quiet", host.gets == 1 && host.posts.isEmpty, "gets \(host.gets) posts \(host.posts.count)")
    check("no permissions: nothing written here", board.text == "phone" && board.writes == 0)
    check("no clipboard_set: Paste types the text", paste(sync, "phone") == .type("phone") && host.posts.count == 1)
    check("no clipboard_set: the next Paste is typed without asking the PC", paste(sync, "phone 2") == .type("phone 2") && host.posts.count == 1)
    board.copy("phone 3")
    check("no clipboard_set: Ctrl+V is the PC's own, the copy unread", paste(sync) == .ctrlV && board.reads == 0, "reads \(board.reads)")
    var ended = false
    sync.streamEnding { ended = true }
    pump { ended }
    check("no clipboard_read: leaving doesn't ask", host.gets == 1 && ended, "\(host.gets)")
}

do {
    // A PC without the endpoint (Sunshine): Paste types
    let host = FakeHost(clipboard: "", getStatus: 404, postStatus: 404)
    let sync = makeSync(host: host, board: FakePasteboard(text: nil), store: FakeStore())
    sync.streamStarted()
    pump { host.gets == 1 }
    check("PC without the endpoint: Paste types", paste(sync, "typed") == .type("typed") && host.posts.isEmpty, "\(host.posts)")
    var ended = false
    sync.streamEnding { ended = true }
    pump { ended }
}

do {
    // A PC that doesn't answer the send: typed after the time limit
    let host = FakeHost(clipboard: "pc")
    let sync = makeSync(host: host, board: FakePasteboard(text: nil), store: FakeStore())
    sync.streamStarted()
    pump { host.gets == 1 }
    host.hang = true
    check("silent PC: Paste is typed", paste(sync, "typed anyway") == .type("typed anyway"))
    host.hang = false
    var ended = false
    sync.streamEnding { ended = true }
    pump { ended }
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
