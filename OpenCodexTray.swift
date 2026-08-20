import AppKit
import ServiceManagement

// OpenCodex Tray — menu-bar switch for the OpenCodex proxy.
// All system logic lives in the bundled ocx-tray-ctl zsh script; this file only draws menus.

let ctlPath = Bundle.main.path(forResource: "ocx-tray-ctl", ofType: nil) ?? ""

/// Click-to-dismiss toast content: rounded card with a title and a detail line.
final class ToastView: NSView {
    let onClick: () -> Void
    init(width: CGFloat, height: CGFloat, title: String, text: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        let t = NSTextField(labelWithString: title)
        t.font = .boldSystemFont(ofSize: 13)
        t.frame = NSRect(x: 14, y: height - 30, width: width - 48, height: 18)
        addSubview(t)
        let close = NSButton(frame: NSRect(x: width - 28, y: height - 28, width: 20, height: 20))
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")
        close.contentTintColor = .tertiaryLabelColor
        close.target = self
        close.action = #selector(closeClicked)
        addSubview(close)
        let s = NSTextField(wrappingLabelWithString: text)
        s.font = .systemFont(ofSize: 11)
        s.textColor = .secondaryLabelColor
        s.frame = NSRect(x: 14, y: 10, width: width - 28, height: height - 44)
        s.isSelectable = false
        addSubview(s)
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    @objc private func closeClicked() { onClick() }
    override func mouseDown(with event: NSEvent) { onClick() }
}

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
    var shadowOn = false        // proxy's shadow-call intercept (Codex titles/summaries → gateway)
    var probeInFlight = false   // a shadow-probe ctl run is currently awaiting its answer
    var credits = ""            // gateway credit balance, e.g. "17.4157"; "" until fetched
    var toast: NSPanel? = nil   // floating notification card; stays up until clicked

