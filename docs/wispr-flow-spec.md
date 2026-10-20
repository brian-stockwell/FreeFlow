# Wispr Flow — feature spec for a one-to-one macOS rebuild (researched 2026-10-19)

Sources: docs.wisprflow.ai help articles (IDs noted), wisprflow.ai, Baseten case study, plus a real
Wispr Flow 1.6.1174 install (`~/Library/Application Support/Wispr Flow/config.json` and `flow.sqlite`).
Local-install facts are marked [LOCAL]; they are the most reliable source of real behavior.

## 0. Architecture facts (what Wispr actually does)
- Electron app + native helper. Cloud ASR (Soniox for meetings [LOCAL: `soniox_native_final`]), fine-tuned
  Llama on Baseten for cleanup. Claims <700 ms p99 end-to-end; users report 1–2 s.
- Insertion is clipboard paste (Cmd+V) with clipboard restore ~0.5 s later; Shift+Insert in terminals/IDEs.
- Context sent per dictation [LOCAL `History.additionalContext`]: `ax_context` (names/words scraped from the
  accessibility tree), `ocr_context` (off by default), `variable_names`, `file_names`, `dictionary_context`,
  `user_first_name/last_name`, `textbox_contents` (full text of focused field). Plus `app` bundle id, `url`
  (for browsers), `personalizationStyleSettings` {appType, style}.
- History row keeps: asrText (raw), formattedText, editedText (what user changed after paste → auto-learn),
  toneMatchedText, audio blob, duration, numWords, language, micDevice, e2eLatency, numWordsCorrected,
  numDictionaryReplacements, status (formatted | raw_transcript | dismissed | no_audio).
- Permissions: Microphone, Accessibility, Input Monitoring (+ system audio for Notetaker).

## 1. Hotkeys (Mac defaults) [LOCAL confirms: 63=Fn→ptt, 49+63=Fn+Space→popo(hands-free), 59+63=Fn+Ctrl→lens/command, 55+59+9 Cmd+Ctrl+V paste_last, 55+59+8 Cmd+Ctrl+C copy_last, 53 Esc dismiss, 46+58 Opt+N meeting recorder]
- Push-to-talk: hold Fn. Release → transcribe+paste.
- Hands-free: Fn+Space toggle, OR double-tap Fn within 0.5 s of starting, OR click the Flow Bar. "Ping" sound when ready. Stop with combo again / click ■ / tap PTT. Third rapid tap cancels.
- Command Mode: hold Fn+Ctrl, speak instruction, release. (Pro-only, off by default.)
- Cancel: Esc (or X on bar). Undo offered via notification. Cmd+Z after paste reverts (single paste).
- Paste last transcript Cmd+Ctrl+V; copy last Cmd+Ctrl+C.
- Binding Fn alone suppresses its system action (emoji picker/dictation). Up to 4 bindings/action, ≤3 keys, modifier required; Caps Lock alone allowed; mouse buttons 4/5/middle allowed.
- Recording warns at 19 min, hard-stops at 20 min (still transcribes). Pressing a non-Flow system shortcut within first second cancels.
- Silence alerts: "No audio received" at 5 s / 15 s; "Unable to access mic" at 8 s.

## 2. Transcription / formatting behavior
- Smart Formatting (default on): fillers, grammar, punctuation, capitalization. Does NOT fix misheard words.
- Backtrack: removes false starts and self-corrections ("actually", "scratch that", "never mind", restating). "coffee at 2 actually 3" → "coffee at 3". Keeps "I actually enjoyed the movie".
- Auto Cleanup levels (Style → Auto Cleanup): None (raw) / Light (default: fillers + grammar) / Medium (rewords for concision). [LOCAL: the reference install is on `light`, `defaultTranscriptionFormat: Apply AI formatting`, `aiFormatting: true`, `styleDetectionEnabled: true`, `shouldAutoLearnWords: true`, `useAxContext: true`, `shouldOCRScreenCapture: false`].
- Command-mode output and dictation into recognized AI apps skip formatting. If formatting fails → paste raw.
- Lists: "first… second…" or numbers → list. Spoken punctuation: period/full stop, comma, question mark, exclamation point, colon, semicolon. "new line"/"next line"/"line break"; "new paragraph". Never adds em dashes.
- Rich text: 1 break = newline, 2 = paragraph. Plain-text targets strip empty lines.
- Capitalization/spacing (on-device even with context off): reads text around cursor; mid-sentence start → lowercase unless proper noun; adds surrounding spaces; drops trailing punctuation if text after cursor continues sentence; when no surrounding text readable (Slack, Gmail, Notion, Discord, Teams, Claude, ChatGPT, RDP) treat as new sentence. Per-app override: automatic / unformatted / proper-noun caps only / all lowercase.
- Trailing-period rule (nothing selected, line has no .!?): Formal never removed; Casual removed up to 10 sentences any app; Very casual always; Excited/no style removed ≤2 sentences, messaging apps only.
- Numbers: "two hundred dollars" → "$200" [LOCAL example]. Stutters/repeats removed ("I I" → "I"). Dictionary applied ("Whisper" → "Wispr").
- Languages: 100+, auto-detect one language per dictation; recommended to select only intended language. [LOCAL: en only.]
- Whisper mode: no toggle, just robustness to quiet speech.
- Voice Profile unlocks after 2,000 words (stats: superpower, catch phrase, most removed word…) [LOCAL keys].

