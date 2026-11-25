import AppKit
import ServiceManagement
import SwiftUI

/// Runs a block on the main thread through the run loop rather than the main
/// dispatch queue, so it also runs while a menu or modal panel is open.
func onMain(_ block: @escaping () -> Void) {
    RunLoop.main.perform(inModes: [.common], block: block)
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let prefs = Prefs()
    private let passwords = PasswordStore()
    private lazy var roamer = Roamer(prefs: prefs, passwords: passwords)
    private lazy var settings = SettingsModel(prefs: prefs, passwords: passwords, roamer: roamer)
    private var settingsWindow: NSWindow?
    private var snapshot = Snapshot()
    /// Settings opens by itself for a missing password only once per launch.
    private var askedForPassword = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let networks = prefs.managed
        Log.write("WiFiHop started, watching: \(networks.isEmpty ? "nothing yet" : networks.joined(separator: ", "))")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        roamer.onUpdate = { [weak self] snapshot in
            onMain { self?.apply(snapshot) }
        }
        roamer.start()

        if !prefs.hasLaunchedBefore {
            prefs.hasLaunchedBefore = true
            do { try SMAppService.mainApp.register() } catch {
                Log.write("Could not enable start at login: \(error.localizedDescription)")
            }
        }
        let report = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            guard let self else { return }
            let frame = self.statusItem.button?.window?.frame ?? .zero
            let login = SMAppService.mainApp.status == .enabled
            Log.write("Menu bar icon visible: \(self.statusItem.isVisible) at x=\(Int(frame.minX)), starts at login: \(login)")
        }
        RunLoop.main.add(report, forMode: .common)

        // Nothing to switch between yet: start with setup.
        if networks.count < 2 {
            onMain { self.openSettings() }
        }
    }

    private func apply(_ new: Snapshot) {
        snapshot = new
        refreshIcon()
        if new.needsPassword != nil, !askedForPassword {
            askedForPassword = true
            openSettings()
        }
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: "wifi.router", accessibilityDescription: "WiFiHop") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "WiFi"
        }
        button.appearsDisabled = prefs.paused
        button.toolTip = snapshot.connected ? "WiFiHop: \(describeSignal(snapshot.rssi))" : "WiFiHop: not connected"
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let networks = prefs.managed

        if !snapshot.connected {
            menu.addItem(info("Wi-Fi not connected"))
        } else if let ssid = snapshot.ssid {
            menu.addItem(info("\(ssid): \(describeSignal(snapshot.rssi))"))
        } else {
            menu.addItem(info("On another network: \(describeSignal(snapshot.rssi))"))
        }

        if networks.count < 2 {
            menu.addItem(info("Choose your networks in Settings"))
        } else if prefs.paused {
            menu.addItem(info("Switching is paused"))
        } else if let ssid = snapshot.needsPassword {
            menu.addItem(info("Needs the password for \(ssid)"))
        } else if let event = snapshot.lastEvent {
            menu.addItem(info(event))
        }
        menu.addItem(.separator())

        if !networks.isEmpty {
            menu.addItem(info("Switches between"))
            for ssid in networks {
                var title = ssid
                if !passwords.has(ssid) {
                    title += "  (needs password)"
                } else if let rssi = snapshot.seen[ssid] {
                    title += "  \(describeSignal(rssi))"
                }
                let item = info(title)
                item.state = ssid == snapshot.ssid ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let pause = action("Pause Switching", #selector(togglePause))
        pause.state = prefs.paused ? .on : .off
        menu.addItem(pause)
        let open = action("Settings…", #selector(openSettings))
        open.keyEquivalent = ","
        menu.addItem(open)
        menu.addItem(action("Show Log", #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WiFiHop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func togglePause() {
        prefs.paused.toggle()
        Log.write(prefs.paused ? "Paused" : "Resumed")
        refreshIcon()
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: settings)))
            window.title = "WiFiHop Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settings.rescan()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        Log.write("Settings opened")
    }
}

// MARK: command line

// `WiFiHop --survey` lists the saved networks in range and their signal.
if CommandLine.arguments.contains("--survey") {
    let wifi = WiFiService()
    let saved = wifi.savedSSIDs()
    let started = Date()
    let found = wifi.survey(saved)
    for (ssid, rssi) in found.sorted(by: { $0.value > $1.value }) {
        print("\(rssi) dBm  \(ssid)")
    }
    print(String(format: "%d of %d saved networks in range, %.1fs", found.count, saved.count, Date().timeIntervalSince(started)))
    exit(0)
}

// `WiFiHop --set-password <name>` stores a network's password read from
// standard input, as an alternative to the Settings window.
if let flag = CommandLine.arguments.firstIndex(of: "--set-password"), CommandLine.arguments.count > flag + 1 {
    let ssid = CommandLine.arguments[flag + 1]
    let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let password = input.trimmingCharacters(in: .newlines)
    guard !password.isEmpty, PasswordStore().set(password, for: ssid) else {
        print("Could not store a password for \(ssid)")
        exit(1)
    }
    print("Stored the password for \(ssid)")
    exit(0)
}

// `WiFiHop --join <name>` joins a network right away with its stored
// password, without waiting for the signal to drop.
if let flag = CommandLine.arguments.firstIndex(of: "--join"), CommandLine.arguments.count > flag + 1 {
    let ssid = CommandLine.arguments[flag + 1]
    guard let password = PasswordStore().get(ssid) else {
        print("No stored password for \(ssid)")
        exit(1)
    }
    do {
        try WiFiService().join(ssid, password: password)
        print("Joined \(ssid)")
        exit(0)
    } catch {
        print("Joining \(ssid) failed: \(error.localizedDescription)")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
