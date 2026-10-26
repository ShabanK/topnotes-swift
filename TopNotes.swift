import AppKit
import SwiftUI

// MARK: - Model

struct CheckItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var text = ""
    var done = false
}

struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    var text = ""
    var color = 0
    var updated = Date()
    /// Custom tab name; nil means "use the first line".
    var name: String? = nil
    var isChecklist = false
    var items: [CheckItem] = []

    var hasContent: Bool {
        isChecklist ? items.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                    : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var title: String {
        if let name, !name.isEmpty { return name }
        let first = isChecklist
            ? (items.first { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }?.text ?? "")
            : (text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "")
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? (isChecklist ? "Empty list" : "Empty note") : trimmed
    }

    /// Switch between free text and a checklist, carrying the content across.
    /// Text lines become items ("- [x] foo" keeps its checked state); items become "- [ ] foo" lines.
    mutating func toggleChecklist() {
        if isChecklist {
            text = items.map { "- [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n")
            items = []
        } else {
            items = text.split(separator: "\n").compactMap { raw in
                var line = raw.trimmingCharacters(in: .whitespaces)
                var done = false
                for prefix in ["- [x] ", "- [X] ", "[x] ", "[X] "] where line.hasPrefix(prefix) {
                    done = true; line.removeFirst(prefix.count)
                }
                for prefix in ["- [ ] ", "[ ] ", "- ", "* ", "• "] where line.hasPrefix(prefix) {
                    line.removeFirst(prefix.count)
                }
                return line.isEmpty ? nil : CheckItem(text: line, done: done)
            }
            if items.isEmpty { items = [CheckItem()] }
            text = ""
        }
        isChecklist.toggle()
    }
}

// Decoding with defaults so notes saved by older versions still load.
extension Note {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? 0
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? Date()
        name = try c.decodeIfPresent(String.self, forKey: .name)
        isChecklist = try c.decodeIfPresent(Bool.self, forKey: .isChecklist) ?? false
        items = try c.decodeIfPresent([CheckItem].self, forKey: .items) ?? []
    }
}

/// cloak.nvim-style masking: every visible character becomes a dot, spacing and line breaks stay.
func cloak(_ s: String) -> String { String(s.map { $0.isWhitespace ? $0 : "•" }) }

enum Palette {
    static let colors: [Color] = [
        Color(red: 1.00, green: 0.93, blue: 0.55), // yellow
        Color(red: 0.72, green: 0.90, blue: 1.00), // blue
        Color(red: 0.78, green: 0.95, blue: 0.70), // green
        Color(red: 1.00, green: 0.78, blue: 0.84), // pink
        Color(red: 0.87, green: 0.80, blue: 1.00), // purple
    ]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
}

@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [Note] = [] { didSet { scheduleSave() } }
    @Published var selectedID: UUID?

    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if isDebugRun {
            // Debug runs must never touch the real notes.
            self.fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("topnotes-debug-unused.json")
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TopNotes", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("notes.json")
        }

        if let data = try? Data(contentsOf: self.fileURL),
           let saved = try? JSONDecoder().decode([Note].self, from: data), !saved.isEmpty {
            notes = saved
        } else {
            notes = [Note()]
        }
        selectedID = notes.first?.id
    }

    var selectedIndex: Int? { notes.firstIndex { $0.id == selectedID } }

    func add() {
        let color = (notes.last?.color ?? -1) + 1
        let note = Note(color: color)
        notes.append(note)
        selectedID = note.id
    }

    func delete(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes.remove(at: i)
        if notes.isEmpty { notes = [Note()] }
        selectedID = notes[min(i, notes.count - 1)].id
    }

    func cycleColor(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].color += 1
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[i].name = trimmed.isEmpty ? nil : trimmed
    }

    func canShift(_ id: UUID, by offset: Int) -> Bool {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return false }
        return notes.indices.contains(i + offset)
    }

    /// Move a tab one or more slots left (negative) or right (positive).
    func shift(_ id: UUID, by offset: Int) {
        guard canShift(id, by: offset), let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes.swapAt(i, i + offset)
    }

    /// Move a tab into the slot currently held by `target`.
    func move(_ id: UUID, onto target: UUID) {
        guard id != target,
              let from = notes.firstIndex(where: { $0.id == id }),
              let to = notes.firstIndex(where: { $0.id == target }) else { return }
        notes.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    func toggleChecklist(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].toggleChecklist()
        notes[i].updated = Date()
    }

    // Debounced so typing doesn't hit the disk on every keystroke.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Views