## 3. Context awareness & Writing Styles
- App category: Email / Work messaging / Personal messaging / Other. In browsers identify the site (domain), fallback to browser name. AI assistants & terminals = Other. Slack/Teams = Work.
- [LOCAL userVoices] work: Slack, Microsoft Teams (style formal, cleanup light); email: Gmail, Microsoft Outlook, Superhuman; personal: Messages, WhatsApp, WeChat, Messenger; other: everything else. Styles per category: Formal / Casual / Very casual (personal only) / Excited! (work/email/other). [LOCAL: work=formal, personal=casual, other=casual].
- Email category → email formatting: greeting, sign-off, line breaks; `emailAutoSignature` + `emailSignatureOption` settings [LOCAL]. Also Missive.
- Reads: text before/after/inside selection; on-screen text for names (email recipients) and capitalization; variable/file names in IDEs (needs Screen Reader Optimized mode); conversation history on Mac. Excludes password fields, numeric-only, URL bars, placeholders, banking apps, Flow's own windows.
- Context off: still sends app name + domain for tone; cursor-adjacent text read on-device only.
- Coding: Cursor/Windsurf/VS Code variable recognition; file @-tagging in Cursor/Windsurf chat ("tag"/"at" + basename); Claude Code/Codex CLI long dictations pasted in parts; terminals plain.
- Notion: skip formatting if surrounding text very short / placeholder.
- Focus mode: blocked apps/urls list [LOCAL: Slack, Superhuman, app.slack.com, mail.google.com, x.com…].

## 4. Command Mode, Transforms, Polish
- Command Mode: focus editable box, hold Fn+Ctrl, speak instruction, release. Sends whole textbox + selection + instruction. Edits selection / drafts replies / search (Perplexity) / build apps. Result pasted verbatim (no formatting). No editable box → shows notification. Esc/Backspace cancels. Double-press locks hands-free.
- Transforms (beta, opt-in): select text + hotkey → replace in place; nothing selected → whole box; empty box → last dictation (60 s); 1–3,000 words. Defaults: Polish Opt+1, Prompt Engineer Opt+2, View Diff Opt+O, custom Opt+3. Up to 8 custom transforms (name, prompt, shortcut) + writing samples. "Auto Apply After Dictation".
- Polish rules [LOCAL defaults]: Make more concise ✓, Clarify main point ✗, Maintain your tone ✓, Reword for clarity ✓, Reorder for readability ✓, Refine phrasing for impact ✗, Add structure for readability ✓. Up to 5 custom instructions. Re-transform: Prompt Engineer / turn into list / translate to English / empathize.
- [LOCAL `Polish` table]: polishInitialText, polishedText, app, instruction, promptName, shortcutKey, diffCount, polishUndone.

## 5. Dictionary & Snippets [LOCAL `Dictionary` table: phrase, replacement, isSnippet, source(manual|default|auto), frequencyUsed, isStarred]
- Dictionary: word/phrase, or misspelling → correct replacement. Auto-learn from post-paste edits (skips filenames/URLs/code/numbers/dates/emoji/common words). Case-insensitive whole-word, longest match wins, contractions untouched. 60 chars/entry, import ≤1,000.
- Snippets: spoken trigger (≤60 chars) → expansion (≤4,000 chars, rich text). Standalone trigger = exact expansion. Longest match wins. Static (no variables).
- [LOCAL defaults seeded]: "btw"→"by the way"; "Wispr Flow"; the user's first name; snippet "my email address"→email; "organize thoughts prompt"→a prompt text. Users then add their own full name and email.

