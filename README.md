# 🎙️ Whisper PTT

A lightweight macOS menu bar app for **local push-to-talk voice input** using [whisper.cpp](https://github.com/ggerganov/whisper.cpp).

Press a hotkey → speak → text gets typed into any app. Fully local, no cloud, no API keys.

Great for **中英混合 (mixed Chinese/English)** input — much better than Apple's built-in dictation for code-switching.

![Menu Bar](https://img.shields.io/badge/macOS-Menu%20Bar%20App-blue?logo=apple)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- 🎤 **Push-to-Talk** — `Ctrl+Option+Space` to start/stop recording (configurable)
- 🔇 **Fully Local** — no internet, no API, everything runs on-device
- 🌐 **Multi-language** — Chinese, English, Japanese, Korean, auto-detect
- 🧠 **Model Switching** — pick any whisper.cpp GGML model from the menu bar
- ⌨️ **Auto-paste** — transcribed text is pasted directly at your cursor
- 🪶 **Tiny** — ~60KB app bundle, no Electron, pure Swift

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon (arm64) — Intel builds available if requested
- [Homebrew](https://brew.sh)

## Install

### 1. Install dependencies

```bash
brew install whisper-cpp sox
```

### 2. Download a whisper model

```bash
mkdir -p ~/.whisper-models
cd ~/.whisper-models

# Medium model — good balance of speed & accuracy for mixed zh/en
curl -LO https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin

# Or for faster transcription (less accurate):
# curl -LO https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin

# Or for best accuracy (slower):
# curl -LO https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

### 3. Install the app

Download `WhisperPTT.dmg` from [Releases](../../releases), open it, and drag **Whisper PTT** to Applications.

Or build from source:

```bash
git clone https://github.com/aspect-build/WhisperPTT.git
cd WhisperPTT
swift build -c release
# Binary at .build/release/WhisperPTT
```

### 4. Remove quarantine (unsigned app)

Since this app is not notarized with Apple, macOS will block it. After copying to Applications, run:

```bash
xattr -cr /Applications/WhisperPTT.app
```

### 5. Grant permissions

On first launch, macOS will ask for:
- **Microphone** — needed to record audio
- **Accessibility** — needed to paste text into apps

Go to **System Settings → Privacy & Security** to enable both.

## Usage

| Action | How |
|---|---|
| Start recording | `Ctrl + Option + Space` |
| Stop & transcribe | `Ctrl + Option + Space` again |
| Switch model | Click menu bar icon → Model |
| Switch language | Click menu bar icon → Language |

The menu bar icon turns 🔴 red while recording.

## Config

Settings are saved at `~/.config/whisper-ptt/config.json`:

```json
{
  "modelPath": "~/.whisper-models/ggml-medium.bin",
  "language": "zh",
  "threads": 6,
  "hotkey": "Ctrl+Option+Space"
}
```

## Building from Source

```bash
swift build -c release
```

The binary is at `.build/release/WhisperPTT`. To create an app bundle:

```bash
# See scripts/bundle.sh (coming soon)
```

## License

MIT
