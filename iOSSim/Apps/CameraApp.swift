import SwiftUI

struct CameraApp: View {
    @Environment(\.deviceSafeArea) private var safeArea

    @State private var mode = 1
    @State private var front = false
    @State private var flashOpacity: Double = 0
    @State private var shutterScale: CGFloat = 1
    @State private var zoom = 1
    @State private var captured: Int?

    private let modes = ["VIDEO", "PHOTO", "PORTRAIT", "PANO"]

    var body: some View {
        ZStack {
            SysColor.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topControls
                viewfinder
                bottomControls
            }

            Palette.paper
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .onAppIntent(.camera) { intent in
            switch intent {
            case .cameraSelfie:
                front = true
                mode = modes.firstIndex(of: "PHOTO") ?? mode
            case .cameraVideo:
                front = false
                mode = modes.firstIndex(of: "VIDEO") ?? mode
            default: break
            }
        }
    }

    private var topControls: some View {
        HStack {
            Image(systemName: "chevron.up")
            Spacer()
            Image(systemName: "bolt.slash.fill")
            Spacer()
            Image(systemName: "livephoto")
        }
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(SysColor.label)
        .padding(.horizontal, 30)
        .frame(height: 44)
        .padding(.top, safeArea.top)
    }

    /// Stand-in for a live camera feed: a blurred scene with a focus reticle.
    private var viewfinder: some View {
        ZStack {
            MockPhoto(index: mode * 3 + 4)
                .overlay(Palette.ink.opacity(0.08))
                // A front camera previews mirrored, the way iOS shows it.
                .scaleEffect(x: front ? -1 : 1)

            // Grid lines
            GeometryReader { geo in
                Path { path in
                    for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                        path.move(to: CGPoint(x: geo.size.width * fraction, y: 0))
                        path.addLine(to: CGPoint(x: geo.size.width * fraction, y: geo.size.height))
                        path.move(to: CGPoint(x: 0, y: geo.size.height * fraction))
                        path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * fraction))
                    }
                }
                .stroke(Palette.paper.opacity(0.25), lineWidth: 0.5)
            }

            // Focus reticle
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(SysColor.yellow, lineWidth: 1)
                .frame(width: 72, height: 72)
                .overlay(alignment: .trailing) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(SysColor.yellow)
                        .offset(x: 16)
                }
                .offset(x: -20, y: 30)
        }
        .clipped()
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) { zoomPicker.padding(.bottom, 16) }
    }

    private var zoomPicker: some View {
        HStack(spacing: 8) {
            ForEach([0, 1, 2], id: \.self) { index in
                let labels = [".5", "1x", "3"]
                Button {
                    Haptics.selection()
                    withAnimation(.snappy) { zoom = index }
                } label: {
                    Text(labels[index])
                        .font(.system(size: zoom == index ? 14 : 12,
                                      weight: zoom == index ? .semibold : .regular))
                        .foregroundStyle(zoom == index ? SysColor.yellow : Palette.paper)
                        .frame(width: zoom == index ? 40 : 32, height: zoom == index ? 40 : 32)
                        .background(Circle().fill(.black.opacity(0.35)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(.black.opacity(0.3)))
    }

    private var bottomControls: some View {
        VStack(spacing: 14) {
            modePicker

            HStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.surfaceRaised)
                    .frame(width: 52, height: 52)
                    .overlay {
                        if let captured {
                            MockPhoto(index: captured)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

                Spacer()

                Button(action: capture) {
                    ZStack {
                        Circle().strokeBorder(Palette.paper, lineWidth: 4).frame(width: 74, height: 74)
                        Circle().fill(Palette.paper).frame(width: 62, height: 62).scaleEffect(shutterScale)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    Haptics.tap(.light)
                    withAnimation(.snappy) { front.toggle() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 22))
                        .foregroundStyle(front ? SysColor.yellow : SysColor.label)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Palette.surfaceRaised))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 30)
        }
        .padding(.top, 14)
        .padding(.bottom, max(safeArea.bottom, 14) + 8)
        .background(SysColor.groupedBackground)
    }

    private var modePicker: some View {
        ScrollViewReader { _ in
            HStack(spacing: 26) {
                ForEach(Array(modes.enumerated()), id: \.offset) { index, name in
                    Button {
                        Haptics.selection()
                        withAnimation(.snappy) { mode = index }
                    } label: {
                        Text(name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(mode == index ? SysColor.yellow : Palette.paper.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func capture() {
        Haptics.tap(.medium)
        withAnimation(.easeOut(duration: 0.08)) {
            shutterScale = 0.85
            flashOpacity = 0.85
        }
        withAnimation(.easeOut(duration: 0.35).delay(0.08)) {
            shutterScale = 1
            flashOpacity = 0
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7).delay(0.12)) {
            captured = Int.random(in: 0..<PhotosData.count)
        }
    }
}
