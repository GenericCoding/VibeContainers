import SwiftUI

struct ClockApp: View {
    @State private var tab = 0
    /// Set by the home-screen quick actions before the tab appears.
    @State private var composingAlarm = false
    @State private var autoStartStopwatch = false
    @Environment(\.deviceSafeArea) private var safeArea

    var body: some View {
        ZStack {
            SysColor.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                switch tab {
                case 1: AlarmsTab(composing: $composingAlarm)
                case 2: StopwatchTab(autoStart: $autoStartStopwatch)
                case 3: TimerTab()
                default: WorldClockTab()
                }

                AppTabBar(items: [
                    TabItem(title: "World Clock", symbol: "globe"),
                    TabItem(title: "Alarms", symbol: "alarm.fill"),
                    TabItem(title: "Stopwatch", symbol: "stopwatch.fill"),
                    TabItem(title: "Timers", symbol: "timer")
                ], selection: $tab, tint: SysColor.orange)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .onAppIntent(.clock) { intent in
            switch intent {
            case .clockCreateAlarm:
                composingAlarm = true
                tab = 1
            case .clockStartStopwatch:
                autoStartStopwatch = true
                tab = 2
            default: break
            }
        }
    }
}

// MARK: - World Clock

private struct WorldClockTab: View {
    @Environment(\.deviceSafeArea) private var safeArea

    /// See ClockFace.anchor — the schedule start must not move.
    private static let anchor = Date(timeIntervalSinceReferenceDate: 0)

    private let cities: [(city: String, zone: String, label: String)] = [
        ("Cupertino", "America/Los_Angeles", "Today"),
        ("New York", "America/New_York", "Today"),
        ("London", "Europe/London", "Today"),
        ("Berlin", "Europe/Berlin", "Today"),
        ("Tokyo", "Asia/Tokyo", "Tomorrow"),
        ("Sydney", "Australia/Sydney", "Tomorrow")
    ]

    var body: some View {
        ZStack(alignment: .top) {
            TimelineView(.periodic(from: Self.anchor, by: 1)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("World Clock")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(SysColor.label)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 10)

                        ForEach(cities, id: \.city) { entry in
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(entry.label), \(offsetText(entry.zone))")
                                        .font(.system(size: 14))
                                        .foregroundStyle(SysColor.secondaryLabel)
                                    Text(entry.city)
                                        .font(.system(size: 24))
                                        .foregroundStyle(SysColor.label)
                                }
                                Spacer()
                                HStack(alignment: .firstTextBaseline, spacing: 3) {
                                    Text(timeText(entry.zone, date: context.date))
                                        .font(.system(size: 50, weight: .thin))
                                    Text(meridiem(entry.zone, date: context.date))
                                        .font(.system(size: 17, weight: .light))
                                }
                                .foregroundStyle(SysColor.label)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(SysColor.separator)
                                    .frame(height: 0.5)
                                    .padding(.leading, 20)
                            }
                        }
                    }
                    .padding(.top, safeArea.top + 46)
                    .padding(.bottom, 100)
                }
            }
        }
    }

    private func formatter(_ zone: String, format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = TimeZone(identifier: zone)
        return formatter
    }

    private func timeText(_ zone: String, date: Date) -> String {
        formatter(zone, format: "h:mm").string(from: date)
    }

    private func meridiem(_ zone: String, date: Date) -> String {
        formatter(zone, format: "a").string(from: date)
    }

    private func offsetText(_ zone: String) -> String {
        guard let target = TimeZone(identifier: zone) else { return "" }
        let delta = (target.secondsFromGMT() - TimeZone.current.secondsFromGMT()) / 3600
        if delta == 0 { return "same time" }
        return "\(delta > 0 ? "+" : "")\(delta)HRS"
    }
}

// MARK: - Alarms

private struct AlarmsTab: View {
    /// Set by the "Create Alarm" quick action; adds one for the next hour.
    @Binding var composing: Bool

    @Environment(\.deviceSafeArea) private var safeArea
    @State private var alarms: [(time: String, meridiem: String, label: String, on: Bool)] = [
        ("6:30", "AM", "Weekdays", true),
        ("7:15", "AM", "Alarm", false),
        ("8:00", "AM", "Weekends", true),
        ("9:45", "PM", "Wind down", false)
    ]
    /// The alarm the quick action just added, highlighted for a moment.
    @State private var addedIndex: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Alarms")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(SysColor.label)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                Text("SLEEP | WAKE UP")
                    .font(.system(size: 13))
                    .foregroundStyle(SysColor.secondaryLabel)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                ForEach(alarms.indices, id: \.self) { index in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(alarms[index].time)
                                    .font(.system(size: 50, weight: .thin))
                                Text(alarms[index].meridiem)
                                    .font(.system(size: 24, weight: .thin))
                            }
                            Text(alarms[index].label)
                                .font(.system(size: 14))
                                .foregroundStyle(SysColor.secondaryLabel)
                        }
                        .foregroundStyle(alarms[index].on ? Palette.paper : SysColor.secondaryLabel)

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { alarms[index].on },
                            set: { alarms[index].on = $0 }
                        ))
                        .labelsHidden()
                        .tint(SysColor.green)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(addedIndex == index ? SysColor.orange.opacity(0.14) : .clear)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(SysColor.separator).frame(height: 0.5).padding(.leading, 20)
                    }
                }
            }
            .padding(.top, safeArea.top + 46)
            .padding(.bottom, 100)
        }
        .onAppear(perform: addRequestedAlarm)
        .onChange(of: composing) { _, _ in addRequestedAlarm() }
    }

    /// "Create Alarm" from the home screen: the next round hour, switched on
    /// and highlighted so it is obvious which one just appeared.
    private func addRequestedAlarm() {
        guard composing else { return }
        composing = false

        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        let hour = Calendar.current.component(.hour, from: next)
        let display = hour % 12 == 0 ? 12 : hour % 12
        withAnimation(.snappy) {
            alarms.insert(("\(display):00", hour < 12 ? "AM" : "PM", "Alarm", true), at: 0)
            addedIndex = 0
        }
        Haptics.tap(.medium)
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.4)) { addedIndex = nil }
        }
    }
}

