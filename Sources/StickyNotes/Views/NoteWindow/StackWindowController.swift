import AppKit
import WebKit

/// One window that shows the front sheet of the default note stack.
///
/// The stack owns the window position. Notes in the stack keep their own
/// Markdown files and metadata but have no window position; the front sheet is
/// picked by creation date and can be cycled with the hover chevrons.
final class StackWindowController: NSWindowController, NSWindowDelegate, WebViewHost {
    /// Space reserved on the right/bottom to show the sheets underneath.
    static let deckDepth: CGFloat = 12

    private(set) var stack: NoteStack
    private weak var coordinator: AppCoordinator?

    var hasWebView = false

    /// Set when the coordinator closes the window because the stack is empty;
    /// the close button in that case must not be treated as "delete a note".
    var isClosingProgrammatically = false

    private var frontNote: Note
    private var rootView: StackRootView!
    private var cardView: NSView!
    private var contentContainer: NSView!
    private var badgeView: StackBadgeView!
    private var titleLabel: NSTextField?
    private var titleStripView: NSView?
    private var chevronUp: NSButton!
    private var chevronDown: NSButton!
    private var dropHighlightView: NSView?
    private var pinButton: NSButton?
    private var colorButtons: [NoteColor: NSButton] = [:]
    private var opacitySlider: NSSlider?
    private var titlebarControlsView: NSView?
    private var snapshotView: NSImageView?
    private var isHovering = false

    /// Translucent sheet that follows the pointer during an ⌥-drag.
    private var ghostWindow: NSWindow?
    private var ghostOrigin: NSPoint = .zero
    private var tearOutNoteID: UUID?

    var frontNoteId: UUID { frontNote.id }

    // Appearance belongs to the stack. Optional fields are seeded from the
    // front note for stack.json written before these fields existed.
    private var stackColorTheme: String { stack.colorTheme ?? frontNote.colorTheme }
    private var stackOpacity: Double { stack.opacity ?? frontNote.opacity }
    private var stackAlwaysOnTop: Bool { stack.alwaysOnTop ?? frontNote.alwaysOnTop }

    // MARK: - Initialization

    init?(stack: NoteStack, coordinator: AppCoordinator) {
        guard let front = coordinator.noteManager.frontStackedNote else { return nil }

        self.stack = stack
        self.coordinator = coordinator
        self.frontNote = front

        let cardSize = stack.size ?? front.size
        let panelSize = NSSize(
            width: max(280, cardSize.width) + Self.deckDepth,
            height: max(150, cardSize.height) + Self.deckDepth
        )
        let origin = ScreenGeometry.restoredOrigin(
            position: stack.position,
            screenUUID: stack.screenUUID,
            screenOffset: stack.screenOffset,
            size: panelSize
        )

        let panel = NotePanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: panel)
        panel.setFrameOrigin(origin)

        setupPanel(panel)
        setupTitlebarAccessory(panel)
        setupContent()
        applyFrontNote(switchEditor: false)

