# MediaFlow Proxy: Basic Guide

An alternative to AIOStreams' built-in proxy. Runs as its own small container ([MediaFlow Proxy Light](https://github.com/mhdzumair/MediaFlow-Proxy-Light), a Rust rewrite), which handles scrub/seek bursts from Stremio-based clients noticeably faster and lighter on CPU than the built-in proxy does.

> Want the full explanation of why this exists, or the hardening options? → [Advanced guide](../advanced/mediaflow-proxy.md)

---

## 1. Pick a subdomain and point it at this server

**This does:** gives MediaFlow its own address, separate from your main AIOStreams domain. It needs its own subdomain because it has to be reachable from your streaming client directly, not routed through AIOStreams.

Same requirement as the main installer: a subdomain with an **A record already pointed at this server's IP**, e.g. `mediaflow.yourdomain.com`. Wait for it to propagate before continuing:

```bash
dig +short mediaflow.yourdomain.com
```

Should print this server's IP.

---

## 2. Install and run the script

```bash
sudo curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-mediaflow.sh -o /opt/aiostreams/setup-mediaflow.sh
sudo bash /opt/aiostreams/setup-mediaflow.sh
```

Choose **2) Start**. It'll ask for the subdomain from step 1 and a password (Enter accepts a generated one). It prints three values at the end.

---

## 3. Paste the settings into AIOStreams

**This does:** the actual point of all this.

1. Open your AIOStreams configure page and log in.
2. Go to the **Proxy** settings page.
3. Set **Proxy Service** to `MediaFlow Proxy`.
4. **URL**: the internal address the script printed (e.g. `http://mediaflow-proxy-light:8888`).
5. **Public URL**: the `https://` subdomain from step 1. This one's required, not optional, it's what your client actually connects to.
6. **Credentials**: the password the script printed.
7. Save.

Refresh the stream list in your Stremio-based client (or just reopen the title) so it picks up URLs pointing at the new proxy. No need to remove and re-add the addon, AIOStreams reads the proxy setting live on each request.

> 💡 Want MediaFlow's video traffic to go through a proxy too (e.g. Webshare, TorGuard)? That's a separate setting from anything in AIOStreams' Addon proxy config, see [Routing its traffic through a proxy](../advanced/mediaflow-proxy.md#routing-its-traffic-through-a-proxy) in the advanced guide. The script's Reconfigure option will ask for it.

> ⚠️ **Running gluetun VPN mode too?** Turning gluetun on does **not** route MediaFlow's video through the VPN, MediaFlow's container sits outside it structurally, always. If you want one consistent identity across everything (whether that's for privacy, or so multiple households can share one debrid API key without tripping its IP lock), see [Which setup actually matches your goal](../advanced/mediaflow-proxy.md#which-setup-actually-matches-your-goal) before assuming gluetun alone covers it.

---

## Everyday use

Run the script again any time for a menu:
```bash
sudo bash /opt/aiostreams/setup-mediaflow.sh
```
- **Status**: running or not, current domain/URL, and the release it runs.
- **Start / Stop**: turn MediaFlow on or off.
- **Update** (option 10): its newest release (or an older one), with a backup first if you like. Releases are pinned, so nothing changes until you update, and an update that doesn't start puts the previous release back by itself.
- **Test**: checks both that the container is alive and that the real public path (DNS + TLS + Caddy) actually works.
- **Show AIOStreams dashboard settings**: reprints the three values from step 3, any time.
- **Add fail2ban protection**: blocks bots that probe the subdomain. See the [advanced guide](../advanced/mediaflow-proxy.md#fail2ban-protection) before turning this on.
- **Uninstall**: clean removal (container, Caddy site, fail2ban jail if added, saved state). The control panel's Add-ons page has it too.

With the [control panel](./control-panel.md), it gets its own card on the Overview (its version, Update, and what's passing through it right now) and a card on the Add-ons page with the three AIOStreams settings from step 3, each with a Copy button. With [phone alerts](./watchdog.md), the watchdog tells you if it stops answering, and can tell you about new releases (off until you switch it on).

---

⚠️ Once MediaFlow is handling playback, AIOStreams' own built-in Streams dashboard will show nothing while a stream plays. That's expected, AIOStreams isn't in the data path anymore, see the [advanced guide](../advanced/mediaflow-proxy.md#what-you-lose-visibility) for why, and what you can check instead.

Need more detail, or want to know what the hardening options actually protect against? → [Advanced guide](../advanced/mediaflow-proxy.md)
