# Other Scripts

Optional add-ons on top of the main install. Each is its own standalone script, run whenever you want.

### VPN Setup

- **Want to use a VPN for addon/scraper unblocking system-wide, instead of managing proxy rules per addon?** Adds a WireGuard VPN via [gluetun](https://github.com/qdm12/gluetun), Docker-isolated, doesn't touch SSH or the host. (This isn't an anonymity setup on its own. See the guide if that's your actual goal.) Run with `setup-vpn-gluetun.sh`. → [Basic](./basic/vpn-setup.md) · [Advanced](./advanced/vpn-setup.md)

### Watchdog Alerts

- **Want a phone alert if something goes down?** Watches the VPN tunnel and AIOStreams (when the VPN is on) and MediaFlow Proxy (whenever it's set up). Needs at least one of those first. Run with `setup-watchdog.sh`. → [Basic](./basic/watchdog.md) · [Advanced](./advanced/watchdog.md)

### Webhook Relay

- **Want to turn a third-party site's "Webhook" notification option into a phone alert?** Gives you a real HTTPS endpoint on your own domain (something webhook fields require but a topic-based service like ntfy doesn't provide on its own), and relays whatever it receives to ntfy. Run with `setup-webhook.sh`. → [Basic](./basic/webhook-relay.md) · [Advanced](./advanced/webhook-relay.md)

### MediaFlow Proxy

- **Seeing a CPU spike every time you scrub/seek during playback?** Swaps AIOStreams' built-in proxy for [MediaFlow Proxy Light](https://github.com/mhdzumair/MediaFlow-Proxy-Light), a faster, lighter Rust-based proxy that handles the same scrub-triggered request bursts with far less CPU cost. Trade-off: you lose AIOStreams' own per-stream dashboard visibility while it's active (see the advanced guide). Includes optional hardening (blocked UI pages, a fail2ban jail). Run with `setup-mediaflow.sh`. → [Basic](./basic/mediaflow-proxy.md) · [Advanced](./advanced/mediaflow-proxy.md)

---

[← Back to main README](../README.md)