// MARK: - Stopwatch

private struct StopwatchTab: View {
    /// Set by the "Start Stopwatch" quick action.
    @Binding var autoStart: Bool

    @Environment(\.deviceSafeArea) private var safeArea

    @State private var running = false
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?
    @State private var laps: [TimeInterval] = []

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { context in
                Text(Self.format(total(at: context.date)))
                    .font(.system(size: 76, weight: .thin, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(SysColor.label)
            }
            .padding(.top, safeArea.top + 30)

            HStack {
                controlButton(title: running ? "Lap" : "Reset",
                              fill: Color(hex: "342A25"), tint: Palette.paper) {
                    if running {
                        laps.insert(total(at: Date()), at: 0)
                    } else {
                        elapsed = 0
                        laps = []
                    }
                }

                Spacer()

                controlButton(title: running ? "Stop" : "Start",
                              fill: running ? Color(hex: "3A2320") : Color(hex: "27301F"),
                              tint: running ? SysColor.red : SysColor.green) {
                    if running {
                        elapsed = total(at: Date())
                        startedAt = nil
                    } else {
                        startedAt = Date()
                    }
                    running.toggle()
                    Haptics.tap(.medium)
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 34)

            lapList
        }
        .padding(.bottom, 60)
    }

    private var lapList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(laps.enumerated()), id: \.offset) { index, lap in
                    HStack {
                        Text("Lap \(laps.count - index)")
                        Spacer()
                        Text(Self.format(lap)).monospacedDigit()
                    }
                    .font(.system(size: 17))
                    .foregroundStyle(SysColor.label)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(SysColor.separator).frame(height: 0.5).padding(.leading, 20)
                    }
                }
            }
        }
        .onAppear(perform: startIfRequested)
        .onChange(of: autoStart) { _, _ in startIfRequested() }
    }

    /// The quick action starts the clock running as the tab appears.
    private func startIfRequested() {
        guard autoStart else { return }
        autoStart = false
        guard !running else { return }
        elapsed = 0
        laps = []
        startedAt = Date()
        running = true
        Haptics.tap(.medium)
    }

    private func controlButton(title: String, fill: Color, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18))
                .foregroundStyle(tint)
                .frame(width: 82, height: 82)
                .background(Circle().fill(fill))
                .overlay(
                    Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1.5).padding(2)
                )
        }
        .buttonStyle(.plain)
    }

    private func total(at date: Date) -> TimeInterval {
        guard let startedAt else { return elapsed }
        return elapsed + date.timeIntervalSince(startedAt)
    }

    static func format(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        let hundredths = Int((interval - floor(interval)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }
}

// MARK: - Timers

private struct TimerTab: View {
    @Environment(\.deviceSafeArea) private var safeArea
    @State private var selection = 5

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .strokeBorder(Palette.surfaceRaised, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(SysColor.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 4) {
                    Text("\(selection):00")
                        .font(.system(size: 62, weight: .thin))
                        .monospacedDigit()
                        .foregroundStyle(SysColor.label)
                    Label("11:47 AM", systemImage: "bell.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(SysColor.secondaryLabel)
                }
            }
            .frame(width: 260, height: 260)
            .padding(.top, safeArea.top + 20)

            HStack(spacing: 12) {
                ForEach([1, 5, 10, 15], id: \.self) { minutes in
                    Button {
                        Haptics.selection()
                        withAnimation(.snappy) { selection = minutes }
                    } label: {
                        Text("\(minutes) min")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(selection == minutes ? Palette.ink : Palette.paper)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(selection == minutes ? SysColor.orange : Palette.surfaceRaised)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 60) {
                Text("Cancel")
                    .frame(width: 78, height: 78)
                    .background(Circle().fill(Color(hex: "342A25")))
                    .foregroundStyle(SysColor.label)
                Text("Start")
                    .frame(width: 78, height: 78)
                    .background(Circle().fill(Color(hex: "27301F")))
                    .foregroundStyle(SysColor.green)
            }
            .font(.system(size: 18))

            Spacer(minLength: 0)
        }
        .padding(.bottom, 70)
    }
}
