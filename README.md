# FreeFlow

A native macOS voice dictation app, built as a free alternative to Wispr Flow. Speech recognition runs on your Mac for free, and you pay only for the Claude API calls you choose to make.

**[Try the interactive tutorial →](https://brian-stockwell.github.io/FreeFlow/)** It covers every feature and runs in your browser, no install needed.

- **Hold Fn**: raw transcript (on-device Apple speech, free).
- **Hold Fn + Ctrl**: transcript cleaned up by Claude Haiku and formatted for where you're typing (email, Slack, AI prompt, document).
- **Hold Fn + Option**: Command Mode. Speak an instruction about the selected text.
- **Fn + Space** or double-tap Fn: hands-free. Tap Fn again to stop. **Esc** cancels.
- **Cmd + Ctrl + V** pastes the last transcript, **Cmd + Ctrl + C** copies it.
- **Option + 1–5**: Transforms (Polish, Prompt Engineer, Turn into a list, Make it concise, Fix grammar only).
- **Option + N** starts or stops a meeting recording: mic and system audio, a live transcript, then a Claude summary and tasks.
- While recording, **tap Control** on its own to switch between Meeting and **Lecture mode**, which writes study notes instead of a meeting summary. You can also switch per meeting in the Meetings window, then Regenerate.

Hub window (menu bar icon → Open FreeFlow): Home (history), Meetings, Scratchpad, Dictionary & Snippets, Style, Transforms, Insights (usage and API cost), Settings.

## Install

You need macOS 26, Xcode 26 (free on the Mac App Store), and an [Anthropic API key](https://console.anthropic.com) for the Claude features. Plain dictation works without a key.

```bash
git clone https://github.com/brian-stockwell/FreeFlow.git
cd FreeFlow
scripts/build.sh --run
```

No git? [Download the ZIP](https://github.com/brian-stockwell/FreeFlow/archive/refs/heads/main.zip), unzip it, and run `scripts/build.sh --run` from inside the folder.

The script builds with SwiftPM, wraps the binary in `FreeFlow.app`, signs it and installs it to `~/Applications`. It signs with your Apple Development certificate when you have one, so permissions survive rebuilds. Without one it signs ad-hoc, and macOS asks for permissions again after each rebuild. See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md#2-build-and-launch) to pick a specific identity.

First launch: grant Microphone, Accessibility and Input Monitoring in the Settings page, download the speech model, and paste your Anthropic API key (stored in Keychain).

Data lives in `~/Library/Application Support/FreeFlow` (SQLite + audio). Dictation audio is deleted after 14 days. Meeting audio is deleted as soon as the transcript is saved.

## Contributing

Start with the [contributor guide](docs/CONTRIBUTING.md): build setup, how a dictation flows through the code, the developer self-tests and two starter exercises. [docs/wispr-flow-spec.md](docs/wispr-flow-spec.md) is the behavior spec.

## License

[MIT](LICENSE)
