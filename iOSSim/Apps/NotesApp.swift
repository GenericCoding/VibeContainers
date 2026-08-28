import SwiftUI

struct NotesApp: View {
    @State private var notes = NotesData.notes
    @State private var openIndex: Int?
    @State private var search = ""

    var body: some View {
        GeometryReader { geo in
            ZStack {
                list
                    .offset(x: openIndex == nil ? 0 : -geo.size.width * 0.3)
                    .overlay(Palette.ink.opacity(openIndex == nil ? 0 : 0.2))
                    .disabled(openIndex != nil)

                if let index = openIndex, notes.indices.contains(index) {
                    NoteEditor(note: $notes[index]) {
                        withAnimation(.appClose) { openIndex = nil }
                    }
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
                }
            }
        }
        .background(SysColor.groupedBackground)
        .onAppIntent(.notes) { intent in
            compose(checklist: intent == .notesChecklist)
        }
    }

    /// Both quick actions start a note; a checklist just starts it with the
    /// first bullet already in place.
    private func compose(checklist: Bool) {
        let title = checklist ? "New Checklist" : "New Note"
        let body = checklist ? "\(title)\n\u{2610} " : "\(title)\n"
        notes.insert(Note(title: title, body: body, date: "Now"), at: 0)
        withAnimation(.appLaunch) { openIndex = 0 }
    }

    private var filtered: [Int] {
        notes.indices.filter {
            search.isEmpty || notes[$0].title.localizedCaseInsensitiveContains(search)
        }
    }

    private var list: some View {
        ZStack(alignment: .bottom) {
            AppScaffold(title: "Notes", searchable: true, searchPlaceholder: "Search", searchText: $search) {
                ListSection(header: nil, footer: nil) {
                    ForEach(filtered, id: \.self) { index in
                        let note = notes[index]
                        ListRow(action: {
                            withAnimation(.appLaunch) { openIndex = index }
                        }) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(note.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(SysColor.label)
                                    .lineLimit(1)
                                HStack(spacing: 5) {
                                    Text(note.date)
                                        .font(.system(size: 14))
                                        .foregroundStyle(SysColor.secondaryLabel)
                                    Text(note.preview)
                                        .font(.system(size: 14))
                                        .foregroundStyle(SysColor.secondaryLabel)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 8)
                        } trailing: {
                            Chevron()
                        }
                    }
                }
            } trailing: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(SysColor.yellow)
            }

            bottomBar
        }
    }

    private var bottomBar: some View {
        NotesToolbar(count: notes.count) { compose(checklist: false) }
    }
}

private struct NotesToolbar: View {
    let count: Int
    var onCompose: () -> Void
    @Environment(\.deviceSafeArea) private var safeArea

    var body: some View {
        ZStack {
            Text("\(count) Notes")
                .font(.system(size: 12))
                .foregroundStyle(SysColor.secondaryLabel)

            HStack {
                Spacer()
                Button(action: onCompose) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 21))
                        .foregroundStyle(SysColor.yellow)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 10)
        .padding(.bottom, max(safeArea.bottom, 10))
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle().fill(SysColor.separator).frame(height: 0.5)
                }
                .ignoresSafeArea()
        }
    }
}

private struct NoteEditor: View {
    @Binding var note: Note
    var onBack: () -> Void

    @State private var keyboard: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.deviceSafeArea) private var safeArea

    var body: some View {
        ZStack(alignment: .top) {
            SysColor.groupedBackground.ignoresSafeArea()

            TextEditor(text: $note.body)
                .font(.system(size: 17))
                .foregroundStyle(SysColor.label)
                .tint(SysColor.yellow)
                .scrollContentBackground(.hidden)
                .background(SysColor.groupedBackground)
                .focused($focused)
                .padding(.horizontal, 16)
                .padding(.top, safeArea.top + 50)
                .padding(.bottom, keyboard > 0 ? keyboard : safeArea.bottom + 50)

            InlineNavBar(title: "", backTitle: "Notes", tint: SysColor.yellow, onBack: {
                focused = false
                syncTitle()
                onBack()
            }) {
                HStack(spacing: 20) {
                    Image(systemName: "square.and.arrow.up")
                    Image(systemName: "ellipsis.circle")
                    if focused {
                        Button("Done") { focused = false }
                            .font(.system(size: 17, weight: .semibold))
                    } else {
                        Image(systemName: "square.and.pencil")
                    }
                }
                .font(.system(size: 18))
                .foregroundStyle(SysColor.yellow)
            }
        }
        .keyboardHeight($keyboard)
    }

    private func syncTitle() {
        let first = note.body.split(separator: "\n").first.map(String.init) ?? "New Note"
        note.title = first.isEmpty ? "New Note" : first
    }
}