## 6. Notes — three distinct things (no product called "Flow Notes")
A. Scratchpad (desktop): sidebar page; Opt+S toggles window (hold/double-tap = dictate into new tab); Flow Bar button optional. Tabs (5/window), pin, search titles+body, autosave, auto-title from first 3 words, images (10/note, 5 MB), version history (50, 10-min merge), offline, sync, share by link. No AI summarization documented. [LOCAL `Notes` + `NoteVersions(source, transformPrompt)` + `NoteImages` tables; `notesViewType: grid`; settings for scratchpad open behavior.]
B. iOS Notes: lock-screen widget etc. (not relevant to Mac).
C. Notetaker (beta Aug 2026, Mac/Win): records system audio + mic, no bot. Zoom/Meet/Teams/huddles/in-person. Start from sidebar / Cmd+N / Opt+N / triple-tap shortcut [LOCAL `notetakerTripleTapShortcutEnabled`]; auto-detect meetings via calendar + notification 15 s before [LOCAL]; recording continues behind Flow Bar pill; "My thoughts" notepad separate from summary; live transcript; speaker-labeled refined transcript; "Flow Summary" (topic headings + next steps, regenerable) [LOCAL example: markdown `### Interview Process` + bullets, `<@speaker:N>` mentions]; Todos extracted; Ask Wispr chat over meetings; folders; share; Granola/Otter import; max recording 2 hr [LOCAL]; auto-end; hide pill in screen share; MCP server. Storage [LOCAL]: `meetings/<id>/upload.ogg`, `live.ndjson` ({id,timestamp,text,speaker{id,source:mic|system,name},startRecordingMs,…}), `refined.ndjson`, `speakers.observations.ndjson` (platform detection e.g. teams), `audio-devices.json`. Free: 50 recordings/week, 5+ min count. Audio deleted after 7 days server-side.

## 7. UI
- Menu bar icon: Open app, Help, Support. Optional dock icon [LOCAL `hideAppInDock: false`]. Launch at login [LOCAL true].
- Hub window ~1350×850 [LOCAL], sidebar: Home (history by date, searchable, hover copy/flag, … menu: Undo/Redo AI edit, Retry, Extract audio WAV, Play; audio kept 14 days; weekly word-cap card; stats), Meetings, Scratchpad, Dictionary, Snippets, Style, Insights, Transforms, Settings, Help. Light/dark theme [LOCAL `theme: light`].
- Flow Bar pill: bottom-center by default [LOCAL `statusDockEdge: bottom`], draggable to L/R edge; states resting/recording/processing/error; X cancel, ✓ confirm, language picker; follows cursor display; avoids Dock; across Spaces; right-click "Hide for 1 hour"; "Show at all times" setting; hidden until onboarding done; can be hidden from screen capture.
- Sounds: start/stop/ping for hands-free, 19-min warning [LOCAL `enableSounds: true`].
- Insights/Usage: WPM (speech time), "Top X%", fixes count, total words, categories (personal/work/email/AI prompts/documents/other), heatmap, streaks [LOCAL stats: 141 WPM, streaks].
- Settings: General (Shortcuts, Microphone w/ ranked devices + override, Languages); System (launch at login, Flow Bar visibility, notifications, dock, Scratchpad behavior); Account; Plans; Data & Privacy (storage, cloud sync, improve model, context awareness, export); Experimental (Command Mode); Vibe coding (file tagging).
- Notifications [LOCAL keys]: MicSwitched, NoAudio, TranscriptCancelled, WeeklyWordsLimit, LearnedDictionaryWords, EmailSignature, SmartFormattingList, FormalityMismatchDetected, PasteFailed, ProcessingDelay, DictationDurationWarning, etc.

## 8. Insertion mechanics
- Clipboard paste; restore previous clipboard ~0.5 s after (files/rich attachments not restored). Failed insertion → transcript stays on clipboard + notification. Cmd+Ctrl+V re-paste.
- 20-min cap; network drop → up to 5 min processing then partial paste; offline → audio saved for retry from History.

## 9. Pricing (for reference)
Free: 2,000 words/week (5,000 hard max). Pro $15/mo or $144/yr: unlimited, Command Mode, some Polish rules. Growth $23, Growth+Notetaker $33.

## 10. Quirks to design around
Missing first words with Bluetooth mics (open mic immediately, buffer pre-roll); wrong caps when no surrounding text; clipboard race; latency 1–2 s; cloud-only; login-item re-adding controversy (don't do that); heavy RAM.
