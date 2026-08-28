import SwiftUI

/// Small, non-interactive diagnostics emitted only when the experimental ABI
/// bridge has an actual structured result for this container widget.
struct ContainerWidgetRuntimeStatusView: View {
    let report: ContainerWidgetRuntimeReport

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
            Text(report.summary)
                .lineLimit(report.outcome == .failed ? 2 : 1)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(foregroundStyle)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: 210, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Widget runtime renderer: \(report.summary)")
        .allowsHitTesting(false)
    }

    private var iconName: String {
        switch report.outcome {
        case .armed: "waveform.path.ecg"
        case .ready: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var foregroundStyle: Color {
        switch report.outcome {
        case .armed: SysColor.secondaryLabel
        case .ready: .green
        case .failed: .orange
        }
    }
}
