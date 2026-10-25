# Other Scripts

Optional add-ons on top of the main install. Each is its own standalone script, run whenever you want.

### Control Panel (beta)

- **Rather manage your server from a web page than over SSH?** A private dashboard on its own subdomain: see what's running, start, stop, update and back up with a button, read the logs, and optionally open a terminal from your phone. Locked behind a secret unlock link plus its own login. Run with `control-panel/setup-ui.sh`. → [Basic](./basic/control-panel.md) · [Advanced](./advanced/control-panel.md)

### AIOMetadata

- **Want your own catalogs and metadata, not a shared public instance?** Runs a private [AIOMetadata](https://github.com/cedya77/aiometadata) on its own subdomain: catalogs, posters, ratings and episode lists from TMDB, TVDB, MDBList and more, for Stremio-based clients, Nuvio and AIOStreams. An addon password keeps it yours, your API keys stay on the server, and releases are pinned, with updates (and a way back) from the menu or the control panel. Included in backups. Run with `setup-aiometadata.sh`. → [Basic](./basic/aiometadata.md) · [Advanced](./advanced/aiometadata.md)

### AIOManager

- **Managing addons across several Stremio accounts?** Runs a private [AIOManager](https://github.com/sonicx161/aiomanager) on its own subdomain: every account's addons in one place, snapshots, autopilot failover rules, watch history, and syncing to Nuvio. Sign-ups stay closed once your login is made (open them for 30 minutes to add someone), releases are pinned, with updates (and a way back) from the menu or the control panel, and it's included in backups. Run with `setup-aiomanager.sh`. → [Basic](./basic/aiomanager.md) · [Advanced](./advanced/aiomanager.md)

### VPN Setup

- **Want to use a VPN for addon/scraper unblocking system-wide, instead of managing proxy rules per addon?** Adds a WireGuard VPN via [gluetun](https://github.com/qdm12/gluetun), Docker-isolated, doesn't touch SSH or the host. (This isn't an anonymity setup on its own. See the guide if that's your actual goal.) Run with `setup-vpn-gluetun.sh`. → [Basic](./basic/vpn-setup.md) · [Advanced](./advanced/vpn-setup.md)

### Watchdog Alerts

- **Want a phone alert when your server needs you?** Works on any install: the site stops answering, the server restarts, the disk is nearly full, or the HTTPS certificate isn't renewing; plus the VPN tunnel, MediaFlow Proxy, AIOMetadata and AIOManager when they're set up. Optional alerts for new AIOStreams, AIOMetadata, AIOManager and MediaFlow releases and a weekly check-in. With the control panel it gets a Phone alerts page. Run with `setup-watchdog.sh`. → [Basic](./basic/watchdog.md) · [Advanced](./advanced/watchdog.md)

### Webhook Relay (retired)

> [!NOTE]
> **Retired in October 2026.** For alerts about this server, use [phone alerts](./basic/watchdog.md). To get another site's alerts on your phone, send them straight to ntfy if it can (many uptime trackers can). Still have the relay? It keeps running until you remove it, with **Uninstall** on its card on the control panel's Add-ons page, or over SSH once your scripts are up to date:
>
> ```bash
> sudo bash /opt/aiostreams/setup-aiostreams.sh remove-webhook-relay
> ```
>
> A restore leaves the relay out, even from a backup that has it.

### MediaFlow Proxy

- **Seeing a CPU spike every time you scrub/seek during playback?** Swaps AIOStreams' built-in proxy for [MediaFlow Proxy Light](https://github.com/mhdzumair/MediaFlow-Proxy-Light), a faster, lighter Rust-based proxy that handles the same scrub-triggered request bursts with far less CPU cost. Trade-off: you lose AIOStreams' own per-stream dashboard visibility while it's active (see the advanced guide). Includes optional hardening (blocked UI pages, a fail2ban jail). Releases are pinned, with updates (and a way back) from the menu or the control panel. Run with `setup-mediaflow.sh`. → [Basic](./basic/mediaflow-proxy.md) · [Advanced](./advanced/mediaflow-proxy.md)

---

[← Back to main README](../README.md)
