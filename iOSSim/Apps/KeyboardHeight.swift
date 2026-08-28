import SwiftUI
import Combine

/// Reports the on-screen keyboard height. The mock apps draw their own
/// chrome outside the safe area, so automatic keyboard avoidance is off and
/// input bars are offset by hand.
struct KeyboardHeightModifier: ViewModifier {
    @Binding var height: CGFloat

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            ) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                      let screen = UIApplication.shared.connectedScenes
                          .compactMap({ $0 as? UIWindowScene }).first?.screen.bounds
                else { return }
                let visible = max(0, screen.height - frame.origin.y)
                withAnimation(.easeOut(duration: 0.25)) { height = visible }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            ) { _ in
                withAnimation(.easeOut(duration: 0.25)) { height = 0 }
            }
    }
}

extension View {
    func keyboardHeight(_ height: Binding<CGFloat>) -> some View {
        modifier(KeyboardHeightModifier(height: height))
    }

    func dismissKeyboardOnTap() -> some View {
        onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }
    }
}

/// Slides a pushed detail screen in from the trailing edge, iOS style.
struct PushTransition: ViewModifier {
    func body(content: Content) -> some View {
        content.transition(
            .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .trailing)
            )
        )
    }
}
