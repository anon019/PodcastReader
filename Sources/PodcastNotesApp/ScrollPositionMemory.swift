import AppKit
import SwiftUI

/// Persists the exact vertical offset of the enclosing native ScrollView.
/// A separate key is used for every episode and reader mode, so an unseen
/// episode starts at zero while a return visit resumes where it left off.
@MainActor
struct ScrollPositionMemory: NSViewRepresentable {
    let key: String

    func makeCoordinator() -> Coordinator {
        Coordinator(key: key)
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(frame: .zero)
        view.onAttach = { [weak coordinator = context.coordinator] probe in
            coordinator?.attach(toEnclosingScrollViewOf: probe)
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.updateKey(key)
        nsView.onAttach?(nsView)
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: Coordinator) {
        coordinator.persistCurrentPosition()
        coordinator.detach()
    }

    final class ProbeView: NSView {
        var onAttach: ((ProbeView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            onAttach?(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private var key: String
        private weak var scrollView: NSScrollView?
        private var isRestoring = false

        init(key: String) {
            self.key = key
        }

        func updateKey(_ newKey: String) {
            guard key != newKey else { return }
            persistCurrentPosition()
            key = newKey
            restorePosition()
        }

        func attach(toEnclosingScrollViewOf view: NSView) {
            guard let enclosing = view.enclosingScrollView else { return }
            guard scrollView !== enclosing else { return }
            detach()
            scrollView = enclosing
            enclosing.contentView.postsBoundsChangedNotifications = true
            restorePosition()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: enclosing.contentView
            )
        }

        func restorePosition() {
            guard scrollView != nil else { return }
            isRestoring = true
            perform(#selector(applyStoredPosition), with: nil, afterDelay: 0)
        }

        @objc private func applyStoredPosition() {
            guard let scrollView else { return }
            scrollView.documentView?.layoutSubtreeIfNeeded()
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let visibleHeight = scrollView.contentView.bounds.height
            let stored = UserDefaults.standard.double(forKey: defaultsKey)
            let restoredY = min(max(0, stored), max(0, documentHeight - visibleHeight))
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: restoredY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isRestoring = false
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            persistCurrentPosition()
        }

        func persistCurrentPosition() {
            guard !isRestoring, let scrollView else { return }
            UserDefaults.standard.set(scrollView.contentView.bounds.origin.y, forKey: defaultsKey)
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            scrollView = nil
        }

        private var defaultsKey: String {
            "readerScrollPosition.\(key)"
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
