# Easy AIOStreams

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

A one-command installer for a self-hosted [AIOStreams](https://github.com/Viren070/AIOStreams) instance — Docker, Caddy (automatic HTTPS via Let's Encrypt), and AIOStreams' built-in login locking config creation to you alone, all in one script.

## Contents

- [What this gives you](#what-this-gives-you)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Re-running the script later](#re-running-the-script-later)
- [Notes](#notes)
- [Bypassing addon & ISP blocking](#bypassing-addon--isp-blocking)
- [Optional add-ons](#optional-add-ons)
- [Migrating to a new server](#migrating-to-a-new-server-optional)
- [Troubleshooting](#troubleshooting)

## What this gives you

- Your own AIOStreams instance, not a shared public one
- HTTPS out of the box, auto-renewing, no manual cert wrangling
- **App-level login** (AIOStreams' own auth): the configure page, dashboard, *and the config API itself* all require your username/password — nobody else can create or edit configs on your instance, even if they talk to the API directly
- A management menu — status checks, restart, updates, switching from stable to nightly & vice versa, backups, clean uninstall, all from one place.
- One-tarball backup and restore for migrating to a new server without losing any configs

## Prerequisites

- A fresh VPS with root access (any provider), running Ubuntu 24.04+ or Debian 13 (should also work on Debian 12, untested)
- A subdomain you control, with an **A record already pointed at your server's IP** before running the script

### Don't have a VPS yet?

Any provider with root SSH access works — DigitalOcean, Hetzner, Oracle's free tier, Vultr, and plenty of others all run this fine. If you want to compare specs and pricing before picking one, [vpsbenchmarks.com's under-$8/month list](https://www.vpsbenchmarks.com/best_vps/2026/under/8) is a decent starting point.

**This script won't run on Vercel, Netlify, Railway, or similar app-hosting platforms.**

### Don't have a domain yet?

Any registrar works, but a couple of tips if you're buying one just for this:

- **Prefer `.xyz` or `.top` over a country-code TLD (`.co.uk`, `.de`, etc.)** if you want to get moving fast. Generic TLDs are usually registered and DNS-ready within minutes; country-code domains can take anywhere from a few hours to a few days to fully activate, which just means sitting around waiting before you can even start the install.
- **[Porkbun](https://porkbun.com)** — cheap `.xyz`/`.top` domains, free WHOIS privacy and a free SSL cert bundled in, and about as close to instant activation as it gets.
- **[Spaceship](https://spaceship.com)** — Namecheap's newer, leaner sister registrar; competitive pricing (especially on `.com`) and free WHOIS privacy included.
- **[Namecheap](https://namecheap.com)** — the established option if you'd rather stick with a name you already trust; slightly pricier on renewals but a huge TLD selection.

Whichever you pick, add an **A record** pointing at your VPS's IP before running the script below — the install will fail the HTTPS step if DNS hasn't propagated yet.

## Quick start

### Confirm your DNS is actually pointing at your server first

The install fails the HTTPS step if your **A record** hasn't propagated yet. Run this — but swap `mystreams.xyz` for your own real domain first, it's just a placeholder:

Bare name only — no `https://`, no trailing `/`, no backslash. e.g. `dig +short mystreams.xyz`, or `dig +short aio.mystreams.xyz` for a subdomain. It should print a single IP — compare it to your server's:

```bash
dig +short mystreams.xyz
```

```bash
curl -4 ifconfig.me
```

If they don't match, DNS hasn't propagated yet — wait a bit and retry (generic TLDs like `.xyz`/`.top` are usually ready in minutes; country-code TLDs can take longer).

**✅ Example: Matches — good to go:**
```
ubuntu@vm1:~$ dig +short mystreams.xyz
192.0.2.15
ubuntu@vm1:~$ curl -4 ifconfig.me
192.0.2.15
```

**❌ Example: Doesn't match yet — wait and retry:**
```
ubuntu@vm1:~$ dig +short mystreams.xyz
198.51.100.23
ubuntu@vm1:~$ curl -4 ifconfig.me
192.0.2.15
```
Different IPs — the domain isn't pointing at this server yet. Don't run the installer until these two lines match.

### Run the installer

```bash
mkdir -p ~/aiostreams && \
curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-aiostreams.sh -o ~/aiostreams/setup-aiostreams.sh && \
cd ~/aiostreams && sudo bash setup-aiostreams.sh
```

The script will ask you for:
1. Your domain/subdomain
2. A username and password for logging into the instance

Passwords are limited to letters, numbers, and `@ % ^ * _ + = . ! ? -` — other symbols would break the `user:pass` environment format.

Everything else — Docker install, HTTPS certificate, secret key generation — is handled automatically.

Once it finishes, visit your domain and log in via AIOStreams' login page — from there, AIOStreams' own setup takes over.

## Re-running the script later

Run it again any time from the same directory (`~/aiostreams`) and it'll detect your existing install and offer a menu that keeps returning to itself after each action, so you can run several in a row without relaunching:

```
 1) View status
 2) Stop AIOStreams
 3) Start AIOStreams
 4) Restart the stack (AIOStreams + Caddy, and the VPN if enabled)
 5) Update (pull latest images + restart; can also switch stable/nightly)
 6) Reconfigure (change domain/login — backs up your current config first)
 7) Uninstall (clean removal)
 8) Backup (one tarball with everything needed for migration or safekeeping)
 9) Restore from backup (also runs on a fresh server: ./setup-aiostreams.sh restore <file>)
10) Exit
```

Moving to a new server? → see [Migrating to a new server](#migrating-to-a-new-server-optional) below.

**Stable vs nightly:** on a fresh install (or Reconfigure), you're asked whether to run the `latest` (stable) or `nightly` build. You can switch channels later at any time from the **Update** option — it'll show your current channel and offer to switch before pulling. Any time you actually change channel (not just re-confirm the one you're on), the script stops for an explicit y/N confirmation — with an extra note to back up first if you're going nightly → stable, since that's a downgrade and could hit a config/database format nightly has moved past.

## Notes

- Your `SECRET_KEY` and login are saved to `~/aiostreams/CREDENTIALS.txt` on first install — move it somewhere safe and delete it from the server; it can't be recovered if lost.
- If you had already created a config *before* enabling this protection, open the configure page once, log in, and hit **Save** so your config picks up the access key.

## Bypassing addon & ISP blocking

Not required for the core install — config-only, no separate script to run.

- 🚫 **A specific scraper/addon getting blocked or rate-limited?** → [Addon Proxy Setup](./docs/basic/addon-proxy-setup.md) ([advanced](./docs/advanced/addon-proxy-setup.md))
- 🔌 **Streams fail to load, but a VPN on your device "fixes" it?** → [Proxy Setup](./docs/basic/proxy-setup.md) ([advanced](./docs/advanced/proxy-setup.md))

## Optional add-ons

Not required for the core install — pick these up any time.

### VPN Setup

🛡️ **Want your debrid provider to never see your VPS's IP at all, or want to use a VPN for addon unblocking instead of a proxy?** Adds a WireGuard VPN via [gluetun](https://github.com/qdm12/gluetun), Docker-isolated, doesn't touch SSH or the host. → [Basic](./docs/basic/vpn-setup.md) · [Advanced](./docs/advanced/vpn-setup.md)

```bash
cd ~/aiostreams && \
curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-vpn-gluetun.sh -o setup-vpn-gluetun.sh && sudo bash setup-vpn-gluetun.sh
```

### Watchdog Alerts

🔔 **Want a phone alert if the VPN tunnel drops?** Requires the VPN layer above first. → [Basic](./docs/basic/watchdog.md) · [Advanced](./docs/advanced/watchdog.md)

```bash
cd ~/aiostreams && \
curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-watchdog.sh -o setup-watchdog.sh && sudo bash setup-watchdog.sh
```

These aren't mutually exclusive — running more than one at once is fine, and each guide links to the others where they interact.

## Migrating to a new server (optional)

- Backup & Restore — back up your whole stack to one tarball and restore it on a new VPS, same domain/login/`SECRET_KEY` and all, so every existing user config and installed Stremio manifest keeps working. Covers the DNS update you'll need to make afterward. → [Basic](./docs/basic/backup-restore.md) · [Advanced](./docs/advanced/backup-restore.md)

## Troubleshooting

- For setup questions or issues not covered here, see the [Reddit discussion thread](https://www.reddit.com/r/StremioAddons/comments/1vo6a5q/self_hosted_aiostreams_easy_install_script/) — several real-world VPS/proxy scenarios get covered there.
- "Couldn't confirm certificate issuance" during a fresh install, even though HTTPS actually works fine — fixed (2026-07). The check used to grep Caddy's logs for wording current Caddy versions no longer produce; it now verifies the TLS certificate directly instead.
- Anything else — VPN, restore, watchdog alerts — has its own **Troubleshooting** section at the bottom of that guide's advanced doc.

## License

MIT — see [LICENSE](./LICENSE). Provided as-is, no warranty; you're responsible for your own server, keys, and data.
