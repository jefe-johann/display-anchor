import AppKit
#if canImport(DisplayAnchorCore)
import DisplayAnchorCore
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = DisplayAnchorController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")
    private let permissionMenuItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let snapshotMenuItem = NSMenuItem(title: "Snapshot Now", action: #selector(snapshotNow), keyEquivalent: "")
    private let restoreMenuItem = NSMenuItem(title: "Restore Last Snapshot", action: #selector(restoreLastSnapshot), keyEquivalent: "")
    private let pauseMenuItem = NSMenuItem(title: "Pause Automatic Restore", action: #selector(togglePause), keyEquivalent: "")
    private let launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()

        controller.onStatusChange = { [weak self] status in
            self?.statusMenuItem.title = status.menuText
            self?.updateMenuState()
        }

        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller.refreshPermissionState()
        updateMenuState()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Display Anchor")
            button.imagePosition = .imageOnly
        }
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self

        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        permissionMenuItem.target = self
        menu.addItem(permissionMenuItem)
        menu.addItem(NSMenuItem.separator())

        snapshotMenuItem.target = self
        restoreMenuItem.target = self
        pauseMenuItem.target = self
        launchAtLoginMenuItem.target = self
        menu.addItem(snapshotMenuItem)
        menu.addItem(restoreMenuItem)
        menu.addItem(pauseMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Display Anchor", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func updateMenuState() {
        let hasPermission = AccessibilityPermission.isTrusted
        permissionMenuItem.isHidden = hasPermission
        snapshotMenuItem.isEnabled = hasPermission && !controller.isPaused()
        restoreMenuItem.isEnabled = hasPermission
        pauseMenuItem.isEnabled = hasPermission
        pauseMenuItem.state = controller.isPaused() ? .on : .off

        switch LaunchAtLogin.status {
        case .enabled:
            launchAtLoginMenuItem.title = "Launch at Login"
            launchAtLoginMenuItem.state = .on
            launchAtLoginMenuItem.isEnabled = true
        case .notRegistered:
            launchAtLoginMenuItem.title = "Launch at Login"
            launchAtLoginMenuItem.state = .off
            launchAtLoginMenuItem.isEnabled = true
        case .requiresApproval:
            launchAtLoginMenuItem.title = "Approve Launch at Login..."
            launchAtLoginMenuItem.state = .off
            launchAtLoginMenuItem.isEnabled = true
        case .notFound:
            launchAtLoginMenuItem.title = "Launch at Login"
            launchAtLoginMenuItem.state = .off
            launchAtLoginMenuItem.isEnabled = true
        @unknown default:
            launchAtLoginMenuItem.title = "Launch at Login Unavailable"
            launchAtLoginMenuItem.state = .off
            launchAtLoginMenuItem.isEnabled = false
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func snapshotNow() {
        controller.snapshotNow()
    }

    @objc private func restoreLastSnapshot() {
        controller.restoreLastSnapshot()
    }

    @objc private func togglePause() {
        controller.setPaused(!controller.isPaused())
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            switch LaunchAtLogin.status {
            case .enabled:
                try LaunchAtLogin.disable()
            case .notRegistered:
                try LaunchAtLogin.enable()
                if LaunchAtLogin.status == .requiresApproval {
                    LaunchAtLogin.openSystemSettings()
                }
            case .requiresApproval:
                LaunchAtLogin.openSystemSettings()
            case .notFound:
                try LaunchAtLogin.enable()
                if LaunchAtLogin.status == .requiresApproval {
                    LaunchAtLogin.openSystemSettings()
                }
            @unknown default:
                NSSound.beep()
            }
        } catch {
            statusMenuItem.title = "Error: \(error.localizedDescription)"
        }

        updateMenuState()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
