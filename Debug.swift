import AppKit
import SwiftUI

// Verification hooks, never triggered in normal use:
//   TopNotes -selftest 1 -workDir <dir>  model checks, exits 0/1
//   TopNotes -snapshotDir <dir>          renders the window to PNGs, exits
// Both work on a throwaway notes file, never the real one.

let isDebugRun = UserDefaults.standard.bool(forKey: "selftest") || UserDefaults.standard.bool(forKey: "interactTest") || UserDefaults.standard.string(forKey: "snapshotDir") != nil

@MainActor
func runDebugCommandIfRequested() {
    let d = UserDefaults.standard
    if d.bool(forKey: "selftest") {
        exit(runSelfTest() ? 0 : 1)
    }
    runInteractTestIfRequested()
    if let dir = d.string(forKey: "snapshotDir") {
        renderSnapshots(to: URL(fileURLWithPath: dir))
        exit(0)
    }
}

@MainActor
private func runSelfTest() -> Bool {
    var failures = 0
    func check(_ ok: Bool, _ label: String) {
        print(ok ? "PASS" : "FAIL", label)
        if !ok { failures += 1 }
    }

    // 1. Notes saved by the old version (no name/isChecklist/items) still load.
    let old = #"[{"text":"Groceries\nmilk","color":1,"id":"11111111-1111-1111-1111-111111111111","updated":811343512}]"#
    let decoded = try? JSONDecoder().decode([Note].self, from: Data(old.utf8))
    check(decoded?.count == 1 && decoded?[0].text == "Groceries\nmilk" && decoded?[0].color == 1
          && decoded?[0].name == nil && decoded?[0].isChecklist == false && decoded?[0].items == [],
          "old-format note decodes with defaults")

    // 2. The real notes file (if any) decodes without losing a note or its text.
    let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TopNotes/notes.json")
    if let data = try? Data(contentsOf: real),
       let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        let notes = try? JSONDecoder().decode([Note].self, from: data)
        let sameText = notes.map { zip($0, raw).allSatisfy { $0.text == ($1["text"] as? String ?? "") } } ?? false
        check(notes?.count == raw.count && sameText, "real notes file decodes (\(raw.count) notes, text intact)")
    }

    // 3. Encode -> decode round-trips every field.
    var full = Note(text: "", color: 3, name: "Renamed", isChecklist: true,
                    items: [CheckItem(text: "a", done: true), CheckItem(text: "b")])
    full.updated = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let again = (try? JSONEncoder().encode([full])).flatMap { try? JSONDecoder().decode([Note].self, from: $0) }
    check(again?.first == full, "round-trip keeps name, checklist flag and items")

    // 4. Reordering.
    let workDir = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "workDir") ?? NSTemporaryDirectory())
    let tmp = workDir.appendingPathComponent("topnotes-selftest-\(UUID()).json")
    let store = NotesStore(fileURL: tmp)
    store.notes = ["A", "B", "C", "D"].map { Note(name: $0) }
    func order() -> String { store.notes.compactMap(\.name).joined() }
    let id = { (n: String) in store.notes.first { $0.name == n }!.id }
    store.move(id("A"), onto: id("C")); check(order() == "BCAD", "drag A onto C -> BCAD (got \(order()))")
    store.move(id("D"), onto: id("B")); check(order() == "DBCA", "drag D onto B -> DBCA (got \(order()))")
    store.move(id("C"), onto: id("C")); check(order() == "DBCA", "drop on itself is a no-op")
    store.shift(id("D"), by: -1); check(order() == "DBCA", "shift left at the start is a no-op")
    store.shift(id("D"), by: 1);  check(order() == "BDCA", "shift right swaps with neighbour (got \(order()))")
    store.shift(id("A"), by: 1);  check(order() == "BDCA", "shift right at the end is a no-op")
    store.shift(id("A"), by: -1); check(order() == "BDAC", "shift left swaps with neighbour (got \(order()))")
    check(!store.canShift(id("B"), by: -1) && store.canShift(id("B"), by: 1), "canShift reflects the ends")

    // 5. Renaming.
    let dID = id("D")
    let d = { store.notes.first { $0.id == dID }! }
    store.rename(dID, to: "  Work  "); check(d().name == "Work", "rename trims whitespace")
    store.notes[store.notes.firstIndex { $0.id == dID }!].text = "first line\nsecond"
    store.rename(dID, to: "   "); check(d().name == nil && d().title == "first line", "empty rename falls back to first line")

    // 6. Text <-> checklist conversion.
    var n = Note(text: "- [x] shipped\nbuy milk\n\n* call Sam\n- [ ] review PR")
    n.toggleChecklist()
    check(n.isChecklist && n.items.map(\.text) == ["shipped", "buy milk", "call Sam", "review PR"]
          && n.items.map(\.done) == [true, false, false, false] && n.text.isEmpty,
          "text -> checklist parses lines, bullets and [x]")
    check(n.title == "shipped", "checklist title is first item")
    n.toggleChecklist()
    check(!n.isChecklist && n.text == "- [x] shipped\n- [ ] buy milk\n- [ ] call Sam\n- [ ] review PR",
          "checklist -> text writes - [ ]/- [x] lines")
    n.toggleChecklist()
    check(n.items.map(\.done) == [true, false, false, false], "round-trip keeps checked state")
    check(cloak("ab c\nd  e") == "•• •\n•  •", "cloak masks characters, keeps spaces and newlines")
    var empty = Note(); empty.toggleChecklist()
    check(empty.items.count == 1 && empty.title == "Empty list", "empty note becomes one blank item")

    try? FileManager.default.removeItem(at: tmp)
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    return failures == 0
}

