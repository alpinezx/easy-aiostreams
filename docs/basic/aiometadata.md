# AIOMetadata: Basic Guide

Your own [AIOMetadata](https://github.com/cedya77/aiometadata): catalogs and metadata (posters, descriptions, ratings, episode lists) for Stremio-based clients and Nuvio, from TMDB, TVDB, MDBList and others. It runs as its own small stack next to AIOStreams, on its own subdomain, and is private: nobody else can create configurations on it.

> Want to know how it's locked down, what a backup holds, or how updates and rolling back work? → [Advanced guide](../advanced/aiometadata.md)

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

Choose **2) Start**. It asks for:

- **The subdomain** from step 1. It checks the A record points here first.
- **An addon password** (Enter accepts a generated one). Creating a configuration needs it, so nobody else can use your server. The configurations you make keep working in your apps without it.

It installs AIOMetadata's newest release and prints four things at the end: the **configure page**, the **addon password**, the **Dashboard** and its **admin key**. Option **6** shows them again any time.

---

## 3. Add your API keys, once

**This does:** the keys every configuration on your server uses, so you never type them into a configuration.

1. Open the **Dashboard** (`https://meta.yourdomain.com/dashboard`) and sign in with the **admin key**.
2. Go to **Settings**, then **API Keys**.
3. Fill in the rows named **Built-in ...**, e.g. **Built-in TMDB Key**. A TMDB key is the only one you need, [free from TMDB](https://www.themoviedb.org/settings/api). The others (TVDB, Fanart, MDBList and so on) are optional extras.
4. Save.

> ⚠️ **Use the Built-in rows only.** The plain rows just above them (e.g. **TMDB API Key**) are handed to anyone who opens your configure page. The Built-in ones stay on your server. If you've put a key in a plain row, move it and clear the plain one. The [advanced guide](../advanced/aiometadata.md#api-keys-built-in-rows-only) shows how to check.

---

## 4. Make a configuration and install it

1. Open the **configure page** (`https://meta.yourdomain.com/configure`).
2. Pick your catalogs and settings, then save. It asks for the **addon password** from step 2, and for a password of its own for this configuration, so you can edit it later.
3. Install it in your Stremio-based client or Nuvio with the button it gives you, or add its manifest URL to AIOStreams.

---

## Everyday use

Run the script again any time for a menu:
```bash
sudo bash /opt/aiostreams/setup-aiometadata.sh
```
- **Status**: running or not, its address, the version it runs and whether a newer one is out.
- **Start / Stop**: turn AIOMetadata on or off. Its settings, configurations and keys are kept.
- **Reconfigure**: change the subdomain or the addon password.
- **Test**: checks it answers, both inside the server and over HTTPS.
- **Show address, password and admin key**: the four values from step 2.
- **Update**: its newest release, with a backup first if you like. If a new release doesn't start, the previous one is put back by itself. You can also pick an older version here.
- **Uninstall**: clean removal (containers, Caddy site, saved state). Back up first if you might want it back.

With the [control panel](./control-panel.md), AIOMetadata gets its own card on the Overview (its version, Update, its Dashboard and Configure links) and a row in Services. New releases come out often, up to twice a day, so the card shows a newer one quietly rather than as something to do.

Your [backups](./backup-restore.md) include AIOMetadata's settings, configurations and keys, and a restore starts it again. With [phone alerts](./watchdog.md), the watchdog tells you if it stops answering, and can tell you about new releases (off until you switch it on).

Need more detail? → [Advanced guide](../advanced/aiometadata.md)
