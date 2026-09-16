# Webhook Relay — Basic Guide

For turning a third-party site's "Webhook" notification option into a phone alert, when that site needs a real HTTPS endpoint to POST to and you don't already have one.

> Want the full explanation of how this works under the hood, or hit a snag? → [Advanced guide](../advanced/webhook-relay.md)

---

## 1. Pick a subdomain and point it at this server

**This does:** gives the relay its own address, separate from your main AIOStreams domain.

Same requirement as the main installer: a subdomain with an **A record already pointed at this server's IP**, e.g. `hooks.yourdomain.top`. Wait for it to propagate before continuing:

```bash
dig +short hooks.yourdomain.top
```

Should print this server's IP.

---

## 2. Get the ntfy app

**This does:** gives you somewhere to actually receive the relayed alerts.

Install [ntfy](https://ntfy.sh) from the Play Store or App Store, or just keep `https://ntfy.sh` open in a browser tab — either works. No account, no signup.

---

## 3. Install and run the script

**This does:** installs the relay and walks you through first-time setup.

```bash
cd ~/aiostreams
curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-webhook.sh -o setup-webhook.sh
sudo bash setup-webhook.sh
```

Choose **2) Start**. It'll ask for:
1. The subdomain from step 1
2. A secret token (Enter accepts a random suggestion — this is what stops randoms from POSTing to your endpoint)
3. An ntfy topic to relay events to (reuse one from the [watchdog](./watchdog.md) or pick a new one — long and hard to guess, since anyone who knows it can see your alerts)

It prints a full URL at the end, something like:

```
https://hooks.yourdomain.top/hook/<your-token>
```

That's what goes into the third-party site.

---

## 4. Subscribe to the ntfy topic

**This does:** confirms you'll actually see relayed events, not just that the container thinks it forwarded one.

In the ntfy app (or your browser tab), subscribe to the exact topic name the script showed you.

---

## 5. Paste the URL into the site

**This does:** the actual point of all this.

Find the site's webhook/notification setup, paste in the full URL from step 3, and confirm/verify it. Most sites send a verification request first — if theirs uses a `challenge` field it expects echoed back, this script already handles that automatically.

You should see a confirmation on the site, and a matching notification land in your ntfy topic within a few seconds.

If it doesn't → see the [advanced guide's troubleshooting section](../advanced/webhook-relay.md#troubleshooting).

---

## Everyday use

Run the script again any time for a menu:
```bash
cd ~/aiostreams
sudo bash setup-webhook.sh
```
- **Status** — running or not, current domain/URL, last few events.
- **Start / Stop** — turn the relay on or off. Config is kept either way. Start also refreshes the code, so pulling a script update just needs a Start, not a full Reconfigure.
- **Send test event** — fires a test payload straight at the container, bypassing DNS/Caddy, to isolate whether a problem is the relay itself or something upstream.
- **View recent events** — the last 30 things it received, useful for seeing exactly what a site actually sent.
- **Reconfigure** — change the subdomain, token, or ntfy target. Applies immediately to the running container, no separate Start needed.
- **Uninstall** — clean removal (container, Caddy site, saved state).

---

Something not behaving, or want to know exactly how the verification handshake works? → [Advanced guide](../advanced/webhook-relay.md)