    var keepAlive: Bool {
        get { defaults.object(forKey: "KeepProxyAlive") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "KeepProxyAlive") }
    }
    // standing instruction: route shadow calls to the gateway whenever the subscription is
    // limited, and back to the subscription when it recovers — the tray flips the intercept
    // both ways; the checkbox itself never changes on its own
    var shadowPolicy: Bool {
        get { defaults.object(forKey: "ShadowPolicy") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ShadowPolicy") }
    }
    var desiredOn: Bool {
        get { defaults.bool(forKey: "DesiredOn") }
        set { defaults.set(newValue, forKey: "DesiredOn") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Start at Login defaults to on: register once on first launch; the
        // Settings toggle (and System Settings) stay the source of truth after.
        if !defaults.bool(forKey: "DidDefaultLoginItem") {
            defaults.set(true, forKey: "DidDefaultLoginItem")
            if SMAppService.mainApp.status == .notRegistered {
                try? SMAppService.mainApp.register()
            }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        statusItem.menu = menu
        applyIcon()
        refresh()
        checkForUpdate()
        refreshCredits()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkForUpdate() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.shadowTick() }
        // Re-check right after the Mac wakes: a probe interrupted by sleep can leave the
        // intercept flipped without the tray ever hearing the answer, and the sub often
        // resets while the lid is closed. A short delay lets Wi-Fi come back first.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                self?.refresh()
                self?.shadowTick()
                self?.refreshCredits()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--test-toast") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.showToast("Subscription is back ✓",
                               "Shadow calls are on your ChatGPT plan again. Switch your Codex threads off the gateway when you're ready.")
            }
        }
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

    // MARK: shadow-call failover policy
    // "Gateway When Limited": while the subscription is healthy, shadow calls stay native and
    // the tray passively watches the request log for 429s; when they appear, the intercept is
    // flipped on. While the intercept is on, a tiny native probe every 30 min detects recovery
    // and flips it back off. A failed probe costs nothing (429); a success is one low-effort call.

    func shadowTick() {
        guard mode == "on", busy == nil else { return }
        run(["shadow-state"]) { out, _ in
            let believedOn = self.shadowOn
            self.shadowOn = (out == "on")
            guard self.shadowPolicy else { return }
            let now = Date().timeIntervalSince1970
            let lastProbe = self.defaults.double(forKey: "LastShadowProbe")
            if self.shadowOn {
                // probe every 30 min — OpenAI sometimes resets quota earlier than announced
                if now - lastProbe > 1800 && !self.probeInFlight {
                    self.shadowProbe(announceRecovery: true)
                }
            } else {
                // A probe that dies mid-flight (the Mac slept between lifting the intercept
                // and hearing the answer) leaves the intercept off without the tray ever
                // seeing "reverted". If we believed it was on and no probe of ours is
                // running, re-probe now: healthy → the missed "back ✓" toast; limited →
                // the intercept re-engages.
                if believedOn && !self.probeInFlight && now - lastProbe > 120 {
                    self.shadowProbe(announceRecovery: true)
                    return
                }
                self.defaults.removeObject(forKey: "ShadowResetsAt")
                // free log check every tick; a fresh native 429 means the sub just hit its limit
                run(["shadow-check"]) { chk, _ in
                    if chk == "limited" && now - lastProbe > 300 { self.shadowProbe() }
                }
            }
        }
    }

    /// announceRecovery: the tray believed the intercept was on when this probe was
    /// scheduled, so a healthy "ok" (intercept found already off) is still a recovery
    /// worth toasting — it means an earlier probe flipped it off but never reported back.
    func shadowProbe(announceRecovery: Bool = false) {
        probeInFlight = true
        defaults.set(Date().timeIntervalSince1970, forKey: "LastShadowProbe")
        run(["shadow-probe"]) { out, _ in
            self.probeInFlight = false
            if out == "reverted" || (out == "ok" && announceRecovery) {
                self.shadowOn = false
                self.defaults.removeObject(forKey: "ShadowResetsAt")
                self.showToast("Subscription is back ✓",
                               "Shadow calls are on your ChatGPT plan again. Switch your Codex threads off the gateway when you're ready.")
            } else if out == "ok" {
                // intercept already off and the subscription is healthy — nothing to do
                self.shadowOn = false
                self.defaults.removeObject(forKey: "ShadowResetsAt")
            } else if out.hasPrefix("limited") {
                let parts = out.components(separatedBy: " ")
                if parts.count > 1, let t = Double(parts[1]) {
                    self.defaults.set(t, forKey: "ShadowResetsAt")
                } else {
                    // no retry hint in the error — try again in 6 h
                    self.defaults.set(Date().timeIntervalSince1970 + 6 * 3600, forKey: "ShadowResetsAt")
                }
                if !self.shadowOn && self.shadowPolicy {
                    run(["shadow-on"]) { _, _ in
                        self.shadowOn = true
                        self.showToast("Subscription limited — shadow calls → gateway",
                                       "Codex background calls were hitting your ChatGPT usage limit, so they now use the gateway. They switch back automatically when your subscription recovers.")
                    }
                }
            } else {
                // inconclusive (proxy hiccup, 502 while the network comes up after wake,
                // interrupted run) — retry in ~2 min instead of waiting the full 30
                self.defaults.set(Date().timeIntervalSince1970 - 1800 + 120, forKey: "LastShadowProbe")
            }
        }
    }

    func shadowStatusLine() -> String {
        let t = defaults.double(forKey: "ShadowResetsAt")
        guard t > 0 else { return "Shadow calls → gateway · checking sub every 30 min" }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return "Shadow calls → gateway · sub resets \(f.string(from: Date(timeIntervalSince1970: t))) · checking every 30 min"
    }

    /// Floating card just under the menu-bar icon, above other windows; stays until clicked.
    func showToast(_ title: String, _ text: String) {
        toast?.close()
        let w: CGFloat = 340, h: CGFloat = 84
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.contentView = ToastView(width: w, height: h, title: title, text: text) { [weak self] in
            self?.toast?.close()
            self?.toast = nil
        }
        var x: CGFloat = 0, y: CGFloat = 0
        if let btnWindow = statusItem.button?.window {
            let f = btnWindow.frame
            x = f.midX - w / 2
            y = f.minY - h - 8
            if let screen = btnWindow.screen {
                x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - w - 8)
            }
        }
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        panel.orderFrontRegardless()
        toast = panel
    }

    @objc func toggleShadowPolicy() {
        shadowPolicy.toggle()
        if shadowPolicy {
            // decide immediately: probe once — limited engages the intercept, healthy leaves it off
            defaults.set(0.0, forKey: "LastShadowProbe")
            shadowProbe()
        } else {
            // policy off = shadow calls always on the subscription
            busy = "Shadow calls → subscription…"
            run(["shadow-off"]) { _, _ in
                self.busy = nil
                self.shadowOn = false
                self.defaults.removeObject(forKey: "ShadowResetsAt")
            }
        }
    }

    func checkForUpdate() {
        run(["check-update"]) { out, _ in
            self.latestVersion = out.components(separatedBy: "\n").last ?? ""
        }
    }

    /// Vercel AI Gateway credit balance; the ctl caches it ~30 min, so calling this on
    /// every menu open is one local file read most of the time.
    func refreshCredits() {
        run(["credits"]) { out, _ in
            self.credits = Double(out) != nil ? out : ""
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
        shadowTick()
        refreshCredits()
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
            if let bal = Double(credits) {
                addSmall(menu, String(format: "Gateway credits: $%.2f", bal))
            }
            if shadowOn { addSmall(menu, shadowStatusLine()) }
            menu.addItem(.separator())
            add(menu, "Turn Off (back to stock Codex)", #selector(turnOff))
            menu.addItem(.separator())
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
        addSettings(menu)
        menu.addItem(.separator())
        add(menu, "Quit", #selector(quitApp))
    }

    func addSettings(_ menu: NSMenu) {
        let sub = NSMenu()
        sub.autoenablesItems = false
        addLoginToggle(sub)
        let ka = add(sub, "Keep Proxy Alive", #selector(toggleKeepAlive))
        ka.state = keepAlive ? .on : .off
        if mode == "on" {
            let sc = add(sub, "Shadow Calls: Gateway When Limited", #selector(toggleShadowPolicy))
            sc.state = shadowPolicy ? .on : .off
        }
        sub.addItem(.separator())
        // version line: update action when npm has something newer, plain label otherwise
        if !latestVersion.isEmpty && !localVersion.isEmpty && latestVersion != localVersion {
            add(sub, "Update OpenCodex (\(localVersion) → \(latestVersion))", #selector(updateOCX))
        } else if !localVersion.isEmpty {
            addInfo(sub, "OpenCodex \(localVersion) — up to date")
        }
        add(sub, "Uninstall…", #selector(uninstallOCX))
        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.addItem(item)
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
