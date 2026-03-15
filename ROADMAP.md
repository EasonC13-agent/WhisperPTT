# WhisperPTT Roadmap

## Vision

Typeless 的功能，但 100% 本地、開源、零隱私風險。

## v1.0 ✅ (Current)

- [x] Menu bar app (Swift, no Electron)
- [x] Push-to-Talk hotkey (Ctrl+Option+Space)
- [x] whisper.cpp local transcription
- [x] Model switching from menu bar
- [x] Multi-language support (zh/en/ja/ko/auto)
- [x] Auto-paste at cursor
- [x] Config persistence (~/.config/whisper-ptt/config.json)

## v1.1 — AI Polish (本地潤稿)

核心賣點，跟 Typeless 拉齊的關鍵功能。

### 方案

- 用 **ollama** 作為本地 LLM backend (idle 時 0% CPU)
- 推薦模型：**Qwen3 4B** (Q4, ~2.5GB RAM, 50-80 tok/s on M1)
  - 備選輕量：Qwen3 1.7B (~1GB, 更快)
  - 備選英文優先：Gemma 3 1B / Phi-4 mini
- 流程：錄音 → whisper 轉錄 → ollama 潤稿 → 貼上

### 潤稿 Prompt

```
你是語音轉文字的後處理器。清理以下語音辨識的原始文字：
- 移除口頭禪（嗯、啊、那個、就是、然後）
- 移除重複和自我修正的片段
- 修正明顯的語音辨識錯誤
- 加上正確標點符號
- 保留原意，不要改寫、擴充或美化
- 中英混合時保持原本的語言切換

原始文字：{transcription}
清理後：
```

### UI

- Menu bar 新增切換：Raw / Polished
- 可選潤稿模型（掃描 ollama list）
- 潤稿時 menu bar icon 顯示 ✨ 或轉圈

### 效能預估 (10 秒語音, M1)

| 步驟 | 耗時 |
|---|---|
| whisper medium 轉錄 | ~3-5s |
| Qwen3 4B 潤稿 | ~0.5-1s |
| **總計** | **~4-6s** |

## v1.2 — Streaming Transcription (即時串流)

- 用 whisper-stream 或 whisper.cpp streaming mode
- 邊說邊出字，不用等錄完
- 適合長段落口述

## v1.3 — Context Awareness (上下文感知)

- 偵測當前 app（Mail, VS Code, Slack...）
- 根據 context 調整潤稿風格：
  - Email → 正式語氣、加問候語
  - Code editor → 保留技術術語、不潤稿
  - Chat → 口語化
- **注意：** 不像 Typeless 用 keylogger/screen scraping
  - 只讀 frontmost app bundle ID (NSWorkspace)
  - 不讀螢幕內容、不攔截鍵盤

## v1.4 — Custom Vocabulary (自訂詞彙)

- 用戶可加專有名詞表
- whisper.cpp --prompt 注入 context hint
- 技術術語、人名、公司名辨識更準

## v2.0 — Cross Platform

- Windows 版 (C++ or Rust + system tray)
- 考慮 iOS shortcut / widget

---

## 商業模式（如果要做）

### 免費開源

- 基本轉錄（現在的 v1.0）
- GitHub 上的 source code

### Pro ($5-8/月 or $60-80/年)

- AI 潤稿（bundled ollama + recommended model）
- 串流轉錄
- 上下文感知
- 自訂詞彙表
- 自動更新

### 定價參考

- Typeless: $12/月 ($144/年)
- Wispr Flow: $10/月 ($96/年)
- 我們比他們便宜 + 100% 本地 = 強力賣點

### 市場時機

- 2026/2 Typeless 隱私爭議爆發
- 台灣/日本社群大量用戶尋找替代品
- 主打「隱私」差異化，timing 正好

---

## Tech Stack

- **Language:** Swift (macOS native)
- **STT:** whisper.cpp (local)
- **LLM:** ollama + Qwen3 (local)
- **Distribution:** DMG + Homebrew cask
- **Signing:** Apple Developer ID + notarization (pending)
- **CI:** GitHub Actions (build + release)
