# Control Panel: Basic Guide

> [!NOTE]
> **Beta.** The control panel is new. If something looks wrong, [open an issue](https://github.com/alpinezx/easy-aiostreams/issues) with a screenshot.

A private web page for your AIOStreams server. See at a glance whether everything is up, and start, stop, update, back up and read logs with a button, from your phone or browser instead of SSH.

![The Overview tab: status, version, the path a request takes, and each service](../images/control-panel/overview.png)

⚠️ **Needs AIOStreams installed first** with `setup-aiostreams.sh`, and a **spare subdomain** for the panel, for example `panel.yourdomain.xyz`.

> Every page and button in detail, and how it's locked down → [Advanced guide](../advanced/control-panel.md)

---

## 1. Point a subdomain at your server

At your domain provider, add an **A record** for a new subdomain (for example `panel`) pointing at the same IP as your AIOStreams domain, as you did for the main domain in the [Quick start](../../README.md#confirm-your-dns-is-actually-pointing-at-your-server-first).

---

## 2. Download the panel

```bash
curl -fsSL https://github.com/alpinezx/easy-aiostreams/archive/refs/heads/main.tar.gz | sudo tar xz -C /opt/aiostreams --strip-components=1 easy-aiostreams-main/control-panel
```

---

## 3. Install it

```bash
sudo bash /opt/aiostreams/control-panel/setup-ui.sh
```

It asks for the subdomain from step 1, then a username and password (at least 10 characters). It takes a minute or two, and ends by printing an **unlock link**, something like `https://panel.yourdomain.xyz/unlock/...`.

---

## 4. Open the unlock link once

Until a browser has opened the unlock link, the panel's address just shows "Not found", so nobody else can even find the login page. Open it once in each browser you'll use (phone, laptop), then bookmark the plain address (`https://panel.yourdomain.xyz`).

![The login page](../images/control-panel/login.png)

Treat the unlock link like a password. If it leaks, make a new one (option 5 in the [panel's menu](#the-panels-menu-over-ssh)); that signs every browser out.

---

## Finding your way around

The pages are icons down the left; point at one to see its name. On a phone they're in the menu at the top left.

<img src="../images/control-panel/overview-phone.png" alt="The Overview tab on a phone" width="300"> <img src="../images/control-panel/menu-phone.png" alt="The menu on a phone" width="300">

- The buttons do the same as the matching options in the setup scripts, so you can mix the panel and SSH freely.
- Cards and pages for add-ons (AIOMetadata, AIOManager, MediaFlow, the VPN, Phone alerts...) only appear once you've set them up with their scripts.
- **Edit** on the Overview and **Edit menu** (the pencil) rearrange or hide cards and pages. The layout is saved on the server, so every device shows the same. Edit menu also has **Colours**: System (follows your device), Light or Dark, saved in that browser only.
- **Activity** keeps what every button printed, if you want to check how an update or backup went.

## Worth knowing

- **Restore is for rolling this same server back.** The panel checks first that the backup matches this install and its domains point here. If not, it refuses and gives you the command to run over SSH instead. Moving to a new server is always done over SSH ([backup guide](./backup-restore.md)).
- **Scheduled backups keep the newest 7 scheduled ones.** Backups you make yourself, ones made before an update, and locked ones are never removed.
- **Install updates** and **Set limits** on the Maintenance page restart every container for a few seconds, the panel included. The job carries on, and the page reconnects by itself.

---

## Turning on the terminal

A shell on the server in your browser, off until you switch it on, behind a key of its own:

```bash
sudo bash /opt/aiostreams/control-panel/setup-ui.sh
```

Choose **8**, then **1**. It shows a **terminal key** once: save it in your password manager. Reload the panel, open **Terminal** and type the key. The Scripts tab's **Run in terminal** buttons then type a script's command in there for you.

![Typing the terminal key](../images/control-panel/terminal-key.png)

---

## The panel's menu over SSH

The same command opens the panel's own menu any time:

```bash
sudo bash /opt/aiostreams/control-panel/setup-ui.sh
```

- **1) Status**, **2) Start**, **3) Stop**
- **4) Update**: download the newest panel and rebuild
- **5) Make a new unlock link**: signs out every browser
- **6) Change username/password**
- **7) Show the unlock link**
- **8) Web terminal**: turn on or off, make a new key
- **9) Uninstall**: removes the panel; AIOStreams isn't touched

## Updating the panel

When a newer panel is out, the version under its logo turns amber, and the **Scripts** tab offers **Update**. The panel is away for about a minute and the page reloads by itself; your login, unlock link and terminal key stay the same.

![The Scripts tab, with the panel's own version and update at the top](../images/control-panel/scripts.png)

If the panel won't start, or is too old to have that button, use **4) Update** in the menu above. Run it over SSH, not from the panel's own terminal, which the rebuild would cut off.

---

[← Other Scripts](../other-scripts.md) · [Advanced guide →](../advanced/control-panel.md)
