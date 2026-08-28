import SwiftUI
import UIKit

private enum CalcOp: String, Hashable {
    case add, subtract, multiply, divide

    var symbol: String {
        switch self {
        case .add: "+"
        case .subtract: "−"
        case .multiply: "×"
        case .divide: "÷"
        }
    }

    func apply(_ lhs: Double, _ rhs: Double) -> Double {
        switch self {
        case .add: lhs + rhs
        case .subtract: lhs - rhs
        case .multiply: lhs * rhs
        case .divide: rhs == 0 ? .nan : lhs / rhs
        }
    }
}

private enum CalcKey: Hashable {
    case digit(String)
    case op(CalcOp)
    case equals, clear, sign, percent, decimal
}

struct CalculatorApp: View {
    @Environment(\.deviceSafeArea) private var safeArea

    @State private var display = "0"
    /// Shown for a moment after the copy quick action.
    @State private var copied = false
    @State private var accumulator: Double?
    @State private var pendingOp: CalcOp?
    @State private var typing = false

    private let rows: [[CalcKey]] = [
        [.clear, .sign, .percent, .op(.divide)],
        [.digit("7"), .digit("8"), .digit("9"), .op(.multiply)],
        [.digit("4"), .digit("5"), .digit("6"), .op(.subtract)],
        [.digit("1"), .digit("2"), .digit("3"), .op(.add)],
        [.digit("0"), .decimal, .equals]
    ]

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 12
            let side = (geo.size.width - spacing * 5) / 4

            VStack(spacing: spacing) {
                Spacer(minLength: 0)

                Text(display)
                    .font(.system(size: 88, weight: .light))
                    .foregroundStyle(SysColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 6)

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: spacing) {
                        ForEach(row, id: \.self) { key in
                            CalcButton(
                                key: key,
                                side: side,
                                spacing: spacing,
                                highlighted: isHighlighted(key),
                                clearTitle: clearTitle
                            ) { press(key) }
                        }
                    }
                }
            }
            .padding(.horizontal, spacing)
            .padding(.bottom, max(safeArea.bottom, 12) + 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SysColor.groupedBackground.ignoresSafeArea())
        .overlay(alignment: .top) {
            if copied {
                Text("Copied \(display)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(SysColor.label)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .padding(.top, safeArea.top + 44)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppIntent(.calculator) { _ in
            UIPasteboard.general.string = display
            Haptics.tap(.medium)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation(.easeOut(duration: 0.25)) { copied = false }
            }
        }
    }

    private var clearTitle: String { (typing || display != "0") ? "C" : "AC" }

    private func isHighlighted(_ key: CalcKey) -> Bool {
        if case .op(let op) = key { return pendingOp == op && !typing }
        return false
    }

    // MARK: - Logic

    private var current: Double { Double(display) ?? 0 }

    private func press(_ key: CalcKey) {
        Haptics.tap(.light)

        switch key {
        case .digit(let value):
            if typing {
                guard display.replacingOccurrences(of: "-", with: "").count < 9 else { return }
                display = display == "0" ? value : display + value
            } else {
                display = value
                typing = true
            }

        case .decimal:
            if !typing {
                display = "0."
                typing = true
            } else if !display.contains(".") {
                display += "."
            }

        case .sign:
            if display.hasPrefix("-") { display.removeFirst() }
            else if display != "0" { display = "-" + display }

        case .percent:
            display = format(current / 100)

        case .clear:
            if typing || display != "0" {
                display = "0"
                typing = false
            } else {
                accumulator = nil
                pendingOp = nil
            }

        case .op(let op):
            resolve()
            accumulator = current
            pendingOp = op
            typing = false

        case .equals:
            resolve()
            pendingOp = nil
            accumulator = nil
            typing = false
        }
    }

    private func resolve() {
        guard let op = pendingOp, let lhs = accumulator else { return }
        let result = op.apply(lhs, current)
        display = format(result)
        accumulator = result
    }

    private func format(_ value: Double) -> String {
        guard value.isFinite else { return "Error" }
        if value == value.rounded() && abs(value) < 1e9 { return String(Int(value)) }
        return String(format: "%g", value)
    }
}

private struct CalcButton: View {
    let key: CalcKey
    let side: CGFloat
    let spacing: CGFloat
    let highlighted: Bool
    let clearTitle: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Capsule().fill(highlighted ? Palette.paper : background)
                Text(title)
                    .font(.system(size: 36))
                    .foregroundStyle(highlighted ? Palette.amber : foreground)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
            .frame(width: isWide ? side * 2 + spacing : side, height: side)
        }
        .buttonStyle(CalcButtonStyle())
    }

    private var isWide: Bool { key == .digit("0") }

    private var title: String {
        switch key {
        case .digit(let value): value
        case .decimal: "."
        case .sign: "+/−"
        case .percent: "%"
        case .clear: clearTitle
        case .equals: "="
        case .op(let op): op.symbol
        }
    }

    private var background: Color {
        switch key {
        case .op, .equals: Palette.amber
        case .clear, .sign, .percent: Color(hex: "9C8B7D")
        default: Color(hex: "342A25")
        }
    }

    private var foreground: Color {
        switch key {
        case .clear, .sign, .percent: Palette.ink
        default: Palette.paper
        }
    }
}

private struct CalcButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.22 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
