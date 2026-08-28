import SwiftUI

struct RemindersApp: View {
    @State private var lists = RemindersData.lists
    @State private var openIndex: Int?
    @State private var search = ""

    var body: some View {
        GeometryReader { geo in
            ZStack {
                overview
                    .offset(x: openIndex == nil ? 0 : -geo.size.width * 0.3)
                    .overlay(Palette.ink.opacity(openIndex == nil ? 0 : 0.2))
                    .disabled(openIndex != nil)

                if let index = openIndex, lists.indices.contains(index) {
                    ReminderListView(list: $lists[index]) {
                        withAnimation(.appClose) { openIndex = nil }
                    }
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
                }
            }
        }
        .background(SysColor.groupedBackground)
        .onAppIntent(.reminders) { _ in
            guard !lists.isEmpty else { return }
            lists[0].items.insert(ReminderItem(title: "New Reminder", done: false, note: nil), at: 0)
            withAnimation(.appLaunch) { openIndex = 0 }
        }
    }

    private var overview: some View {
        AppScaffold(title: "Lists", searchable: true, searchText: $search) {
            VStack(spacing: 22) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    ForEach(Array(lists.enumerated()), id: \.element.id) { index, list in
                        Button {
                            withAnimation(.appLaunch) { openIndex = index }
                        } label: {
                            SmartTile(list: list)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

                ListSection(header: "My Lists") {
                    ForEach(Array(lists.enumerated()), id: \.element.id) { index, list in
                        ListRow(separatorInset: 57, action: {
                            withAnimation(.appLaunch) { openIndex = index }
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: list.symbol)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(SysColor.label)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(list.color))
                                Text(list.name)
                                    .font(.system(size: 17))
                                    .foregroundStyle(SysColor.label)
                            }
                        } trailing: {
                            HStack(spacing: 8) {
                                Text("\(list.items.filter { !$0.done }.count)")
                                    .font(.system(size: 17))
                                    .foregroundStyle(SysColor.secondaryLabel)
                                Chevron()
                            }
                        }
                    }
                }
            }
        } trailing: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18))
                .foregroundStyle(SysColor.blue)
        }
    }
}

private struct SmartTile: View {
    let list: ReminderList

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: list.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(list.color))
                Spacer()
                Text("\(list.items.filter { !$0.done }.count)")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(SysColor.label)
            }
            Text(list.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SysColor.secondaryLabel)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SysColor.secondaryGrouped)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ReminderListView: View {
    @Binding var list: ReminderList
    var onBack: () -> Void

    @Environment(\.deviceSafeArea) private var safeArea
    @State private var newTitle = ""
    @State private var keyboard: CGFloat = 0
    @FocusState private var addingFocused: Bool
    @State private var adding = false

    var body: some View {
        ZStack(alignment: .top) {
            SysColor.groupedBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(list.name)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(list.color)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)

                    VStack(spacing: 0) {
                        ForEach($list.items) { $item in
                            ReminderRow(item: $item, tint: list.color)
                        }

                        if adding {
                            HStack(spacing: 12) {
                                Circle()
                                    .strokeBorder(SysColor.secondaryLabel, lineWidth: 1.5)
                                    .frame(width: 22, height: 22)
                                TextField("New Reminder", text: $newTitle)
                                    .font(.system(size: 17))
                                    .foregroundStyle(SysColor.label)
                                    .tint(list.color)
                                    .focused($addingFocused)
                                    .onSubmit(commit)
                            }
                            .padding(.horizontal, 20)
                            .frame(minHeight: 44)
                        }
                    }
                }
                .padding(.top, safeArea.top + 56)
                .padding(.bottom, 100)
            }

            InlineNavBar(title: list.name, backTitle: "Lists", tint: list.color, onBack: onBack) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(list.color)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Button {
                adding = true
                addingFocused = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                    Text("New Reminder")
                        .font(.system(size: 17, weight: .medium))
                }
                .foregroundStyle(list.color)
            }
            .padding(.leading, 20)
            .padding(.bottom, keyboard > 0 ? keyboard + 12 : max(safeArea.bottom, 16) + 6)
        }
        .keyboardHeight($keyboard)
    }

    private func commit() {
        let text = newTitle.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { adding = false; return }
        list.items.append(ReminderItem(title: text, done: false, note: nil))
        newTitle = ""
    }
}

private struct ReminderRow: View {
    @Binding var item: ReminderItem
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                Haptics.tap(.light)
                withAnimation(.snappy) { item.done.toggle() }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(item.done ? tint : SysColor.secondaryLabel, lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    if item.done {
                        Circle().fill(tint).frame(width: 13, height: 13)
                    }
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 17))
                    .foregroundStyle(item.done ? SysColor.secondaryLabel : Palette.paper)
                    .strikethrough(item.done, color: SysColor.secondaryLabel)
                if let note = item.note {
                    Text(note)
                        .font(.system(size: 14))
                        .foregroundStyle(SysColor.secondaryLabel)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SysColor.separator)
                .frame(height: 0.5)
                .padding(.leading, 54)
        }
    }
}
