# Addon Proxy Setup (routing scraper/addon traffic through a proxy)

> In a hurry? [Basic guide](../basic/addon-proxy-setup.md) covers the same steps with no deep explanations.

## What this is for

Scrapers like Torrentio sit behind Cloudflare and actively rate-limit or
blacklist IP ranges they recognise as datacenter/VPN/proxy traffic .  which
is exactly what a VPS's IP looks like to them. When that happens, you'll
typically see one of:

- The addon returning **zero results** where it used to return some
- A **403 Forbidden** in the logs for that addon's requests specifically
- The addon showing as rate-limited or erroring out entirely

This is a narrower, cheaper problem than "streams won't play" (that's the
[Proxy Setup](./proxy-setup.md) guide, a different feature). Here, it's
just that one scraper's *search* requests getting blocked .  nothing to do
with playback or your debrid account.

The fix: route just that scraper's outbound requests through a different
IP. AIOStreams has a built-in feature for exactly this .  the **Addon
Proxy** .  configured from the admin dashboard, not your regular per-user
config page.

---

## This is a different feature to the other two proxy-shaped things in AIOStreams

Three separate things use the word "proxy." Here's what distinguishes them:

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

⚠️ **Watch for link/text mismatches when copying credentials anywhere else.** If you paste this into a chat app, email, or anywhere that auto-links text, some tools render `user:pass@host:port` as clickable link text that doesn't match the real URL underneath. Always check the actual link target, not just what's displayed, before trusting or reusing it

---

**On free proxies specifically:** they're shared across many users, so
there's a real chance a given IP is already flagged by the same
Cloudflare-backed protection you're trying to route around. It costs
nothing to try, but if a proxy doesn't clear the block, that's often why . 
try a different one from the pool before assuming your config is wrong. If
you're relying on this long-term rather than as an occasional fix, a paid
residential/rotating proxy tends to fare better against this kind of
detection than another datacenter IP.

---

## Configuring it

1. Log into your AIOStreams **admin dashboard**.
2. Go to **Settings** → **Outbound Requests**.
3. **Addon proxy URL(s)** .  add your proxy's full connection URL:
   ```
   http://username:password@host:port
   ```
   Each one you add gets an index, starting at `0`, in the order you add
   them. You can add more than one .  useful if you want different addons
   routed through different proxies (e.g. a paid residential proxy for one
   heavily-blocked scraper, a free one for another).
