import AppKit
import ServiceManagement

// OpenCodex Tray — menu-bar switch for the OpenCodex proxy.
// All system logic lives in the bundled ocx-tray-ctl zsh script; this file only draws menus.

let ctlPath = Bundle.main.path(forResource: "ocx-tray-ctl", ofType: nil) ?? ""

/// Run a ctl subcommand off the main thread; `done` is called back on the main thread.
func run(_ args: [String], done: @escaping (String, Int32) -> Void) {
    DispatchQueue.global().async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [ctlPath] + args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do { try p.run() } catch {
            DispatchQueue.main.async { done("", -1) }
            return
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let status = p.terminationStatus
        DispatchQueue.main.async { done(out, status) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    let defaults = UserDefaults.standard

    // last known state from `ocx-tray-ctl state`
    var mode = "off"            // on | broken | off | absent
    var localVersion = ""
    var routedCount = "0"
    var port = "10100"
    var latestVersion = ""

    var busy: String? = nil     // non-nil while a ctl command runs; shown at top of menu
    var fixAttempts = 0         // keep-alive backoff: stop after 3 failed restarts
    var warnedNoKey = false

    var keepAlive: Bool {
        get { defaults.object(forKey: "KeepProxyAlive") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "KeepProxyAlive") }
    }
    var desiredOn: Bool {
        get { defaults.bool(forKey: "DesiredOn") }
        set { defaults.set(newValue, forKey: "DesiredOn") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        statusItem.menu = menu
        applyIcon()
        refresh()
        checkForUpdate()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkForUpdate() }
    }

    // MARK: state

    func refresh() {
        run(["state"]) { out, _ in
            let lines = out.components(separatedBy: "\n")
            self.mode         = lines.count > 0 ? lines[0] : "off"
            self.localVersion = lines.count > 1 ? lines[1] : ""
            self.routedCount  = lines.count > 2 ? lines[2] : "0"
            self.port         = lines.count > 3 ? lines[3] : "10100"
            self.latestVersion = lines.count > 4 ? lines[4] : ""
            if self.mode == "on" {
                self.desiredOn = true
                self.fixAttempts = 0
            }
            self.applyIcon()
            // Keep Proxy Alive: restart a dead proxy while Codex config still points at it
            if self.keepAlive && self.desiredOn && self.mode == "broken"
                && self.busy == nil && self.fixAttempts < 3 {
                self.fixAttempts += 1
                self.startProxy(verb: "Restarting proxy…")
            }
        }
    }

    func checkForUpdate() {
        run(["check-update"]) { out, _ in
            self.latestVersion = out.components(separatedBy: "\n").last ?? ""
        }
    }

    func applyIcon() {
        let name: String
        switch mode {
        case "on":     name = "circle.fill"
        case "broken": name = "exclamationmark.triangle.fill"
        case "absent": name = "circle.dashed"
        default:       name = "circle"
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "OpenCodex")?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = "OCX"
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        populate(menu)
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    func addSmall(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        menu.addItem(item)
    }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        if let busy = busy {
            addInfo(menu, busy)
            menu.addItem(.separator())
        }

        switch mode {
        case "absent":
            addInfo(menu, "OpenCodex is not installed")
            menu.addItem(.separator())
            add(menu, "Install OpenCodex…", #selector(installOCX))
            menu.addItem(.separator())
            addLoginToggle(menu)
            menu.addItem(.separator())
            add(menu, "Quit", #selector(quitApp))
            return

        case "on":
            addInfo(menu, "● OpenCodex — On")
            addSmall(menu, "Routing \(routedCount) gateway models · port \(port)")
            menu.addItem(.separator())
            add(menu, "Turn Off (back to stock Codex)", #selector(turnOff))
            menu.addItem(.separator())
            add(menu, "Manage Models…", #selector(openModels))
            add(menu, "Request Log…", #selector(openLogs))
            add(menu, "Open Dashboard…", #selector(openDashboard))

        case "broken":
            addInfo(menu, "⚠ OpenCodex — proxy not responding")
            addSmall(menu, "Codex requests may fail until fixed")
            menu.addItem(.separator())
            add(menu, "Fix: Restart Proxy", #selector(fixProxy))
            add(menu, "Turn Off (back to stock Codex)", #selector(turnOff))

        default: // off
            addInfo(menu, "○ OpenCodex — Off (stock Codex)")
            menu.addItem(.separator())
            add(menu, "Turn On (route gateway models)", #selector(turnOn))
        }

        menu.addItem(.separator())
        addLoginToggle(menu)
        let ka = add(menu, "Keep Proxy Alive", #selector(toggleKeepAlive))
        ka.state = keepAlive ? .on : .off
        menu.addItem(.separator())

        // version line: update action when npm has something newer, plain label otherwise
        if !latestVersion.isEmpty && !localVersion.isEmpty && latestVersion != localVersion {
            add(menu, "Update OpenCodex (\(localVersion) → \(latestVersion))", #selector(updateOCX))
        } else if !localVersion.isEmpty {
            addInfo(menu, "OpenCodex \(localVersion) — up to date")
        }
        add(menu, "Uninstall…", #selector(uninstallOCX))
        menu.addItem(.separator())
        add(menu, "Quit", #selector(quitApp))
    }

    func addLoginToggle(_ menu: NSMenu) {
        let item = add(menu, "Start at Login", #selector(toggleLogin))
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: actions

    func startProxy(verb: String) {
        busy = verb
        run(["on"]) { out, code in
            self.busy = nil
            if out.contains("no-key") && !self.warnedNoKey {
                self.warnedNoKey = true
                self.alert("Gateway key not found",
                           "No VERCEL_AI_GATEWAY_KEY item in your login Keychain. The proxy is running and subscription models still work, but gateway models will fail until the key is added.")
            }
            if code != 0 {
                self.alert("Proxy didn't start",
                           "OpenCodex did not come up. Check ~/.opencodex/tray-proxy.log for details.")
            }
            self.refresh()
        }
    }

    @objc func turnOn() {
        desiredOn = true
        startProxy(verb: "Turning OpenCodex on…")
    }

    @objc func fixProxy() {
        fixAttempts = 0
        startProxy(verb: "Restarting proxy…")
    }

    @objc func turnOff() {
        desiredOn = false
        busy = "Turning off — restoring stock Codex…"
        run(["off"]) { _, _ in
            self.busy = nil
            self.refresh()
        }
    }

    func openURL(_ path: String) {
        if let url = URL(string: "http://127.0.0.1:\(port)/\(path)") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func openModels()    { openURL("#dashboard/models") }
    @objc func openLogs()      { openURL("#logs") }
    @objc func openDashboard() { openURL("#dashboard") }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            alert("Start at Login failed", error.localizedDescription)
        }
    }

    @objc func toggleKeepAlive() {
        keepAlive.toggle()
        fixAttempts = 0
    }

    @objc func updateOCX() {
        busy = "Updating OpenCodex…"
        run(["update"]) { out, code in
            self.busy = nil
            self.checkForUpdate()
            self.refresh()
            if code == 0 {
                self.alert("OpenCodex \(out.replacingOccurrences(of: "updated to ", with: ""))",
                           "Update finished. If Codex desktop is open, quit and reopen it to pick up the new version.")
            } else {
                self.alert("Update failed", out.isEmpty ? "Check ~/.opencodex/tray-proxy.log." : out)
            }
        }
    }

    @objc func installOCX() {
        busy = "Installing OpenCodex…"
        run(["install"]) { out, code in
            self.busy = nil
            self.refresh()
            if code == 0 {
                self.alert("OpenCodex installed", "Use “Turn On” to start routing gateway models.")
            } else {
                self.alert("Install failed", out.isEmpty ? "Check ~/.opencodex/tray-proxy.log." : out)
            }
        }
    }

    @objc func uninstallOCX() {
        let a = NSAlert()
        a.messageText = "Uninstall OpenCodex?"
        a.informativeText = "This turns the proxy off (restoring stock Codex) and removes the OpenCodex package. Your settings in ~/.opencodex are kept, so reinstalling later brings everything back."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        busy = "Uninstalling…"
        run(["uninstall"]) { out, code in
            self.busy = nil
            self.refresh()
            if code != 0 {
                self.alert("Uninstall failed", out.isEmpty ? "Check ~/.opencodex/tray-proxy.log." : out)
            }
        }
    }

    @objc func quitApp() {
        guard mode == "on" else { NSApp.terminate(nil); return }
        let a = NSAlert()
        a.messageText = "OpenCodex proxy is running"
        a.informativeText = "Leave it running and Codex keeps using your gateway models. Turn it off to go back to stock Codex."
        a.addButton(withTitle: "Leave Running & Quit")
        a.addButton(withTitle: "Turn Off & Quit")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            NSApp.terminate(nil)
        case .alertSecondButtonReturn:
            run(["off"]) { _, _ in NSApp.terminate(nil) }
        default:
            break
        }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
