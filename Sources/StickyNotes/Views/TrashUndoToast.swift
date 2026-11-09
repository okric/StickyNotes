import AppKit

/// Floating toast shown after a note's file is moved to the Trash.
///
/// It offers a single Undo action and dismisses itself after a few seconds, so
/// a close is never a dead end but also never blocks with a second dialog.
final class TrashUndoToast: NSPanel {

    private static let displayDuration: TimeInterval = 8

    private let onUndo: () -> Void
    private let onDismiss: () -> Void
    private var dismissTimer: Timer?

    init(title: String, onUndo: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onUndo = onUndo
        self.onDismiss = onDismiss

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 54),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false

        buildContent(title: title)
        positionOnMouseScreen()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Presentation

    func present() {
        orderFrontRegardless()
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: Self.displayDuration,
            repeats: false
        ) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        orderOut(nil)
        onDismiss()
    }

    // MARK: - Content

    private func buildContent(title: String) {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "Moved “\(title)” to the Trash")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let undoButton = NSButton(title: "Undo", target: self, action: #selector(undoTapped))
        undoButton.bezelStyle = .rounded
        undoButton.controlSize = .small
        undoButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [label, undoButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])

        contentView = background
    }

    @objc private func undoTapped() {
        onUndo()
        dismiss()
    }

    private func positionOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        setFrameOrigin(NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.minY + 32
        ))
    }
}