4. **Addon proxy config** .  add rules mapping a hostname (or a
   `[context]` label like `[torrent_grabs]`) to a proxy index:
   - Key: `torrentio.strem.fun`, Value: `0` .  routes just Torrentio
     through your first configured proxy.
   - Key: `*`, Value: `0` .  routes *everything* through it (rarely what
     you want; defeats the point of a surgical fix and burns through a
     free tier's request limits fast).
   - Key: `*.strem.fun`, Value: `1` .  wildcard, matches any subdomain.

   When multiple rules could match the same request, the most specific one
   wins: exact hostname, then wildcard hostname, then `[context]` label,
   then global `*`. Note that this specificity order, not the order you add
   rules in the dashboard UI, decides what fires .  a `*` rule added first or
   last behaves identically either way.
5. Click **Save**. No restart needed .  this is a runtime setting.

**Confirmed by testing, and this reverses an earlier assumption:** as soon
as any URL exists under **Addon proxy URL(s)**, leaving **Addon proxy
config** completely empty does not mean nothing gets proxied. It means
*everything* does. A test run with zero config rules and one proxy URL
saved showed addon metadata calls, CDN traffic, and a full video fetch all
routing through the proxy, no rule required to trigger it. One session
pushed a free 1GB tier past 110% and broke the proxy for the rest of the
billing period. There is no safe unconfigured state once a proxy URL is
present.

**Rule of thumb: the moment you add a proxy URL, add `* = false` in the
same breath, before anything else.** Then add an indexed rule only for
the specific hostname(s) you actually want proxied. This isn't optional
tidiness and it isn't the same as leaving `*` unset, an empty config and
an explicit `* = false` are two different states, and only one of them is
safe. The exception: you're deliberately running an uncapped or paid
proxy and want everything routed through it by default, in which case
skip the `false` rule and set `*` to whichever index you want as the
default.

**Worked example** .  proxying Torrentio and TorBox's API specifically.
The `* = false` line isn't optional here, it's the line that keeps
everything else, including a Built-in Proxy video fetch if you're running
one, off this proxy entirely:

```
* = false
torrentio.strem.fun = 0
api.torbox.app = 0
```

Double-check exact hostnames against the addon's manifest URL rather than
guessing. A wrong domain won't error, it'll just quietly not match
anything, so the addon stays unproxied with no obvious sign why.
Torrentio's is `torrentio.strem.fun`, not `.stream.`, an easy typo to
make.

### Scaling beyond one addon

**Tested and confirmed: `[torrent_grabs]` is not a substitute for listing
hostnames, and shouldn't be expected to work for addons like Torrentio.**
A config of `* = false` + `[torrent_grabs] = 0` with no hostname rule
produced a 403 and zero Webshare activity on a Torrentio search, the same
search that worked fine with an explicit `torrentio.strem.fun = 0` rule.

Why, per AIOStreams' own docs and project history:

- `[torrent_grabs]`/`[nzb_grabs]` are paired with the `[newznab]`/
  `[torznab]` indexer addon types specifically. They tag the *grab*
  request, the second call an indexer-style addon makes to fetch the
  actual `.torrent`/`.nzb` file after an initial search. Torrentio has no
  such second step, it returns stream/magnet info in one call, so there's
  no "grab" request for this label to ever match, regardless of proxy
  config. It was never going to cover Torrentio.
- Even on addons that do have a grab step, there's a documented history
  of these labels not firing at all: a merged upstream fix
  ([PR #1046](https://github.com/Viren070/AIOStreams/pull/1046)) found
  that the internal proxy check was being made with no request-type
  context whatsoever, so `[nzb_grabs]` matched nothing, ever, until that
  fix shipped, and only for NZB-type grabs specifically. No equivalent
  fix for `[torrent_grabs]` was found at time of writing, so treat it as
  unreliable even on a genuine Torznab indexer addon until you've tested
  it yourself.

The reliable way to cover more than one addon is still to list each
hostname explicitly:

```
* = false
torrentio.strem.fun = 0
api.torbox.app = 0
```

More rules to maintain, but confirmed to work regardless of addon type.

### When `* = 0` (proxy everything) is actually fine

Two separate cases where a global rule isn't the bandwidth risk described
above:

- **You're not using the Built-in Proxy at all.** Without it, Stremio
  fetches the video directly from the source, AIOStreams never relays
  those bytes itself, so there's no video-sized fetch for `*` to sweep in.
  You'd still be proxying every addon's manifest/search/metadata calls,
  just not the large one.
- **You're using Built-in Proxy, but bandwidth genuinely isn't a
  constraint** .  a paid or uncapped proxy, covered above.

Either way, `* = 0` still means every metadata and search call from every
addon goes through the proxy, not just the video. Usually fine, just not
"nothing happens" the way it might read at a glance.

This is the dashboard equivalent of the `ADDON_PROXY` and
`ADDON_PROXY_CONFIG` environment variables, if you'd rather pin it via
`.env` instead (locks the field read-only in the dashboard).

---

## Watch for overlap with the Built-in Proxy

The Addon Proxy intercepts requests made via AIOStreams' internal request
utility, not just addon search calls specifically. If the [Built-in
Proxy](./proxy-setup.md) is also enabled, its fetch of the actual source
video is itself an outgoing request. That means a global Addon Proxy rule
(`* = 0`) can catch that fetch too, routing full video bytes through
whatever you've set as the addon proxy, not just lightweight metadata
calls.

This is easy to miss because nothing errors, the proxy just quietly
handles far more traffic than expected. **Measured, not hypothetical:**
with `* = 0` set and Built-in Proxy enabled, a single playback showed up
in the proxy provider's logs as a 379 MB request on its own, on top of
several smaller addon metadata calls (movie database lookups, indexer
sites) that had never gone anywhere near the proxy before. That's over
half of a free 1GB Webshare tier from one stream. With `* = false` set
instead and only the blocked scraper's hostname given an index, the exact
same playback produced zero bytes and zero requests in the proxy's logs .
the video fetch and every other unmatched call went out on the VPS's own
IP as normal.

On a capped free proxy, `* = 0` (or any index on the global rule) can burn
through the entire allowance in one sitting. It's why **Addon proxy
config** should always be scoped to specific hostnames with an explicit
`* = false` first, covered above, and why your debrid/video source domain
should never appear in that list.

**On proxy sources:** if you already pay for a VPN service, check whether
it offers its own proxy endpoints (SOCKS5 or HTTP) alongside the VPN.
These are often uncapped since they run on the same allowance as the VPN
itself, which makes them a more cost-effective and durable choice here
than a free proxy tier, especially if you want to run Addon Proxy scoped
broadly or alongside Built-in Proxy. Check your VPN provider's support
docs for manual/service credentials, these are usually separate from your
regular account login.

---

## Testing it

Search for something on the previously-blocked addon. Two ways to confirm
it's actually working, not just configured:

- **Results come back** where they didn't before .  the practical test.
- **Check the logs** for that addon's requests .  a 403 disappearing
  (replaced by a normal 200) confirms the block is actually cleared, not
  just that AIOStreams *attempted* to use the proxy.

If it's still failing after adding the proxy, double check the exact
hostname in **Addon proxy config** matches what's actually in the addon's
configured URL (some addons use a different subdomain or a self-hosted
mirror rather than the public one) .  a mismatch here means the rule simply
never fires.

**If you're repeating the same search or playback to compare before/after
results:** clear the relevant cache entries first (admin dashboard →
Cache), specifically the search caches (e.g. `eztv:search`,
`torznab:api:search:v2`, `streams`) and resolved-link caches (`st:link`,
`tb:link`, `usenet-stream:link`, `easynews:link`). Otherwise a repeat
search or playback can serve a cached result instead of actually re-running
the request, making it look like nothing changed when the config change
was never re-tested. This is purely about getting a clean test, it doesn't
affect and won't undo bandwidth already used, and it has no bearing on the
`* = false` guidance above.

---

## This is instance-wide, not per-config

Unlike the [Proxy setting](./proxy-setup.md#important-this-is-per-config-not-instance-wide),
which lives inside each user's saved config, the Addon Proxy is an admin
setting .  set once, applies to every config on this instance. For a
typical single-user setup, that distinction doesn't matter in practice,
but it's worth knowing if you ever add additional users.

---

## Where this leaves the VPN layer

Before this feature, the [VPN layer](./vpn-setup.md) (`setup-vpn-gluetun.sh`)
was the only way to fix a blocked scraper .  routing *everything* AIOStreams
does through a WireGuard tunnel, because the block wasn't otherwise
addressable per-addon. That's still a completely valid thing to run, but
for the specific problem of "one scraper is blocked," it's no longer the
first thing to reach for:

- **Just want to unblock a specific scraper?** Addon Proxy. Free, surgical,
  five minutes, no bandwidth cost, nothing else about your setup changes.
- **Multiple things blocked at once, or you'd rather route everything
  through a VPN by default instead of managing proxy rules per addon?**
  The VPN layer is the broader tool .  it wraps AIOStreams' entire outbound
  traffic, including your debrid provider's own API calls (account checks,
  library, resolving links), not just scraper search requests. See
  [VPN Setup](./vpn-setup.md#relationship-to-the-proxy-setting) for the
  full picture of what it covers that Addon Proxy doesn't. *(If your
  actual goal is your debrid provider never seeing your real IP at all,
  that's a stricter goal than either of these .  see
  [Anonymity, if that's actually your goal](./vpn-setup.md#anonymity-if-thats-actually-your-goal).)*
- **Both blocked traffic and privacy matter to you?** Nothing stops you
  running both .  they don't conflict. Addon Proxy can even point at your
  existing `gluetun` container as one of its proxy entries
  (`http://gluetun:8080`) instead of a separate paid/free proxy, if you'd
  rather not manage a second credential.
