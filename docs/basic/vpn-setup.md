# VPN Setup — Basic Guide

For adding a WireGuard VPN layer to AIOStreams.

## Do you actually need this?

This layer, [Addon Proxy Setup](./addon-proxy-setup.md), and [Proxy Setup](./proxy-setup.md) solve three different problems — check which one matches what you're seeing:

- **Streams fail to load or time out, and turning on a VPN on your phone/TV "fixes" it** → that's your ISP blocking your debrid traffic, not your VPS's IP. You need the [Proxy Setup](./proxy-setup.md) instead — you don't need this guide.
- **A scraper inside AIOStreams or Comet (Torrentio, MediaFusion, etc.) is rate-limited, blacklisted, or quietly returning zero results** → that's your VPS's own IP getting blocked by that specific service. Try [Addon Proxy Setup](./addon-proxy-setup.md) first — it's free, takes a few minutes, and fixes just that addon without touching anything else. This VPN layer also fixes it (it's broader — covers every scraper and API call at once), but it's the heavier option: more setup, and it changes how *everything* AIOStreams does exits your VPS, not just the one blocked service.
- **You want your debrid provider to never see your VPS's IP at all** — not just for unblocking, but so they can't see it for anything, searches or playback — this is what the VPN layer is actually for. Addon Proxy only routes what you explicitly add rules for; it won't cover this by default. Add the [Proxy Setup](./proxy-setup.md) too if you also want the video-data hop covered.

  > [!WARNING]
  > **The rest of this box only matters if your goal is anonymity — skip it if you're just here for unblocking.** If you don't care whether your debrid provider has ever seen your real IP, and just want a broader fix than Addon Proxy covers (bullet above), the VPN works fine for that with no extra conditions — turn it on and it does the job.
  >
  > If you *do* want the "never sees my real IP" goal, it only protects a fresh account, and only if you stay behind it — every time. It hides your VPS's IP going forward; it can't erase history the provider already has, and it stops protecting you the moment any connection to that account happens outside it.
  >
  > - The account needs to be created *and always used* from behind a VPN, from the very first login — ideally paid for in a way that doesn't tie back to you (e.g. Monero).
  > - Opening the debrid provider's own app/website directly on any device, or logging into the account from anywhere not behind a VPN, exposes your real IP to them — even once, permanently.
  >
  > This VPS-side VPN can't protect you from either of those — they happen outside this setup entirely. → [Full explanation](../advanced/vpn-setup.md#anonymity-requires-constant-vigilance)

- **None of the above, everything's working fine** → you probably don't need any of these guides yet.

Still not sure, or want the full technical breakdown of what each layer actually covers? → [Advanced guide](../advanced/vpn-setup.md#relationship-to-the-proxy-setting)

---

## 1. Get a WireGuard config file from your VPN provider

**This does:** gives you the file this script needs to connect.

In your VPN provider's site or app, look for an "advanced," "manual setup," or "WireGuard" section, and download a `.conf` file for a server/location of your choice.

**Test it works** by opening it in a WireGuard app on your own computer first and confirming it connects. Then **disconnect it there** before moving on — you can't use the same file in two places at once.

---

## 2. Check one line inside the file

**This does:** confirms gluetun (the VPN tool) can actually use this file — it needs an IP address, not a domain name.

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

Either way the script auto-detects it — remember the path in case you need it, but you likely won't need to type it.

---

## 4. Install and run the script

**This does:** installs the VPN layer and walks you through first-time setup.

```bash
cd ~/aiostreams
curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-vpn-gluetun.sh -o setup-vpn-gluetun.sh && sudo bash setup-vpn-gluetun.sh
```

It'll ask for the path to your `.conf` file from step 3, then set everything up and switch you into VPN mode automatically.

---

## 5. Confirm it's working

**This does:** proves your traffic is actually going through the VPN now.

```bash
curl ifconfig.me
echo
docker exec gluetun wget -qO- ifconfig.me/ip
echo
```
(The `echo` lines just force clean line breaks between outputs — without them the two IPs can print running into each other, which looks like something's stuck when it isn't.)

These two IPs should be **different**. If they match, the VPN isn't active — see the [advanced guide's troubleshooting section](../advanced/vpn-setup.md#troubleshooting).

Then load `https://yourdomain`, log in, and play a stream that previously needed a VPN on your device — with your device's VPN turned off.

---

## 6. Prove the kill switch actually blocks traffic (optional but recommended)

**This does:** confirms a dropped tunnel fails closed instead of quietly leaking through your VPS's real IP.

```bash
docker stop gluetun
```
Try loading `https://yourdomain` or playing a stream — it should fail (a Caddy 502, or the stream just not loading), not quietly keep working. That failure **is** the proof: if it kept working, your traffic wasn't really going through the tunnel to begin with.

Then bring it back properly — don't just `docker start gluetun`:
```bash
sudo ./setup-vpn-gluetun.sh
```
Choose **2) Turn VPN ON**.

---

## Everyday use

Run the script again any time for a menu:
```bash
sudo ./setup-vpn-gluetun.sh
```
- **Turn VPN ON / OFF** — switches modes, a few seconds of downtime.
- **Status** — shows whether it's on and healthy.
- **Reconfigure VPN** — swap in a different `.conf` file.

---

Need to change your domain/login later, or something isn't behaving? → [Advanced guide](../advanced/vpn-setup.md)

---

**Want to know if the tunnel ever goes down**, rather than finding out when a stream fails? → [Watchdog Alerts](./watchdog.md) — a phone notification when it drops, and again when it recovers.
