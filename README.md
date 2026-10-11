# ExcuseMe

Voice dictation for macOS. Hold a key, speak, and polished text appears wherever your cursor is. A native, private, free alternative to Wispr Flow.

## Features

**Dictation**
- Hold **Fn** (or Right ⌥ / ⌘ / ⌃) to talk, release to insert. Tap once for hands-free (with a timer), tap again to finish, Esc to cancel.
- Removes fillers, applies self-corrections ("Tuesday, no wait, Wednesday" → "Wednesday"), fixes punctuation, formats lists.
- **Fast path:** short, clean dictations skip the LLM, so quick replies land about 0.3 s after you release the key.
- **Screen context:** reads the text before your cursor so it adds spaces only when needed and continues mid-sentence in lowercase. Never reads password fields.
- **Per-app tone** (formal / casual / very casual) and **custom instructions** ("Use British spelling").

**Beyond Wispr Flow**
- **Live words while you speak:** the pill streams what it hears, on-device and private. Wispr shows nothing until it's done.
- **"Scratch that"** removes your last dictation. **Voice edits without selecting:** hold Fn + Control right after dictating and say "make that shorter" or "change Friday to Monday". Wispr's Command Mode needs existing text, is paid-only, and is experimental.
- **Speak one language, write another:** speak Hindi or Hinglish, get English (or the reverse). Wispr only transcribes in the language you spoke.
- **Regional formatting:** India gets ₹ amounts with lakh/crore and Indian digit grouping. Spoken emails ("rahul at the rate gmail dot com") become `rahul@gmail.com` everywhere.
- **Transcribe audio files and WhatsApp voice notes** (.opus/.ogg, .m4a, .mp3, .wav…) into clean paragraphs from the menu.
- **Never lose a dictation:** failed audio is saved to disk (it survives a restart) for one-click retry. If the network drops, the live on-device transcript is used instantly. A dead or muted mic is detected and switched automatically. If an app blocks pasting, the text stays on your clipboard and you're told.
- **Privacy log:** every history entry says whether it stayed on this Mac or went to the cloud. Context comes from accessibility text only, never screenshots.

**Private meeting notes** (menu bar → Start Meeting Notes)
- Records your mic and the call audio (Zoom, Meet, Teams, Slack…) as **separate tracks**, so the transcript is labelled **You / Them** without a diarization model. Echo from speakers is removed.
- Writes notes: title, summary, key points, decisions, **action items with owners and due dates**, and open questions. Export as Markdown.
- Audio is deleted once notes are written (configurable). With the on-device engine, nothing leaves the Mac.

**Ask mode** (hold Fn + Shift)
- Ask about anything, or about the selected text ("what does this error mean?"), and get an answer card with Copy / Insert.
- **Voice actions on this Mac, confirmed before they run:** "remind me to call Rahul at 5" (Reminders), "lunch with Priya Friday 1pm at Social" (Calendar), "email Sam I'll be late" (Mail draft, signed with your name), "open Figma", "search …".

**Re-polish from History:** redo any past dictation as more formal, more casual, shorter, bullets, grammar-only, or translated.

**Snippet variables:** `{date}`, `{time}`, `{day}`, `{tomorrow}`, `{clipboard}`.

**Command mode** (hold Fn + Control)
- With text selected: "make this more formal", "translate to Hindi", "turn this into bullet points".
- With nothing selected: "write a polite reply declining the meeting on Friday".

**Accuracy**
- **Personal dictionary**, passed to Whisper as vocabulary and to the cleanup model as exact spellings.
- **Auto-learn:** fix a misheard name after dictating (Devianchu → Divyanshu) and it's added to the dictionary.
- Guards reject LLM output that answers the question instead of transcribing it, or that summarizes.

**Engines**
- Transcription: Groq `whisper-large-v3-turbo` (free tier), OpenAI, any OpenAI-compatible server, or **Apple on-device** (free, offline).
- Cleanup: **Auto** (cloud LLM → Apple on-device → rules), or pick one. Retired models are replaced automatically.
- **Offline fallback:** if the network fails, it transcribes on-device instead of failing.

**Reliability**
- Silence is trimmed before upload, so Whisper doesn't invent "Thank you." from silence. Known hallucinated phrases are stripped.
- Long clips are uploaded as AAC (about 5× smaller). The connection is opened while you talk. Network errors are retried once.
- **Retry Last Dictation** in the menu when something fails. Recording stops automatically after 6 minutes.

**App**
- Microphone picker, launch at login, snippets, searchable history with the original transcript, usage stats (words, WPM, time saved).
- About 14 MB of memory, 0% CPU when idle, a 1.8 MB app.

## vs Wispr Flow

