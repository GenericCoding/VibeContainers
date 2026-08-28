import SwiftUI

struct MailApp: View {
    @State private var mail = MailData.inbox
    @State private var openIndex: Int?
    @State private var search = ""
    @State private var focusSearch = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                inbox
                    .offset(x: openIndex == nil ? 0 : -geo.size.width * 0.3)
                    .overlay(Palette.ink.opacity(openIndex == nil ? 0 : 0.2))
                    .disabled(openIndex != nil)

                if let index = openIndex, mail.indices.contains(index) {
                    MailDetail(item: mail[index]) {
                        withAnimation(.appClose) { openIndex = nil }
                    }
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
                }
            }
        }
        .background(SysColor.groupedBackground)
        .onAppIntent(.mail) { intent in
            switch intent {
            case .mailCompose: compose()
            case .mailSearch:
                openIndex = nil
                focusSearch = true
            default: break
            }
        }
    }

    /// A new draft goes to the top of the inbox and opens, which is as close as
    /// a mock mailbox gets to a compose window.
    private func compose() {
        let draft = MailItem(sender: "Draft",
                             subject: "New Message",
                             preview: "",
                             date: "Now",
                             unread: false,
                             body: "")
        mail.insert(draft, at: 0)
        withAnimation(.appLaunch) { openIndex = 0 }
    }

    private var unreadCount: Int { mail.filter(\.unread).count }

    private var inbox: some View {
        ZStack(alignment: .bottom) {
            AppScaffold(title: "Inbox", searchable: true, searchText: $search,
                        searchFocus: $focusSearch) {
                ListSection {
                    ForEach(mail.indices.filter(matchesSearch), id: \.self) { index in
                        let item = mail[index]
                        ListRow(separatorInset: 30, action: {
                            mail[index].unread = false
                            withAnimation(.appLaunch) { openIndex = index }
                        }) {
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(SysColor.blue)
                                    .frame(width: 9, height: 9)
                                    .opacity(item.unread ? 1 : 0)
                                    .padding(.top, 6)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.sender)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(SysColor.label)
                                    Text(item.subject)
                                        .font(.system(size: 15))
                                        .foregroundStyle(SysColor.label.opacity(0.9))
                                        .lineLimit(1)
                                    Text(item.preview)
                                        .font(.system(size: 15))
                                        .foregroundStyle(SysColor.secondaryLabel)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .padding(.vertical, 9)
                        } trailing: {
                            VStack(alignment: .trailing, spacing: 8) {
                                HStack(spacing: 6) {
                                    if item.flagged {
                                        Image(systemName: "flag.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(SysColor.orange)
                                    }
                                    Text(item.date)
                                        .font(.system(size: 15))
                                        .foregroundStyle(SysColor.secondaryLabel)
                                }
                                Chevron().font(.system(size: 12))
                            }
                            .padding(.top, 10)
                        }
                    }
                }
            } trailing: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18))
                    .foregroundStyle(SysColor.blue)
            }

            toolbar
        }
    }

    private func matchesSearch(_ index: Int) -> Bool {
        guard !search.isEmpty else { return true }
        let item = mail[index]
        return item.sender.localizedCaseInsensitiveContains(search)
            || item.subject.localizedCaseInsensitiveContains(search)
    }

    private var toolbar: some View {
        MailToolbar(unread: unreadCount)
    }
}

private struct MailToolbar: View {
    let unread: Int
    @Environment(\.deviceSafeArea) private var safeArea

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 21))
                .foregroundStyle(SysColor.blue)
            Spacer()
            VStack(spacing: 1) {
                Text("Updated Just Now")
                    .font(.system(size: 12))
                    .foregroundStyle(SysColor.secondaryLabel)
                Text("\(unread) Unread")
                    .font(.system(size: 12))
                    .foregroundStyle(SysColor.secondaryLabel)
            }
            Spacer()
            Image(systemName: "square.and.pencil")
                .font(.system(size: 21))
                .foregroundStyle(SysColor.blue)
        }
        .padding(.horizontal, 20)
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

private struct MailDetail: View {
    let item: MailItem
    var onBack: () -> Void

    @Environment(\.deviceSafeArea) private var safeArea

    var body: some View {
        ZStack(alignment: .top) {
            SysColor.groupedBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.subject)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(SysColor.label)

                    HStack(spacing: 10) {
                        Avatar(initials: initials, tint: SysColor.indigo, size: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.sender)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(SysColor.label)
                            HStack(spacing: 3) {
                                Text("To: me")
                                    .font(.system(size: 14))
                                    .foregroundStyle(SysColor.secondaryLabel)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(SysColor.secondaryLabel)
                            }
                        }
                        Spacer()
                        Text(item.date)
                            .font(.system(size: 14))
                            .foregroundStyle(SysColor.secondaryLabel)
                    }

                    Rectangle().fill(SysColor.separator).frame(height: 0.5)

                    Text(item.body)
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.label.opacity(0.92))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)
                .padding(.top, safeArea.top + 60)
                .padding(.bottom, safeArea.bottom + 80)
            }

            InlineNavBar(title: "", backTitle: "Inbox", onBack: onBack) {
                HStack(spacing: 22) {
                    Image(systemName: "chevron.up")
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SysColor.blue.opacity(0.6))
            }
        }
        .overlay(alignment: .bottom) { actionBar }
    }

    private var initials: String {
        item.sender.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            ForEach(["archivebox", "trash", "envelope", "arrowshape.turn.up.left", "square.and.pencil"], id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(SysColor.blue)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 12)
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
