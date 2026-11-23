import AppKit
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers

enum FixtureMenu {
    case toolbar(String)
    case row(String)

    var arguments: [String] {
        switch self {
        case .toolbar(let title): ["toolbar", title]
        case .row(let title): ["row", title]
        }
    }
}

extension HelpCapture {
    func captureMenus() throws {
        try capture("library-actions", title: "Library", size: (1080, 495), menu: .toolbar("Library Actions")) {
            workspace(.library)
        }
        try capture("download-menu", title: "Library", size: (1080, 405), menu: .toolbar("Download")) {
            workspace(.library)
        }
        if let transfer = model.transfers.first, requested.isEmpty || requested.contains("transfer-actions") {
            model.showNotifiedTransfers([transfer.id])
        }
        try capture("transfer-actions", title: "Downloads", size: (870, 396), menu: .toolbar("Download Actions")) {
            workspace(.transfers)
        }
        try capture("library-sort-menu", title: "Library", size: (1080, 405), menu: .toolbar("Sort Library")) {
            workspace(.library)
        }
        try capture("library-filter-menu", title: "Library", size: (1080, 405), menu: .toolbar("Filter Library")) {
            workspace(.library)
        }
        try capture("library-book-menu", title: "Library", size: (1080, 405), menu: .row("Demo Book 3")) {
            workspace(.library)
        }
        try capture("library-saved-book-menu", title: "Library", size: (1080, 405), menu: .row("Demo Book 1")) {
            workspace(.library)
        }
        try capture("transfer-output-menu", title: "Downloads", size: (870, 396), menu: .row("Demo Book 1")) {
            workspace(.transfers)
        }
        try capture("transfer-recovery-menu", title: "Downloads", size: (870, 396), menu: .row("Demo Book 4")) {
            workspace(.transfers)
        }
        try capture("converter-file-menu", title: "Convert Files", size: (900, 380), menu: .row("Demo Book 3")) {
            workspace(.convert)
        }
    }

    func captureFixtureMenu(_ menu: FixtureMenu, window: NSWindow, destination: URL) throws {
        let rowPosition = fixture.appending(path: "row-position.json")
        defer { try? FileManager.default.removeItem(at: rowPosition) }
        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--capture-menu", String(ProcessInfo.processInfo.processIdentifier)] + menu.arguments
            + [destination.path, rowPosition.path]
        try FixtureMenuTracking(helper: helper, window: window, rowPosition: rowPosition).run()
        guard helper.terminationStatus == 0 else { throw MenuCaptureError.missingMenu(menu.arguments[1]) }
    }

    func captureAlerts() throws {
        try captureAlert("quit-progress", DownAudibleAppDelegate.transferQuitAlert())
        try captureAlert("quit-save-failed", DownAudibleAppDelegate.queueSaveFailureAlert(
            TransferQueueStore.helpScreenshotSaveError, quitting: true
        ))
    }

    private func captureAlert(_ name: String, _ alert: @autoclosure () -> NSAlert) throws {
        guard requested.isEmpty || requested.contains(name) else { return }
        let alert = alert()
        if let icon = Bundle.main.url(forResource: "DownAudible", withExtension: "png").flatMap(NSImage.init(contentsOf:)) {
            alert.icon = icon
        }
        alert.layout()
        let window = alert.window
        window.appearance = NSAppearance(named: .aqua)
        window.center()
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let destination = output.appending(path: name + ".png")
        guard let content = window.contentView else { throw CocoaError(.fileWriteUnknown) }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let image = bitmap.cgImage, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(gray: 0.956, alpha: 1)
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let result = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        try writePNG(result, to: destination)
        print(name)
    }
}

@MainActor
private final class FixtureMenuTracking: NSObject {
    let helper: Process
    let window: NSWindow
    let rowPosition: URL
    private var menu: NSMenu?

    init(helper: Process, window: NSWindow, rowPosition: URL) {
        self.helper = helper
        self.window = window
        self.rowPosition = rowPosition
    }

    func run() throws {
        let notifications = NotificationCenter.default
        notifications.addObserver(self, selector: #selector(menuDidBeginTracking), name: NSMenu.didBeginTrackingNotification,
                                  object: nil)
        defer { notifications.removeObserver(self) }
        try helper.run()
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(finishTracking), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate() }
        var openedRowMenu = false
        while helper.isRunning {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if !openedRowMenu, let data = try? Data(contentsOf: rowPosition) {
                openedRowMenu = true
                try openRowMenu(at: JSONDecoder().decode(CGPoint.self, from: data))
            }
        }
    }

    private func openRowMenu(at position: CGPoint) throws {
        guard let primaryScreen = NSScreen.screens.first else { throw MenuCaptureError.invalidImage }
        let screenPoint = CGPoint(x: position.x, y: primaryScreen.frame.maxY - position.y)
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        if let press = NSEvent.mouseEvent(with: .rightMouseDown, location: windowPoint, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: 1, pressure: 1) {
            window.sendEvent(press)
        }
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        menu = notification.object as? NSMenu
    }

    @objc private func finishTracking(_ timer: Timer) {
        guard !helper.isRunning else { return }
        if let menu {
            menu.cancelTracking()
        } else if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
                                                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                isARepeat: false, keyCode: 53) {
            NSApp.postEvent(escape, atStart: true)
        }
    }
}

