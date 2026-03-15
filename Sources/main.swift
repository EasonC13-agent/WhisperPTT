import Cocoa
import Carbon.HIToolbox

// MARK: - Config
struct AppConfig: Codable {
    var modelPath: String
    var language: String
    var threads: Int
    var hotkey: String  // display only, actual binding is in code

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
        hotkey: "Ctrl+Option+Space"
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
    var recordProcess: Process?
    let wavPath = NSTemporaryDirectory() + "whisper-ptt-recording.wav"
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        buildMenu()

        // Register global hotkey: Ctrl+Shift+Space
        registerHotKey()

        // Save default config if none exists
        if !FileManager.default.fileExists(atPath: AppConfig.configURL.path) {
            config.save()
        }
    }

    func updateIcon() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: isRecording ? "mic.fill" : "mic",
                                   accessibilityDescription: "Whisper PTT")
            // Tint red when recording
            if isRecording {
                button.contentTintColor = .systemRed
            } else {
                button.contentTintColor = nil
            }
        }
    }

    func buildMenu() {
        let menu = NSMenu()

        // Status
        let statusText = isRecording ? "🔴 Recording..." : "⏸ Ready"
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Toggle recording
        let toggleTitle = isRecording ? "⏹ Stop & Transcribe" : "🎙️ Start Recording"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleRecording), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

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
            if modelFile == currentModelName {
                item.state = .on
            }
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

        // Hotkey info
        let hotkeyItem = NSMenuItem(title: "⌨️ Hotkey: \(config.hotkey)", action: nil, keyEquivalent: "")
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Whisper PTT", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    // MARK: - Recording

    @objc func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        isRecording = true
        updateIcon()
        buildMenu()

        // Play start sound
        NSSound(named: "Tink")?.play()

        // Remove old recording
        try? FileManager.default.removeItem(atPath: wavPath)

        // Start sox recording
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sox")
        process.arguments = ["-d", "-r", "16000", "-c", "1", "-b", "16", wavPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        recordProcess = process
    }

    func stopRecording() {
        isRecording = false
        updateIcon()

        // Play stop sound
        NSSound(named: "Pop")?.play()

        // Stop sox
        recordProcess?.terminate()
        recordProcess?.waitUntilExit()
        recordProcess = nil

        // Small delay for file flush
        usleep(300_000)

        let fm = FileManager.default
        guard fm.fileExists(atPath: wavPath),
              (try? fm.attributesOfItem(atPath: wavPath))?[.size] as? UInt64 ?? 0 > 0 else {
            showNotification(title: "Whisper PTT", body: "No audio recorded")
            buildMenu()
            return
        }

        showNotification(title: "Whisper PTT", body: "Transcribing...")

        // Run whisper in background
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = self.transcribe()
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

    func transcribe() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
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
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        let text = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
            .joined()
            .trimmingCharacters(in: .whitespaces)

        return text
    }

    func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)  // V key
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Global Hotkey (Ctrl+Shift+Space)

    func registerHotKey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x57505454)  // 'WPTT'
        hotKeyID.id = 1

        // Ctrl+Option+Space: modifiers = controlKey | optionKey, keycode = 49 (space)
        let modifiers: UInt32 = UInt32(controlKey | optionKey)
        let keyCode: UInt32 = 49  // space

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        }

        // Install handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            let appDelegate = NSApplication.shared.delegate as! AppDelegate
            DispatchQueue.main.async {
                appDelegate.toggleRecording()
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    // MARK: - Menu Actions

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
        // Open HuggingFace whisper.cpp models page
        NSWorkspace.shared.open(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/tree/master")!)
    }

    @objc func quitApp() {
        if isRecording {
            recordProcess?.terminate()
        }
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Notifications

    func showNotification(title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \"\(body)\" with title \"\(title)\""]
        try? process.run()
    }
}

// MARK: - Main
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Menu bar only, no dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
