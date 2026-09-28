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
    private var measuring = false

    private var targetIDs: [String] = {
        let d = UserDefaults.standard
        if let list = d.stringArray(forKey: "targetBundleIDs"), !list.isEmpty { return list }
        if let single = d.string(forKey: "targetBundleID") { return [single] }
        return ["com.spotify.client"]
    }() {
        didSet { UserDefaults.standard.set(targetIDs, forKey: "targetBundleIDs") }
    }
    private var useBuiltInMic = UserDefaults.standard.object(forKey: "useBuiltInMic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useBuiltInMic, forKey: "useBuiltInMic") }
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

        // Keep-alive: reattach when target apps (re)appear or their HAL processes change.
        // .common mode so it keeps firing while the status menu is open.
        let keepAlive = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(keepAlive, forMode: .common)

        // Rebuild when the default output device changes (e.g. AirPods connect).
        var defAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defAddr, .main) { [weak self] _, _ in
            self?.scheduleRestart()
        }

        // macOS makes AirPods the default input when they connect, which forces call mode.
        var inAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inAddr, .main) { [weak self] _, _ in
            self?.enforceBuiltInMic()
        }
        enforceBuiltInMic()

        if engine == nil { measure() }
    }

    private func enforceBuiltInMic() {
        // The output's format changes when it leaves call mode, so rebuild the graph.
        if useBuiltInMic, moveDefaultInputOffBluetooth() { scheduleRestart() }
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
            engineError = "Not measured yet"
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
        guard enabled, !measuring, let engine, !engine.isRunning, !targetIDs.isEmpty else { return }
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
        if measuring {
            status = "Measuring…"
        } else if let engine, engine.isRunning {
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

        let mic = NSMenuItem(title: "Use Built-in Mic", action: #selector(toggleBuiltInMic), keyEquivalent: "")
        mic.target = self
        mic.state = useBuiltInMic ? .on : .off
        menu.addItem(mic)

        let measureItem = NSMenuItem(title: "Measure Spatial Audio…", action: #selector(measure), keyEquivalent: "")
        measureItem.target = self
        menu.addItem(measureItem)

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

    @objc private func toggleBuiltInMic() {
        useBuiltInMic.toggle()
        enforceBuiltInMic()
    }

    @objc private func measure() {
        Task { @MainActor in await runMeasurement() }
    }

    @MainActor private func runMeasurement() async {
        guard !measuring else { return }
        measuring = true
        engine?.stop()
        defer {
            measuring = false
            tryStart()
        }

        let movie = FileManager.default.temporaryDirectory.appendingPathComponent("spatialize-sweep.mov")
        do {
            try await Task.detached { try writeSweepMovie(to: movie) }.value
        } catch {
            return showMeasurementError(error)
        }
        // Playing makes Spatialize Stereo show up for this app in Control Center; the throwaway
        // tap raises the audio-capture permission prompt now instead of mid-measurement.
        let setup = try? launchSweepPlayer(movie, ["--setup"])
        _ = try? ProcessRecorder(audioProcess(pid: getpid()), frames: 1)
        let alert = NSAlert()
        alert.messageText = "Set Spatialize Stereo to Fixed"
        alert.informativeText = "Put your AirPods on and pause other audio. While this test sound plays, open Control Center → Sound and set Spatialize Stereo to Fixed for your AirPods."
        alert.addButton(withTitle: "Measure")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        let proceed = alert.runModal() == .alertFirstButtonReturn
        setup?.terminate()
        guard proceed else { return }

        do {
            let progress = showProgress(seconds: 2 + 2 * (passSeconds + 0.5))
            defer { progress.close() }
            try await Task.sleep(for: .seconds(2))  // switching the mode briefly reconfigures the output
            let fixed = try await recordPass(movie: movie, spatialize: true)
            let off = try await recordPass(movie: movie, spatialize: false)
            let irs = try extractIR(fixed: fixed, off: off)
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try irs.write(to: irURL)
            loadEngine()
            NSSound(named: "Glass")?.play()  // the passes are silent, so mark the end
        } catch {
            showMeasurementError(error)
        }
    }

    /// Time-based, since the passes are silent and run a fixed length.
    private func showProgress(seconds: Double) -> NSWindow {
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 20, width: 300, height: 20))
        bar.isIndeterminate = false
        bar.maxValue = seconds
        bar.setAccessibilityLabel("Measuring Spatial Audio")
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 60),
                            styleMask: .titled, backing: .buffered, defer: false)
        panel.title = "Measuring Spatial Audio"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false  // panels hide by default once focus returns to another app
        panel.level = .floating
        panel.contentView?.addSubview(bar)
        panel.center()
        panel.orderFrontRegardless()
        let start = Date()
        let ticker = Timer(timeInterval: 0.2, repeats: true) { [weak panel] timer in
            guard let panel, panel.isVisible else { return timer.invalidate() }
            bar.doubleValue = Date().timeIntervalSince(start)
        }
        RunLoop.main.add(ticker, forMode: .common)
        return panel
    }

    private func showMeasurementError(_ error: Error) {
        let failed = NSAlert()
        failed.messageText = "Measurement failed"
        failed.informativeText = error.localizedDescription
        NSApp.activate()
        failed.runModal()
    }
}

if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--play-sweep" {
    runSweepPlayer(Array(CommandLine.arguments.dropFirst(2)))
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
