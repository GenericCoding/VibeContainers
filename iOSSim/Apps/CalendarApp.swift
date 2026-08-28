import SwiftUI

struct CalendarApp: View {
    @Environment(\.deviceSafeArea) private var safeArea

    @State private var selected = Calendar.current.component(.day, from: Date())
    @State private var events = CalendarData.today
    /// The event the quick action just created, highlighted for a moment.
    @State private var addedEvent: UUID?
    private let calendar = Calendar.current

    private var monthName: String {
        Date().formatted(.dateTime.month(.wide).year())
    }

    private var daysInMonth: Int {
        calendar.range(of: .day, in: .month, for: Date())?.count ?? 30
    }

    /// Weekday index (0 = Sunday) that the 1st of the month lands on.
    private var leadingBlanks: Int {
        var components = calendar.dateComponents([.year, .month], from: Date())
        components.day = 1
        guard let first = calendar.date(from: components) else { return 0 }
        return calendar.component(.weekday, from: first) - 1
    }

    private var today: Int { calendar.component(.day, from: Date()) }

    var body: some View {
        ZStack(alignment: .top) {
            SysColor.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                grid
                Rectangle().fill(SysColor.separator).frame(height: 0.5)
                eventList
            }
            .padding(.top, safeArea.top + 44)

            navBar
        }
        .overlay(alignment: .bottom) { toolbar }
        .onAppIntent(.calendar) { _ in addEvent() }
    }

    private var navBar: some View {
        HStack {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                Text("2026").font(.system(size: 17))
            }
            .foregroundStyle(SysColor.red)
            Spacer()
            HStack(spacing: 20) {
                Image(systemName: "magnifyingglass")
                Image(systemName: "plus")
            }
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(SysColor.red)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .padding(.top, safeArea.top)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SysColor.separator).frame(height: 0.5)
                }
                .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(monthName)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(SysColor.label)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { day in
                    Text(day)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SysColor.secondaryLabel)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 10) {
            ForEach(0..<leadingBlanks, id: \.self) { index in
                Color.clear.frame(height: 40).id("blank\(index)")
            }

            ForEach(1...daysInMonth, id: \.self) { day in
                Button {
                    Haptics.selection()
                    withAnimation(.snappy) { selected = day }
                } label: {
                    VStack(spacing: 3) {
                        Text("\(day)")
                            .font(.system(size: 19, weight: day == today ? .semibold : .regular))
                            .foregroundStyle(dayForeground(day))
                            .frame(width: 34, height: 34)
                            .background {
                                if day == selected {
                                    Circle().fill(day == today ? SysColor.red : Palette.paper)
                                }
                            }
                        Circle()
                            .fill(hasEvents(day) ? SysColor.secondaryLabel : .clear)
                            .frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }

    private func dayForeground(_ day: Int) -> Color {
        if day == selected { return day == today ? Palette.paper : Palette.ink }
        if day == today { return SysColor.red }
        return Palette.paper
    }

    private func hasEvents(_ day: Int) -> Bool {
        day % 3 == 0 || day == today || (day == selected && addedEvent != nil)
    }

    /// "New Event" from the home screen: an hour from now, on the selected day.
    private func addEvent() {
        let start = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        let end = Calendar.current.date(byAdding: .hour, value: 2, to: Date()) ?? Date()
        let format = Date.FormatStyle.dateTime.hour().minute()
        let event = CalendarEvent(title: "New Event",
                                  time: "\(start.formatted(format)) – \(end.formatted(format))",
                                  location: "No location",
                                  color: Palette.clay)
        withAnimation(.snappy) {
            selected = today
            events.insert(event, at: 0)
            addedEvent = event.id
        }
        Haptics.tap(.medium)
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation(.easeOut(duration: 0.4)) { addedEvent = nil }
        }
    }

    private var eventList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if hasEvents(selected) {
                    ForEach(events) { event in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(event.color)
                                .frame(width: 4)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.title)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(SysColor.label)
                                Text(event.location)
                                    .font(.system(size: 14))
                                    .foregroundStyle(SysColor.secondaryLabel)
                            }
                            Spacer()
                            Text(event.time)
                                .font(.system(size: 14))
                                .foregroundStyle(SysColor.secondaryLabel)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(height: 62)
                        .background(addedEvent == event.id ? SysColor.red.opacity(0.12) : .clear)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(SysColor.separator).frame(height: 0.5).padding(.leading, 16)
                        }
                    }
                } else {
                    Text("No Events")
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.secondaryLabel)
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 100)
        }
    }

    private var toolbar: some View {
        HStack {
            Text("Today")
                .font(.system(size: 17))
                .foregroundStyle(SysColor.red)
            Spacer()
            HStack(spacing: 20) {
                Image(systemName: "calendar")
                Image(systemName: "tray.full")
            }
            .font(.system(size: 17))
            .foregroundStyle(SysColor.red)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, max(safeArea.bottom, 10) + 4)
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
