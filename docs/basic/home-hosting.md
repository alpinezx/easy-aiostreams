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
2. Click **Add a domain**, then **Connect a domain** (not Transfer or Buy). Type the bare domain, like `yourdomain.xyz`.
3. Leave the DNS scan on automatic and continue. A spare domain shows **no records**: that's right. Continue to activation, and **Confirm** on the "Add records later" box.
4. Pick the **Free** plan.
5. Cloudflare shows **two nameservers** (like `kirk.ns.cloudflare.com`). At your registrar, replace the domain's nameservers with those two. On Porkbun: the small **NS** tag under the domain, delete the four `ns.porkbun.com` ones, add Cloudflare's two, **Save**, then **OK** on the warning.
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

1. **Networking → Tunnels**, click your tunnel's name, then the **Routes** tab, then **Add route**.
2. Choose **Published application**.
3. Fill it in:
   - **Subdomain:** just the first part, like `aio` (the Domain box adds the rest). Check the **Full hostname** line reads what you expect.
   - **Domain:** your domain.
   - **Path:** leave empty.
   - **Service URL:** `http://caddy:80`
4. Leave the other settings alone and click **Add route**.

Add one for each name you'll use: AIOStreams now, and later one each for the control panel and any add-on with its own subdomain. They all use the same `http://caddy:80`.

> [!IMPORTANT]
> Use the **Routes tab on your tunnel**, not **Networking → Routes** in the sidebar: that one is for private networks. If a box mentions WARP, Gateway or Split Tunnels, you're in the wrong place.

---

## 5. Install

**This does:** installs everything, then starts the tunnel with your token.

Follow the README's [Run the installer](../../README.md#run-the-installer) steps. You can skip its DNS check: through a tunnel, your domain points at Cloudflare, not your home.

When it asks **How will people reach this server?**, choose **2) Through a Cloudflare Tunnel**. Then paste the token when asked. **Nothing shows on screen** while you paste: that's expected.

It ends with **The Cloudflare Tunnel is connected**. Visit your domain and log in.

---

## 6. Always use HTTPS

In Cloudflare, open your domain, then **SSL/TLS → Edge Certificates**, and switch on **Always Use HTTPS**. Visitors who type `http://` are then sent to the secure address.

---

## After installing

From here it works just like a VPS install. The main README covers each part:

- [The management menu](../../README.md#re-running-the-script-later): status, restart, updates, backups. Option **11** is the Cloudflare Tunnel's own menu.
- [The control panel](./control-panel.md), to manage it all from your browser or phone. Add its route first (step 4).
- [Backup & Restore](./backup-restore.md)
- [Other scripts](../other-scripts.md): add-ons, the VPN layer, phone alerts
- [Troubleshooting](../troubleshooting.md)

---

## Adding more later

- **The control panel or an add-on:** add its route first (step 4), then install it as its guide says. Where it would check your DNS, it reminds you about the route instead.
- **Already installed on a home server?** Run `sudo bash /opt/aiostreams/setup-aiostreams.sh`, choose **11) Cloudflare Tunnel**, then **Turn the tunnel on**. It lists the routes you need.
- **Moving from a VPS to home?** Back up on the VPS, restore at home ([Backup & Restore](./backup-restore.md)), then turn the tunnel on as above. Switch the VPS off afterwards.

---

## If something's not right

- **Your browser says the site doesn't exist, but it's set up.** Something looked the name up before its route existed, and your router or ISP is remembering "doesn't exist" for up to 30 minutes. Wait, or try your phone on mobile data. Adding routes before installing avoids it.
- **"The Cloudflare Tunnel isn't connected".** Usually the token: choose **11) Cloudflare Tunnel**, then **Change the token**, and paste it again.
- **Red "stream canceled by remote" lines in the tunnel's log.** Someone closed a page or stopped a video. Harmless; the control panel shows them in grey.

More fixes: [Advanced guide: Troubleshooting](../advanced/home-hosting.md#troubleshooting)