@MainActor
private func renderSnapshots(to dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("snapshot-notes.json")
    try? FileManager.default.removeItem(at: file)
    let store = NotesStore(fileURL: file)
    store.notes = [
        Note(text: "Meeting notes\nAgenda…", color: 0),
        Note(color: 1, name: "Groceries", isChecklist: true, items: [
            CheckItem(text: "Milk", done: true),
            CheckItem(text: "Eggs"),
            CheckItem(text: "Coffee beans", done: true),
            CheckItem(text: "Bread"),
        ]),
        Note(text: "Ideas", color: 3),
    ]

    func shoot(_ name: String, _ view: some View) {
        store.selectedID = store.notes[1].id
        let host = NSHostingView(rootView: view.environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let bounds = host.bounds
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        host.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        window.orderOut(nil)
        print("wrote", name)
    }

    shoot("checklist.png", NotesView())
    shoot("renaming.png", NotesView(renaming: store.notes[1]))
    store.saveNow()
    try? FileManager.default.removeItem(at: file)
}

// MARK: - Interaction test (synthetic mouse/keyboard events into our own window)
//   TopNotes -interactTest 1 -workDir <dir>

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
enum DebugProbe {
    static var tabFrames: [UUID: CGRect] = [:]   // window coordinates, top-left origin
    static var eyeFrame: CGRect = .zero
    static var itemDeleteFrames: [UUID: CGRect] = [:]
    static var cloaked = true
}

@MainActor
func runInteractTestIfRequested() {
    guard UserDefaults.standard.bool(forKey: "interactTest") else { return }
    setvbuf(stdout, nil, _IONBF, 0)   // keep the log if the app crashes mid-test
    let dir = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "workDir") ?? NSTemporaryDirectory())
    let file = dir.appendingPathComponent("interact-notes.json")
    try? FileManager.default.removeItem(at: file)
    let store = NotesStore(fileURL: file)
    store.notes = [Note(text: "secret", name: "Alpha"), Note(name: "Beta"), Note(name: "Gamma wide"), Note(name: "Delta"),
                   Note(name: "List", isChecklist: true, items: [CheckItem()]),
                   // Unnamed (so it stays out of order()), items never edited during the test.
                   Note(isChecklist: true, items: [CheckItem(text: "alpha item"), CheckItem(text: "beta item")])]
    store.selectedID = store.notes[0].id

    let height: CGFloat = 360
    let host = NSHostingView(rootView: NotesView().environmentObject(store))
    // Borderless like the real menu bar panel, so SwiftUI's window coordinates == content coordinates.
    // A non-activating panel can be key without the app being active, same as the real menu bar popover.
    let window = KeyablePanel(contentRect: NSRect(x: 200, y: 200, width: 380, height: height),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)

    var failures = 0
    func check(_ ok: Bool, _ label: String) { print(ok ? "PASS" : "FAIL", label); if !ok { failures += 1 } }
    // Pump the real event queue so queued synthetic events flow through NSApp like real input.
    func spin(_ s: Double = 0.25) {
        let until = Date().addingTimeInterval(s)
        while Date() < until {
            if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
            }
        }
    }
    func order() -> String { store.notes.compactMap(\.name).map { String($0.prefix(1)) }.joined() }
    func id(_ name: String) -> UUID { store.notes.first { $0.name?.hasPrefix(name) == true }!.id }
    func center(_ name: String) -> CGPoint { let f = DebugProbe.tabFrames[id(name)]!; return CGPoint(x: f.midX, y: f.midY) }
    func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) {
        let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: height - p.y), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        NSApp.postEvent(e, atStart: false)
    }
    func click(_ p: CGPoint, clicks: Int = 1) {
        for n in 1...clicks { mouse(.leftMouseDown, p, clicks: n); mouse(.leftMouseUp, p, clicks: n); spin(0.08) }
        spin()
    }
    func type(_ text: String) {
        for ch in text {
            let c = ch == "\n" ? "\r" : String(ch)
            for t in [NSEvent.EventType.keyDown, .keyUp] {
                NSApp.postEvent(NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, characters: c, charactersIgnoringModifiers: c,
                                                  isARepeat: false, keyCode: ch == "\n" ? 36 : 0)!, atStart: false)
            }
            spin(0.02)
        }
        spin()
    }
    func snapshot(_ name: String) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }

    // A freshly built app can take a moment to settle; start only once the panel is key.
    let deadline = Date().addingTimeInterval(5)
    while !window.isKeyWindow && Date() < deadline { window.makeKeyAndOrderFront(nil); spin(0.1) }
    spin(1.5)
    check(window.isKeyWindow, "test panel is key")
    check(DebugProbe.tabFrames.count == store.notes.count, "tab frames measured")

    spin(0.5)
    let countBefore = store.notes.count
    click(CGPoint(x: 380 - 10 - 7, y: DebugProbe.tabFrames[id("Alpha")]!.midY))
    check(store.notes.count == countBefore + 1, "plus button adds a note")
    if store.notes.count > countBefore { store.notes.removeLast(); store.selectedID = store.notes[0].id; spin() }

    // Single click selects.
    click(center("Beta"))
    check(store.selectedID == id("Beta"), "single click selects a tab")

    // Arrows on the active tab (Beta) move it.
    let betaID = id("Beta")
    func arrowPoint(_ dx: Int) -> CGPoint {
        let f = DebugProbe.tabFrames[betaID]!
        return CGPoint(x: dx < 0 ? f.minX + 8 : f.maxX - 8, y: f.midY)
    }
    click(arrowPoint(1));  check(order() == "AGBDL", "right arrow moves tab right -> AGBDL (got \(order()))")
    click(arrowPoint(-1)); check(order() == "ABGDL", "left arrow moves it back -> ABGDL (got \(order()))")
    click(arrowPoint(-1)); check(order() == "BAGDL", "left again -> BAGDL (got \(order()))")
    click(arrowPoint(-1)); check(order() == "BAGDL", "left arrow at the first slot does nothing")
    check(store.selectedID == betaID, "moved tab stays selected")
    let namesBefore = store.notes.map(\.name)
    // The tab moves away after the first click, so the second click of a double click misses the arrow.
    click(arrowPoint(1), clicks: 2)
    check(order() == "ABGDL", "double click on an arrow moves once -> ABGDL (got \(order()))")
    type("Z\n")
    check(Set(store.notes.compactMap(\.name)) == Set(namesBefore.compactMap { $0 }), "double click on an arrow does not start a rename")
    // Cloak: hidden on start, eye reveals, closing + reopening the panel hides again.
    let alphaID = id("Alpha")
    func alphaText() -> String { store.notes.first { $0.id == alphaID }!.text }
    click(center("Alpha")); spin(0.3)
    type("Q")
    check(alphaText() == "secret", "hidden note ignores typing (text: \(alphaText()))")
    snapshot("cloaked.png")
    click(CGPoint(x: DebugProbe.eyeFrame.midX, y: DebugProbe.eyeFrame.midY)); spin(0.4)
    type("Q")
    check(alphaText().contains("Q"), "eye reveals and the note is editable (text: \(alphaText()))")
    snapshot("revealed.png")
    window.orderOut(nil); spin(0.3)                 // popover closes
    window.makeKeyAndOrderFront(nil); spin(0.5)     // and opens again
    let beforeHidden = alphaText()
    type("W")
    check(alphaText() == beforeHidden, "reopening hides the notes again")
    click(CGPoint(x: DebugProbe.eyeFrame.midX, y: DebugProbe.eyeFrame.midY)); spin(0.4)   // reveal for the rest of the test
    check(!DebugProbe.cloaked, "eye reveals again after reopening")

    // Right after launch the popover is shown but not key; clicking into it makes it key.
    // That must not re-hide notes the user just revealed.
    window.orderOut(nil); spin(0.3)
    window.orderFrontRegardless(); spin(0.3)                       // shown, not key
    if DebugProbe.cloaked { click(CGPoint(x: DebugProbe.eyeFrame.midX, y: DebugProbe.eyeFrame.midY)); spin(0.4) }
    check(!DebugProbe.cloaked, "revealed while the panel is not key")
    window.makeKey(); spin(0.4)                                    // user clicks into the note
    check(!DebugProbe.cloaked, "panel becoming key does not re-hide revealed notes")

    // Double click renames; Return commits.
    let renameID = betaID
    click(center("Beta"), clicks: 2)
    type("X\n")
    // The rename field opens with its text selected (standard macOS), so typing replaces the old name.
    let renamed = store.notes.first { $0.id == renameID }!
    check(renamed.name == "X", "double click + type + Return renames (names now: \(store.notes.map { $0.name ?? "-" }))")

    // Checklist: Return adds an item; long text wraps.
    click(center("List")); spin(0.5)
    check(window.isKeyWindow, "panel still key before checklist typing")
    type("first item\n")
    let list = store.notes.first { $0.isChecklist }!
    check(list.items.count == 2 && list.items[0].text == "first item", "Return in an item adds a new one (items: \(list.items.map(\.text)))")
    type("a long checklist item that should definitely wrap onto a second line instead of running off the edge")
    snapshot("checklist-wrap.png")
    let after = store.notes.first { $0.isChecklist }!
    check(after.items.count == 2 && after.items[1].text.hasPrefix("a long"), "typing long text stays in one item")

    // Removing items while one is being edited (this used to crash the app).
    func listItems() -> [CheckItem] { store.notes.first { $0.isChecklist }!.items }
    let focusedItem = listItems()[1]                       // the long item we are typing in
    let x = DebugProbe.itemDeleteFrames[focusedItem.id]!
    click(CGPoint(x: x.midX, y: x.midY)); spin(0.5)
    check(listItems().map(\.text) == ["first item"], "× on the item being edited removes it (items: \(listItems().map(\.text)))")

    click(CGPoint(x: DebugProbe.itemDeleteFrames[listItems()[0].id]!.midX - 200, y: DebugProbe.itemDeleteFrames[listItems()[0].id]!.midY))
    type("more")
    type("\n")                                             // Return adds an empty item below and focuses it
    let beforeBackspace = listItems()
    for t in [NSEvent.EventType.keyDown, .keyUp] {      // Backspace on the new empty item
        NSApp.postEvent(NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
                                         charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!, atStart: false)
    }
    spin(0.5)
    func cursor() -> String {
        guard let tv = window.firstResponder as? NSTextView else { return "no text field focused" }
        let r = tv.selectedRange(), n = (tv.string as NSString).length
        return r == NSRange(location: n, length: 0) ? "at end" : "selection \(r.location)+\(r.length) of \(n)"
    }
    check(cursor() == "at end", "after Backspace the cursor sits at the end of the previous item (\(cursor()))")
    check(listItems().count == beforeBackspace.count - 1 && listItems().map(\.text) == ["first itemmore"],
          "Backspace on an empty item removes it (before: \(beforeBackspace.map(\.text)), after: \(listItems().map(\.text)))")

    // × on the last item moves the cursor to the end of the one above.
    click(CGPoint(x: DebugProbe.itemDeleteFrames[listItems()[0].id]!.midX - 200, y: DebugProbe.itemDeleteFrames[listItems()[0].id]!.midY))
    type("\n"); spin(0.5)
    type("second"); spin(0.3)
    check(listItems().map(\.text) == ["first itemmore", "second"], "setup: second item typed (items: \(listItems().map(\.text)))")
    let secondFrame = DebugProbe.itemDeleteFrames[listItems().last!.id]!
    click(CGPoint(x: secondFrame.midX, y: secondFrame.midY)); spin(0.6)
    let responderText = (window.firstResponder as? NSTextView)?.string ?? "none"
    check(responderText == "first itemmore", "after × focus moves to the previous item (focused text: \(responderText))")
    check(cursor() == "at end", "after × the cursor sits at the end of the previous item (\(cursor()))")

    // Remove every item, including the focused last one.
    while let it = listItems().last, let f = DebugProbe.itemDeleteFrames[it.id], listItems().count > 0 {
        let n = listItems().count
        click(CGPoint(x: f.midX, y: f.midY)); spin(0.3)
        if listItems().count == n { break }
    }
    check(listItems().isEmpty, "removing all items works (left: \(listItems().count))")

    // Focus moving to an item that was never edited must put the cursor at its end, not select it all.
    let freshID = store.notes.last!.id
    store.selectedID = freshID; spin(0.6)
    func freshItems() -> [CheckItem] { store.notes.first { $0.id == freshID }!.items }
    func focusedText() -> String { (window.firstResponder as? NSTextView)?.string ?? "none" }
    let betaX = DebugProbe.itemDeleteFrames[freshItems()[1].id]!
    click(CGPoint(x: betaX.midX, y: betaX.midY)); spin(0.6)
    check(focusedText() == "alpha item" && cursor() == "at end",
          "× moving to an untouched item puts the cursor at its end (focused: \(focusedText()), \(cursor()))")

    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    try? FileManager.default.removeItem(at: file)
    exit(failures == 0 ? 0 : 1)
}
