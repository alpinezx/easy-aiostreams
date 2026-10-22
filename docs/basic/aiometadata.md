# AIOMetadata: Basic Guide

Your own [AIOMetadata](https://github.com/cedya77/aiometadata): catalogs and metadata for Stremio-based clients, Nuvio and AIOStreams. The script installs it next to AIOStreams on its own subdomain and keeps it private. How you use it from there (catalogs, keys, configurations) is AIOMetadata's own territory: see [its README](https://github.com/cedya77/aiometadata#readme).

> Want the details: what it runs, backups, updates and going back? → [Advanced guide](../advanced/aiometadata.md)

---

## 1. Pick a subdomain and point it at this server

**This does:** gives AIOMetadata its own address, separate from your main AIOStreams domain. Your apps fetch catalogs from it directly.

Same requirement as the main installer: a subdomain with an **A record already pointed at this server's IP**, e.g. `meta.yourdomain.com`. Wait for it to propagate before continuing:

```bash
dig +short meta.yourdomain.com
```

Should print this server's IP.

---

## 2. Install and run the script

```bash
sudo curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-aiometadata.sh -o /opt/aiostreams/setup-aiometadata.sh
sudo bash /opt/aiostreams/setup-aiometadata.sh
```

Choose **2) Start**. It asks for the subdomain from step 1 (and checks it points here), and an **addon password** (Enter accepts a generated one). It installs AIOMetadata's newest release and prints its **configure page**, **addon password**, **Dashboard** and **admin key**. Option **6** shows them again any time.

---

## What's set up for you

- **Nobody can piggyback on your instance.** Creating a configuration needs the addon password, so your server and your API keys only serve your own configurations. The ones you make keep working in your apps without it.
- **The Dashboard is yours alone.** Guest mode is switched off, so it opens only with the admin key.
- **Releases are pinned**, so nothing changes until you update, and an update that doesn't start puts the previous release back by itself.
- **It's in your backups**, and a restore starts it again.

> ⚠️ When you add API keys in the Dashboard, use the rows named **Built-in ...** (e.g. **Built-in TMDB Key**). The plain rows just above them are shown to anyone who opens your configure page.

---

## Everyday use

Run the script again any time for a menu:
```bash
sudo bash /opt/aiostreams/setup-aiometadata.sh
```
- **Status**: running or not, its address, the release it runs and whether a newer one is out.
- **Start / Stop**: turn it on or off. Its settings and configurations are kept.
- **Reconfigure**: change the subdomain or the addon password.
- **Test**: checks it answers, both inside the server and over HTTPS.
- **Show address, password and admin key**.
- **Update**: its newest release (or an older one), with a backup first if you like.
- **Uninstall**: clean removal. Back up first if you might want it back.

With the [control panel](./control-panel.md), it gets its own card on the Overview (its version, Update, and its Dashboard and Configure links) and a row in Services. With [phone alerts](./watchdog.md), the watchdog tells you if it stops answering, and can tell you about new releases (off until you switch it on).

Need more detail? → [Advanced guide](../advanced/aiometadata.md)
