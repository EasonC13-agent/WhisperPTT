import Cocoa
import Carbon.HIToolbox

// MARK: - Config
struct AppConfig: Codable {
    var modelPath: String
    var language: String
    var threads: Int
    var hotkey: String
    var useStreaming: Bool
    var streamStep: Int
    var streamLength: Int
    var setupDone: Bool

    static let configURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/whisper-ptt")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    static let defaultConfig = AppConfig(
        modelPath: NSHomeDirectory() + "/.whisper-models/ggml-base.bin",
        language: "zh",
        threads: 6,
        hotkey: "Ctrl+Option (⌃⌥)",
        useStreaming: true,
        streamStep: 3000,
        streamLength: 10000,
        setupDone: false
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

// MARK: - Available Models for Download
struct DownloadableModel {
    let name: String
    let file: String
    let size: String
    let description: String
    let url: String
}

let availableModels: [DownloadableModel] = [
    DownloadableModel(name: "base", file: "ggml-base.bin",
                      size: "142 MB", description: "Fast, good for English",
                      url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"),
    DownloadableModel(name: "small", file: "ggml-small.bin",
                      size: "466 MB", description: "Balanced speed/accuracy",
                      url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"),
    DownloadableModel(name: "medium", file: "ggml-medium.bin",
                      size: "1.5 GB", description: "Great for 中英混合",
                      url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"),
    DownloadableModel(name: "large-v3-turbo", file: "ggml-large-v3-turbo.bin",
                      size: "1.6 GB", description: "Best accuracy, slower",
                      url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"),
]

// MARK: - Model Scanner
struct WhisperModel {
    let name: String
    let path: String
    let sizeStr: String
}

func modelDir() -> String {
    return NSHomeDirectory() + "/.whisper-models"
}

func scanModels() -> [WhisperModel] {
    let dir = modelDir()
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    return files
        .filter { $0.hasPrefix("ggml-") && ($0.hasSuffix(".bin") || $0.hasSuffix(".gguf")) }
        .sorted()
        .compactMap { file -> WhisperModel? in
            let path = dir + "/" + file
            let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? UInt64 ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            let name = file.replacingOccurrences(of: "ggml-", with: "")
                           .replacingOccurrences(of: ".bin", with: "")
                           .replacingOccurrences(of: ".gguf", with: "")
            return WhisperModel(name: name, path: path, sizeStr: sizeStr)
        }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var config = AppConfig.load()
    var isRecording = false
    var isDownloading = false
    var downloadProgress = ""

    // Batch mode
    var recordProcess: Process?
    let wavPath = NSTemporaryDirectory() + "whisper-ptt-recording.wav"

    // Streaming mode
    var streamProcess: Process?
    var streamPipe: Pipe?
    var streamOutputFile: String = NSTemporaryDirectory() + "whisper-ptt-stream.txt"
    var accumulatedText = ""

    // Download
    var downloadTask: URLSessionDownloadTask?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        buildMenu()
        registerHotKey()

        log("App launched")

        // First run setup
        if !config.setupDone {
            log("First run — starting setup")
            firstRunSetup()
        } else if !FileManager.default.fileExists(atPath: config.modelPath) {
            // Model was deleted or path changed
            let models = scanModels()
            if let first = models.first {
                config.modelPath = first.path
                config.save()
                log("Model path updated to: \(first.path)")
            } else {
                showSetupAlert()
            }
        }
    }

    // MARK: - First Run Setup

    func firstRunSetup() {
        // Check for Homebrew
        let hasBrew = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") ||
                      FileManager.default.isExecutableFile(atPath: "/usr/local/bin/brew")

        if !hasBrew {
            let alert = NSAlert()
            alert.messageText = "🍺 Homebrew Required"
            alert.informativeText = "Whisper PTT needs Homebrew to install dependencies.\n\nInstall Homebrew first:\n/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"\n\nThen relaunch this app."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Open Homebrew Website")
            alert.addButton(withTitle: "Quit")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            }
            NSApplication.shared.terminate(nil)
            return
        }

        // Check/install dependencies
        let missingDeps = checkDependencies()
        if !missingDeps.isEmpty {
            let alert = NSAlert()
            alert.messageText = "📦 Installing Dependencies"
            alert.informativeText = "Whisper PTT needs: \(missingDeps.joined(separator: ", "))\n\nThis will run:\nbrew install \(missingDeps.joined(separator: " "))\n\nThis may take a few minutes."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                installDependencies(missingDeps)
            } else {
                NSApplication.shared.terminate(nil)
                return
            }
        }

        // Check for models
        let models = scanModels()
        if models.isEmpty {
            showSetupAlert()
        } else {
            config.modelPath = models.first!.path
            config.setupDone = true
            config.save()
            buildMenu()
            showNotification(title: "Whisper PTT", body: "✅ Ready! Press Ctrl+Option to start")
        }
    }

    func checkDependencies() -> [String] {
        var missing: [String] = []
        if findExecutable("whisper-cli") == nil { missing.append("whisper-cpp") }
        if findExecutable("sox") == nil { missing.append("sox") }
        return missing
    }

    func installDependencies(_ deps: [String]) {
        let brewPath = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew")
            ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"

        log("Installing: \(deps.joined(separator: ", ")) using \(brewPath)")
        showNotification(title: "Whisper PTT", body: "⏳ Installing \(deps.joined(separator: ", "))...")

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: brewPath)
            process.arguments = ["install"] + deps
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Ensure brew can find its deps
            var env = ProcessInfo.processInfo.environment
            let brewBin = (brewPath as NSString).deletingLastPathComponent
            if let path = env["PATH"] {
                env["PATH"] = "\(brewBin):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(path)"
            } else {
                env["PATH"] = "\(brewBin):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            }
            process.environment = env

            do {
                try process.run()
                process.waitUntilExit()

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""

                if !stdout.isEmpty { self.log("brew stdout: \(stdout.prefix(500))") }
                if !stderr.isEmpty { self.log("brew stderr: \(stderr.prefix(500))") }

                if process.terminationStatus == 0 {
                    self.log("Dependencies installed successfully")
                    DispatchQueue.main.async {
                        self.showNotification(title: "Whisper PTT", body: "✅ Dependencies installed!")
                        let models = scanModels()
                        if models.isEmpty {
                            self.showSetupAlert()
                        } else {
                            self.config.modelPath = models.first!.path
                            self.config.setupDone = true
                            self.config.save()
                            self.buildMenu()
                        }
                    }
                } else {
                    self.log("brew install failed (code \(process.terminationStatus)): \(stderr.prefix(300))")
                    DispatchQueue.main.async {
                        // If it failed but the tools exist now (e.g. already installed warning), continue
                        let stillMissing = self.checkDependencies()
                        if stillMissing.isEmpty {
                            self.log("Dependencies already present despite brew error — continuing")
                            let models = scanModels()
                            if models.isEmpty {
                                self.showSetupAlert()
                            } else {
                                self.config.modelPath = models.first!.path
                                self.config.setupDone = true
                                self.config.save()
                                self.buildMenu()
                            }
                        } else {
                            self.showNotification(title: "Whisper PTT", body: "❌ brew install failed. Run manually: brew install \(deps.joined(separator: " "))")
                        }
                    }
                }
            } catch {
                self.log("ERROR running brew: \(error)")
            }
        }
    }

