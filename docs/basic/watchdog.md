# Watchdog Alerts — Basic Guide

For getting a phone notification if the VPN tunnel goes down.

⚠️ **Requires the [VPN layer](./vpn-setup.md) already set up.** The only thing this watches right now is gluetun's tunnel.

> Want the full explanation of how this works under the hood, or hit a snag? → [Advanced guide](../advanced/watchdog.md)

---

## 1. Get the ntfy app

**This does:** gives you somewhere to actually receive the alert.

Install [ntfy](https://ntfy.sh) from the Play Store or App Store, or just keep `https://ntfy.sh` open in a browser tab — either works. No account, no signup, nothing to register.

---

## 2. Install and run the script

**This does:** installs the watchdog and walks you through first-time setup.

```bash
cd ~/aiostreams
curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-watchdog.sh -o setup-watchdog.sh && sudo bash setup-watchdog.sh
```

Choose **2) Start**. It'll suggest a random topic name (or let you type your own — pick something long and hard to guess, since anyone who knows it can see your alerts), then pause so you can subscribe before it sends a test alert.

---

## 3. Subscribe to the topic

**This does:** confirms you'll actually see the alerts, not just that the script thinks it sent one.

In the ntfy app (or your browser tab), subscribe to the exact topic name the script showed you. Then go back to the script and press Enter to receive the test alert.

---

## 4. Confirm the test alert arrived

**This does:** proves delivery actually works, before you ever need it for real.

You should see: *"🔔 Test alert from AIOStreams watchdog — if you see this, alerts are working."*

If nothing shows up within a few seconds, don't move on yet — see the [advanced guide's troubleshooting section](../advanced/watchdog.md#troubleshooting).

---

## What you'll get

- **🔴 A "DOWN" alert** if gluetun's tunnel fails health checks for a few minutes straight (not on a single blip — see the advanced guide for why).
- **✅ A "back up" alert** once it recovers. One alert per state change, not a repeat every check.
- **Silence while you're intentionally in direct mode** — turning the VPN off on purpose won't page you.

---

## Everyday use

Run the script again any time for a menu:
```bash
sudo ./setup-watchdog.sh
```
- **Status** — is it running, when did it last check, and the current tunnel state.
- **Start / Stop** — turn checking on or off. Config is kept either way.
- **Send test alert** — fire a test message any time, without waiting for a real failure.
- **Reconfigure** — change the ntfy topic.
- **Uninstall** — clean removal (timer, service, saved state).

---

Something not behaving, or want to know exactly what it's checking and how often? → [Advanced guide](../advanced/watchdog.md)
