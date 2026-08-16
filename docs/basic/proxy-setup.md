# Proxy Setup — Basic Guide

Turn this on if streams fail to load or time out, and using a VPN on your device "fixes" it — that means your ISP is blocking your debrid traffic. (Seeing a *scraper or addon* inside AIOStreams/Comet rate-limited, blacklisted, or returning nothing instead? That's your VPS's own IP getting blocked — try [Addon Proxy Setup](./addon-proxy-setup.md) first, it's free and fixes just that addon; the [VPN Setup guide](./vpn-setup.md) also fixes it but is the heavier, broader option.)

> Want to know exactly how this works, or the bandwidth details? → [Advanced guide](../advanced/proxy-setup.md)

---

## Turn it on

This routes your debrid traffic (TorBox, Real-Debrid, etc.) through your VPS instead of your playback device, so ISP blocking can't see it.

1. Open your AIOStreams configure page and log in.
2. Go to the **Proxy** settings page.
3. Toggle **Enable**.
4. Leave **Proxy Service** as `Builtin Proxy`.
5. Under **Credentials**, enter the same `username:password` you use to log in.
6. Leave **Public IP** blank.
7. Under **Proxy Controls → Proxied Services**, select your debrid service (e.g. TorBox).
8. Leave **Proxied Addons** empty.
9. Click **Save**.

---

## Test it

Turn off any VPN on your playback device, then load a stream that previously failed. If it plays now, it worked.

---

⚠️ **One thing to know:** this routes real video data through your VPS, which counts against your VPS provider's bandwidth allowance if you stream a lot.

If you ever create a second config from scratch, you'll need to repeat these steps on that config too — this setting isn't instance-wide.

---

Need more detail? → [Advanced guide](../advanced/proxy-setup.md)