    func showSetupAlert() {
        let alert = NSAlert()
        alert.messageText = "🧠 Download a Whisper Model"
        alert.informativeText = "Choose a model to download. You can change or add more later from the menu bar.\n\n• base (142 MB) — Fast, good for English\n• small (466 MB) — Balanced\n• medium (1.5 GB) — Great for 中英混合 ⭐\n• large-v3-turbo (1.6 GB) — Best accuracy"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "base (142 MB) — Fastest")
        alert.addButton(withTitle: "medium (1.5 GB) — Recommended")
        alert.addButton(withTitle: "Skip (I'll add manually)")

        let response = alert.runModal()
        var modelToDownload: DownloadableModel?

        switch response {
        case .alertFirstButtonReturn:
            modelToDownload = availableModels.first { $0.name == "base" }
        case .alertSecondButtonReturn:
            modelToDownload = availableModels.first { $0.name == "medium" }
        default:
            config.setupDone = true
            config.save()
            return
        }

        if let model = modelToDownload {
            downloadModel(model, isSetup: true)
        }
    }

    // MARK: - Model Download

    func downloadModel(_ model: DownloadableModel, isSetup: Bool = false) {
        guard !isDownloading else {
            showNotification(title: "Whisper PTT", body: "⏳ Already downloading...")
            return
        }

        isDownloading = true
        downloadProgress = "Starting..."
        buildMenu()
        log("Downloading model: \(model.name) from \(model.url)")
        showNotification(title: "Whisper PTT", body: "⬇️ Downloading \(model.name) (\(model.size))...")

        let dir = modelDir()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let destPath = dir + "/" + model.file

        guard let url = URL(string: model.url) else { return }

        let session = URLSession(configuration: .default, delegate: DownloadDelegate(appDelegate: self, destPath: destPath, modelName: model.name, isSetup: isSetup), delegateQueue: nil)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    func downloadCompleted(modelName: String, destPath: String, isSetup: Bool) {
        isDownloading = false
        log("Model \(modelName) downloaded to \(destPath)")
        config.modelPath = destPath
        if isSetup { config.setupDone = true }
        config.save()
        buildMenu()
        showNotification(title: "Whisper PTT", body: "✅ Model \(modelName) ready! Press Ctrl+Option to start")
    }

    func downloadFailed(modelName: String, error: String) {
        isDownloading = false
        log("Download failed for \(modelName): \(error)")
        buildMenu()
        showNotification(title: "Whisper PTT", body: "❌ Download failed: \(error)")
    }

    // MARK: - Logging
    let logFile: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/whisper-ptt")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("whisper-ptt.log")
    }()

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        print(line, terminator: "")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    func updateIcon() {
        if let button = statusItem.button {
            let symbolName: String
            if isDownloading {
                symbolName = "arrow.down.circle"
            } else if isRecording {
                symbolName = "mic.fill"
            } else {
                symbolName = "mic"
            }
            button.image = NSImage(systemSymbolName: symbolName,
                                   accessibilityDescription: "Whisper PTT")
            if isRecording {
                button.contentTintColor = .systemRed
            } else if isDownloading {
                button.contentTintColor = .systemBlue
            } else {
                button.contentTintColor = nil
            }
        }
    }

    // MARK: - Menu

    func buildMenu() {
        let menu = NSMenu()

        // Status
        let statusText: String
        if isDownloading {
            statusText = "⬇️ Downloading... \(downloadProgress)"
        } else if isRecording {
            statusText = "🔴 Recording..."
        } else {
            statusText = "⏸ Ready"
        }
        let si = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        si.isEnabled = false
        menu.addItem(si)

        menu.addItem(NSMenuItem.separator())

        // Toggle recording
        if !isDownloading {
            let toggleTitle = isRecording ? "⏹ Stop & Paste" : "🎙️ Start Recording"
            let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleRecording), keyEquivalent: "")
            toggleItem.target = self
            menu.addItem(toggleItem)

            menu.addItem(NSMenuItem.separator())
        }

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

        // Model section
        let modelMenu = NSMenu()

        // Installed models
        let models = scanModels()
        let currentModelName = (config.modelPath as NSString).lastPathComponent
        if !models.isEmpty {
            let installedHeader = NSMenuItem(title: "── Installed ──", action: nil, keyEquivalent: "")
            installedHeader.isEnabled = false
            modelMenu.addItem(installedHeader)

            for model in models {
                let item = NSMenuItem(title: "\(model.name) (\(model.sizeStr))", action: #selector(selectModel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = model.path
                let modelFile = (model.path as NSString).lastPathComponent
                if modelFile == currentModelName { item.state = .on }
                modelMenu.addItem(item)
            }

            // Delete submenu
            modelMenu.addItem(NSMenuItem.separator())
            let deleteMenu = NSMenu()
            for model in models {
                let item = NSMenuItem(title: "🗑 \(model.name) (\(model.sizeStr))", action: #selector(deleteModel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = model.path
                deleteMenu.addItem(item)
            }
            let deleteItem = NSMenuItem(title: "Delete Model...", action: nil, keyEquivalent: "")
            deleteItem.submenu = deleteMenu
            modelMenu.addItem(deleteItem)
        }

        // Download section
        modelMenu.addItem(NSMenuItem.separator())
        let dlHeader = NSMenuItem(title: "── Download ──", action: nil, keyEquivalent: "")
        dlHeader.isEnabled = false
        modelMenu.addItem(dlHeader)

        let installedFiles = Set(models.map { ($0.path as NSString).lastPathComponent })
        for dm in availableModels {
            if installedFiles.contains(dm.file) { continue }  // Skip already installed
            let item = NSMenuItem(title: "⬇️ \(dm.name) (\(dm.size)) — \(dm.description)",
                                  action: #selector(downloadModelAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dm.name
            item.isEnabled = !isDownloading
            modelMenu.addItem(item)
        }

        if installedFiles.count == availableModels.count {
            let allDone = NSMenuItem(title: "All models installed ✅", action: nil, keyEquivalent: "")
            allDone.isEnabled = false
            modelMenu.addItem(allDone)
        }

        let currentDisplay = currentModelName
            .replacingOccurrences(of: "ggml-", with: "")
            .replacingOccurrences(of: ".bin", with: "")
        let modelMenuItem = NSMenuItem(title: "Model: \(currentDisplay)", action: nil, keyEquivalent: "")
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

        // Log
        let logItem = NSMenuItem(title: "View Log...", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        let quitItem = NSMenuItem(title: "Quit Whisper PTT", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    // MARK: - Toggle

    @objc func toggleRecording() {
        if isDownloading { return }
        if isRecording {
            if config.useStreaming { stopStreaming() } else { stopBatchRecording() }
        } else {
            if config.useStreaming { startStreaming() } else { startBatchRecording() }
        }
    }

    // MARK: - Streaming Mode

    func startStreaming() {
        guard let streamPath = findExecutable("whisper-stream") else {
            log("ERROR: whisper-stream not found")
            showNotification(title: "Whisper PTT", body: "❌ whisper-stream not found! Run: brew install whisper-cpp")
            return
        }
        if !FileManager.default.fileExists(atPath: config.modelPath) {
            log("ERROR: model not found at \(config.modelPath)")
            showNotification(title: "Whisper PTT", body: "❌ No model! Download one from the menu bar")
            return
        }

        isRecording = true
        updateIcon()
        buildMenu()
        accumulatedText = ""
        NSSound(named: "Tink")?.play()
        try? FileManager.default.removeItem(atPath: streamOutputFile)

        log("Starting streaming: \(streamPath) model=\(config.modelPath)")

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

        streamPipe = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let _ = handle.availableData  // drain stdout
        }

        // Capture stderr from whisper-stream for debugging
        let errPipe = Pipe()
        process.standardError = errPipe

        // Watch for unexpected termination
        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                if self.isRecording {
                    self.log("whisper-stream died unexpectedly (code \(proc.terminationStatus)): \(stderr.prefix(500))")
                    self.isRecording = false
                    self.updateIcon()
                    self.buildMenu()
                    self.showNotification(title: "Whisper PTT", body: "❌ whisper-stream crashed. Check mic permissions in System Settings!")
                }
            }
        }

        do {
            try process.run()
            streamProcess = process
            log("whisper-stream PID: \(process.processIdentifier)")
            showNotification(title: "Whisper PTT", body: "🔴 Streaming... speak now")
        } catch {
            log("ERROR: \(error)")
            showNotification(title: "Whisper PTT", body: "❌ Failed: \(error.localizedDescription)")
            isRecording = false
            updateIcon()
            buildMenu()
        }
    }

    func stopStreaming() {
        isRecording = false
        updateIcon()
        NSSound(named: "Pop")?.play()

        streamPipe?.fileHandleForReading.readabilityHandler = nil
        streamProcess?.terminate()
        streamProcess?.waitUntilExit()
        streamProcess = nil
        streamPipe = nil
        usleep(300_000)

        var finalText = ""
        if let content = try? String(contentsOfFile: streamOutputFile, encoding: .utf8) {
            finalText = content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("[") }
                .joined()
                .trimmingCharacters(in: .whitespaces)
        }

        log("Streaming result: \(finalText.prefix(100))")
        if !finalText.isEmpty {
            pasteText(finalText)
            showNotification(title: "Whisper PTT", body: "✅ \(String(finalText.prefix(80)))")
        } else {
            showNotification(title: "Whisper PTT", body: "No speech detected")
        }
        buildMenu()
    }

    // MARK: - Batch Mode

    func findExecutable(_ name: String) -> String? {
        let paths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func startBatchRecording() {
        guard let soxPath = findExecutable("sox") else {
            log("ERROR: sox not found")
            showNotification(title: "Whisper PTT", body: "❌ sox not found! Run: brew install sox")
            return
        }
        if !FileManager.default.fileExists(atPath: config.modelPath) {
            log("ERROR: model not found")
            showNotification(title: "Whisper PTT", body: "❌ No model! Download one from the menu bar")
            return
        }

        log("Starting batch recording: \(soxPath)")
        isRecording = true
        updateIcon()
        buildMenu()
        NSSound(named: "Tink")?.play()
        try? FileManager.default.removeItem(atPath: wavPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: soxPath)
        process.arguments = ["-d", "-r", "16000", "-c", "1", "-b", "16", wavPath]
        process.standardOutput = FileHandle.nullDevice
        let soxErrPipe = Pipe()
        process.standardError = soxErrPipe

        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            let errData = soxErrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                if self.isRecording {
                    self.log("sox died unexpectedly (code \(proc.terminationStatus)): \(stderr.prefix(500))")
                    self.isRecording = false
                    self.updateIcon()
                    self.buildMenu()
                    self.showNotification(title: "Whisper PTT", body: "❌ Recording failed. Check mic permissions!")
                }
            }
        }

        do {
            try process.run()
            recordProcess = process
        } catch {
            log("ERROR: \(error)")
            showNotification(title: "Whisper PTT", body: "❌ Recording failed: \(error.localizedDescription)")
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

        showNotification(title: "Whisper PTT", body: "⏳ Transcribing...")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = self.transcribeBatch()
            DispatchQueue.main.async {
                if let text = result, !text.isEmpty {
                    self.log("Batch result: \(text.prefix(100))")
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
            log("ERROR: whisper-cli not found")
            return nil
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = ["-m", config.modelPath, "-l", config.language,
                             "-t", "\(config.threads)", "--no-timestamps", "-f", wavPath]
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

    // MARK: - Global Hotkey (Ctrl+Option)

    var flagsMonitor: Any?

    func registerHotKey() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let targetFlags: NSEvent.ModifierFlags = [.control, .option]
            if flags == targetFlags {
                DispatchQueue.main.async { self.toggleRecording() }
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
        log("Model changed to: \(path)")
        buildMenu()
    }

    @objc func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        config.language = code
        config.save()
        buildMenu()
    }

    @objc func downloadModelAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let model = availableModels.first(where: { $0.name == name }) else { return }
        downloadModel(model)
    }

    @objc func deleteModel(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let name = (path as NSString).lastPathComponent

        let alert = NSAlert()
        alert.messageText = "Delete \(name)?"
        alert.informativeText = "This will free up disk space. You can re-download anytime."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            try? FileManager.default.removeItem(atPath: path)
            log("Deleted model: \(path)")

            // If deleted the current model, switch to another
            if config.modelPath == path {
                let remaining = scanModels()
                config.modelPath = remaining.first?.path ?? AppConfig.defaultConfig.modelPath
                config.save()
            }
            buildMenu()
            showNotification(title: "Whisper PTT", body: "🗑 Deleted \(name)")
        }
    }

    @objc func openLog() {
        NSWorkspace.shared.open(logFile)
    }

    @objc func quitApp() {
        if isRecording {
            streamProcess?.terminate()
            recordProcess?.terminate()
        }
        downloadTask?.cancel()
        NSApplication.shared.terminate(nil)
    }

    func showNotification(title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \"\(body)\" with title \"\(title)\""]
        try? process.run()
    }
}

