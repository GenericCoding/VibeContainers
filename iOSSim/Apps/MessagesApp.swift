import SwiftUI

struct MessagesApp: View {
    @State private var conversations = MessagesData.conversations
    @State private var openIndex: Int?
    @State private var search = ""

    var body: some View {
        GeometryReader { geo in
            ZStack {
                list
                    .offset(x: openIndex == nil ? 0 : -geo.size.width * 0.3)
                    .overlay(Palette.ink.opacity(openIndex == nil ? 0 : 0.2))
                    .disabled(openIndex != nil)

                if let index = openIndex, conversations.indices.contains(index) {
                    ChatView(conversation: $conversations[index]) {
                        withAnimation(.appClose) { openIndex = nil }
                    }
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
                }
            }
        }
        .background(SysColor.groupedBackground)
        .onAppIntent(.messages) { _ in
            let draft = Conversation(name: "New Message", time: "Now", unread: false, messages: [])
            conversations.insert(draft, at: 0)
            withAnimation(.appLaunch) { openIndex = 0 }
        }
    }

    private var filtered: [Int] {
        conversations.indices.filter {
            search.isEmpty || conversations[$0].name.localizedCaseInsensitiveContains(search)
        }
    }

    private var list: some View {
        AppScaffold(title: "Messages", searchable: true, searchText: $search) {
            ListSection {
                ForEach(filtered, id: \.self) { index in
                    let conversation = conversations[index]
                    ListRow(separatorInset: 72, action: {
                        conversations[index].unread = false
                        withAnimation(.appLaunch) { openIndex = index }
                    }) {
                        HStack(spacing: 12) {
                            ZStack(alignment: .leading) {
                                Circle()
                                    .fill(SysColor.blue)
                                    .frame(width: 8, height: 8)
                                    .opacity(conversation.unread ? 1 : 0)
                                    .offset(x: -14)
                                Avatar(initials: conversation.initials, tint: conversation.tint, size: 48)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(conversation.name)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(SysColor.label)
                                Text(conversation.preview)
                                    .font(.system(size: 15))
                                    .foregroundStyle(SysColor.secondaryLabel)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(.leading, 14)
                        .padding(.vertical, 8)
                    } trailing: {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(conversation.time)
                                .font(.system(size: 15))
                                .foregroundStyle(SysColor.secondaryLabel)
                            Chevron().font(.system(size: 12))
                        }
                    }
                }
            }
        } trailing: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 18))
                .foregroundStyle(SysColor.blue)
        }
    }
}

// MARK: - Chat

private struct ChatView: View {
    @Binding var conversation: Conversation
    var onBack: () -> Void

    @State private var draft = ""
    @State private var keyboard: CGFloat = 0
    @Environment(\.deviceSafeArea) private var safeArea

    var body: some View {
        ZStack(alignment: .top) {
            SysColor.groupedBackground.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        Text("Today 11:12 AM")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SysColor.secondaryLabel)
                            .padding(.vertical, 10)

                        ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                            Bubble(
                                message: message,
                                isTail: index == conversation.messages.count - 1
                                    || conversation.messages[index + 1].isMine != message.isMine
                            )
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, safeArea.top + 96)
                    .padding(.bottom, 70)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: conversation.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(conversation.messages.last?.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo(conversation.messages.last?.id, anchor: .bottom)
                }
            }

            header

            inputBar
                .frame(maxHeight: .infinity, alignment: .bottom)
                .offset(y: -keyboard)
        }
        .keyboardHeight($keyboard)
    }

    private var header: some View {
        VStack(spacing: 3) {
            Avatar(initials: conversation.initials, tint: conversation.tint, size: 40)
            HStack(spacing: 2) {
                Text(conversation.name)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(SysColor.label)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        .padding(.top, safeArea.top + 4)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SysColor.separator).frame(height: 0.5)
                }
                .ignoresSafeArea()
        }
        .overlay(alignment: .leading) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SysColor.blue)
                    .padding(.horizontal, 16)
            }
            .padding(.top, safeArea.top)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(SysColor.secondaryLabel)
                .frame(width: 32, height: 32)
                .background(Circle().fill(SysColor.tertiary))

            HStack(spacing: 6) {
                TextField("iMessage", text: $draft, axis: .vertical)
                    .font(.system(size: 17))
                    .foregroundStyle(SysColor.label)
                    .tint(SysColor.blue)
                    .lineLimit(1...5)
                    .padding(.leading, 12)
                    .padding(.vertical, 7)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(SysColor.label)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(draft.isEmpty ? SysColor.gray.opacity(0.5) : SysColor.blue))
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.trailing, 3)
                .padding(.vertical, 3)
            }
            .background(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(SysColor.separator, lineWidth: 1)
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, keyboard > 0 ? 8 : max(safeArea.bottom, 12))
        .background {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Haptics.tap(.light)
        conversation.messages.append(ChatMessage(text: text, isMine: true))
        draft = ""

        let reply = MessagesData.replies.randomElement() ?? "👍"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            conversation.messages.append(ChatMessage(text: reply, isMine: false))
        }
    }
}

private struct Bubble: View {
    let message: ChatMessage
    let isTail: Bool

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 60) }

            Text(message.text)
                .font(.system(size: 17))
                .foregroundStyle(SysColor.label)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    if message.isMine {
                        LinearGradient(colors: [Color(hex: "8FAFC6"), Color(hex: "63849E")],
                                       startPoint: .top, endPoint: .bottom)
                    } else {
                        SysColor.tertiary
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.bottom, isTail ? 6 : 0)

            if !message.isMine { Spacer(minLength: 60) }
        }
    }
}
