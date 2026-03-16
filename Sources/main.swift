import Cocoa
import Carbon.HIToolbox

// MARK: - Config
struct AppConfig: Codable {
    var modelPath: String
    var language: String
    var threads: Int
    var hotkey: String
    var useStreaming: Bool
    var streamStep: Int      // ms between transcription steps
    var streamLength: Int    // ms of audio context per step

    static let configURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/whisper-ptt")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    static let defaultConfig = AppConfig(
        modelPath: NSHomeDirectory() + "/.whisper-models/ggml-medium.bin",
        language: "zh",
        threads: 6,
        hotkey: "Ctrl+Option (⌃⌥)",
        useStreaming: true,
        streamStep: 3000,
        streamLength: 10000
    )

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return defaultConfig
        }
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(self) {
            try? data.write(to: AppConfig.configURL)
        }
    }
}

// MARK: - Model Scanner
struct WhisperModel {
    let name: String
    let path: String
}

func scanModels() -> [WhisperModel] {
    let modelDir = NSHomeDirectory() + "/.whisper-models"
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: modelDir) else { return [] }
    return files
        .filter { $0.hasPrefix("ggml-") && ($0.hasSuffix(".bin") || $0.hasSuffix(".gguf")) }
        .sorted()
        .map { WhisperModel(name: $0.replacingOccurrences(of: "ggml-", with: "")
                                    .replacingOccurrences(of: ".bin", with: "")
                                    .replacingOccurrences(of: ".gguf", with: ""),
                             path: modelDir + "/" + $0) }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var config = AppConfig.load()
    var isRecording = false
    // hotkey handled via flagsChanged monitor

    // Batch mode
    var recordProcess: Process?
    let wavPath = NSTemporaryDirectory() + "whisper-ptt-recording.wav"

    // Streaming mode
    var streamProcess: Process?
    var streamPipe: Pipe?
    var streamOutputFile: String = NSTemporaryDirectory() + "whisper-ptt-stream.txt"
    var accumulatedText = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        buildMenu()
        registerHotKey()

        if !FileManager.default.fileExists(atPath: AppConfig.configURL.path) {
            config.save()
        }
    }

    func updateIcon() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: isRecording ? "mic.fill" : "mic",
                                   accessibilityDescription: "Whisper PTT")
            button.contentTintColor = isRecording ? .systemRed : nil
        }
    }

    func buildMenu() {
        let menu = NSMenu()

        // Status
        let statusText = isRecording ? "🔴 Recording..." : "⏸ Ready"
        let si = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        si.isEnabled = false
        menu.addItem(si)

        menu.addItem(NSMenuItem.separator())

        // Toggle recording
        let toggleTitle = isRecording ? "⏹ Stop & Paste" : "🎙️ Start Recording"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleRecording), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        // Mode toggle
        let modeTitle = config.useStreaming ? "✅ Streaming Mode (real-time)" : "⬜ Streaming Mode (real-time)"
        let modeItem = NSMenuItem(title: modeTitle, action: #selector(toggleStreamingMode), keyEquivalent: "")
        modeItem.target = self
        menu.addItem(modeItem)

        let batchTitle = !config.useStreaming ? "✅ Batch Mode (record → transcribe)" : "⬜ Batch Mode (record → transcribe)"
        let batchItem = NSMenuItem(title: batchTitle, action: #selector(toggleStreamingMode), keyEquivalent: "")
        batchItem.target = self
        menu.addItem(batchItem)

        menu.addItem(NSMenuItem.separator())

        // Model selection
        let modelMenu = NSMenu()
        let models = scanModels()
        let currentModelName = (config.modelPath as NSString).lastPathComponent
        for model in models {
            let item = NSMenuItem(title: model.name, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.path
            let modelFile = (model.path as NSString).lastPathComponent
            if modelFile == currentModelName { item.state = .on }
            modelMenu.addItem(item)
        }
        if models.isEmpty {
            let noModel = NSMenuItem(title: "(no models in ~/.whisper-models/)", action: nil, keyEquivalent: "")
            noModel.isEnabled = false
            modelMenu.addItem(noModel)
        }
        modelMenu.addItem(NSMenuItem.separator())
        let downloadItem = NSMenuItem(title: "Download Models...", action: #selector(openModelDownload), keyEquivalent: "")
        downloadItem.target = self
        modelMenu.addItem(downloadItem)

        let modelMenuItem = NSMenuItem(title: "Model: \(currentModelName.replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(of: ".bin", with: ""))", action: nil, keyEquivalent: "")
        modelMenuItem.submenu = modelMenu
        menu.addItem(modelMenuItem)

        // Language selection
        let langMenu = NSMenu()
        let languages = [("zh", "中文 (+ English mix)"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"), ("auto", "Auto Detect")]
        for (code, label) in languages {
            let item = NSMenuItem(title: "\(label) [\(code)]", action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            if code == config.language { item.state = .on }
            langMenu.addItem(item)
        }
        let langMenuItem = NSMenuItem(title: "Language: \(config.language)", action: nil, keyEquivalent: "")
        langMenuItem.submenu = langMenu
        menu.addItem(langMenuItem)

        menu.addItem(NSMenuItem.separator())

        let hotkeyItem = NSMenuItem(title: "⌨️ Hotkey: \(config.hotkey)", action: nil, keyEquivalent: "")
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Whisper PTT", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    // MARK: - Toggle

    @objc func toggleRecording() {
        if isRecording {
            if config.useStreaming {
                stopStreaming()
            } else {
                stopBatchRecording()
            }
        } else {
            if config.useStreaming {
                startStreaming()
            } else {
                startBatchRecording()
            }
        }
    }

    // MARK: - Streaming Mode

    func startStreaming() {
        isRecording = true
        updateIcon()
        buildMenu()
        accumulatedText = ""

        NSSound(named: "Tink")?.play()

        // Remove old output file
        try? FileManager.default.removeItem(atPath: streamOutputFile)

        // Launch whisper-stream with file output
        guard let streamPath = findExecutable("whisper-stream") else {
            showNotification(title: "Whisper PTT", body: "❌ whisper-stream not found! Run: brew install whisper-cpp")
            isRecording = false
            updateIcon()
            buildMenu()
            return
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: streamPath)
        process.arguments = [
            "-m", config.modelPath,
            "-l", config.language,
            "-t", "\(config.threads)",
            "--step", "\(config.streamStep)",
            "--length", "\(config.streamLength)",
            "--keep-context",
            "-f", streamOutputFile
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // Read stdout in real-time for live preview
        streamPipe = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                // Filter out whisper-stream noise lines
                let lines = text.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && !trimmed.hasPrefix("[") && !trimmed.hasPrefix("whisper_") &&
                       !trimmed.contains("init:") && !trimmed.contains("main:") {
                        // Don't double-accumulate; file output is canonical
                    }
                }
            }
        }

        do {
            try process.run()
            streamProcess = process
            showNotification(title: "Whisper PTT", body: "🔴 Streaming... speak now")
        } catch {
            showNotification(title: "Whisper PTT", body: "❌ Failed to start whisper-stream")
            isRecording = false
            updateIcon()
            buildMenu()
        }
    }

    func stopStreaming() {
        isRecording = false
        updateIcon()
        NSSound(named: "Pop")?.play()

        // Stop whisper-stream
        streamPipe?.fileHandleForReading.readabilityHandler = nil
        streamProcess?.terminate()
        streamProcess?.waitUntilExit()
        streamProcess = nil
        streamPipe = nil

        usleep(300_000)

        // Read transcribed text from output file
        var finalText = ""
        if let content = try? String(contentsOfFile: streamOutputFile, encoding: .utf8) {
            finalText = content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("[") }
                .joined()
                .trimmingCharacters(in: .whitespaces)
        }

        if !finalText.isEmpty {
            pasteText(finalText)
            showNotification(title: "Whisper PTT", body: "✅ \(String(finalText.prefix(80)))")
        } else {
            showNotification(title: "Whisper PTT", body: "No speech detected")
        }

        buildMenu()
    }

    // MARK: - Batch Mode (original)

    func findExecutable(_ name: String) -> String? {
        let paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func startBatchRecording() {
        guard let soxPath = findExecutable("sox") else {
            showNotification(title: "Whisper PTT", body: "❌ sox not found! Run: brew install sox")
            return
        }

        isRecording = true
        updateIcon()
        buildMenu()

        NSSound(named: "Tink")?.play()
        try? FileManager.default.removeItem(atPath: wavPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: soxPath)
        process.arguments = ["-d", "-r", "16000", "-c", "1", "-b", "16", wavPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            recordProcess = process
        } catch {
            showNotification(title: "Whisper PTT", body: "❌ Failed to start recording: \(error.localizedDescription)")
            isRecording = false
            updateIcon()
            buildMenu()
        }
    }

    func stopBatchRecording() {
        isRecording = false
        updateIcon()
        NSSound(named: "Pop")?.play()

        recordProcess?.terminate()
        recordProcess?.waitUntilExit()
        recordProcess = nil

        usleep(300_000)

        let fm = FileManager.default
        guard fm.fileExists(atPath: wavPath),
              (try? fm.attributesOfItem(atPath: wavPath))?[.size] as? UInt64 ?? 0 > 0 else {
            showNotification(title: "Whisper PTT", body: "No audio recorded")
            buildMenu()
            return
        }

        showNotification(title: "Whisper PTT", body: "Transcribing...")

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = self.transcribeBatch()
            DispatchQueue.main.async {
                if let text = result, !text.isEmpty {
                    self.pasteText(text)
                    self.showNotification(title: "Whisper PTT", body: "✅ \(String(text.prefix(80)))")
                } else {
                    self.showNotification(title: "Whisper PTT", body: "No speech detected")
                }
                self.buildMenu()
            }
        }

        buildMenu()
    }

    func transcribeBatch() -> String? {
        guard let whisperPath = findExecutable("whisper-cli") else {
            DispatchQueue.main.async {
                self.showNotification(title: "Whisper PTT", body: "❌ whisper-cli not found! Run: brew install whisper-cpp")
            }
            return nil
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = [
            "-m", config.modelPath,
            "-l", config.language,
            "-t", "\(config.threads)",
            "--no-timestamps",
            "-f", wavPath
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
            .joined()
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Paste

    func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Global Hotkey (Ctrl+Option only, no extra key needed)

    var flagsMonitor: Any?

    func registerHotKey() {
        // Monitor modifier key changes globally
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let targetFlags: NSEvent.ModifierFlags = [.control, .option]

            // Trigger when exactly Ctrl+Option are pressed (no other modifiers)
            if flags == targetFlags {
                DispatchQueue.main.async {
                    self.toggleRecording()
                }
            }
        }
    }

    // MARK: - Menu Actions

    @objc func toggleStreamingMode() {
        config.useStreaming = !config.useStreaming
        config.save()
        buildMenu()
    }

    @objc func selectModel(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        config.modelPath = path
        config.save()
        buildMenu()
    }

    @objc func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        config.language = code
        config.save()
        buildMenu()
    }

    @objc func openModelDownload() {
        NSWorkspace.shared.open(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/tree/master")!)
    }

    @objc func quitApp() {
        if isRecording {
            streamProcess?.terminate()
            recordProcess?.terminate()
        }
        NSApplication.shared.terminate(nil)
    }

    func showNotification(title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \"\(body)\" with title \"\(title)\""]
        try? process.run()
    }
}

// MARK: - Main
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
