# VPN Setup .  Basic Guide

For adding a WireGuard VPN layer to AIOStreams.

## Do you actually need this?

This layer, [Addon Proxy Setup](./addon-proxy-setup.md), and [Proxy Setup](./proxy-setup.md) solve three different problems .  check which one matches what you're seeing:

- **Streams fail to load or time out, and turning on a VPN on your phone/TV "fixes" it** → that's your ISP blocking your debrid traffic, not your VPS's IP. You need the [Proxy Setup](./proxy-setup.md) instead .  you don't need this guide.
- **A scraper inside AIOStreams or Comet (Torrentio, MediaFusion, etc.) is rate-limited, blacklisted, or quietly returning zero results** → that's your VPS's own IP getting blocked by that specific service. Try [Addon Proxy Setup](./addon-proxy-setup.md) first .  it's free, takes a few minutes, and fixes just that addon without touching anything else. This VPN layer also fixes it, and covers every scraper and API call at once instead of one at a time .  use it if multiple things are blocked, or you'd rather route everything through a VPN by default instead of managing proxy rules per addon.
- **None of the above, everything's working fine** → you probably don't need any of these guides yet.

> [!NOTE]
> This is an unblocking tool, not an anonymity tool. It's a different, stricter goal to make your debrid account itself untraceable to you .  this VPN alone doesn't do that, and it's easy to undo by accident (e.g. opening the debrid app on a device that isn't behind it). → [Advanced guide](../advanced/vpn-setup.md#anonymity-if-thats-actually-your-goal) if that's what you're after.

Still not sure, or want the full technical breakdown of what each layer actually covers? → [Advanced guide](../advanced/vpn-setup.md#relationship-to-the-proxy-setting)

---

## 1. Get a WireGuard config file from your VPN provider

**This does:** gives you the file this script needs to connect.

In your VPN provider's site or app, look for an "advanced," "manual setup," or "WireGuard" section, and download a `.conf` file for a server/location of your choice.

**Test it works** by opening it in a WireGuard app on your own computer first and confirming it connects. Then **disconnect it there** before moving on .  you can't use the same file in two places at once.

---

## 2. Check one line inside the file

**This does:** confirms gluetun (the VPN tool) can actually use this file .  it needs an IP address, not a domain name.

Open the `.conf` file and find the `Endpoint =` line. If it looks like this, you're good, skip to step 3:
```
Endpoint = 212.15.80.116:51820
```

If it looks like this instead (a name, not numbers):
```
Endpoint = new-york.us.wg.someprovider.net:51820
```
Run this to get the real IP:
```bash
dig +short new-york.us.wg.someprovider.net
```
Replace the hostname in the file with the IP it gives you, keeping the `:51820` part as-is.

---

## 3. Upload the file to your server

**This does:** puts the `.conf` file where the script can find it.

Use any SFTP app (FileZilla, WinSCP, Termius) to drop the file into your home directory on the server. Where that is depends on how you log in:
- **Logged in as root:** `/root/myvpn.conf`
- **Logged in as yourself, using `sudo` to run the script:** your own home directory, e.g. `/home/your_user/myvpn.conf`

Either way the script auto-detects it .  remember the path in case you need it, but you likely won't need to type it.

---

## 4. Install and run the script

**This does:** installs the VPN layer and walks you through first-time setup.

```bash
cd ~/aiostreams
curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-vpn-gluetun.sh -o setup-vpn-gluetun.sh
sudo bash setup-vpn-gluetun.sh
```

It'll ask for the path to your `.conf` file from step 3, then set everything up and switch you into VPN mode automatically.

---

## 5. Confirm it's working

**This does:** proves your traffic is actually going through the VPN now.

Run the script and choose **1) Status** .  it prints gluetun's exit IP directly, no typing required:
```bash
cd ~/aiostreams
sudo bash setup-vpn-gluetun.sh
```

Want to see it side-by-side with your VPS's own real IP, for extra proof? Run both of these:
```bash
curl ifconfig.me
echo
docker exec gluetun wget -qO- ifconfig.me/ip
echo
```
(The `echo` lines just force clean line breaks between outputs .  without them the two IPs can print running into each other, which looks like something's stuck when it isn't.)

These two IPs should be **different**. If they match, the VPN isn't active .  see the [advanced guide's troubleshooting section](../advanced/vpn-setup.md#troubleshooting).

Then load `https://yourdomain`, log in, and play a stream that previously needed a VPN on your device .  with your device's VPN turned off.

---

## 6. Prove the kill switch actually blocks traffic (optional but recommended)

**This does:** confirms a dropped tunnel fails closed instead of quietly leaking through your VPS's real IP.

```bash
docker stop gluetun
```
Try loading `https://yourdomain` or playing a stream .  it should fail (a Caddy 502, or the stream just not loading), not quietly keep working. That failure **is** the proof: if it kept working, your traffic wasn't really going through the tunnel to begin with.

Then bring it back properly .  don't just `docker start gluetun`:
```bash
cd ~/aiostreams
sudo bash setup-vpn-gluetun.sh
```
Choose **2) Turn VPN ON**.

---

## Everyday use

Run the script again any time for a menu:
```bash
cd ~/aiostreams
sudo bash setup-vpn-gluetun.sh
```
- **Turn VPN ON / OFF** .  switches modes, a few seconds of downtime.
- **Status** .  shows whether it's on and healthy.
- **Reconfigure VPN** .  swap in a different `.conf` file.

---

Need to change your domain/login later, or something isn't behaving? → [Advanced guide](../advanced/vpn-setup.md)

---

**Want to know if the tunnel ever goes down**, rather than finding out when a stream fails? → [Watchdog Alerts](./watchdog.md) .  a phone notification when it drops, and again when it recovers.
