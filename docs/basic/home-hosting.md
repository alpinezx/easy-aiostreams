# Hosting from Home: Basic Guide

For running Easy AIOStreams on a computer at home (a mini PC, an old laptop, a home server) instead of a VPS, through a free Cloudflare Tunnel. This guide replaces the main README's Prerequisites and Quick start, which are for a VPS. Everything after installing is the same, and [After installing](#after-installing) links to it.

## Is this for you?

- **It works behind any home router.** Nothing to forward, no fixed IP, and it doesn't mind CGNAT (common on mobile broadband and some fibre). The server connects out to Cloudflare, and visitors reach it through that connection.
- **It's free.** A Cloudflare account and a tunnel cost nothing.
- **Your domain has to use Cloudflare's DNS.** You keep it where you bought it; only its nameservers move. A spare domain is easiest.
- **Your home upload speed is the limit.** A typical home line uploads 20 to 50 Mbit/s, enough for one or two streams through a proxy at once. Plain AIOStreams (which only sends links, not video) barely uses any.
- **The box has to stay on.** After a power cut or restart everything comes back by itself, tunnel included.

Want more detail first? → [Advanced guide](../advanced/home-hosting.md)

## What you need

- **A computer at home that stays on**, running Ubuntu 24.04+ or Debian 13, with at least 2 GB of RAM. A cable to your router is better than Wi-Fi.
- **SSH access to it** (or its own screen and keyboard), with a user that can use `sudo`.
- **A domain of your own** (step 1).
- **A free Cloudflare account** (step 2).

---

## 1. Get a domain

**This does:** gives you a name for your server, like `yourdomain.xyz`. Skip this if you already have a spare one.

You need a whole domain of your own, bought from a **registrar** (a company that sells domains). Free subdomains like DuckDNS's won't work here: a tunnel needs a domain you can point at Cloudflare.

The easiest choice is to **buy it from Cloudflare itself**: in your Cloudflare account (step 2), **Domains → Buy domain**. It's then on Cloudflare already, and you can skip step 2.

