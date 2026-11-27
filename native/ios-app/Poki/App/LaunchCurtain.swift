import SwiftUI
import UIKit

/// Retain the system launch view over the app's first frame, then fade into the app.
struct LaunchCurtain: UIViewRepresentable {
    var firstFrame: (CFTimeInterval) -> Void
    var done: () -> Void

    func makeUIView(context: Context) -> Stage {
        let stage = Stage(firstFrame: firstFrame, done: done)
        if let scene = UIStoryboard(name: "LaunchScreen", bundle: .main).instantiateInitialViewController()?.view {
            scene.frame = stage.bounds
            scene.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            stage.addSubview(scene)
        }
        return stage
    }

    func updateUIView(_ stage: Stage, context: Context) {}

    final class Stage: UIView {
        private var firstFrame: ((CFTimeInterval) -> Void)?
        private let done: () -> Void
        private var started = false
        private var transitionFinished = false
        private var attachedAt: CFTimeInterval = 0
        private var displayLink: CADisplayLink?

        init(firstFrame: @escaping (CFTimeInterval) -> Void, done: @escaping () -> Void) {
            self.firstFrame = firstFrame
            self.done = done
            super.init(frame: UIScreen.main.bounds)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            displayLink?.invalidate()
            displayLink = nil
            guard window != nil else { return }
            if firstFrame != nil {
                attachedAt = CACurrentMediaTime()
                let link = CADisplayLink(target: self, selector: #selector(frameDisplayed))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            guard !started else { return }
            started = true
            // The first frame goes up as the launch screen was; the curtain starts on the next one.
            DispatchQueue.main.async { self.open() }
        }

        @objc private func frameDisplayed(_ link: CADisplayLink) {
            // The timestamp is for the previous refresh. Wait for one after the curtain was attached.
            guard link.timestamp >= attachedAt else { return }
            link.invalidate()
            displayLink = nil
            let report = firstFrame
            firstFrame = nil
            report?(link.timestamp)
            if transitionFinished { done() }
        }

        private func open() {
            layoutIfNeeded()
            let finish: (UIViewAnimatingPosition) -> Void = { [weak self] _ in
                guard let self else { return }
                self.transitionFinished = true
                if self.firstFrame == nil { self.done() }
            }
            let fade = UIViewPropertyAnimator(duration: 0.25, curve: .easeInOut) { self.alpha = 0 }
            fade.addCompletion(finish)
            fade.startAnimation()
        }
    }
}
