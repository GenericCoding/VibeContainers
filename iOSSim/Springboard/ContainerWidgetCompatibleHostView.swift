import SwiftUI

/// A distinct host path for views produced by the real guest
/// StaticConfiguration provider/generator pair. Keeping this separate from the
/// private Chrono controller makes fallback and lifetime ownership explicit.
struct ContainerWidgetCompatibleHostView: UIViewControllerRepresentable {
    let session: ContainerWidgetCompatibleSession

    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        let controller = UIHostingController(rootView: session.content)
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIHostingController<AnyView>,
        context: Context
    ) {
        uiViewController.rootView = session.content
    }
}