struct NotesView: View {
    @EnvironmentObject var store: NotesStore
    @State private var confirmDelete = false
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    /// Notes start hidden and re-hide whenever the popover closes.
    @State private var cloaked = true
    @FocusState private var editorFocused: Bool
    @FocusState private var renameFocused: Bool

    init(renaming: Note? = nil) {
        _renamingID = State(initialValue: renaming?.id)
        _renameDraft = State(initialValue: renaming?.title ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Divider()
            if let i = store.selectedIndex {
                editor(for: i)
            }
        }
        .frame(width: 380, height: 360)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in hide() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in hide() }
    }

    private func hide() {
        cloaked = true
        commitRename()
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.notes) { note in
                            tab(note)
                                .id(note.id)
                                .background(GeometryReader { g in
                                    let _ = DebugProbe.tabFrames[note.id] = g.frame(in: .global)
                                    Color.clear
                                })
                        }
                    }
                    .padding(.vertical, 1)
                }
                // Keep the active tab visible after it moves.
                .onChange(of: store.notes.map(\.id)) {
                    if let id = store.selectedID { proxy.scrollTo(id) }
                }
            }
            Button { store.add(); confirmDelete = false } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New note")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    @ViewBuilder
    private func tab(_ note: Note) -> some View {
        let selected = note.id == store.selectedID
        let shape = RoundedRectangle(cornerRadius: 6)
        let fill = Palette.color(note.color).opacity(selected ? 1 : 0.55)

        if renamingID == note.id {
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(width: 110)
                .background(shape.fill(fill))
                .overlay(shape.stroke(.black.opacity(0.35), lineWidth: 1))
                .focused($renameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { renamingID = nil }
                .onChange(of: renameFocused) { if !renameFocused { commitRename() } }
                .onAppear { renameFocused = true }
        } else {
            HStack(spacing: 2) {
                if selected { arrow("chevron.left", note.id, by: -1) }
                // Custom names stay readable (like keys in cloak); titles taken from the note body are masked.
                Text(cloaked && note.name == nil && note.hasContent ? cloak(note.title) : note.title)
                    .lineLimit(1)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.black.opacity(selected ? 0.85 : 0.6))
                    .padding(.horizontal, selected ? 2 : 8).padding(.vertical, 4)
                    .frame(maxWidth: 110)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startRename(note) }
                    .simultaneousGesture(TapGesture().onEnded {
                        store.selectedID = note.id
                        confirmDelete = false
                    })
                    .help("Double-click to rename")
                if selected { arrow("chevron.right", note.id, by: 1) }
            }
            .background(shape.fill(fill))
        }
    }

    /// Arrows on the active tab move it one slot left or right; invisible (but still spaced) at the ends.
    private func arrow(_ symbol: String, _ id: UUID, by offset: Int) -> some View {
        let canMove = store.canShift(id, by: offset)
        return Button { store.shift(id, by: offset) } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.black.opacity(0.55))
        .opacity(canMove ? 1 : 0)
        .disabled(!canMove)
        .help(offset < 0 ? "Move tab left" : "Move tab right")
    }

    private func startRename(_ note: Note) {
        commitRename()
        store.selectedID = note.id
        renameDraft = cloaked && note.name == nil ? "" : note.title
        renamingID = note.id
    }

    private func commitRename() {
        guard let id = renamingID else { return }
        renamingID = nil
        // Saving the auto-derived title verbatim would freeze it; only store a real change.
        if let note = store.notes.first(where: { $0.id == id }), renameDraft != note.title,
           !(renameDraft.isEmpty && note.name == nil) {
            store.rename(id, to: renameDraft)
        }
    }

    private func editor(for i: Int) -> some View {
        let note = store.notes[i]
        return VStack(spacing: 0) {
            Group {
                if cloaked {
                    CloakedView(note: note)
                } else if note.isChecklist {
                    ChecklistEditor(items: $store.notes[i].items)
                } else {
                    TextEditor(text: $store.notes[i].text)
                        .font(.system(size: 13))
                        .foregroundStyle(.black.opacity(0.85))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .focused($editorFocused)
                        .onAppear { editorFocused = true }
                }
            }
            .onChange(of: store.notes[i].text) { store.notes[i].updated = Date() }
            .onChange(of: store.notes[i].items) { store.notes[i].updated = Date() }

            HStack(spacing: 10) {
                Button { store.cycleColor(note.id) } label: { Image(systemName: "paintpalette") }
                    .help("Change color")
                Button { store.toggleChecklist(note.id) } label: {
                    Image(systemName: note.isChecklist ? "text.alignleft" : "checklist")
                }
                .help(note.isChecklist ? "Turn into plain text" : "Turn into a checklist")
                Button { cloaked.toggle() } label: {
                    Image(systemName: cloaked ? "eye.slash" : "eye").frame(width: 18)
                }
                .help(cloaked ? "Show notes" : "Hide notes")
                .background(GeometryReader { g in
                    let _ = DebugProbe.eyeFrame = g.frame(in: .global)
                    Color.clear
                })
                Text(note.updated, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(.black.opacity(0.45))
                Spacer()
                if confirmDelete {
                    Text("Delete?").font(.caption).foregroundStyle(.black.opacity(0.6))
                    Button("Yes") { store.delete(note.id); confirmDelete = false }
                    Button("No") { confirmDelete = false }
                } else {
                    Button { confirmDelete = true } label: { Image(systemName: "trash") }
                        .help("Delete note")
                }
                Button { store.saveNow(); NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Top Notes")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.black.opacity(0.6))
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Palette.color(note.color))
    }
}

/// Read-only masked rendering of a note; same layout as the editors so the shape stays familiar.
struct CloakedView: View {
    let note: Note

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if note.isChecklist {
                    ForEach(note.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: item.done ? "checkmark.square.fill" : "square").font(.system(size: 14))
                            Text(cloak(item.text)).font(.system(size: 13)).opacity(item.done ? 0.45 : 1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                    }
                } else {
                    Text(cloak(note.text))
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .foregroundStyle(.black.opacity(0.6))
            .padding(note.isChecklist ? 12 : 15)
        }
    }
}

struct ChecklistEditor: View {
    @Binding var items: [CheckItem]
    @FocusState private var focused: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach($items) { $item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button { item.done.toggle() } label: {
                            Image(systemName: item.done ? "checkmark.square.fill" : "square")
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.borderless)

                        // Text fields can't draw strikethrough, so ticked items show as plain text.
                        if item.done {
                            Text(item.text)
                                .font(.system(size: 13))
                                .strikethrough()
                                .opacity(0.45)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { item.done = false; focused = item.id }
                                .help("Click to untick and edit")
                        } else {
                        TextField("List item", text: $item.text, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($focused, equals: item.id)
                            .onSubmit { insert(after: item.id) }
                            .onKeyPress(.delete) {
                                guard item.text.isEmpty else { return .ignored }
                                remove(item.id)
                                return .handled
                            }
                        }

                        Button { remove(item.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.borderless)
                            .opacity(0.4)
                            .help("Remove item")
                    }
                    .padding(.vertical, 3)
                }

                Button { insert(after: items.last?.id) } label: {
                    Label("Add item", systemImage: "plus").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .opacity(0.6)
                .padding(.top, 4)
            }
            .foregroundStyle(.black.opacity(0.85))
            .padding(12)
        }
        .onAppear { focused = items.first { $0.text.isEmpty }?.id }
    }

    /// Return in an item adds a fresh one right below it.
    private func insert(after id: UUID?) {
        let new = CheckItem()
        let at = id.flatMap { id in items.firstIndex { $0.id == id } }.map { $0 + 1 } ?? items.count
        items.insert(new, at: at)
        focused = new.id
    }

    /// Backspace on an empty item removes it and moves focus up.
    private func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: i)
        focused = items.isEmpty ? nil : items[max(0, i - 1)].id
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: NotesStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { runDebugCommandIfRequested() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { store?.saveNow() }
    }
}

@main
struct TopNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = NotesStore()

    var body: some Scene {
        MenuBarExtra {
            NotesView()
                .environmentObject(store)
                .onAppear { delegate.store = store }
        } label: {
            Image(systemName: "note.text")
        }
        .menuBarExtraStyle(.window)
    }
}
