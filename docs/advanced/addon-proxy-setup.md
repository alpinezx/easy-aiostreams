# Addon Proxy Setup (routing scraper/addon traffic through a proxy)

> 🏃 In a hurry? [Basic guide](../basic/addon-proxy-setup.md) covers the same steps with no deep explanations.

## What this is for

Scrapers like Torrentio sit behind Cloudflare and actively rate-limit or
blacklist IP ranges they recognise as datacenter/VPN/proxy traffic — which
is exactly what a VPS's IP looks like to them. When that happens, you'll
typically see one of:

- The addon returning **zero results** where it used to return some
- A **403 Forbidden** in the logs for that addon's requests specifically
- The addon showing as rate-limited or erroring out entirely

This is a narrower, cheaper problem than "streams won't play" (that's the
[Proxy Setup](./proxy-setup.md) guide, a different feature). Here, it's
just that one scraper's *search* requests getting blocked — nothing to do
with playback or your debrid account.

The fix: route just that scraper's outbound requests through a different
IP. AIOStreams has a built-in feature for exactly this — the **Addon
Proxy** — configured from the admin dashboard, not your regular per-user
config page.

---

## This is a different feature to the other two proxy-shaped things in AIOStreams

It's easy to conflate three separate things that all involve the word
"proxy." Worth being precise:

| Feature | What it routes | Where it's configured | Who it affects |
|---|---|---|---|
| **Addon Proxy** (this guide) | AIOStreams' own outbound requests to scraper/addon endpoints (e.g. Torrentio's search API) | Admin dashboard → Settings → Outbound Requests | Instance-wide |
| **Proxy** ([separate guide](./proxy-setup.md)) | The resolved video *stream* being relayed to your playback device | Per-user config → Proxy page | Just that user's config |
| **VPN layer** ([separate guide](./vpn-setup.md)) | *Everything* the AIOStreams container does outbound, at the Docker network level | `setup-vpn-gluetun.sh` | Instance-wide, unconditionally |

The Addon Proxy is the cheapest and most surgical of the three: free (a
handful of proxies from a free tier is usually enough), scoped to exactly
the addon that's actually blocked, and doesn't touch anything else.

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

⚠️ **Watch for link/text mismatches when copying credentials anywhere else.** If you paste this into a chat app, email, or anywhere that auto-links text, some tools render `user:pass@host:port` as clickable link text that doesn't match the real URL underneath. Always check the actual link target, not just what's displayed, before trusting or reusing it

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

## Configuring it

1. Log into your AIOStreams **admin dashboard**.
2. Go to **Settings** → **Outbound Requests**.
3. **Addon proxy URL(s)** — add your proxy's full connection URL:
   ```
   http://username:password@host:port
   ```
   Each one you add gets an index, starting at `0`, in the order you add
   them. You can add more than one — useful if you want different addons
   routed through different proxies (e.g. a paid residential proxy for one
   heavily-blocked scraper, a free one for another).
4. **Addon proxy config** — add rules mapping a hostname (or a
   `[context]` label like `[torrent_grabs]`) to a proxy index:
   - Key: `torrentio.strem.fun`, Value: `0` — routes just Torrentio
     through your first configured proxy.
   - Key: `*`, Value: `0` — routes *everything* through it (rarely what
     you want; defeats the point of a surgical fix and burns through a
     free tier's request limits fast).
   - Key: `*.strem.fun`, Value: `1` — wildcard, matches any subdomain.

   When multiple rules could match the same request, the most specific one
   wins: exact hostname, then wildcard hostname, then `[context]` label,
   then global `*`.
5. Click **Save**. No restart needed — this is a runtime setting.

This is the dashboard equivalent of the `ADDON_PROXY` and
`ADDON_PROXY_CONFIG` environment variables, if you'd rather pin it via
`.env` instead (locks the field read-only in the dashboard).

---

## Testing it

Search for something on the previously-blocked addon. Two ways to confirm
it's actually working, not just configured:

- **Results come back** where they didn't before — the practical test.
- **Check the logs** for that addon's requests — a 403 disappearing
  (replaced by a normal 200) confirms the block is actually cleared, not
  just that AIOStreams *attempted* to use the proxy.

If it's still failing after adding the proxy, double check the exact
hostname in **Addon proxy config** matches what's actually in the addon's
configured URL (some addons use a different subdomain or a self-hosted
mirror rather than the public one) — a mismatch here means the rule simply
never fires.

---

## This is instance-wide, not per-config

Unlike the [Proxy setting](./proxy-setup.md#important-this-is-per-config-not-instance-wide),
which lives inside each user's saved config, the Addon Proxy is an admin
setting — set once, applies to every config on this instance. For a
typical single-user setup, that distinction doesn't matter in practice,
but it's worth knowing if you ever add additional users.

---

## Where this leaves the VPN layer

Before this feature, the [VPN layer](./vpn-setup.md) (`setup-vpn-gluetun.sh`)
was the only way to fix a blocked scraper — routing *everything* AIOStreams
does through a WireGuard tunnel, because the block wasn't otherwise
addressable per-addon. That's still a completely valid thing to run, but
for the specific problem of "one scraper is blocked," it's no longer the
first thing to reach for:

- **Just want to unblock a specific scraper?** Addon Proxy. Free, surgical,
  five minutes, no bandwidth cost, nothing else about your setup changes.
- **Want your debrid provider (TorBox, Real-Debrid, etc.) to never see
  your VPS's real IP at all** — for privacy, not because anything's
  blocked — the VPN layer is still the right tool. Addon Proxy only
  routes addon/scraper *search* traffic; it doesn't touch your debrid
  provider's own API calls (account checks, library, resolving links)
  unless you deliberately add a rule for that provider's hostname too —
  and doing that is a different, higher-stakes decision than routing a
  public scraper, since it's tied to your actual paid account rather than
  an anonymous search request. See
  [VPN Setup](./vpn-setup.md#relationship-to-the-proxy-setting) for the
  full picture of what the VPN layer covers that this doesn't.
- **Both blocked traffic and privacy matter to you?** Nothing stops you
  running both — they don't conflict. Addon Proxy can even point at your
  existing `gluetun` container as one of its proxy entries
  (`http://gluetun:8080`) instead of a separate paid/free proxy, if you'd
  rather not manage a second credential.
