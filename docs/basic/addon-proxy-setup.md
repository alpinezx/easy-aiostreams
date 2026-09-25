# Addon Proxy Setup .  Basic Guide

Use this if a **scraper or addon** inside AIOStreams (Torrentio, MediaFusion, etc.) is returning zero results and shows **403 Forbidden** in the AIOStreams logs for that addon's requests specifically. That means your VPS's IP getting blocked by that specific service. This is the cheapest, most surgical fix: free, no VPN needed, fixes just the one addon that's blocked.

> A **429 Too Many Requests** can also often be cleared the same way .  rate limits are usually tracked per-IP, so a fresh proxy IP can get you unstuck even though it's technically a different error.

> Seeing streams fail to *load or play*, and a VPN on your device "fixes" it? That's a different problem .  see [Proxy Setup](./proxy-setup.md) instead.

> Want the full explanation, or to route more than one addon? → [Advanced guide](../advanced/addon-proxy-setup.md)

> **Already using the [video Proxy setting](./proxy-setup.md)? You can run both.** They don't conflict, Addon Proxy only touches the hostnames you explicitly list below, everything else (including your video stream) stays untouched. The only requirement: `* = false` has to actually be set in step 2, an empty config with no rules at all is not safe, it defaults to proxying everything once a URL is saved. Follow this guide as written and you're fine running both at once.

---

## 1. Get a free proxy
1. Sign up at [webshare.io](https://www.webshare.io/) .  you'll land on **Free → Proxy List**, showing 10 free proxies already provisioned for you.
2. Pick any row, click the **⋮** (three dots) at the end of that row, and choose **Copy cURL Request**. This copies a full command like:

   > ⚠️ Example only .  replace with your own copied values.

   ```
   curl --proxy "http://username:password@proxy.example.com:8080/" https://ipv4.webshare.io/
   ```

3. You only need the proxy part in the middle .  not the `curl --proxy` wrapper, not the trailing test URL, not the trailing slash. From the example above, that's:
   ```
   http://username:password@proxy.example.com:8080
   ```
   That's the exact string that goes into **Addon proxy URL(s)** below.


## 2. Add it to AIOStreams

1. Log into your AIOStreams **admin dashboard** (not the regular configure page).
2. Go to **Settings** → **Outbound Requests**.
3. Under **Addon proxy URL(s)**, click **+** and add:

   > ⚠️ Example only .  replace with your own copied values.
   ```
   http://username:password@proxy.example.com:8080
   ```

   Each URL you add here gets numbered top to bottom, starting at `0`. The
   first one is `0`, the second one you add is `1`, and so on. That number
   is what you'll reference as the "index" in step 4 below.

4. Under **Addon proxy config**, add **two** rules, not one:
   > ⚠️ Torrentio is used here as the example addon. Swap in whichever addon's hostname is actually giving you the 403/zero results.
   - Key: `*`, Value: `false` .  this is the part that actually keeps everything else off the proxy. Don't skip it.
   - Key: the addon's hostname, e.g. `torrentio.strem.fun`, Value: `0` (the index of the proxy you just added, if you add a second proxy URL later and want this addon to use it instead, change this to `1`)
5. Click **Save**.

Your config should look like this:
```
* = false
torrentio.strem.fun = 0
```

This routes *only* that one addon's traffic through the proxy. The `* = false` line is what makes that true, not an assumption .  see the warning below.

## Test it

Search for something that previously failed on the blocked addon. If results come back now instead of nothing/an error, it worked.

⚠️ **If it's not working:** Check you've entered the values correctly and/or try a different proxy address. The free ones can often be blacklisted. If you're using the free proxy option, you have ten to try.

⚠️ **Never leave `*` unset, and never set it to an index, on a capped free proxy.** Confirmed by testing: leaving **Addon proxy config** completely empty, no rules at all, does not mean nothing gets proxied once a URL is saved under **Addon proxy URL(s)**. It means everything does. A test with zero config entries and one proxy URL saved showed addon calls, CDN traffic, and a full video playback all routing through the proxy, over 1.1 GB in one session, blowing straight past a free 1GB Webshare tier and breaking the proxy for the rest of the billing period. With `* = false` set instead, none of that traffic touched the proxy. An empty config and an explicit `* = false` are not the same thing, only one of them is safe. Always add `* = false` the moment you save a proxy URL, then list only the specific hostnames you actually want proxied with an index.

> ℹ️ Using [MediaFlow Proxy](./mediaflow-proxy.md) instead of the video Proxy setting? This warning doesn't apply to you, video never touches this config either way. See the [MediaFlow guide](./mediaflow-proxy.md) for how to proxy its traffic separately, if you want that.

💡 **Have a paid, uncapped proxy (or one bundled with a VPN plan you already pay for)?** Then routing everything through `* = 0` isn't a mistake, it's a legitimate choice if you'd rather have all outbound traffic, addon and video, going out through the same IP by default. The `* = false` warning above exists because most people start on a free tier with a hard cap. If bandwidth genuinely isn't a constraint for you, skip it and set `*` to whichever proxy index you want as the default.

💡 If you already pay for a VPN service, check if it offers its own proxy addresses (SOCKS5 or HTTP). These are often uncapped and free to use since they run on your existing VPN plan, making them a more durable option here than a free proxy tier.

---

This is an admin-level setting and applies instance-wide, not per-config like the video Proxy setting.

---

Need more detail, or want to route multiple addons through different proxies? → [Advanced guide](../advanced/addon-proxy-setup.md)
