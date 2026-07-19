# Ph3b3-Light — parity TODO

The voice/language surface on Ph3b3-Light must reach **feature parity with the
main Ph3b3 server (Nyx)**. Nyx's implementation is the reference — match its
behavior. These are the two standing parity briefs, carried into this repo.

---

## 1. Status tab — "Language & Voice" card

Bring the portal's Status tab to parity with Nyx's Language & Voice card.

- [ ] Language picker + voice picker (the voice list is **filtered to the current
      language** — you only see voices that serve it).
- [ ] **Language is master; voice auto-follows** on a language change — no "also
      switch voice?" prompt. Per-language voice memory (Spanish→English→Spanish
      restores the chosen Spanish voice).
- [ ] "**Speaking with: <voice>**" banner reflecting the active voice.
- [ ] **Preview ▶** per voice — speaks that voice's own-language sample line —
      behind the server-side **audible-RMS gate** (silence is an error, never a
      silent 200; each voice logs its `(voice, text)` pair).
- [ ] **Three language states, labeled distinctly** in the picker/banner:
      - *voiced* — has an approved voice, speaks.
      - *— voice in review* — a voice is installed but unreviewed (NOT "text only").
      - *— text only* — a genuine gap, no voice at all (ja/ko/hi/id).
- [ ] The **by-ear review flow**: preview + approve/reject unreviewed candidates;
      reject deletes the model from disk. Only *approved* voices reach the main
      dropdown.

## 2. Voice-bench parity

Match Nyx's voice bench end to end.

- [ ] **15 voiced languages** — en, es (×4 regional voices), fr, de, zh, it, pl,
      ru, vi, ar, tr, nl, uk, cs, sv — plus **text-only** ja/ko/hi/id.
- [ ] **Registry** (`config/voices.yaml`) with full, enforced entries per voice:
      `model`, `lang`, `script`, `tier`, `sample_text` (native), `display_name`
      (`<Name> — <Language> (<Region>)`), `status`. A voice missing `display_name`
      or `sample_text` fails the synth check (fails install, not render).
- [ ] **Hash-pinned install** in `setup.sh` (sha256 of each `.onnx` + `.onnx.json`,
      verified on install); **zero runtime network fetches**.
- [ ] **Native-script handling**: `script: native` for Arabic (RTL), Cyrillic
      (ru/uk), and Hanzi (zh) so they aren't Latin-stripped to nothing.
- [ ] **RTL rendering** — wrap `display_name` in `<bdi>` / `dir="auto"` in the
      banner, picker, and review flow so Arabic can't reorder the LTR chrome.
- [ ] **Text-only mode**: a language with no approved voice synthesizes **nothing**
      (reply delivered as text, Alba never assigned) — declared design, never
      silent-by-surprise. Derived from the registry: the day a language gains an
      approved voice, the label drops with zero code change.

---

## How parity is delivered

**Ph3b3-Light must stand alone** — a bare clone, pointed at nothing but its own
Windows/WSL2 machine, runs the full experience. It never *depends* on Nyx (or any
other instance) to work. So parity means **porting Nyx's implementation INTO this
repo's own server** and keeping it in sync:

- `modules/voices.py` — registry loader, language/voice state, three-state logic.
- `modules/tts_module.py` — multi-voice synth, native-script handling, RMS gate.
- `agent/server.py` — the `/language` + `/voice/*` endpoints (incl. the review flow).
- `config/voices.yaml` — the voice registry (full enforced entries).
- `setup.sh` — the hash-pinned voice-download block.

The portal's server-selector (it *can* also point at a remote Ph3b3) is a bonus,
not the identity — light works with nothing but itself.

> Note: the README already advertises the voice/language features. The current
> seeded `agent/server.py` is from the older `windows` branch and does **not** yet
> have the 15-voice bench / review gate / text-only mode — this port closes that gap.

*Seeded from the `windows` branch of `Astroson111/ph3b3`.*
