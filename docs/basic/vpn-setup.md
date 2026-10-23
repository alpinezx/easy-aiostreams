# VPN Setup: Basic Guide

For adding a WireGuard VPN layer to AIOStreams.

## Do you actually need this?

This layer, [Addon Proxy Setup](./addon-proxy-setup.md), and [Proxy Setup](./proxy-setup.md) solve three different problems. Check which one matches what you're seeing:

- **Streams fail to load or time out, and turning on a VPN on your phone/TV "fixes" it** → that's your ISP blocking your debrid traffic, not your VPS's IP. You need the [Proxy Setup](./proxy-setup.md) instead. You don't need this guide.
- **A scraper inside AIOStreams or Comet (Torrentio, MediaFusion, etc.) is rate-limited, blacklisted, or quietly returning zero results** → that's your VPS's own IP getting blocked by that specific service. Try [Addon Proxy Setup](./addon-proxy-setup.md) first: it's free, takes a few minutes, and fixes just that addon without touching anything else. This VPN layer also fixes it, and covers every scraper and API call at once instead of one at a time: use it if multiple things are blocked, or you'd rather route everything through a VPN by default instead of managing proxy rules per addon.
- **None of the above, everything's working fine** → you probably don't need any of these guides yet.

> [!NOTE]
> This is an unblocking tool, not an anonymity tool. It's a different, stricter goal to make your debrid account itself untraceable to you: this VPN alone doesn't do that, and it's easy to undo by accident (e.g. opening the debrid app on a device that isn't behind it). → [Advanced guide](../advanced/vpn-setup.md#anonymity-if-thats-actually-your-goal) if that's what you're after.

Still not sure, or want the full technical breakdown of what each layer actually covers? → [Advanced guide](../advanced/vpn-setup.md#relationship-to-the-proxy-setting)

---

## 1. Get a WireGuard config file from your VPN provider

**This does:** gives you the file this script needs to connect.

In your VPN provider's site or app, look for an "advanced," "manual setup," or "WireGuard" section, and download a `.conf` file for a server/location of your choice.

**Test it works** by opening it in a WireGuard app on your own computer first and confirming it connects. Then **disconnect it there** before moving on: you can't use the same file in two places at once.

---

## 2. Install and run the script

**This does:** installs the VPN layer and walks you through first-time setup.

```bash
sudo curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-vpn-gluetun.sh -o /opt/aiostreams/setup-vpn-gluetun.sh
sudo bash /opt/aiostreams/setup-vpn-gluetun.sh
```

It asks how you'd like to give it your config. Press **Enter** to paste it:

1. Open the `.conf` file on your computer in a text editor (Notepad is fine), select everything and copy it.
2. Paste it into the SSH window. **Nothing shows on screen**, since it holds your private key. That's expected.
3. Press **Enter**, then **Ctrl+D**.

If the file's `Endpoint =` line has a name rather than an IP (like `new-york.us.wg.someprovider.net:51820`), the script looks the name up for you and lists the server addresses it found, fastest first. Press **Enter** for the recommended one. There's no need to edit the file first.

It then sets everything up and switches you into VPN mode.

Prefer to upload the file? Put it in your home folder with any SFTP app (FileZilla, WinSCP, Termius) and choose **2** instead of pasting; the script finds it.

---

## 3. Confirm it's working

**This does:** proves your traffic is actually going through the VPN now.

Run the script and choose **1) Status**: it prints gluetun's exit IP directly, no typing required:
```bash
sudo bash /opt/aiostreams/setup-vpn-gluetun.sh
```

Want to see it side-by-side with your VPS's own real IP, for extra proof? Run both of these:
```bash
curl ifconfig.me
echo
docker exec gluetun wget -qO- ifconfig.me/ip
echo
```
(The `echo` lines just force clean line breaks between outputs: without them the two IPs can print running into each other, which looks like something's stuck when it isn't.)

These two IPs should be **different**. If they match, the VPN isn't active: see the [advanced guide's troubleshooting section](../advanced/vpn-setup.md#troubleshooting).

Then load `https://yourdomain`, log in, and play a stream that previously needed a VPN on your device, with your device's VPN turned off.

---

## 4. Prove the kill switch actually blocks traffic (optional but recommended)

**This does:** confirms a dropped tunnel fails closed instead of quietly leaking through your VPS's real IP.

```bash
docker stop gluetun
```
Try loading `https://yourdomain` or playing a stream: it should fail (a Caddy 502, or the stream just not loading), not quietly keep working. That failure **is** the proof: if it kept working, your traffic wasn't really going through the tunnel to begin with.

Then bring it back properly (don't just `docker start gluetun`):
```bash
sudo bash /opt/aiostreams/setup-vpn-gluetun.sh
```
Choose **2) Turn VPN ON**.

---

## Everyday use

Run the script again any time for a menu:
```bash
sudo bash /opt/aiostreams/setup-vpn-gluetun.sh
```
- **Turn VPN ON / OFF**: switches modes, a few seconds of downtime.
- **Status**: shows whether it's on and healthy.
- **Reconfigure VPN**: switch to a different config. Paste it, pick an address, and it's used straight away. Its option **3** keeps your config and just picks a different server address, handy if the current one turns slow or blocked. Option **4** goes back to the config you used before your last change (the one you leave becomes the previous one, so you can swap back again), and **5** lists the configs kept on the server, to delete any you don't need.

Using the [control panel](./control-panel.md)? Its **VPN** page shows whether you're connected and where your traffic leaves from, and has **Turn VPN on** and **Turn VPN off**, **Change server** (another address for the same config, fastest first), **Change config** (paste a new one, with a way back), **Update VPN**, and a list of the configs on the server to use or delete. The Overview gets a VPN card too, and the **Network** page graphs what goes through the tunnel.

---

Need to change your domain/login later, or something isn't behaving? → [Advanced guide](../advanced/vpn-setup.md)

---

**Want to know if the tunnel ever goes down**, rather than finding out when a stream fails? → [Watchdog Alerts](./watchdog.md): a phone notification when it drops, and again when it recovers.
