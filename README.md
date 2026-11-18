<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Branding/logo-horizontal-dark.svg">
    <img src="Branding/logo-horizontal-light.svg" alt="QoL Notch" width="520">
  </picture>
</p>

# QoL Notch

A free, open-source Dynamic Island for the Mac notch, built around a teleprompter that follows your voice. "QoL" is short for quality of life: lots of small, useful things, right where you already look.

## What works so far

- An island that rests inside the notch and grows open when you point at it, with tabs for the prompter, a Home view (music, what's next, weather or system load), now playing, your calendar, a camera mirror, a quick note, a timer, clipboard history and a file shelf with AirDrop.
- Now playing works with anything that plays on the Mac, including browser tabs in Chrome and Safari: artwork, a progress bar you can drag, previous, play/pause and next. Shuffle and repeat work in Music and Spotify.
- Small extras: the cover spins as a vinyl record and colours the island's glow, a full-screen now-playing view, an app launcher, a clock widget, a daily line on Home, battery time left, and an optional Touch ID lock for Notes and Clipboard.
- Make it yours: Black or Glass style, your own accent colour, where the glow comes from, which widgets Home shows, and which six tools sit beside the notch, in your order.
- Experimental: music controls on the lock screen. Off by default; it uses undocumented parts of macOS that an update could break.
- Every tab follows the theme you pick, including an optional frosted-glass look.
- Live activities beside the notch while it rests: a running timer's countdown, or bars while music plays.
- The resting notch speaks up for a moment: a timer ending, a meeting a minute away, plugging in or a low battery, and (if you turn it on) volume and brightness. New screenshots drop out of the notch to click or drag, dragging a file opens the Shelf, timer digits flip, the record has a tonearm, and the lock screen can show a large cover. Each has its own switch.
- Detach the prompter from the notch to use it as a free panel you can drag and resize.
- A black panel at the notch showing your script, hidden from screen sharing and recording.
- Voice follow: the script advances as you speak and waits when you stop. Recognition stays on-device where the Mac supports it.
- Drag the panel anywhere, resize it from its edges, double-click the grip to snap back to the notch.
- Click any word to jump to it; ⌘←/→ and ⌘↑/↓ step by one or ten words.
- Thai and mixed Thai/English scripts: Thai is split into words and tracked even though it has no spaces. Language is picked automatically from the script, or set by hand.
- Import a Markdown or Obsidian note as your script (⌘O); links, tags, callouts and formatting are stripped so only speakable text remains. Reload it after editing the note.
- A Look tab to restyle everything live: font, weight, size, colours, current-word style, glow, corner radius.
- Team scripts: start a line with `@Name:` to mark who speaks. Each person picks their name, other people's lines dim, and a "You're next" cue appears before their turn.
- Rehearsal stats after each run: time, words per minute, where you paused and for how long, time per section, and an approximate filler-word count, with a time limit to rehearse against.
- Phone remote with no app: scan a QR code and control the prompter from your phone's browser over Wi-Fi.
- Six built-in themes, plus your own saved as small `.qoltheme` files you can import, export and share.

## Build and run

Requires macOS 14+ and Xcode command line tools.

```bash
./scripts/bundle.sh
open "build/QoL Notch.app"
```

Run the tests with `swift test`.

The logo, the app icon and the social preview are drawn from numbers in `scripts/make_logo.py`. Run `./scripts/render_logo.sh` after changing them.

The first time you press Start, macOS asks for microphone and speech recognition access.

## License

MIT. See [LICENSE](LICENSE).