        // Adopt (and persist) the first card size so later sheet switches and
        // relaunches keep the same window size.
        if stack.size == nil {
            coordinator.noteManager.updateStackSize(cardSize)
        }
        if stack.colorTheme == nil || stack.opacity == nil
            || stack.alwaysOnTop == nil || stack.isMinimized == nil {
            coordinator.noteManager.updateStackAppearance(
                colorTheme: stackColorTheme,
                opacity: stackOpacity,
                alwaysOnTop: stackAlwaysOnTop,
                isMinimized: stack.isMinimized ?? false
            )
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupPanel(_ panel: NSPanel) {
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.alphaValue = CGFloat(stackOpacity)
        panel.title = "Sticky Stack"
        panel.delegate = self
        panel.minSize = NSSize(
            width: 280 + Self.deckDepth,
            height: 150 + Self.deckDepth
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden

        applyAlwaysOnTop(stackAlwaysOnTop)

        if stack.isMinimized == true {
            panel.miniaturize(nil)
        }
    }

    private func setupTitlebarAccessory(_ panel: NSPanel) {
        while !panel.titlebarAccessoryViewControllers.isEmpty {
            panel.removeTitlebarAccessoryViewController(at: 0)
        }

        let container = TitlebarControlsView(frame: NSRect(x: 0, y: 0, width: 190, height: 22))
        var xOffset: CGFloat = 4

        let slider = NSSlider(frame: NSRect(x: xOffset, y: 4, width: 50, height: 14))
        slider.minValue = 0.2
        slider.maxValue = 1.0
        slider.doubleValue = stackOpacity
        slider.target = self
        slider.action = #selector(opacityChanged(_:))
        slider.controlSize = .mini
        slider.toolTip = "Opacity"
        opacitySlider = slider
        container.addSubview(slider)
        xOffset += 58

        let pin = NSButton(frame: NSRect(x: xOffset, y: 2, width: 18, height: 18))
        pin.wantsLayer = true
        pin.bezelStyle = .regularSquare
        pin.isBordered = false
        pin.title = ""
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        if let img = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pin")?
            .withSymbolConfiguration(config) {
            pin.image = img
        }
        pin.contentTintColor = .labelColor
        pin.alphaValue = stackAlwaysOnTop ? 1.0 : 0.25
        pin.imagePosition = .imageOnly
        pin.target = self
        pin.action = #selector(toggleAlwaysOnTop)
        pin.toolTip = "Always on Top"
        pinButton = pin
        container.addSubview(pin)
        xOffset += 26

        for color in NoteColor.allCases {
            let dot = NSButton(frame: NSRect(x: xOffset, y: 5, width: 12, height: 12))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 6
            dot.layer?.backgroundColor = color.color.cgColor
            dot.layer?.borderWidth = color.rawValue == stackColorTheme ? 2 : 1
            dot.layer?.borderColor = NSColor(white: 0, alpha: color.rawValue == stackColorTheme ? 0.4 : 0.12).cgColor
            dot.isBordered = false
            dot.title = ""
            dot.target = self
            dot.action = #selector(colorDotClicked(_:))
            dot.toolTip = color.displayName
            colorButtons[color] = dot
            container.addSubview(dot)
            xOffset += 16
        }

        // Controls appear only while the stack window is key.
        container.isHidden = true
        titlebarControlsView = container

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .right
        panel.addTitlebarAccessoryViewController(accessory)
    }

    private func setupContent() {
        guard let panel = window as? NSPanel else { return }

        let contentRect = panel.contentRect(forFrameRect: panel.frame)

        let root = StackRootView(frame: NSRect(origin: .zero, size: contentRect.size))
        root.autoresizingMask = [.width, .height]
        root.deckDepth = Self.deckDepth
        root.cardColor = NoteColor.from(stackColorTheme).color
        root.stackedCount = coordinator?.noteManager.stackedNotes.count ?? 1
        root.onHoverChanged = { [weak self] hovering in
            self?.setChevronsVisible(hovering)
        }
        rootView = root
        panel.contentView = root

        let card = NSView(frame: root.cardFrame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 3
        card.layer?.masksToBounds = true
        card.layer?.backgroundColor = NoteColor.from(stackColorTheme).color.cgColor
        cardView = card
        root.cardView = card
        root.addSubview(card)

        let content = NSView(frame: card.bounds)
        content.autoresizingMask = [.width, .height]
        // Layer-backed so the preview/WebView composites above the card's
        // background layer (plain views can disappear behind it).
        content.wantsLayer = true
        contentContainer = content
        card.addSubview(content)

        let titleStrip: CGFloat = 30
        let strip = NSView(
            frame: NSRect(
                x: 0,
                y: card.bounds.height - 28 - titleStrip,
                width: card.bounds.width,
                height: titleStrip
            )
        )
        strip.autoresizingMask = [.width, .minYMargin]
        strip.wantsLayer = true
        strip.layer?.backgroundColor = NoteColor.from(stackColorTheme).color.cgColor
        titleStripView = strip

        let label = NSTextField(labelWithString: frontNote.title)
        label.frame = NSRect(x: 12, y: 5, width: strip.bounds.width - 70, height: 20)
        label.autoresizingMask = [.width]
        label.font = NoteFont.titleFont(family: coordinator?.settings.titleFontFamily)
        label.textColor = NSColor(white: 0.1, alpha: 0.85)
        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        titleLabel = label
        strip.addSubview(label)
        card.addSubview(strip)

        let badge = StackBadgeView(frame: NSRect(x: 10, y: 8, width: 46, height: 18))
        badge.autoresizingMask = [.maxXMargin, .maxYMargin]
        badge.count = root.stackedCount
        badge.isHidden = badge.count < 2
        badgeView = badge
        card.addSubview(badge)

        let size: CGFloat = 22
        chevronUp = makeChevronButton(
            symbol: "chevron.up",
            tooltip: "Previous note (newer)",
            action: #selector(showPreviousSheet)
        )
        chevronDown = makeChevronButton(
            symbol: "chevron.down",
            tooltip: "Next note (older)",
            action: #selector(showNextSheet)
        )
        chevronUp.frame = NSRect(
            x: card.bounds.width - size - 10,
            y: card.bounds.height - 64,
            width: size,
            height: size
        )
        chevronDown.frame = NSRect(
            x: card.bounds.width - size - 10,
            y: card.bounds.height - 94,
            width: size,
            height: size
        )
        chevronUp.autoresizingMask = [.minXMargin, .minYMargin]
        chevronDown.autoresizingMask = [.minXMargin, .minYMargin]
        card.addSubview(chevronUp)
        card.addSubview(chevronDown)
        updateChevronVisibility()

        // Titlebar drag surface. Also starts an ⌥-drag tear-out.
        let overlay = StackTitlebarView(
            frame: NSRect(x: 0, y: card.bounds.height - 28, width: card.bounds.width, height: 28)
        )
        overlay.autoresizingMask = [.width, .minYMargin]
        overlay.onOptionDragBegan = { [weak self] in self?.beginTearOut() }
        overlay.onOptionDragMoved = { [weak self] delta in self?.moveTearOut(by: delta) }
        overlay.onOptionDragEnded = { [weak self] in self?.endTearOut() }
        card.addSubview(overlay)

        let highlight = PassthroughView(frame: card.bounds)
        highlight.autoresizingMask = [.width, .height]
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 3
        highlight.layer?.borderWidth = 4
        highlight.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
        highlight.isHidden = true
        dropHighlightView = highlight
        card.addSubview(highlight)

        showTextPreview()
    }

    private func makeChevronButton(
        symbol: String,
        tooltip: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.title = ""
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        button.contentTintColor = .white
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.isHidden = true
        return button
    }

    // MARK: - Stack state

    /// Refresh metadata without touching the window frame (called from WindowManager).
    func updateStack(_ stack: NoteStack) {
        self.stack = stack
    }

    /// True only for the sheet the stack is currently showing, so the shared
    /// WebView never treats a hidden member note as this window's content.
    func contains(_ noteId: UUID) -> Bool {
        noteId == frontNote.id
    }

    /// Pull the latest model state into the window. Safe to call often.
    func refreshFromModel() {
        guard let manager = coordinator?.noteManager else { return }
        guard let stack = manager.stack else {
            DispatchQueue.main.async { [weak self] in
                self?.coordinator?.windowManager.closeStackWindow()
            }
            return
        }
        self.stack = stack

        guard let front = manager.frontStackedNote else {
            // The last member was deleted outside the app.
            DispatchQueue.main.async { [weak self] in
                self?.coordinator?.windowManager.closeStackWindow()
            }
            return
        }

        if front.id != frontNote.id {
            frontNote = front
            applyFrontNote(switchEditor: hasWebView)
        } else {
            frontNote = front
            refreshAppearance()
        }
    }

    /// Update colors, badge and titlebar controls without touching the editor.
    private func refreshAppearance() {
        titleLabel?.stringValue = frontNote.title
        let color = NoteColor.from(stackColorTheme)
        cardView?.layer?.backgroundColor = color.color.cgColor
        titleStripView?.layer?.backgroundColor = color.color.cgColor
        rootView?.cardColor = color.color
        rootView?.needsDisplay = true
        window?.alphaValue = CGFloat(stackOpacity)

        opacitySlider?.doubleValue = stackOpacity
        pinButton?.alphaValue = stackAlwaysOnTop ? 1.0 : 0.25
        for (theme, button) in colorButtons {
            let selected = theme.rawValue == stackColorTheme
            button.layer?.borderWidth = selected ? 2 : 1
            button.layer?.borderColor = NSColor(white: 0, alpha: selected ? 0.4 : 0.12).cgColor
        }

        let count = coordinator?.noteManager.stackedNotes.count ?? 1
        badgeView?.count = count
        badgeView?.isHidden = count < 2
        rootView?.stackedCount = count
        updateChevronVisibility()
    }

    private func cycleFront(by delta: Int) {
        guard let manager = coordinator?.noteManager else { return }
        let ordered = manager.stackedNotes
        guard ordered.count > 1,
              let index = ordered.firstIndex(where: { $0.id == frontNote.id }) else { return }
        let next = ordered[(index + delta + ordered.count) % ordered.count]
        manager.setStackFront(next.id)
        frontNote = next
        applyFrontNote(switchEditor: hasWebView)
    }

    @objc private func showPreviousSheet() {
        cycleFront(by: -1)
    }

    @objc private func showNextSheet() {
        cycleFront(by: 1)
    }

    private func setChevronsVisible(_ hovering: Bool) {
        isHovering = hovering
        updateChevronVisibility()
    }

    private func updateChevronVisibility() {
        let count = coordinator?.noteManager.stackedNotes.count ?? 1
        let visible = isHovering && count > 1 && ghostWindow == nil
        chevronUp?.isHidden = !visible
        chevronDown?.isHidden = !visible
    }

    /// Apply the stack's look and, optionally, put the front sheet in the shared editor.
    private func applyFrontNote(switchEditor: Bool) {
        titleLabel?.stringValue = frontNote.title
        refreshAppearance()
        applyAlwaysOnTop(stackAlwaysOnTop)

        if hasWebView {
            let manager = SharedWebViewManager.shared
            if switchEditor {
                manager.switchToNote(frontNote.id, note: frontNote)
            }
            manager.webView.callAsyncJavaScript(
                "window.setNoteColor(colorTheme)",
                arguments: ["colorTheme": stackColorTheme],
                in: nil,
                in: .page,
                completionHandler: nil
            )
            manager.setReadOnly(RemoteWriteAccess.isReadOnly(frontNote))
        } else {
            showTextPreview()
        }
    }

    private func applyAlwaysOnTop(_ alwaysOnTop: Bool) {
        guard let panel = window as? NSPanel else { return }
        if alwaysOnTop {
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isFloatingPanel = true
        } else {
            panel.level = .floating
            panel.collectionBehavior = [.managed]
            panel.isFloatingPanel = false
        }
    }

    // MARK: - Titlebar actions

    @objc private func colorDotClicked(_ sender: NSButton) {
        guard let color = colorButtons.first(where: { $0.value === sender })?.key else { return }
        stack.colorTheme = color.rawValue
        coordinator?.noteManager.updateStackAppearance(colorTheme: color.rawValue)
        for (theme, button) in colorButtons {
            let selected = theme == color
            button.layer?.borderWidth = selected ? 2 : 1
            button.layer?.borderColor = NSColor(white: 0, alpha: selected ? 0.4 : 0.12).cgColor
        }
        cardView.layer?.backgroundColor = color.color.cgColor
        titleStripView?.layer?.backgroundColor = color.color.cgColor
        rootView.cardColor = color.color
        rootView.needsDisplay = true

        if hasWebView {
            SharedWebViewManager.shared.webView.callAsyncJavaScript(
                "window.setNoteColor(colorTheme)",
                arguments: ["colorTheme": color.rawValue],
                in: nil,
                in: .page,
                completionHandler: nil
            )
        }
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        let opacity = sender.doubleValue
        stack.opacity = opacity
        window?.alphaValue = CGFloat(opacity)
        coordinator?.noteManager.updateStackAppearance(opacity: opacity)
    }

    @objc private func toggleAlwaysOnTop() {
        let value = !stackAlwaysOnTop
        stack.alwaysOnTop = value
        applyAlwaysOnTop(value)
        coordinator?.noteManager.updateStackAppearance(alwaysOnTop: value)
        pinButton?.alphaValue = value ? 1.0 : 0.25
    }

    /// Highlight the stack while a placed note is dragged over it.
    func setDropHighlight(_ highlighted: Bool) {
        dropHighlightView?.isHidden = !highlighted
    }

    // MARK: - External updates (menus, folder sync)

    func refreshFonts() {
        titleLabel?.font = NoteFont.titleFont(family: coordinator?.settings.titleFontFamily)
        if !hasWebView {
            showTextPreview()
        }
    }

    func applyColorTheme(_ theme: String) {
        stack.colorTheme = theme
        refreshAppearance()
        if hasWebView {
            SharedWebViewManager.shared.webView.callAsyncJavaScript(
                "window.setNoteColor(colorTheme)",
                arguments: ["colorTheme": theme],
                in: nil,
                in: .page,
                completionHandler: nil
            )
        }
    }

    func applyOpacity(_ opacity: Double) {
        stack.opacity = opacity
        window?.alphaValue = CGFloat(opacity)
        opacitySlider?.doubleValue = opacity
    }

    func applyAlwaysOnTopSetting(_ alwaysOnTop: Bool) {
        stack.alwaysOnTop = alwaysOnTop
        applyAlwaysOnTop(alwaysOnTop)
        pinButton?.alphaValue = alwaysOnTop ? 1.0 : 0.25
    }

    func applyExternalUpdate(content: String) {
        frontNote.content = content
        if let current = coordinator?.noteManager.getNote(frontNote.id) {
            frontNote.title = current.title
            titleLabel?.stringValue = current.title
        }
        SharedWebViewManager.shared.invalidateCachedState(for: frontNote.id)
        guard hasWebView else {
            showTextPreview()
            return
        }
        SharedWebViewManager.shared.webView.callAsyncJavaScript(
            "window.setContent(content)",
            arguments: ["content": content],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    // MARK: - WebView

    func attachWebView() {
        guard !hasWebView else { return }
        let manager = SharedWebViewManager.shared
        guard let current = coordinator?.noteManager.getNote(frontNote.id) else { return }
        frontNote = current

        // Snapshot the window the WebView is leaving (a note window or this stack).
        manager.snapshotActiveHostBeforeMove()

        let wv = manager.webView
        wv.alphaValue = 0
        wv.frame = contentContainer.bounds
        wv.autoresizingMask = [.width, .height]
        contentContainer.addSubview(wv)
        hasWebView = true
        manager.setActiveHost(self)

        manager.switchToNoteSkippingSerialization(frontNote.id, note: frontNote)

        if manager.isReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.revealWebView()
            }
        }
    }

    func revealWebView() {
        guard hasWebView else { return }
        let wv = SharedWebViewManager.shared.webView
        if wv.frame.size != contentContainer.bounds.size {
            wv.frame = contentContainer.bounds
        }
        wv.alphaValue = 1
        removeNonWebViewSubviews()
        wv.window?.makeFirstResponder(wv)
        wv.evaluateJavaScript("window.focusEditor()")
    }

    func showSnapshot(_ image: NSImage) {
        removeNonWebViewSubviews()

        let imageView = NSImageView(frame: contentContainer.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTopLeft
        snapshotView = imageView
        contentContainer.addSubview(imageView)
    }

    func showTextPreview() {
        removeNonWebViewSubviews()

        let content = coordinator?.noteManager.getNote(frontNote.id)?.content
            ?? frontNote.content
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let scrollView = NSScrollView(frame: contentContainer.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false

        let contentSize = scrollView.contentView.bounds.size
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 62)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textStorage?.setAttributedString(
            MarkdownPreview.attributedString(
                for: content,
                fontFamily: coordinator?.settings.noteFontFamily
            )
        )

        scrollView.documentView = textView
        contentContainer.addSubview(scrollView)
    }

    private func removeNonWebViewSubviews() {
        for sub in contentContainer.subviews where !(sub is WKWebView) {
            sub.removeFromSuperview()
        }
        snapshotView = nil
    }

    var contentSize: NSSize { contentContainer.bounds.size }

    // MARK: - Tear-out (⌥-drag)

    private func beginTearOut() {
        guard ghostWindow == nil, let panel = window else { return }
        // Pull the note out at the stack's visible size, not the sheet's old
        // stored size (which is not used while it lives in the stack).
        let size = NSSize(
            width: max(280, contentSize.width),
            height: max(150, contentSize.height)
        )
        let origin = NSPoint(
            x: panel.frame.minX,
            y: panel.frame.minY + Self.deckDepth
        )

        let ghost = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        ghost.isOpaque = false
        ghost.backgroundColor = NoteColor.from(stackColorTheme).color.withAlphaComponent(0.92)
        ghost.hasShadow = true
        ghost.level = panel.level
        ghost.ignoresMouseEvents = true
        ghost.alphaValue = 0.9
        ghost.orderFront(nil)

        ghostWindow = ghost
        ghostOrigin = origin
        tearOutNoteID = frontNote.id
        updateChevronVisibility()
    }

    private func moveTearOut(by delta: CGSize) {
        guard let ghost = ghostWindow else { return }
        ghost.setFrameOrigin(
            NSPoint(x: ghostOrigin.x + delta.width, y: ghostOrigin.y + delta.height)
        )
    }

    private func endTearOut() {
        guard let ghost = ghostWindow, let noteID = tearOutNoteID else { return }
        let origin = ghost.frame.origin
        let size = ghost.frame.size
        ghost.close()
        ghostWindow = nil
        tearOutNoteID = nil
        updateChevronVisibility()

        if hasWebView {
            // Capture the last keystrokes before the stack stops showing this note.
            SharedWebViewManager.shared.flushCurrentNoteState()
        }
        coordinator?.pullOutFrontNote(noteId: noteID, to: origin, size: size)
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        titlebarControlsView?.isHidden = false
        attachWebView()
    }

    func windowDidResignKey(_ notification: Notification) {
        titlebarControlsView?.isHidden = true
    }

    func windowDidResize(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        // The panel is the stack card plus the deck margin. Switching sheets
        // never resizes the window; only the user does.
        coordinator?.noteManager.updateStackSize(
            CGSize(
                width: max(280, frame.width - Self.deckDepth),
                height: max(150, frame.height - Self.deckDepth)
            )
        )
    }

    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        let frame = window.frame
        let screen = ScreenGeometry.screen(for: frame)
        coordinator?.noteManager.updateStackPlacement(
            position: frame.origin,
            screenUUID: screen.flatMap { ScreenGeometry.uuid(for: $0) },
            screenOffset: screen.map {
                ScreenGeometry.offset(of: frame.origin, on: $0)
            }
        )
    }

    func windowDidMiniaturize(_ notification: Notification) {
        coordinator?.noteManager.updateStackAppearance(isMinimized: true)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        coordinator?.noteManager.updateStackAppearance(isMinimized: false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosingProgrammatically { return true }
        guard let coordinator, !coordinator.isQuitting else { return true }
        guard let current = coordinator.noteManager.getNote(frontNote.id) else {
            return true
        }

        if current.isRemote {
            let alert = NSAlert()
            alert.messageText = "Close this note?"
            alert.informativeText = "It stays on the server; open its link to show it again."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        } else if !current.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let alert = NSAlert()
            alert.messageText = "Move this note to the Trash?"
            alert.informativeText = "“\(current.title).md” will be moved to the Trash. You can restore it from there."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }

        // Delete the front sheet and stay open on the next one. When no notes
        // remain, the notes binding closes the window via closeStackWindow().
        let noteId = frontNote.id
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.hasWebView {
                SharedWebViewManager.shared.flushCurrentNoteState()
            }
            self.coordinator?.closeNoteWindow(noteId)
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if hasWebView {
            SharedWebViewManager.shared.flushCurrentNoteState()
            SharedWebViewManager.shared.webView.removeFromSuperview()
            hasWebView = false
        }
        SharedWebViewManager.shared.hostWillClose(self)
        ghostWindow?.close()
        ghostWindow = nil
        coordinator?.windowManager.stackWindowWillClose(self)
    }
}

// MARK: - Views

/// Draws the sheets under the front card and tracks hover for the chevrons.
final class StackRootView: NSView {
    var deckDepth: CGFloat = 12
    var stackedCount: Int = 1 {
        didSet { needsDisplay = true }
    }
    var cardColor: NSColor = .windowBackgroundColor {
        didSet { needsDisplay = true }
    }

    weak var cardView: NSView?
    var onHoverChanged: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?

    var cardFrame: NSRect {
        NSRect(
            x: 0,
            y: deckDepth,
            width: max(0, bounds.width - deckDepth),
            height: max(0, bounds.height - deckDepth)
        )
    }

    override func layout() {
        super.layout()
        cardView?.frame = cardFrame
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let cardView else { return }

        let layers = min(max(stackedCount - 1, 0), 3)

        // Farthest sheet first; the card view covers all but a few points of it.
        for index in stride(from: layers, through: 1, by: -1) {
            let fraction = 0.08 * CGFloat(index)
            let color = cardColor.blended(withFraction: fraction, of: .black) ?? cardColor
            color.setFill()
            let rect = cardView.frame.offsetBy(
                dx: CGFloat(index) * (deckDepth / 3),
                dy: -CGFloat(index) * (deckDepth / 3)
            )
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }

    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

/// Overlay that paints but never takes clicks.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Small "N" badge showing how many sheets are in the stack.
final class StackBadgeView: NSView {
    var count: Int = 1 {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Never steal clicks from the editor.
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = "\(count)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor(white: 0, alpha: 0.65)
        ]
        let textSize = text.size(withAttributes: attributes)
        let width = max(bounds.height, textSize.width + 10)
        let rect = NSRect(
            x: bounds.maxX - width,
            y: bounds.minY,
            width: width,
            height: bounds.height
        )

        NSColor(white: 0, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        text.draw(
            at: NSPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }
}

/// Titlebar drag surface that turns ⌥-drag into a "pull this note out" gesture.
final class StackTitlebarView: NSView {
    var onOptionDragBegan: (() -> Void)?
    var onOptionDragMoved: ((CGSize) -> Void)?
    var onOptionDragEnded: (() -> Void)?

    private var dragOrigin: NSPoint?
    private var dragStart: NSPoint?
    private var optionStart: NSPoint?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }

        if event.modifierFlags.contains(.option) {
            optionStart = NSEvent.mouseLocation
            onOptionDragBegan?()
            return
        }

        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
            return
        }

        dragOrigin = window.frame.origin
        dragStart = NSEvent.mouseLocation

        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let optionStart {
            let current = NSEvent.mouseLocation
            onOptionDragMoved?(
                CGSize(
                    width: current.x - optionStart.x,
                    height: current.y - optionStart.y
                )
            )
            return
        }

        guard let window, let origin = dragOrigin, let start = dragStart else { return }
        let current = NSEvent.mouseLocation
        window.setFrameOrigin(
            NSPoint(
                x: origin.x + current.x - start.x,
                y: origin.y + current.y - start.y
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        if optionStart != nil {
            optionStart = nil
            onOptionDragEnded?()
            return
        }
        dragOrigin = nil
        dragStart = nil
    }
}