Any other registrar works too, for example [Porkbun](https://porkbun.com) or [Namecheap](https://namecheap.com). `.xyz` and `.top` are cheap and ready within minutes; country domains (`.co.uk`, `.de`) can take hours or days.

You only need the domain. Don't add any records at the registrar: Cloudflare makes them for you later.

---

## 2. Put your domain on Cloudflare

**This does:** lets Cloudflare answer for your domain, which a tunnel needs. Bought it from Cloudflare? It's already done: skip to step 3.

1. Make a free account at [dash.cloudflare.com](https://dash.cloudflare.com/sign-up).
2. In the left sidebar, click **Domains**, then **Overview** under it. Click the blue **Add a domain** button at the top right, then **Connect a domain** (not Transfer or Buy). Type the bare domain, like `yourdomain.xyz`.
3. Leave the DNS scan on automatic and continue. A spare domain shows **no records**: that's right. Continue to activation, and **Confirm** on the "Add records later" box.
4. Pick the **Free** plan.
5. Cloudflare shows **two nameservers** (like `kirk.ns.cloudflare.com`). At your registrar, replace the domain's nameservers with those two. On Porkbun: the small **NS** tag under the domain, delete the four `ns.porkbun.com` ones, add Cloudflare's two, **Save**, then **OK** on the warning. Somewhere else? Search for something like "change nameservers Namecheap", with your registrar's name.
6. Make sure **DNSSEC is off** at your registrar (it is unless you turned it on).
7. Back in Cloudflare, click **Check nameservers now**. It usually turns **Active** within minutes, and you get an email saying so.

> [!TIP]
> Using a domain that already runs other sites? Cloudflare's DNS scan copies its records over, but check they're all there before you change the nameservers, or those sites stop working.

---

## 3. Create the tunnel

**This does:** makes the connection your server will use, and gives you its token.

1. In Cloudflare's left sidebar: **Networking → Tunnels → Create Tunnel**.
2. Give it a name, like `aios-home`.
3. Under **Operating System**, choose **Docker**.
4. Click the copy button on the **Run tunnel with Docker** box and paste it into a private note. Keep only the long part after `--token` (it starts with `eyJ`): that's the **token**. Run nothing.

The page then waits for a connection, with **Continue** greyed out. That's expected: your server makes the connection in step 5. You can leave the page.

> [!CAUTION]
> The token lets anyone run your tunnel. Keep it private, like a password.

---

## 4. Add a route for each subdomain

**This does:** tells Cloudflare which names go down the tunnel. Do it **before** installing.

1. Leave the waiting page from step 3: click **Tunnels** in the left sidebar (under **Networking**). Then click your tunnel's name, and the **Routes** tab at the top left, next to **Overview**. Click **Add route**.
2. Choose **Published application**.
3. Fill it in:
   - **Subdomain:** just the first part, like `aio` (the Domain box adds the rest). Check the **Full hostname** line reads what you expect.
   - **Domain:** usually filled in already. With more than one domain on Cloudflare, pick the right one from its list.
   - **Path:** leave empty.
   - **Service URL:** `http://caddy:80`
4. Leave **Additional application settings** at the bottom folded: nothing in it is needed. Click **Add route**.

Add one for each name you'll use: AIOStreams now, and later one each for the control panel and any add-on with its own subdomain. They all use the same `http://caddy:80`.

> [!IMPORTANT]
> Use the **Routes tab on your tunnel**, not **Networking → Routes** in the sidebar: that one is for private networks. If a box mentions WARP, Gateway or Split Tunnels, you're in the wrong place.

Cloudflare's DNS page may show **Recommendations** like "Visitors cannot reach www…". Ignore them: each route makes the record it needs.

---

## 5. Install

**This does:** installs everything, then starts the tunnel with your token.

On the home computer, create the install folder and move into it:

```bash
sudo mkdir -p /opt/aiostreams && cd /opt/aiostreams
```

Download the installer:

```bash
sudo curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-aiostreams.sh -o setup-aiostreams.sh
```

Run it:

```bash
sudo bash setup-aiostreams.sh
```

It first asks **Where is this server?** Choose **2) A computer at home**, then **1) Fresh install**. (Moving from a VPS? Choose **2) Restore from a backup** instead: see [Adding more later](#adding-more-later).)

It asks for your domain (the full name from your route in step 4, like `aio.yourdomain.xyz`), a login and which build to run, like a VPS install, but skips the VPS's DNS check (your domain points at Cloudflare, not your home). Then it asks for the tunnel's token: paste it. **Nothing shows on screen** while you paste: that's expected.

It ends with **The Cloudflare Tunnel is connected**. Visit your domain and log in.

---

## 6. Always use HTTPS

**This does:** sends visitors who type `http://` to the secure address.

1. In Cloudflare's left sidebar, click **Domains**, then **Overview** under it.
2. Click your domain's name in the list in the middle.
3. In the left sidebar again, click **SSL/TLS**, then **Edge Certificates** under it.
4. Scroll down the page to **Always Use HTTPS**. It's off on a new domain: switch it on.

Its note about redirect loops doesn't apply: through the tunnel, your server never redirects to HTTPS itself, so the two can't loop.

---

## After installing

From here it works just like a VPS install. The main README covers each part:

- [The management menu](../../README.md#re-running-the-script-later): status, restart, updates, backups. With the tunnel on, option **11** is its own menu (a VPS doesn't have it).
- [The control panel](./control-panel.md), to manage it all from your browser or phone. Add its route first (step 4).
- [Backup & Restore](./backup-restore.md)
- [Other scripts](../other-scripts.md): add-ons, the VPN layer, phone alerts
- [Troubleshooting](../troubleshooting.md)

---

## Adding more later

- **The control panel or an add-on:** add its route first (step 4), then install it as its guide says. Where it would check your DNS, it reminds you about the route instead.
- **Already installed on a home server?** Run `sudo bash /opt/aiostreams/setup-aiostreams.sh tunnel`, then **Turn the tunnel on**. It lists the routes you need.
- **Moving from a VPS to home?** Back up on the VPS and copy the backup home ([Backup & Restore](./backup-restore.md)). In Cloudflare, delete the domains' old A records, then add their routes (step 4). At home, run the installer as in step 5, choose **2) A computer at home**, then **2) Restore from a backup**: it asks for the tunnel's token and puts the restored stack behind it. Switch the VPS off afterwards.
- **Changing your domain:** keep the same tunnel. Add a route for the new name first (step 4), then run `sudo bash /opt/aiostreams/setup-aiostreams.sh`, choose **6) Reconfigure** and type the new name. Once the site opens on it, delete the old name's route on the tunnel's Routes tab. One tunnel works for every domain in your Cloudflare account; you only need a new one for a domain in a different Cloudflare account. Then create it (step 3), add a route on it for every name you use, and choose **11) Cloudflare Tunnel**, then **Change the token**.

---

## If something's not right

- **Your browser says the site doesn't exist, but it's set up.** Something looked the name up before its route existed, and your router or ISP is remembering "doesn't exist" for up to 30 minutes. Wait, or try your phone on mobile data. Adding routes before installing avoids it.
- **"The Cloudflare Tunnel isn't connected".** Usually the token: choose **11) Cloudflare Tunnel**, then **Change the token**, and paste it again.
- **Red "stream canceled by remote" lines in the tunnel's log.** Someone closed a page or stopped a video. Harmless; the control panel shows them in grey.

More fixes: [Advanced guide: Troubleshooting](../advanced/home-hosting.md#troubleshooting)
