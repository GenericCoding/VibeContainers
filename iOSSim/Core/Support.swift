import SwiftUI
import UIKit
import Darwin

enum DeviceIdentity {
    static var phoneModelName: String {
#if targetEnvironment(simulator)
        if let simulatorName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"],
           !simulatorName.isEmpty {
            return simulatorName
        }
#endif

        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return phoneModelNames[identifier] ?? identifier
    }

    private static let phoneModelNames: [String: String] = [
        "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8",
        "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        "iPhone14,6": "iPhone SE (3rd generation)", "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max", "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e"
    ]
}

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)
        let r, g, b, a: Double
        switch raw.count {
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// The real dynamic iOS system palette used by the touch interface.
///
/// Controller mode owns its PS-style colours through `Palette`; mock apps use
/// UIKit's semantic colours so grouped screens, labels, fills and separators
/// track native iOS contrast and material behaviour.
enum SysColor {
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let secondaryGrouped = Color(uiColor: .secondarySystemGroupedBackground)
    static let tertiary = Color(uiColor: .tertiarySystemGroupedBackground)
    static let separator = Color(uiColor: .separator)
    static let label = Color(uiColor: .label)
    static let secondaryLabel = Color(uiColor: .secondaryLabel)
    static let fill = Color(uiColor: .tertiarySystemFill)
    /// The system tint. Follows the accent chosen in Customization.
    static var blue: Color { Appearance.shared.accent }
    static let green = Color(uiColor: .systemGreen)
    static let red = Color(uiColor: .systemRed)
    static let orange = Color(uiColor: .systemOrange)
    static let yellow = Color(uiColor: .systemYellow)
    static let purple = Color(uiColor: .systemPurple)
    static let pink = Color(uiColor: .systemPink)
    static let teal = Color(uiColor: .systemTeal)
    static let indigo = Color(uiColor: .systemIndigo)
    static let gray = Color(uiColor: .systemGray)
}

// MARK: - Shapes

/// Continuous ("squircle") rounded rectangle, the iOS icon corner curve.
struct Squircle: InsettableShape {
    var cornerRadius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: max(0, cornerRadius - inset), style: .continuous)
            .path(in: rect.insetBy(dx: inset, dy: inset))
    }

    func inset(by amount: CGFloat) -> Squircle {
        Squircle(cornerRadius: cornerRadius, inset: inset + amount)
    }

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }
}

enum Metrics {
    /// Apple's icon corner ratio.
    static func iconCorner(for size: CGFloat) -> CGFloat { size * 0.2237 }
    static let fallbackSafeArea = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)

    /// Reads the key window's safe area insets.
    ///
    /// Call this from an action (`onAppear`, a gesture, …) and stash the
    /// result — **never** from a `body`. Touching UIKit's layout while SwiftUI
    /// is evaluating a body forces a UIKit layout pass that re-enters the
    /// SwiftUI graph; the result is an "AttributeGraph: cycle detected"
    /// warning and, after the first frame, an app whose state updates are
    /// silently never delivered again.
    static func readSafeArea() -> EdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first else {
            return fallbackSafeArea
        }
        // Zero is a valid top inset in iPhone landscape and an entirely zero
        // inset is valid for some resizable iPad scenes. Once a window exists,
        // forward UIKit's values verbatim instead of substituting portrait math.
        let insets = window.safeAreaInsets
        return EdgeInsets(top: insets.top, leading: insets.left,
                          bottom: insets.bottom, trailing: insets.right)
    }
}

/// Loads the host's compiled app icon without asking CoreUI for an ordinary
/// named-image rendition. App-icon sets are emitted as root-level PNGs for
/// SpringBoard, not as normal `UIImage(named:)` assets; probing them by asset
/// name logs `CUIThemeStore: No theme registered with id=0` on launch even
/// though the catalog and icon are both valid.
enum HostAppIcon {
    static let image: UIImage? = {
        let bundle = Bundle.main
        var baseNames: [String] = []

        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = bundle.infoDictionary?[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let files = primary["CFBundleIconFiles"] as? [String] else { continue }
            baseNames.append(contentsOf: files.reversed())
        }
        baseNames.append(contentsOf: ["AppIcon60x60", "AppIcon76x76"])

        var seen: Set<String> = []
        for rawName in baseNames where seen.insert(rawName).inserted {
            let name = (rawName as NSString).deletingPathExtension
            for suffix in ["@3x", "@2x", ""] {
                guard let url = bundle.url(forResource: name + suffix, withExtension: "png"),
                      let image = UIImage(contentsOfFile: url.path) else { continue }
                return image
            }
        }

        // Asset thinning can choose a device-specific filename not listed in
        // the processed plist. Restrict the fallback to root app-icon PNGs so
        // guest icons and unrelated resources can never be selected.
        let rootFiles = (try? FileManager.default.contentsOfDirectory(
            at: bundle.bundleURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let iconFiles = rootFiles
            .filter {
                $0.pathExtension.caseInsensitiveCompare("png") == .orderedSame
                    && $0.deletingPathExtension().lastPathComponent.hasPrefix("AppIcon")
            }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let rhs = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return lhs > rhs
            }
        return iconFiles.lazy.compactMap { UIImage(contentsOfFile: $0.path) }.first
    }()
}

// MARK: - Haptics

enum Haptics {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - Environment

private struct SafeAreaKey: EnvironmentKey {
    static let defaultValue = Metrics.fallbackSafeArea
}

private struct DismissAppKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Real device insets, forwarded manually because app windows are drawn
    /// inside a scaled container during the open/close transition.
    var deviceSafeArea: EdgeInsets {
        get { self[SafeAreaKey.self] }
        set { self[SafeAreaKey.self] = newValue }
    }

