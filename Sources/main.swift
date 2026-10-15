import AppKit
import ServiceManagement

// macOS 27 draws every status item inside MenuBarAgent. Its "visibility restriction"
// (the mechanism behind exam/assessment mode) takes an allowlist of apps and system
// items; everything else disappears until the restriction is invalidated.
@objc private protocol VisibilityAssertion {
    @objc(activateWithConfiguration:completionHandler:)
    func activate(with configuration: AnyObject, completionHandler: @escaping (NSError?) -> Void)
    func invalidate()
}

private let restrictionAvailable: Bool =
    dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW) != nil
    && NSClassFromString("MBAssessmentModeConfiguration") != nil
    && NSClassFromString("MBAssessmentModeAssertion") != nil

private func restrict(allowedApps: [String], allowedSystemItems: [Int],
                      completion: @escaping (NSError?) -> Void) -> VisibilityAssertion? {
    guard restrictionAvailable,
          let configClass = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
          let assertionClass = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
          let allocated = (configClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
          let config = allocated.perform(NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:"),
                                         with: allowedSystemItems.map(NSNumber.init) as NSArray,
                                         with: allowedApps as NSArray)?.takeRetainedValue()
    else { return nil }
    let assertion = unsafeBitCast(assertionClass.init(), to: VisibilityAssertion.self)
    assertion.activate(with: config, completionHandler: completion)
    return assertion
}

// MBSystemItemIdentifier values, matched by the item's accessibility description.
// Clock (2) and Control Center (8) always stay.
private let systemItems: [(prefix: String, id: Int)] = [
    ("Battery", 0), ("Bluetooth", 1), ("Display", 3), ("Keyboard", 4),
    ("Sound", 5), ("Volume", 5), ("Wi‑Fi", 6), ("Wi-Fi", 6), ("Screen Mirroring", 7),
]

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}

private func children(_ element: AXUIElement, _ name: String = kAXChildrenAttribute) -> [AXUIElement] {
    attribute(element, name) as? [AXUIElement] ?? []
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private let ownID = Bundle.main.bundleIdentifier ?? "cm.chad.bartend"
    private var item: NSStatusItem!
    private var collapsed = true
    private var assertion: VisibilityAssertion?
    private var applied: [String]?

    // Remembered so apps that aren't running yet stay hidden when they launch.
    private var hiddenApps: Set<String> {
        get { Set(defaults.stringArray(forKey: "hiddenApps") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "hiddenApps") }
    }
    private var hiddenSystemItems: Set<Int> {
        get { Set(defaults.array(forKey: "hiddenSystemItems") as? [Int] ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "hiddenSystemItems") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // A newly launched app must join the allowlist, or its icon would vanish too.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appsChanged),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        if !AXIsProcessTrusted() { requestAccessibility() }
        apply()
        // Once the chevron has a place in the bar, pick up what sits left of it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.scan()
            self?.apply()
        }
    }

    @objc private func appsChanged() { apply() }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    @objc private func toggle() {
        if !AXIsProcessTrusted() { requestAccessibility() }
        if !collapsed { scan() }
        collapsed.toggle()
        apply()
    }

    /// Marks every icon left of the chevron as hidden and every icon right of it as shown.
    /// Icons not in the bar right now (already hidden, or app not running) keep their state.
    private func scan() {
        guard AXIsProcessTrusted(),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
        else { return }
        for window in children(AXUIElementCreateApplication(agent.processIdentifier), kAXWindowsAttribute) {
            var entries: [(x: CGFloat, app: String?, system: Int?)] = []
            for slot in children(window) {
                guard let content = children(slot).first, let value = attribute(slot, kAXPositionAttribute) else { continue }
                var origin = CGPoint.zero
                AXValueGetValue(value as! AXValue, .cgPoint, &origin)
                var pid: pid_t = 0
                AXUIElementGetPid(content, &pid)
                guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { continue }
                if id == "com.apple.MenuBarAgent" {
                    let label = (children(content).first.flatMap { attribute($0, kAXDescriptionAttribute) } as? String) ?? ""
                    entries.append((origin.x, nil, systemItems.first { label.hasPrefix($0.prefix) }?.id))
                } else {
                    entries.append((origin.x, id, nil))
                }
            }
            guard let chevron = entries.first(where: { $0.app == ownID })?.x else { continue }
            let left = entries.filter { $0.x < chevron }
            hiddenApps = hiddenApps.subtracting(entries.compactMap(\.app)).union(left.compactMap(\.app))
            hiddenSystemItems = hiddenSystemItems.subtracting(entries.compactMap(\.system)).union(left.compactMap(\.system))
            return
        }
    }

    private func apply() {
        let symbol = !restrictionAvailable ? "exclamationmark.triangle" : "ellipsis"
        item.button?.image = NSImage(systemSymbolName: symbol,
            accessibilityDescription: collapsed ? "Show hidden menu bar icons" : "Hide menu bar icons")
        item.button?.toolTip = "Click to \(collapsed ? "show" : "hide") icons · ⌘-drag icons left of this to hide them"

        guard collapsed, !(hiddenApps.isEmpty && hiddenSystemItems.isEmpty) else { return release() }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let allowedApps = running.subtracting(hiddenApps).union([ownID]).sorted()
        let allowedSystem = (0..<256).filter { !hiddenSystemItems.contains($0) }
        let key = allowedApps + hiddenSystemItems.sorted().map(String.init)
        guard key != applied else { return }

        // Replace the old assertion only once the new one is active, so nothing flashes.
        let old = assertion
        assertion = restrict(allowedApps: allowedApps, allowedSystemItems: allowedSystem) { error in
            DispatchQueue.main.async {
                if let error { NSLog("Bartend: restriction failed: \(error)") }
                old?.invalidate()
            }
        }
        applied = assertion == nil ? nil : key
        if assertion == nil { old?.invalidate() }
    }

    private func release() {
        assertion?.invalidate()
        assertion = nil
        applied = nil
    }

    // MARK: Menu

    private func showMenu() {
        let menu = NSMenu()
        if !restrictionAvailable {
            menu.addItem(withTitle: "Hiding needs macOS 27’s MenuBarAgent", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: collapsed ? "Show Hidden Icons" : "Hide Icons",
                         action: #selector(toggle), keyEquivalent: "").target = self
            menu.addItem(withTitle: "⌘-drag icons left of the chevron to hide them", action: nil, keyEquivalent: "")
            if !AXIsProcessTrusted() {
                menu.addItem(withTitle: "Allow Accessibility Access…",
                             action: #selector(requestAccessibility), keyEquivalent: "").target = self
            }
        }
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit Bartend", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // Opening Bartend again from Finder shows everything, in case the chevron is lost.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        collapsed = false
        apply()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { release() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
