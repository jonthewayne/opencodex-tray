# OpenCodex Tray

A tiny macOS menu-bar app for [OpenCodex](https://www.npmjs.com/package/@bitkyc08/opencodex) — the local proxy that adds Vercel AI Gateway models to Codex's model picker.

One glance tells you whether Codex is routing through OpenCodex or talking to stock OpenAI, and one click flips it.

```
● OpenCodex — On
   Routing 3 gateway models · port 10100
   Gateway credits: $17.42                            (Vercel AI Gateway balance, refreshed ~30 min)
   Shadow calls → gateway · retries sub Wed 8:59 PM   (only while the intercept is on)
Turn Off (back to stock Codex)
──────────────
Open Dashboard…       ← model toggles, live request log, providers
──────────────
Settings ▸            ✓ Start at Login
                      ✓ Keep Proxy Alive   ← auto-restarts a dead proxy so Codex never silently breaks
                      ✓ Shadow Calls: Gateway When Limited   ← standing policy; tray flips the intercept both ways
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
git clone https://github.com/jonthewayne/opencodex-tray.git
cd opencodex-tray
./build.sh install
```

`./build.sh` alone builds `OpenCodex Tray.app` in place without installing.

On first launch the app registers itself to start at login (a menu-bar status app is only useful if it's always there). Turn it off in **Settings ▸ Start at Login** if you'd rather launch it manually — the toggle is respected from then on.

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

## Shadow-call failover

Codex fires small background "shadow calls" (thread titles, summaries) at your ChatGPT subscription. When the subscription hits its usage limit those calls 429. OpenCodex's *Shadow Call Intercept* can reroute them to a gateway model — but it's a static on/off switch with no failover of its own.

The tray turns it into a policy. **Shadow Calls: Gateway When Limited** is a standing instruction, not a state indicator — it stays checked (or unchecked) until *you* change it:

- **Checked** — use the gateway only when the subscription needs it. While shadow calls are native, the tray watches the proxy's request log every minute (`shadow-check`); a fresh native 429 means the subscription just hit its limit, so the intercept is flipped **on** and a toast tells you. While the intercept is on, `shadow-probe` runs every 30 minutes — lift the intercept for a moment, send one tiny native low-effort request — and a 200 means the subscription is back: the intercept is flipped **off** and a toast card drops down under the menu-bar icon, floating above other windows until you dismiss it, so you know to move your main Codex threads off the gateway too. A 429 restores the intercept and shows the error's reset timestamp in the status line.
- **Unchecked** — never: shadow calls always stay on your subscription (the intercept is turned off when you uncheck it).

Probing is on a fixed 30-minute cadence rather than waiting for the announced reset, because OpenAI sometimes resets quota early. A failed probe costs nothing; a successful one is a single low-effort request. (Verified: a 429 on one model doesn't cool down others — probing never blocks models that still work.) Launch the app with `--test-toast` to preview the notification card.

Sleep can kill a probe at the worst moment: the probe lifts the intercept, the Mac dozes off before the answer arrives, and the intercept is left off with nobody having seen the result (this happened live on 2026-08-19 — the subscription recovered but no toast ever appeared). Two defenses cover it: the tray re-checks ~8 seconds after every wake (`NSWorkspace.didWakeNotification`), and whenever it notices the intercept is off while it last believed it was on — with no probe of its own in flight — it re-probes immediately. A healthy answer becomes the missed "Subscription is back ✓" toast; a 429 re-engages the intercept. Probe answers that are neither 200 nor 429 (a 502 while Wi-Fi is still coming up, say) are treated as inconclusive and retried in ~2 minutes.

## Gateway credits

While the proxy is on, the menu shows your Vercel AI Gateway credit balance (`GET https://ai-gateway.vercel.sh/v1/credits`, authenticated with the same Keychain key the proxy uses). The value is cached for ~30 minutes in `~/.opencodex/tray-credits-cache`, so opening the menu is a local file read most of the time; a failed fetch keeps showing the last known balance. No key in the Keychain — no line.

## License

MIT