| | ExcuseMe | Wispr Flow |
|---|---|---|
| Price | Free (Groq free tier, or fully on-device) | $12–15/month after 2,000 words/week |
| Privacy | Fully on-device mode available | Cloud only |
| App size / memory | 1.8 MB / ~14 MB | ~300 MB / ~800 MB (Electron) |
| Command mode, dictionary, auto-learn, snippets, per-app tone | ✓ | ✓ |
| Offline fallback | ✓ | ✗ |
| Live transcript while speaking | ✓ | ✗ |
| Voice-edit last dictation without selecting ("scratch that", "make that shorter") | ✓ | Partial (needs selection/text, Pro only) |
| Speak one language, write another | ✓ | ✗ |
| ₹ / lakh-crore and spoken-email formatting | ✓ | ✗ |
| Audio file and voice note transcription | ✓ | ✗ |
| Failed audio kept on disk, auto mic recovery, paste verification | ✓ | Known issues: lost chunks, missing first words |
| Per-dictation privacy log | ✓ | ✗ |
| Meeting notes | ✓ Free, private, separate-track speaker labels | Paid; cloud; weekly limit on Free |
| Ask about anything, or the selection, in a floating card | ✓ | Opens Perplexity / notification |
| Local voice actions (Reminders, Calendar, Mail, open apps) | ✓ | Via MCP setup |
| Re-polish past dictations | ✓ | ✗ |
| Snippet variables | ✓ | ✗ |
| Custom LLM / bring your own server | ✓ | ✗ |
| Platforms | macOS | Mac, Windows, iOS, Android |

## Build & run

Requirements: macOS 14+ (on-device engines need macOS 26), Apple Silicon, Swift 6 command line tools.

```bash
./scripts/build-app.sh            # → build/ExcuseMe.app
./scripts/build-app.sh --install  # also copies to /Applications and launches
```

The script signs with your first "Apple Development" identity if present, so permissions survive rebuilds. Set `SIGN_IDENTITY=-` for ad-hoc signing.

## First launch

1. **Accessibility:** System Settings → Privacy & Security → Accessibility → enable ExcuseMe. It's needed for the global key, reading context, and pasting.
2. **Microphone:** allow when prompted.
3. **Engine:** paste a free Groq key (console.groq.com/keys) or choose *On-device*.
4. Using Fn? Set System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**.

## Testing from the command line

The app binary has a headless mode that runs the real pipeline with your saved settings:

```bash
say -o /tmp/test.aiff "um can you send the deck to Divyanshu"
/Applications/ExcuseMe.app/Contents/MacOS/ExcuseMe --transcribe /tmp/test.aiff --vocab Divyanshu --app com.apple.mail
/Applications/ExcuseMe.app/Contents/MacOS/ExcuseMe --transcribe /tmp/test.aiff --local            # on-device engine
/Applications/ExcuseMe.app/Contents/MacOS/ExcuseMe --command "make this formal" --selection "hey whats up"
/Applications/ExcuseMe.app/Contents/MacOS/ExcuseMe --models                                        # provider's models
```

Other flags: `--cleanup auto|apple|api|rules|off`, `--before "text before the cursor"`, `--write-in English`, `--region india`, `--file voice-note.opus`, `--preview clip.aiff` (live streaming test). Set `EXCUSEME_DEBUG=1` to see raw model outputs. More: `--ask "remind me…" [--selection …]`, `--meeting --you a.aiff --them b.aiff` (runs the meeting processor on two tracks).

## Architecture

```
HotkeyMonitor (CGEventTap) ─► DictationController
  AudioRecorder (AVAudioEngine → 16 kHz) ─► trimSilence
  FocusContext (AX: app, window, text before caret, selection)
  Pipeline.transcribe ─► Transcriber (Groq/OpenAI, WAV/AAC, retry) │ LocalSpeech (Apple SpeechAnalyzer)
  Pipeline.polish ─► snippets ─► fast path │ Cleanup (cloud LLM / Apple FoundationModels / rules) + guards
  Pipeline.command ─► Command (rewrite selection or generate)
  TextInserter (pasteboard + ⌘V, clipboard restored) ─► CorrectionLearner ─► dictionary
```

| File | Role |
|---|---|
| `DictationController.swift` | State machine, modes, retry |
| `HotkeyMonitor.swift` | Global key + modifier detection |
| `AudioRecorder.swift` | Capture, device selection, silence trim, WAV/AAC |
| `FocusContext.swift` | Accessibility context, smart spacing and casing |
| `Transcriber.swift` / `LocalSpeech.swift` | Cloud and on-device transcription |
| `Cleanup.swift` | Prompting, fast path, guards, command mode, Apple model |
| `ModelResolver.swift` | Replaces retired provider models |
| `CorrectionLearner.swift` | Learns corrected words |
| `Pipeline.swift` / `CLI.swift` | Shared pipeline, headless test hook |
| `Pill.swift`, `SettingsView.swift`, `AppDelegate.swift` | UI |
