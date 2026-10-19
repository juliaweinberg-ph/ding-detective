import AppKit
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
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 560),
                        styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        let hosting = NSHostingView(rootView: WidgetView(store: store, requestAudio: { [weak self] in self?.requestAudio() }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        if !panel.setFrameUsingName("DingWidget"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - 360, y: visible.maxY - 580))
        }
        panel.setFrameAutosaveName("DingWidget")
        applyWindowLevel()
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
