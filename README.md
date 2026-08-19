# OpenCodex Tray

A tiny macOS menu-bar app for [OpenCodex](https://www.npmjs.com/package/@bitkyc08/opencodex) — the local proxy that adds Vercel AI Gateway models to Codex's model picker.

One glance tells you whether Codex is routing through OpenCodex or talking to stock OpenAI, and one click flips it.

```
● OpenCodex — On
   Routing 3 gateway models · port 10100
Turn Off (back to stock Codex)
──────────────
Open Dashboard…       ← model toggles, live request log, providers
──────────────
Settings ▸            ✓ Start at Login
                      ✓ Keep Proxy Alive   ← auto-restarts a dead proxy so Codex never silently breaks
                      ──────────
                      OpenCodex 2.25.0 — up to date   (becomes "Update OpenCodex (x → y)" when npm has newer)
                      Uninstall…
──────────────
Quit
```

## States

| Icon | State | Meaning |
|---|---|---|
| ● | On | Codex config is injected and the proxy answers `/healthz` |
| ○ | Off | Stock Codex — proxy stopped, native config restored |
| ⚠ | Attention | Config still points at the proxy but it isn't responding — menu offers **Fix: Restart Proxy** |
| ◌ | Absent | OpenCodex isn't installed — menu collapses to **Install OpenCodex…** |

"Off" is a healthy state, not an error: Codex works normally against OpenAI, just without the gateway models.

## Install

Requires macOS 13+, Xcode command-line tools (`swiftc`), and Node/npm (nvm and Homebrew layouts are both auto-detected).

```sh
git clone https://github.com/jonshumate/opencodex-tray.git
cd opencodex-tray
./build.sh install
```

`./build.sh` alone builds `OpenCodex Tray.app` in place without installing.

## Gateway key

The proxy reads your Vercel AI Gateway key from the macOS login Keychain at start — service name `VERCEL_AI_GATEWAY_KEY`. It is passed to the proxy as an environment variable and **never written to any config file**. Add it once with:

```sh
security add-generic-password -s VERCEL_AI_GATEWAY_KEY -a "$USER" -w
```

Without the key the proxy still runs and your ChatGPT-subscription models keep working; only gateway models fail.

## How it works

The app is a single AppKit file (`OpenCodexTray.swift`). Every system action — health probe, start/stop, npm update, Keychain read — lives in `ocx-tray-ctl`, a plain zsh script bundled into the app's Resources. You can run it yourself:

```sh
./ocx-tray-ctl state
```

prints five lines: mode (`on|off|broken|absent`), installed version, routed model count, port, and the latest published version (cached ~6 h).

- **Turn On** = `ocx start` detached, with the Keychain key in its environment, then waits for `/healthz`.
- **Turn Off** = `ocx stop` — stops the proxy and restores your original `~/.codex/config.toml`.
- **Keep Proxy Alive** retries a dead proxy up to 3 times, then leaves the ⚠ menu for you.
- **Update** = `npm install -g` latest, restarting the proxy if it was on.
- **Uninstall** removes the npm package but keeps `~/.opencodex` so a reinstall restores your setup.

## License

MIT
