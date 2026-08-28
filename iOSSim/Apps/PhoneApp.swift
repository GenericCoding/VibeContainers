import SwiftUI

struct PhoneApp: View {
    @State private var tab = 3
    @State private var typed = ""
    @State private var composingContact = false
    @State private var contacts: [PhoneContact] = []
    @State private var draftName = ""
    @State private var draftNumber = ""
    @Environment(\.deviceSafeArea) private var safeArea

    var body: some View {
        ZStack {
            SysColor.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                switch tab {
                case 3: keypad
                case 1: recents
                case 2: contactsTab
                default: placeholder
                }

                AppTabBar(items: [
                    TabItem(title: "Favorites", symbol: "star.fill"),
                    TabItem(title: "Recents", symbol: "clock.fill"),
                    TabItem(title: "Contacts", symbol: "person.crop.circle.fill"),
                    TabItem(title: "Keypad", symbol: "circle.grid.3x3.fill"),
                    TabItem(title: "Voicemail", symbol: "recordingtape")
                ], selection: $tab, tint: SysColor.green)
            }
            .ignoresSafeArea(edges: .bottom)
            if composingContact {
                newContactSheet
                    .zIndex(3)
            }
        }
        .onAppIntent(.phone) { _ in
            tab = 2
            withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                composingContact = true
            }
        }
    }

    // MARK: - Contacts

    private var contactsTab: some View {
        ZStack {
            if contacts.isEmpty {
                placeholder
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(contacts) { contact in
                            HStack(spacing: 12) {
                                Avatar(initials: contact.initials, tint: SysColor.green, size: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.name)
                                        .font(.system(size: 17))
                                        .foregroundStyle(SysColor.label)
                                    Text(contact.number)
                                        .font(.system(size: 14))
                                        .foregroundStyle(SysColor.secondaryLabel)
                                }
                                Spacer()
                                Image(systemName: "phone.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(SysColor.green)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 11)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(SysColor.separator)
                                    .frame(height: 0.5).padding(.leading, 70)
                            }
                        }
                    }
                    .padding(.top, safeArea.top + 46)
                    .padding(.bottom, 100)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                Haptics.tap(.light)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                    composingContact = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SysColor.green)
                    .padding(.trailing, 20)
                    .padding(.top, safeArea.top + 8)
            }
            .buttonStyle(.plain)
        }
    }

    /// The form the "New Contact" quick action lands on.
    private var newContactSheet: some View {
        ZStack {
            Rectangle()
                .fill(Palette.ink.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture { dismissDraft() }

            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Text("New Contact")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SysColor.label)

                    TextField("Name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(SysColor.label)
                        .tint(SysColor.green)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(SysColor.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                    TextField("Phone", text: $draftNumber)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(SysColor.label)
                        .tint(SysColor.green)
                        .keyboardType(.phonePad)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(SysColor.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .padding(18)

                Rectangle().fill(SysColor.separator).frame(height: 0.5)

                HStack(spacing: 0) {
                    Button(action: dismissDraft) {
                        Text("Cancel")
                            .font(.system(size: 17))
                            .foregroundStyle(SysColor.blue)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)

                    Rectangle().fill(SysColor.separator).frame(width: 0.5, height: 44)

                    Button(action: saveDraft) {
                        Text("Done")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(draftName.isEmpty ? SysColor.secondaryLabel : SysColor.blue)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(draftName.isEmpty)
                }
            }
            .frame(width: 280)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.paper.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: Palette.ink.opacity(0.5), radius: 30, y: 12)
            .transition(.scale(scale: 1.1).combined(with: .opacity))
        }
    }

    private func dismissDraft() {
        withAnimation(.easeOut(duration: 0.18)) { composingContact = false }
        draftName = ""
        draftNumber = ""
    }

    private func saveDraft() {
        let number = draftNumber.isEmpty ? "No number" : draftNumber
        withAnimation(.snappy) {
            contacts.append(PhoneContact(name: draftName, number: number))
            contacts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        Haptics.tap(.medium)
        dismissDraft()
    }

    // MARK: - Keypad

    private var keypad: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Text(formatted(typed))
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(SysColor.label)
                .frame(height: 50)
                .padding(.top, safeArea.top + 20)

            VStack(spacing: 14) {
                ForEach(KeypadKey.rows, id: \.first?.digit) { row in
                    HStack(spacing: 26) {
                        ForEach(row, id: \.digit) { key in
                            Button {
                                Haptics.tap(.light)
                                if typed.count < 15 { typed += key.digit }
                            } label: {
                                VStack(spacing: 1) {
                                    Text(key.digit)
                                        .font(.system(size: 36, weight: .regular))
                                        .foregroundStyle(SysColor.label)
                                    Text(key.letters)
                                        .font(.system(size: 10, weight: .medium))
                                        .kerning(1.5)
                                        .foregroundStyle(SysColor.label.opacity(0.8))
                                        .frame(height: 10)
                                }
                                .frame(width: 74, height: 74)
                                .background(Circle().fill(Palette.surface))
                            }
                            .buttonStyle(KeypadStyle())
                        }
                    }
                }
            }
            .padding(.top, 20)

            HStack(spacing: 26) {
                Color.clear.frame(width: 74, height: 74)

                Button {
                    Haptics.tap(.medium)
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(SysColor.label)
                        .frame(width: 74, height: 74)
                        .background(Circle().fill(SysColor.green))
                }
                .buttonStyle(KeypadStyle())

                Button {
                    if !typed.isEmpty { typed.removeLast() }
                } label: {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(typed.isEmpty ? .clear : Palette.paper)
                        .frame(width: 74, height: 74)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 22)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 70)
    }

    private func formatted(_ digits: String) -> String {
        guard !digits.isEmpty else { return " " }
        var result = ""
        for (index, character) in digits.enumerated() {
            if index == 0 { result += "(" }
            if index == 3 { result += ") " }
            if index == 6 { result += "-" }
            result.append(character)
        }
        return result
    }

    // MARK: - Recents

    private var recents: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Recents")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(SysColor.label)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                ForEach(PhoneData.recents) { call in
                    HStack(spacing: 12) {
                        Image(systemName: call.missed ? "phone.arrow.down.left" : "phone.arrow.up.right")
                            .font(.system(size: 15))
                            .foregroundStyle(SysColor.secondaryLabel)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(call.name)
                                .font(.system(size: 17))
                                .foregroundStyle(call.missed ? SysColor.red : Palette.paper)
                            Text(call.kind)
                                .font(.system(size: 14))
                                .foregroundStyle(SysColor.secondaryLabel)
                        }

                        Spacer()

                        Text(call.time)
                            .font(.system(size: 15))
                            .foregroundStyle(SysColor.secondaryLabel)

                        Image(systemName: "info.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(SysColor.blue)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(SysColor.separator).frame(height: 0.5).padding(.leading, 54)
                    }
                }
            }
            .padding(.top, safeArea.top + 46)
            .padding(.bottom, 100)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: tab == 0 ? "star" : (tab == 2 ? "person.crop.circle" : "recordingtape"))
                .font(.system(size: 42))
                .foregroundStyle(SysColor.secondaryLabel)
            Text(tab == 0 ? "No Favorites" : (tab == 2 ? "No Contacts" : "No Voicemail"))
                .font(.system(size: 17))
                .foregroundStyle(SysColor.secondaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct KeypadKey {
    let digit: String
    let letters: String

    static let rows: [[KeypadKey]] = [
        [.init(digit: "1", letters: " "), .init(digit: "2", letters: "ABC"), .init(digit: "3", letters: "DEF")],
        [.init(digit: "4", letters: "GHI"), .init(digit: "5", letters: "JKL"), .init(digit: "6", letters: "MNO")],
        [.init(digit: "7", letters: "PQRS"), .init(digit: "8", letters: "TUV"), .init(digit: "9", letters: "WXYZ")],
        [.init(digit: "*", letters: " "), .init(digit: "0", letters: "+"), .init(digit: "#", letters: " ")]
    ]
}

private struct KeypadStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.25 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
