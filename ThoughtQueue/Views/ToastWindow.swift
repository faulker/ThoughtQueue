import Cocoa

/// Transient "pill" toast near the top of the screen for brief feedback.
final class ToastWindow: NSWindow {
    private static var current: ToastWindow?
    private static var fadeWorkItem: DispatchWorkItem?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func show(message: String, duration: TimeInterval = 1.5) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { show(message: message, duration: duration) }
            return
        }

        fadeWorkItem?.cancel()
        fadeWorkItem = nil
        current?.orderOut(nil)
        current = nil

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.sizeToFit()

        let padding: CGFloat = 24
        let width = label.frame.width + padding * 2
        let height: CGFloat = 36

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - 80

        let window = ToastWindow(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        container.layer?.cornerRadius = height / 2

        label.frame = NSRect(x: padding, y: (height - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        container.addSubview(label)

        window.contentView = container
        window.alphaValue = 1.0
        window.orderFront(nil)
        current = window

        let workItem = DispatchWorkItem { [weak window] in
            guard let window = window else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                window.animator().alphaValue = 0
            }, completionHandler: { [weak window] in
                window?.orderOut(nil)
                if current === window { current = nil }
            })
        }
        fadeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }
}
