# Ph3b3-Light
*pronounced "Phoebe"* — the light client.

A private, self-hosted AI companion that runs on your own **Windows** PC. No cloud, no accounts, no subscriptions — every conversation, voice, and image stays on your machine.

Ph3b3-Light is the thin, Windows-friendly build of Ph3b3: a fast web portal you open in **Edge** or **Chrome** (or install as a desktop/phone app) that talks to a local AI running on your own hardware. She chats, speaks aloud in **16 languages**, listens to your voice, and generates images — all locally.

**Built by Alexander Jordan Olson (Astroson). Made with soul.**

![The Ph3b3-Light portal running in a browser on Windows](docs/light-portal.png)

---

## What it does

- **Chat** with a local LLM (via [Ollama](https://ollama.com), e.g. `hermes3`) — private and offline after setup.
- **Speaks 16 languages**, each in its own native voice (Piper TTS): English, Spanish, German, French, Italian, Polish, Russian, Portuguese, Dutch, Ukrainian, Turkish, Arabic, Hindi, Swedish, Vietnamese, and Chinese (Mandarin). Alba (English) is never used to fake another language — every language gets its own voice.
- **Voice input** — hold-to-talk, or hands-free auto mode (Whisper speech-to-text).
- **Image generation** with a browsable gallery.
- **Two portals, one server:**
  - **Ph3b3-Light** (`/light/`) — the fast everyday client (cyan moon 🌙).
  - **Ph3b3** (`/chat/`) — the full main portal (purple moon).
  - One tap switches between them; the root `/` opens Light.
- **Installable as an app (PWA)** — pin it to your Windows taskbar from Edge/Chrome, or add it to your Android home screen. Each portal installs as its own distinct app with its own icon.
- **One private login** — a single username + password guards your data (no stacked browser pop-ups). Change them anytime from Settings; they're saved to `.env`.

---

## Requirements

- **Windows 10 or 11**
- **WSL2** with Ubuntu (Ph3b3-Light's engine runs here)
- **[Ollama for Windows](https://ollama.com)** — runs the model natively on your GPU
- A modern browser — **Edge**, Chrome, or Firefox

---

## Quick start — one command

You need **WSL2** first (Windows' built-in Linux). If you've never used it, open an
**admin PowerShell**, run `wsl --install -d Ubuntu`, reboot, and set a Linux
username/password when prompted. That's the only manual step.

Then, from the **Ubuntu terminal**, clone and run the wizard:

```bash
cd ~ && git clone https://github.com/Astroson111/ph3b3-light.git && cd ph3b3-light
powershell.exe -ExecutionPolicy Bypass -File ./setup.ps1
```

That's it. The wizard (`setup.ps1`) does everything else for you:

1. Confirms WSL2 is present.
2. Makes sure **Ollama** is running (your Windows install *or* one it sets up in
   WSL) and pulls the `hermes3` model.
3. Installs system libraries, the Python environment, the **Alba** English voice,
   and a small Whisper speech-to-text model.
4. Generates a `.env` with a **random password — printed once, so copy it down.**
5. Starts the server, waits until she's healthy, and **opens the portal in your
   browser**.

**First run downloads a few gigabytes** (the `hermes3` model is the big one, ~4.7 GB)
and takes roughly **15–30 minutes** on a typical connection. It's **safe to re-run** —
completed steps are skipped, and your `.env`/password are never overwritten.

When it finishes, your browser opens **Ph3b3-Light** at `http://localhost:7331/light/`.
Sign in once at the single login screen with the username/password the wizard printed
(no browser pop-up) — you can change them later in Settings. Tap **☾ Ph3b3** in the top
bar to switch to the full portal.

> **Already living in the Ubuntu terminal / no interest in the Windows browser bits?**
> Just run `./setup.sh` (same steps, Linux-only) then `.venv/bin/python agent/server.py`.
> Add the other 15 language voices any time with `./setup.sh voices-all`.
>
> **Prefer to do everything by hand?** The full manual runbook — including GPU
> passthrough, mirrored networking, and firewall rules — is in
> **[INSTALL.md](INSTALL.md)**.

---

## Install it as a Windows app (PWA)

1. Open `http://localhost:7331/light/` in **Edge**.
2. **⋯ → Apps → Install this site as an app**.
3. It installs as **Ph3b3-Light** with its own icon on your taskbar/Start menu.
4. Repeat at `/chat/` to also install the main **Ph3b3** app — the two live side by side as separate apps.

On **Android**, use Chrome's **Add to Home screen** to install each portal as its own app (requires HTTPS — see below).

---

## Voice & language

Open **🗣 VOICE** in the top bar to choose a voice and language and preview how it sounds. Each language speaks in its own native voice; languages without an installed native voice appear as *functional* (translation-only). Changes are stored server-side, so both portals stay in sync.

*Note: Piper has no Japanese or Korean voice — those languages are text-only.*

---

## Signing in & changing your login

Ph3b3-Light has **one login** — a single username and password. The page itself
loads without a browser pop-up; the login screen (and everything behind it — your
chats, voice, images) is guarded in-app.

- The wizard creates the first login: username **`phoebe`** and a **random password
  it prints once** (copy it down).
- **Change your username or password** anytime from **🗣 VOICE → 🔑 Account**: enter a
  new username, a new password (twice), and hit **Update login**. It applies
  immediately — you stay signed in — and is saved to `.env`, so it survives a restart.
  (Passwords must be at least 6 characters.)
- Credentials live only in your `.env` on this machine and never leave it.

---

## Web search — Metis (off by default)

Ph3b3-Light can search the live web when you ask — but **web access is OFF by
default** (privacy-first, since this is a public repo strangers will run). You
turn it on per-session from the **🗣 Status page** in either portal.

- **You're always told.** Every search is announced in the reply ("I searched the
  web for …") and the answer ends with a **Sources** list of the URLs used. No
  silent searches, ever.
- **Honest consent.** When web access is ON, your search queries **leave this
  machine** — to your own SearXNG instance if you run one, or directly to
  DuckDuckGo otherwise. That is the trade you are opting into; everything else in
  Ph3b3-Light stays local.
- **Two backends** (`PH3B3_SEARCH_BACKEND`): `auto` (default — SearXNG if you've
  configured a reachable one, else DuckDuckGo), `searxng`, or `ddg`. The Status
  card shows the active backend ("via SearXNG" / "via DuckDuckGo"). See
  [INSTALL.md](INSTALL.md) to run SearXNG locally.
- **Guardrails.** Fetched pages are treated as untrusted data (they can't make
  Ph3b3 run tools or change persona); the fetcher refuses private/LAN/localhost
  addresses; the safety floor gates queries and answers in any language; a broken
  scrape fails loudly rather than pretending there were no results; and there is
  no separate search log beyond your normal chat.

## Access from your phone (optional)

Ph3b3-Light is local-first — it lives on your PC. To reach it from other devices without opening ports on your router, put your PC and phone on the same [Tailscale](https://tailscale.com) network and open your PC's private address on port `7331`. For a full Android app install you'll want HTTPS, which `tailscale serve` provides on your private network.

---

## Responsible Use

Ph3b3-Light bundles network-scanning and cybersecurity modules, meant only for networks you own or have explicit permission to scan.

- Never run network scans on networks you don't own.
- nmap OS detection needs root — use it only on your own network.
- The cybersecurity modules are defensive tools, not offensive ones.
- Voice and camera data stays on your machine — be mindful of others' privacy.

She's a work in progress, the same as the person who made her. That's not a disclaimer — that's the point. Use her responsibly.

---

## License

MIT — © 2026 Alexander Jordan Olson (Astroson). See [LICENSE](LICENSE).

*Made with soul. Handle with care.* 🌙

---

*Seeded from the `windows` branch of [Astroson111/ph3b3](https://github.com/Astroson111/ph3b3), then given its own clean history. The firmware's WiFi/server credentials live in a gitignored `secrets.h` — copy `firmware/src/secrets.example.h` → `secrets.h` and fill in your own; never commit it.*
