// main.swift — menu bar app around the Spatialize engine.

import AppKit
import CoreAudio

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var engine: Spatializer?
    private var engineError: String?
    private var enabled = true
    private var restartPending = false

    private var targetIDs: [String] = {
        let d = UserDefaults.standard
        if let list = d.stringArray(forKey: "targetBundleIDs"), !list.isEmpty { return list }
        if let single = d.string(forKey: "targetBundleID") { return [single] }
        return ["com.spotify.client"]
    }() {
        didSet { UserDefaults.standard.set(targetIDs, forKey: "targetBundleIDs") }
    }
    private let supportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Spatialize")
    private var irURL: URL { supportDir.appendingPathComponent("irs.bin") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let symbol = NSImage(systemSymbolName: "airpods.pro", accessibilityDescription: "Spatialize")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Spatialize")
        statusItem.button?.image = symbol
        menu.delegate = self
        statusItem.menu = menu

        loadEngine()
        tryStart()

        // Keep-alive: reattach when Spotify (re)appears or its HAL processes change.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }

        // Rebuild when the default output device changes (e.g. AirPods connect).
        var defAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defAddr, .main) { [weak self] _, _ in
            self?.scheduleRestart()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
    }

    // MARK: - engine lifecycle

    private func loadEngine() {
        engine?.stop()
        engine = nil
        let url = FileManager.default.fileExists(atPath: irURL.path)
            ? irURL
            : Bundle.main.url(forResource: "irs", withExtension: "bin")
        guard let url, let data = try? Data(contentsOf: url) else {
            engineError = "No IR file. Use “Import IR File…” (see README to measure one)."
            return
        }
        do {
            engine = try Spatializer(irData: data)
            engineError = nil
        } catch {
            engineError = error.localizedDescription
        }
    }

    private func tryStart() {
        guard enabled, let engine, !engine.isRunning, !targetIDs.isEmpty else { return }
        do {
            try engine.start(bundleIDs: targetIDs)
            engineError = nil
        } catch {
            engineError = error.localizedDescription
        }
    }

    private func scheduleRestart() {
        guard !restartPending else { return }
        restartPending = true
        engine?.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.restartPending = false
            self?.tryStart()
        }
    }

    private func tick() {
        guard enabled, !restartPending else { return }
        if let engine, engine.isRunning {
            // App relaunches get fresh HAL process objects, and newly started target
            // apps need to be folded into the tap; both show up as a set difference.
            if Spatializer.audioProcesses(bundleIDs: targetIDs) != engine.tappedProcesses {
                scheduleRestart()
            }
        } else {
            tryStart()
        }
    }

    // MARK: - menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if let engine, engine.isRunning {
            status = "Spatializing \(targetNames()) → \(engine.deviceName)"
        } else if !enabled {
            status = "Paused"
        } else if targetIDs.isEmpty {
            status = "No target apps selected"
        } else {
            status = engineError ?? "Waiting for \(targetNames())…"
        }
        let statusLine = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: enabled ? "Pause" : "Resume",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let targets = NSMenuItem(title: "Target Apps", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let candidates = Set(Spatializer.runningAudioBundleIDs()).union(targetIDs)
            .filter { $0 != Bundle.main.bundleIdentifier && !$0.hasPrefix("com.apple.audio") }
        let entries = candidates
            .map { (id: $0, name: displayName($0)) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        for entry in entries {
            let item = NSMenuItem(title: entry.name, action: #selector(toggleTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            item.state = targetIDs.contains(entry.id) ? .on : .off
            sub.addItem(item)
        }
        if entries.isEmpty {
            let none = NSMenuItem(title: "No audio apps detected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        targets.submenu = sub
        menu.addItem(targets)

        let importItem = NSMenuItem(title: "Import IR File…", action: #selector(importIR), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Spatialize", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func displayName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? (bundleID == "com.spotify.client" ? "Spotify" : bundleID)
    }

    private func targetNames() -> String {
        targetIDs.map(displayName).joined(separator: ", ")
    }

    @objc private func toggleTarget(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if let idx = targetIDs.firstIndex(of: id) {
            targetIDs.remove(at: idx)
        } else {
            targetIDs.append(id)
        }
        if targetIDs.isEmpty {
            engine?.stop()
        } else {
            scheduleRestart()
        }
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        if enabled {
            tryStart()
        } else {
            engine?.stop()
        }
    }

    @objc private func importIR() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an irs.bin produced by extract-ir"
        guard panel.runModal() == .OK, let src = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: irURL.path) {
                try FileManager.default.removeItem(at: irURL)
            }
            try FileManager.default.copyItem(at: src, to: irURL)
            loadEngine()
            tryStart()
        } catch {
            engineError = "Import failed: \(error.localizedDescription)"
        }
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