// MARK: - Download Delegate
class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let appDelegate: AppDelegate
    let destPath: String
    let modelName: String
    let isSetup: Bool

    init(appDelegate: AppDelegate, destPath: String, modelName: String, isSetup: Bool) {
        self.appDelegate = appDelegate
        self.destPath = destPath
        self.modelName = modelName
        self.isSetup = isSetup
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            // Remove existing file if any
            try? FileManager.default.removeItem(atPath: destPath)
            try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: destPath))
            DispatchQueue.main.async {
                self.appDelegate.downloadCompleted(modelName: self.modelName, destPath: self.destPath, isSetup: self.isSetup)
            }
        } catch {
            DispatchQueue.main.async {
                self.appDelegate.downloadFailed(modelName: self.modelName, error: error.localizedDescription)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress: String
        if totalBytesExpectedToWrite > 0 {
            let pct = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100
            let downloaded = ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)
            progress = "\(downloaded) (\(Int(pct))%)"
        } else {
            progress = ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)
        }

        DispatchQueue.main.async {
            self.appDelegate.downloadProgress = progress
            self.appDelegate.updateIcon()
            self.appDelegate.buildMenu()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.appDelegate.downloadFailed(modelName: self.modelName, error: error.localizedDescription)
            }
        }
    }
}

// MARK: - Main
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