    /// Closes the currently open mock app.
    var dismissApp: () -> Void {
        get { self[DismissAppKey.self] }
        set { self[DismissAppKey.self] = newValue }
    }
}

// MARK: - Animation vocabulary

extension Animation {
    /// Pushed detail screens inside an app.
    static var appLaunch: Animation { .spring(response: 0.52, dampingFraction: 0.82, blendDuration: 0) }
    static var appClose: Animation { .spring(response: 0.42, dampingFraction: 0.88, blendDuration: 0) }
    static var snappy: Animation { .spring(response: 0.32, dampingFraction: 0.8) }

    /// Shared surface choreography. `interfaceSpring` presents discrete modal
    /// surfaces; `gestureSettle` returns directly manipulated content to rest.
    static var interfaceSpring: Animation {
        .spring(response: 0.34, dampingFraction: 0.88, blendDuration: 0.06)
    }
    static var gestureSettle: Animation {
        .spring(response: 0.36, dampingFraction: 0.90, blendDuration: 0.08)
    }

    /// Pressing responds immediately, while release carries a small amount of
    /// velocity so an icon does not feel as though it snaps back mechanically.
    static var iconPress: Animation { .easeOut(duration: 0.09) }
    static var iconRelease: Animation {
        .spring(response: 0.24, dampingFraction: 0.82, blendDuration: 0.05)
    }

    /// Opacity-only fallback used when either Reduce Motion setting is active.
    static var reducedMotionFade: Animation { .easeOut(duration: 0.16) }

    /// The springboard's circular app reveal. It is quick with only enough
    /// under-damping to keep the icon-origin expansion from feeling mechanical.
    static var windowOpen: Animation {
        .spring(response: 0.29, dampingFraction: 0.86, blendDuration: 0.06)
    }
    static var windowClose: Animation {
        .spring(response: 0.25, dampingFraction: 0.90, blendDuration: 0.06)
    }

    /// Content and icon handoff independently of the geometry spring. Closing
    /// hides content faster so the shrinking circle remains visually clean.
    static var windowReveal: Animation { .easeOut(duration: 0.13) }
    static var windowHide: Animation { .easeIn(duration: 0.09) }
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

// MARK: - Small shared views

/// Native iOS material used by floating touch surfaces such as the dock and
/// weather cards. Grouped lists use solid semantic backgrounds instead.
struct GlassSurface: View {
    var cornerRadius: CGFloat = 20
    /// Panels sitting on other panels go quieter so the stack stays readable.
    var depth: CGFloat = 1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        shape
            .fill(.regularMaterial)
            .overlay {
                shape.fill(Color(uiColor: .secondarySystemBackground).opacity(0.16 * depth))
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.10 * depth), lineWidth: 0.5)
            }
    }
}

extension View {
    /// Puts the view on glass.
    func glass(cornerRadius: CGFloat = 20, depth: CGFloat = 1) -> some View {
        background(GlassSurface(cornerRadius: cornerRadius, depth: depth))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// A cyan bloom under a lit element — used sparingly, on the things that
    /// are meant to look powered.
    func bloom(_ radius: CGFloat = 12, color: Color = Palette.bloom, opacity: Double = 0.5) -> some View {
        shadow(color: color.opacity(opacity), radius: radius)
    }
}

extension View {
    /// Reports layout frames through SwiftUI's geometry observation path.
    /// Unlike a `GeometryReader` feeding `onChange(of: CGRect)`, this does not
    /// synchronously re-enter the same layout pass when an animation produces
    /// several intermediate frames in one display refresh.
    func recordGlobalFrame(_ update: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { rect in
            update(rect)
        }
    }
}

/// Frosted card kept for the screens that lay out their own padding.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content.glass(cornerRadius: cornerRadius)
    }
}

/// Grabber + title header used by the mock sheet-style screens.
struct NavBarTitle: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 34, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