private enum MenuCaptureError: LocalizedError {
    case incorrectArguments
    case missingPermission
    case missingItem(String)
    case missingMenu(String)
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .incorrectArguments: "The menu capture helper must be launched by its capture app."
        case .missingPermission: "Menu captures require Accessibility and Screen Recording access for the terminal."
        case .missingItem(let title): "The fixture window has no accessible \(title) menu button or row."
        case .missingMenu(let title): "Could not capture the open \(title) menu."
        case .invalidImage: "The captured menu did not contain any visible pixels."
        }
    }
}

func captureFixtureMenu(arguments: [String]) throws {
    guard arguments.count == 5, let pid = Int32(arguments[0]), pid == getppid() else {
        throw MenuCaptureError.incorrectArguments
    }
    guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { throw MenuCaptureError.missingPermission }
    let kind = arguments[1]
    let title = arguments[2]
    let target = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(target, 0.5)
    switch kind {
    case "toolbar":
        guard let button = toolbarButton(in: target, title: title) else { throw MenuCaptureError.missingItem(title) }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    case "row":
        guard let row = tableRow(in: target, title: title) else { throw MenuCaptureError.missingItem(title) }
        let rowPosition = try contextMenuPosition(for: row, title: title)
        try JSONEncoder().encode(rowPosition).write(to: URL(filePath: arguments[4]), options: .atomic)
    default:
        throw MenuCaptureError.incorrectArguments
    }
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if let number = popupWindowNumber(pid: pid) {
            let destination = URL(filePath: arguments[3])
            try captureMenuWindow(number, to: destination)
            return
        }
        Thread.sleep(forTimeInterval: 0.04)
    }
    throw MenuCaptureError.missingMenu(title)
}

private func tableRow(in element: AXUIElement, title: String) -> AXUIElement? {
    let role: String? = axAttribute(element, kAXRoleAttribute)
    if role == kAXRowRole, containsLabel(title, in: element) { return element }
    let children: [AXUIElement]? = axAttribute(element, kAXChildrenAttribute)
    return children?.lazy.compactMap { tableRow(in: $0, title: title) }.first
}

private func containsLabel(_ title: String, in element: AXUIElement) -> Bool {
    let fields = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
    if fields.contains(where: { axAttribute(element, $0, as: String.self)?.contains(title) == true }) {
        return true
    }
    let children: [AXUIElement]? = axAttribute(element, kAXChildrenAttribute)
    return children?.contains { containsLabel(title, in: $0) } == true
}

private func contextMenuPosition(for row: AXUIElement, title: String) throws -> CGPoint {
    var position = CGPoint.zero
    var size = CGSize.zero
    guard let origin: AXValue = axAttribute(row, kAXPositionAttribute),
          let dimensions: AXValue = axAttribute(row, kAXSizeAttribute),
          AXValueGetValue(origin, .cgPoint, &position), AXValueGetValue(dimensions, .cgSize, &size),
          size.width > 0, size.height > 0 else { throw MenuCaptureError.missingItem(title) }
    return CGPoint(x: position.x + min(116, size.width / 2), y: position.y + size.height / 2)
}

private func axAttribute<T>(_ element: AXUIElement, _ key: String, as _: T.Type = T.self) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value as? T
}

private func toolbarButton(in element: AXUIElement, title: String) -> AXUIElement? {
    let role: String? = axAttribute(element, kAXRoleAttribute)
    let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap {
        axAttribute(element, $0, as: String.self)
    }
    if [kAXMenuButtonRole, kAXPopUpButtonRole, kAXButtonRole].contains(role ?? ""), labels.contains(title) {
        return element
    }
    let children: [AXUIElement]? = axAttribute(element, kAXChildrenAttribute)
    return children?.lazy.compactMap { toolbarButton(in: $0, title: title) }.first
}

private func popupWindowNumber(pid: Int32) -> UInt32? {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.first {
        ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
            ($0[kCGWindowLayer as String] as? Int32 ?? 0) >= CGWindowLevelForKey(.popUpMenuWindow)
    }?[kCGWindowNumber as String] as? UInt32
}

private func captureMenuWindow(_ number: UInt32, to destination: URL) throws {
    let raw = destination.deletingLastPathComponent().appending(path: UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: raw) }
    let screenshot = Process()
    screenshot.executableURL = URL(filePath: "/usr/sbin/screencapture")
    screenshot.arguments = ["-x", "-o", "-l", String(number), raw.path]
    try screenshot.run()
    screenshot.waitUntilExit()
    guard screenshot.terminationStatus == 0,
          let source = CGImageSourceCreateWithURL(raw as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let srgb = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
        throw MenuCaptureError.invalidImage
    }
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.draw(image, in: bounds)
    var visible = CGRect.null
    for row in 0..<image.height {
        for column in 0..<image.width where pixels[row * context.bytesPerRow + column * 4 + 3] >= 128 {
            visible = visible.union(CGRect(x: column, y: row, width: 1, height: 1))
        }
    }
    guard !visible.isNull,
          let cropped = image.cropping(to: visible.insetBy(dx: -12, dy: -12).intersection(bounds)) else {
        throw MenuCaptureError.invalidImage
    }
    try writePNG(cropped, to: destination)
}

private func writePNG(_ image: CGImage, to destination: URL) throws {
    guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw MenuCaptureError.invalidImage
    }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer) else { throw MenuCaptureError.invalidImage }
}
