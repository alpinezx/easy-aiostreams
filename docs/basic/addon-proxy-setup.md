# Addon Proxy Setup — Basic Guide

Use this if a **scraper or addon** inside AIOStreams (Torrentio, MediaFusion, etc.) is returning zero results and shows **403 Forbidden** in the AIOStreams logs for that addon's requests specifically. That means your VPS's IP getting blocked by that specific service. This is the cheapest, most surgical fix: free, no VPN needed, fixes just the one addon that's blocked.

> Seeing streams fail to *load or play*, and a VPN on your device "fixes" it? That's a different problem — see [Proxy Setup](./proxy-setup.md) instead.

> Want the full explanation, or to route more than one addon? → [Advanced guide](../advanced/addon-proxy-setup.md)

---

## 1. Get a free proxy
1. Sign up at [webshare.io](https://www.webshare.io/) — you'll land on **Free → Proxy List**, showing 10 free proxies already provisioned for you.
2. Pick any row, click the **⋮** (three dots) at the end of that row, and choose **Copy cURL Request**. This copies a full command like:

   > ⚠️ Example only — replace with your own copied values.

   ```
   curl --proxy "http://oiyfdxag:iv6licrazhu5@31.59.47.176:6754/" https://ipv4.webshare.io/
   ```

3. You only need the proxy part in the middle — not the `curl --proxy` wrapper, not the trailing test URL, not the trailing slash. From the example above, that's:
   ```
   http://oiyfdxag:iv6licrazhu5@31.59.47.176:6754
   ```
   That's the exact string that goes into **Addon proxy URL(s)** below.

---

**On free proxies specifically:** they're shared across many users, so
there's a real chance a given IP is already flagged by the same
Cloudflare-backed protection you're trying to route around. It costs
nothing to try, but if a proxy doesn't clear the block, that's often why —
try a different one from the pool before assuming your config is wrong. If
you're relying on this long-term rather than as an occasional fix, a paid
residential/rotating proxy tends to fare better against this kind of
detection than another datacenter IP.

---

## 2. Add it to AIOStreams

1. Log into your AIOStreams **admin dashboard** (not the regular configure page).
2. Go to **Settings** → **Outbound Requests**.
3. Under **Addon proxy URL(s)**, click **+** and add:

   > ⚠️ Example only — replace with your own copied values.
   ```
   http://oiyfdxag:iv6licrazhu5@31.59.47.176:6754
   ```
   
4. Under **Addon proxy config**, click **+** and add a rule:
   > Torrentio is being used in this specific example.
   - Key: the addon's hostname, e.g. `torrentio.strem.fun`
   - Value: `0` (the index of the proxy you just added)
5. Click **Save**.

This routes *only* that one addon's traffic through the proxy — everything else continues as normal.

---

## Test it

Search for something that previously failed on the blocked addon. If results come back now instead of nothing/an error, it worked.

---

⚠️ **One thing to know:** this is an admin-level setting — it applies instance-wide, not per-config like the video Proxy setting. For a typical single-user setup that's exactly what you want.

---

Need more detail, or want to route multiple addons through different proxies? → [Advanced guide](../advanced/addon-proxy-setup.md)
