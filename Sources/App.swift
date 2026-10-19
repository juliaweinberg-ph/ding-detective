import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = DingStore()
    private lazy var audio = AudioWatcher(store: store)
    private lazy var notifications = NotificationWatcher(store: store)
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var collapseObserver: AnyCancellable?
    private let collapsedSize = NSSize(width: 320, height: 56)
    private let expandedMinSize = NSSize(width: 320, height: 420)
    private var statusResetWork: DispatchWorkItem?
    private var permissionTimer: Timer?

    private var onDesktop: Bool {
        get { UserDefaults.standard.bool(forKey: "onDesktop") }
        set { UserDefaults.standard.set(newValue, forKey: "onDesktop"); applyWindowLevel() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPanel()
        store.onHeard = { [weak self] ding in self?.flashStatusItem(ding) }

        audio.start()
        notifications.start()
        checkAudioPermission(promptIfUndetermined: true)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAudioPermission(promptIfUndetermined: false) }
        }
        panel.orderFrontRegardless()
    }

    // MARK: Permissions

    private func checkAudioPermission(promptIfUndetermined: Bool) {
        switch Permissions.audioCaptureGranted {
        case true?:
            audio.setPrecise(true)
        case false?:
            audio.setPrecise(false)
        case nil:
            audio.setPrecise(false)
            if promptIfUndetermined { requestAudio() }
        }
    }

    private func requestAudio() {
        UserDefaults.standard.set(true, forKey: "askedAudio")
        if Permissions.audioCaptureGranted == false {
            Permissions.openAudioCaptureSettings()
            return
        }
        Permissions.requestAudioCapture { granted in
            DispatchQueue.main.async { [weak self] in
                if granted { self?.audio.setPrecise(true) } else { Permissions.openAudioCaptureSettings() }
            }
        }
    }

    // MARK: Panel

    private func setUpPanel() {
        // Borderless and transparent: SwiftUI draws the glass card / capsule, and the window
        // shadow follows its shape.
        panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 580),
                            styleMask: [.borderless, .resizable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let hosting = NSHostingView(rootView: WidgetView(store: store, requestAudio: { [weak self] in self?.requestAudio() }))
        hosting.sizingOptions = []   // the panel's frame is managed here, not by SwiftUI
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting

        if !panel.setFrameUsingName("DingWidget"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - 360, y: visible.maxY - 580))
        }
        panel.setFrameAutosaveName("DingWidget")
        applyWindowLevel()
        applyCollapsed(animated: false)
        collapseObserver = store.$collapsed.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyCollapsed(animated: true) }
        }
    }

    /// Resizes the panel for the collapsed bar or the full widget, keeping its top edge in place
    /// (and its right edge, when it sits on the right half of the screen).
    private func applyCollapsed(animated: Bool) {
        let defaults = UserDefaults.standard
        var frame = panel.frame
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame
        let top = frame.maxY
        let right = frame.maxX
        let anchorRight = frame.midX > screen.midX

        if store.collapsed {
            if frame.height > collapsedSize.height + 1 {
                defaults.set(NSStringFromSize(frame.size), forKey: "expandedSize")
            }
            frame.size = collapsedSize
            panel.styleMask.remove(.resizable)
            panel.contentMinSize = collapsedSize
        } else {
            var size = defaults.string(forKey: "expandedSize").map(NSSizeFromString) ?? NSSize(width: 340, height: 580)
            if size.height <= collapsedSize.height + 1 { size = NSSize(width: 340, height: 580) }
            size.width = max(size.width, expandedMinSize.width)
            size.height = max(size.height, expandedMinSize.height)
            frame.size = size
            panel.styleMask.insert(.resizable)
            panel.contentMinSize = expandedMinSize
        }

        frame.origin.y = top - frame.height
        if anchorRight { frame.origin.x = right - frame.width }
        // Expanding near the bottom of the screen: slide up rather than run off it.
        if frame.minY < screen.minY { frame.origin.y = screen.minY }
        panel.setFrame(frame, display: true, animate: animated)
        // The shadow is computed from what's drawn, so refresh it once SwiftUI has redrawn the new shape.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.panel.invalidateShadow() }
    }

    private func applyWindowLevel() {
        if onDesktop {
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        } else {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }
    }

    private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        resetStatusItem()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            menu.delegate = self
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    /// The menu bar briefly names whoever just dinged, so you can tell without looking at the widget.
    private func flashStatusItem(_ ding: Ding) {
        guard let button = statusItem.button else { return }
        if ding.isIdentified {
            let icon = AppResolver.shared.icon(for: ding.bundleID, path: ding.appPath).copy() as! NSImage
            icon.size = NSSize(width: 16, height: 16)
            button.image = icon
            button.title = " \(ding.appName)"
        } else {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
            button.title = " System sound"
        }
        button.imagePosition = .imageLeading
        statusResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resetStatusItem() }
        statusResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func resetStatusItem() {
        statusItem.button?.image = NSImage(systemSymbolName: "bell.and.waves.left.and.right", accessibilityDescription: "Ding Detective")
        statusItem.button?.title = ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(panel.isVisible ? "Hide Widget" : "Show Widget") { [weak self] in self?.togglePanel() })
        menu.addItem(item(store.collapsed ? "Expand Widget" : "Collapse Widget") { [weak self] in
            guard let self else { return }
            self.store.collapsed.toggle()
            if !self.panel.isVisible { self.panel.orderFrontRegardless() }
        })
        menu.addItem(.separator())
        menu.addItem(item("Float Above Windows", checked: !onDesktop) { [weak self] in self?.onDesktop = false })
        menu.addItem(item("Sit on Desktop", checked: onDesktop) { [weak self] in self?.onDesktop = true })
        menu.addItem(.separator())

        let ignoredItem = NSMenuItem(title: "Ignored Apps", action: nil, keyEquivalent: "")
        let ignoredMenu = NSMenu()
        let resolver = AppResolver.shared
        for id in store.ignored.sorted() where id != "com.cheapassjimmy.dingdetective" {
            let app = resolver.app(forBundleID: id)
            ignoredMenu.addItem(item("\(app.name)  (click to track again)") { [weak self] in self?.store.ignored.remove(id) })
        }
        if ignoredMenu.items.isEmpty { ignoredMenu.addItem(withTitle: "None", action: nil, keyEquivalent: "") }
        ignoredItem.submenu = ignoredMenu
        menu.addItem(ignoredItem)

        if !store.preciseAudio {
            menu.addItem(item("Enable Precise Detection…") { [weak self] in self?.requestAudio() })
        }
        if !store.notificationAccess {
            menu.addItem(item("Grant Full Disk Access…") { Permissions.openFullDiskAccessSettings() })
        }
        menu.addItem(item("Launch at Login", checked: SMAppService.mainApp.status == .enabled) {
            let service = SMAppService.mainApp
            if service.status == .enabled { try? service.unregister() } else { try? service.register() }
        })
        menu.addItem(item("Clear History") { [weak self] in self?.store.clear() })
        menu.addItem(.separator())
        menu.addItem(item("Quit Ding Detective") { NSApp.terminate(nil) })
    }

    private func item(_ title: String, checked: Bool = false, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        item.state = checked ? .on : .off
        return item
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// Double-clicking an empty spot would otherwise trigger the system zoom/minimize title bar action.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func zoom(_ sender: Any?) {}
    override func miniaturize(_ sender: Any?) {}
}
