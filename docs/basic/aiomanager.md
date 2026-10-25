# AIOManager: Basic Guide

Your own [AIOManager](https://github.com/sonicx161/aiomanager): one place to manage the addons of several Stremio accounts, keep snapshots of them, and sync to Nuvio. The script installs it next to AIOStreams on its own subdomain, and keeps it to the logins you make. How you use it from there (accounts, addons, autopilot) is AIOManager's own territory: see [its documentation](https://github.com/sonicx161/aiomanager#readme).

> Want the details: what it runs, sign-ups, backups, updates and going back? → [Advanced guide](../advanced/aiomanager.md)

---

## 1. Pick a subdomain and point it at this server

**This does:** gives AIOManager its own address, separate from your main AIOStreams domain. You open it in your browser.

Same requirement as the main installer: a subdomain with an **A record already pointed at this server's IP**, e.g. `manager.yourdomain.com`. Wait for it to propagate before continuing:

```bash
dig +short manager.yourdomain.com
```

Should print this server's IP.

---

## 2. Install and run the script

```bash
sudo curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-aiomanager.sh -o /opt/aiostreams/setup-aiomanager.sh
sudo bash /opt/aiostreams/setup-aiomanager.sh
```

Choose **2) Start**. It asks for the subdomain from step 1 (and checks it points here), installs AIOManager's newest release, and opens **sign-ups** so you can make your login.

---

## 3. Make your login

1. Open your subdomain in a browser and choose **New Account**. AIOManager makes you a **UUID**; you choose the password.
2. Copy your UUID from **Settings → General → Sync Identity** and keep it with your password in your password manager. **There's no password reset.**
3. Back in the terminal, press **Enter**. The script checks a login exists, then closes sign-ups.

From then on the sign-in page only offers **Login**: nobody else can make an account on your server.

---

## What's set up for you

- **Sign-ups are closed** once your login exists. Need another one (for someone in your household)? Open them for 30 minutes with option **10**, or the switch on the control panel's Add-ons page. They close by themselves afterwards, even if the server restarts in between.
- **Releases are pinned**, so nothing changes until you update, and an update that doesn't start puts the previous release back by itself.
- **It's in your backups**, logins and all, and a restore starts it again.

---

## Everyday use

Run the script again any time for a menu:
```bash
sudo bash /opt/aiostreams/setup-aiomanager.sh
```
- **Status**: running or not, its address, the release it runs, whether sign-ups are open, and how many logins there are.
- **Start / Stop**: turn it on or off. Its logins and data are kept.
- **Reconfigure**: change the subdomain.
- **Test**: checks it answers, both inside the server and over HTTPS, and that sign-ups are as set.
- **Show address**.
- **Update**: its newest release (or an older one), with a backup first if you like.
- **Uninstall**: clean removal. Back up first if you might want it back. The control panel's Add-ons page has it too.
- **Sign-ups** (option 10): open them for 30 minutes, or close them now.

With the [control panel](./control-panel.md), it gets its own card on the Overview (its version, Update, its Dashboard link, and how many logins it has) and a card on the Add-ons page with the sign-ups switch. With [phone alerts](./watchdog.md), the watchdog tells you if it stops answering, and can tell you about new releases (off until you switch it on).

Need more detail? → [Advanced guide](../advanced/aiomanager.md)
