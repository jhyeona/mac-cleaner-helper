import AppKit
import SwiftUI

struct BiuMascotView: View {
    let size: CGFloat
    var showsWand = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBlinking = false
    @State private var isFloating = false
    @State private var wandIsPlaying = false

    private var restingImage: NSImage? {
        image(named: "biu-redesign-v7-felt-dust")
    }

    private var blinkingImage: NSImage? {
        image(named: "biu-redesign-v7-felt-dust-blink")
    }

    private var wandImage: NSImage? {
        image(named: "biu-felt-wand-v2")
    }

    var body: some View {
        ZStack {
            characterArtwork
            .offset(
                x: -size * 0.1,
                y: reduceMotion ? -size * 0.04 : (isFloating ? -size * 0.065 : -size * 0.015)
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                value: isFloating
            )

            if showsWand, let wandImage {
                Image(nsImage: wandImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size * 0.47, height: size * 0.31)
                    .rotationEffect(
                        .degrees(reduceMotion ? -12 : (wandIsPlaying ? 9 : -19)),
                        anchor: .bottomLeading
                    )
                    .offset(
                        x: size * 0.34,
                        y: reduceMotion ? -size * 0.2 : (wandIsPlaying ? -size * 0.29 : -size * 0.14)
                    )
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 1.15).repeatForever(autoreverses: true),
                        value: wandIsPlaying
                    )
                    .accessibilityHidden(true)
            }
        }
        // The PNG includes generous transparent margins. The layout uses a cropped
        // viewport so those invisible pixels never become visible top padding.
        .frame(width: size * 1.12, height: size * 0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("마술봉과 노는 작은 펠트 먼지 정령 비우")
        .onAppear {
            isFloating = true
            wandIsPlaying = true
        }
        .task(id: reduceMotion) {
            isBlinking = false
            guard !reduceMotion else { return }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Double.random(in: 2.8...5.2)))
                    isBlinking = true
                    try await Task.sleep(for: .milliseconds(130))
                    isBlinking = false
                } catch {
                    isBlinking = false
                    return
                }
            }
        }
    }

    private var characterArtwork: some View {
        ZStack {
            if let restingImage {
                Image(nsImage: restingImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }

            if let blinkingImage {
                Image(nsImage: blinkingImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .opacity(isBlinking ? 1 : 0)
                    .mask {
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: geometry.size.width * 0.08)
                                .frame(
                                    width: geometry.size.width * 0.43,
                                    height: geometry.size.height * 0.28
                                )
                                .offset(
                                    x: geometry.size.width * 0.32,
                                    y: geometry.size.height * 0.27
                                )
                                .blur(radius: max(1, geometry.size.width * 0.015))
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(1.16)
        .offset(y: -size * 0.025)
        .frame(width: size * 0.82, height: size * 0.84)
        .clipped()
    }

    private func image(named name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
