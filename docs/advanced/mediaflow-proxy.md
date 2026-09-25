# MediaFlow Proxy (advanced)

> 🏃 In a hurry? [Basic guide](../basic/mediaflow-proxy.md) covers the same steps with no deep explanations.

## What this is for

If you use a Stremio-based client (Stremio itself, Nuvio, and others) with AIOStreams' built-in proxy, you may notice a real CPU spike on your VPS every time you scrub/seek during playback, sometimes lasting 20-30 seconds. This isn't a bug specific to AIOStreams, and it isn't something a config change fixes:

Stremio-based clients open several parallel byte-range requests to the same file when you seek, sometimes 3-4 at once, occasionally more. Each of those forces the proxy in front of it to independently resolve and fetch the stream (hitting the source addon, the debrid API, then the CDN) rather than reusing one resolution across all of them, even though they're all requesting the exact same underlying file. That's real, repeated work, done redundantly, several times over, for a single seek.

Switching the actual proxying work from AIOStreams' built-in Node-based proxy to [MediaFlow Proxy Light](https://github.com/mhdzumair/MediaFlow-Proxy-Light) (a Rust rewrite, drop-in API-compatible with the original Python MediaFlow Proxy) doesn't eliminate this redundant-request pattern, that's baked into the client, not the proxy, but it resolves and discards each duplicate request so much faster that the spike shrinks from tens of seconds down to a few seconds. Same underlying behavior, much less time spent on it.

This is a genuine trade-off, not a strict upgrade, see [What you lose: visibility](#what-you-lose-visibility) below before deciding it's worth it for your setup.

---

## Why it needs its own subdomain, and why Public URL is required

AIOStreams generates the stream URL your client actually connects to. If MediaFlow's `URL` field points at an internal Docker address (`http://mediaflow-proxy-light:8888`), that's fine for AIOStreams itself to reach it, but your client is out on the internet and has no way to resolve or reach that address. The `Public URL` field exists specifically for this split: internal address for AIOStreams' own checks, public address for what actually gets handed to clients. Leaving Public URL blank when the URL field is internal-only will produce links your client can never load.

This is documented behavior in AIOStreams itself (see its own field descriptions on the Proxy settings page), not a workaround specific to this script.

---

## Networking: why aiostreams needs to be on `aios_shared`

By default, only `caddy` sits on the `aios_shared` Docker network in every compose template this project writes. `aiostreams` doesn't, because nothing before MediaFlow ever needed `aiostreams` itself to reach something else on that shared network, only the other direction (other bolt-ons reaching `caddy`) was ever needed.

MediaFlow is the first case where `aiostreams` needs to call *out* to something on `aios_shared` directly (to verify the proxy's public IP when you save the Proxy settings page). `setup-mediaflow.sh` detects and fixes this automatically, on every Start and Reconfigure, by patching `aiostreams`'s network list in your main `docker-compose.yml` if it isn't already there. Safe to run repeatedly, it checks first and does nothing if already correct.

If you ever see AIOStreams' Proxy settings page fail to save with `TypeError: fetch failed`, this networking gap is almost always why. Re-running Start (option 2) will re-apply the fix.

---

## What you lose: visibility

This is the real cost of switching, and it's worth being clear-eyed about it before you decide.

AIOStreams' own built-in Streams dashboard works by reading data AIOStreams tracks about streams passing through **its own** built-in proxy: filename, bytes served, current speed, request count, live progress. Once MediaFlow is doing the actual proxying, those bytes never pass through AIOStreams at all, AIOStreams only handles the initial link resolution now. There's nothing left for it to track, so the dashboard will correctly show nothing while a MediaFlow-proxied stream plays. That's not a bug, it's an accurate report of what AIOStreams can actually see.

MediaFlow Proxy Light does expose its own figures at `/metrics` (JSON: total requests, total bytes served, uptime, and an `active_connections` count that drops back as soon as each request is set up, so it reads close to 0 during real streaming). These are combined totals, not per-stream data: no filename, no per-file progress, no per-file speed. There's no way to rebuild the same rich per-stream view against it; that data simply doesn't exist in that shape.

**The two most reliable ways to confirm MediaFlow is actually doing the work, without full dashboard visibility:**

1. **Check the actual request domain.** Open DevTools' Network tab on your client while something plays, and confirm the video request goes to your MediaFlow subdomain, not directly to your debrid provider. This is the single most certain, unambiguous check, the domain a request hits can't be faked or misleading.
2. **Watch MediaFlow's own access log live:**
   ```bash
   docker logs -f mediaflow-proxy-light
   ```
   You'll see a line per request, including the filename (in the URL path) and status code (`206` for a real range request being served). Even with `Encrypt MediaFlow URLs` turned on in AIOStreams, only the destination parameter is encrypted, the filename itself stays readable in the log.

If you rely heavily on per-stream visibility day to day, weigh that against the CPU improvement (tens of seconds down to a few seconds) before switching. There's no wrong answer here, just make the trade-off deliberately rather than being surprised by it afterward.

---

## Routing its traffic through a proxy

By default, MediaFlow fetches video directly on this VPS's own IP.
**This is completely separate from AIOStreams' [Addon proxy
config](./addon-proxy-setup.md).** That setting only ever covers requests
AIOStreams itself makes, once MediaFlow is doing the actual fetching, the
video never passes through AIOStreams' request path at all, so nothing in
Addon proxy config, `* = false`, `* = 0`, hostname rules, none of it, has
any effect on MediaFlow's traffic either way. If you're using MediaFlow
and also want video routed through a proxy, it has to be set here,
independently.

MediaFlow Proxy Light exposes this via two environment variables:

```
APP__PROXY__PROXY_URL=http://user:pass@host:port
APP__PROXY__ALL_PROXY=true
```

Both matter. `PROXY_URL` alone configures a proxy but doesn't necessarily
apply it to every request by default, `ALL_PROXY=true` is what actually
turns it on globally. SOCKS5 is supported too
(`socks5://user:pass@host:port`), though see the
[addon-proxy guide's protocol notes](./addon-proxy-setup.md) if you're
deciding between the two, some providers restrict SOCKS5 to torrent-style
traffic specifically and it may not work for general streaming even
though it's accepted syntactically.

`setup-mediaflow.sh`'s Reconfigure option will prompt for an optional
proxy URL and wire it into the container automatically. Leave it blank to
keep video going out on the VPS's own IP as before.

**Test this the same way as any other proxy claim in this project, don't
trust it just because it's configured:** play something, then check your
proxy provider's own activity/usage dashboard for a request matching the
video's actual duration and size. If nothing shows up, the setting isn't
taking effect, if a large request appears matching what you just watched,
it's working.

---

## Which setup actually matches your goal

People reach for a proxy/VPN here for two genuinely different reasons,
and they need different setups. Worth being clear about which one you
actually have before picking a config, since the "correct" answer
changes completely depending on it.

**Goal A: one consistent IP, so a debrid provider's per-account IP lock
doesn't break when multiple households share one API key.** This isn't
about hiding anything, it's about every request looking like it came
from the same place. Self-hosting AIOStreams already centralizes
scraping, metadata, and debrid API calls onto your VPS's IP for everyone
who uses it, that part needs no extra setup at all. The only gap is
video playback, which without Built-in Proxy or MediaFlow goes straight
from each household's Stremio client to the CDN on their own home IP.
Turning on Built-in Proxy or MediaFlow, **even with no outbound proxy
configured on either**, closes that gap: video now also routes through
your VPS, so everything lands on one IP, your VPS's own. Nothing to
prove privacy-wise here, your real IP is exactly what's meant to be
visible, consistently, to the debrid provider.

**Goal B: hide your VPS's real IP from the debrid provider, scrapers,
and metadata services entirely.** This needs an actual proxy or VPN
somewhere in the path, your VPS's own IP alone isn't good enough, since
that's the thing you're trying not to expose.

**Goal C: both at once, hidden and shared.** Same requirement as Goal B,
a consistent *proxy* identity instead of your VPS's own, satisfies both:
one IP, and it isn't your real one.

| Setup | Scraping/metadata/debrid API sees | Video fetch sees | Achieves Goal A (consistency) | Achieves Goal B (hidden) |
|---|---|---|---|---|
| Built-in Proxy, no VPN, no Addon proxy | Your VPS's real IP | Your VPS's real IP (same request path) | ✅ | ❌ |
| Built-in Proxy + VPN (gluetun) | VPN exit IP | VPN exit IP (same request path, inherits gluetun automatically) | ✅ | ✅ |
| Built-in Proxy + Addon proxy config (`* = 0` or scoped, static IP) | Proxy's IP | Proxy's IP (same request path) | ✅ | ✅ |
| MediaFlow, no outbound proxy, no VPN | Your VPS's real IP | Your VPS's real IP (routed through MediaFlow, but MediaFlow has no proxy set, so still the VPS's own) | ✅ | ❌ |
| **MediaFlow + VPN (gluetun), MediaFlow's own proxy left unset** | VPN exit IP | **Your VPS's real IP** .  MediaFlow's container isn't on gluetun's network, gluetun being on doesn't change this | ❌ **split IP, breaks consistency too** | ❌ |
| MediaFlow + matching outbound proxy set on both Addon proxy config and MediaFlow's `PROXY_URL` | Proxy's IP | Proxy's IP (deliberately pointed at the same provider) | ✅ | ✅ |

The row to actually watch out for is the VPN+MediaFlow one. It's the
only combination on this list that's worse than doing nothing: not only
does it fail to hide your IP, it doesn't even keep a single consistent
identity, since video and everything else end up on two different IPs
in the same session. If you're running gluetun and want MediaFlow's
scrub/seek speed too, you need to explicitly set MediaFlow's own proxy
to close that gap, gluetun being on doesn't do it for you.

If Goal A is genuinely all you need (a private setup for your own
household, or one where you've separately confirmed your debrid provider
doesn't flag your VPS's hosting range, e.g. some allow Oracle/AWS ranges
that others block), the simplest row on this table, MediaFlow or
Built-in Proxy alone with nothing else configured, is a completely valid
and much easier setup to maintain than the full privacy stack. Don't add
VPN or proxy complexity you don't actually need.

---

## Hardening

Any public subdomain gets scanned by automated bots within hours of going live, regardless of what's actually running there, checking for WordPress vulnerabilities, exposed admin panels, common CGI paths, and so on. This is indiscriminate background internet noise, not targeted at you specifically, but worth closing off since MediaFlow's own browsable UI pages (home page, `/docs`, `/speedtest`, playlist/URL builder tools) serve no purpose in this setup and only add attack surface.

`setup-mediaflow.sh` blocks these pages automatically, every time you Start or Reconfigure, at the Caddy layer (returning a clean 404), regardless of what MediaFlow Proxy Light itself supports. This is deliberate: the original Python MediaFlow Proxy has `DISABLE_HOME_PAGE`/`DISABLE_DOCS`/`DISABLE_SPEEDTEST` environment variables, but MediaFlow Proxy Light's own environment variable reference does not list equivalents, so blocking at Caddy is the reliable option rather than relying on an unconfirmed feature.

### fail2ban protection

Menu option 7 goes a step further: it installs a fail2ban jail that watches Caddy's access log for this one subdomain specifically, and bans any IP that triggers 3 `401`s or `404`s on paths *outside* MediaFlow's real API within 10 minutes, for 24 hours.

Only paths outside the real API count: anything under `/proxy/*` and `/extractor/*` (including MediaFlow's encrypted links, `/_token_…/proxy/…`, which is what AIOStreams sends), plus `/generate_url(s)`, `/health`, `/metrics` and the bare `/`, is ignored even when it errors. That matters because real clients can legitimately get errors there: a `401` from a stream link cached before you changed the password, or a `404` passed through from a dead upstream link. Counting those would ban your own IP from ports 80/443 for 24 hours, main AIOStreams site included. Bots, on the other hand, probe paths like `/wp-login.php`, `/.env` and `/admin`, which a real client never requests, so those still get banned.

**This server's own public IP is automatically detected and permanently exempted** from ever being banned by this jail. This matters because testing the subdomain *from the server itself* (e.g. running `curl` against the public domain while SSH'd into the VPS) causes the request to hairpin back through the server's own public IP, making a local test look identical to an external visitor. Without the exemption, this is a realistic and easy way to accidentally ban your own server, and since the ban applies firewall-wide on ports 80/443, it would also take down your main AIOStreams domain, not just this subdomain, since both share the same server and IP.

**If you (or whoever's watching streams) route through a commercial VPN, know that the ban is by IP, not by person.** Commercial VPN exit IPs are typically shared across many of that provider's customers at once. If anyone else on your same exit node trips the 3-strikes rule on this subdomain, you get banned right along with them for 24 hours, through no action of your own. There's no per-user way around this, IP is the only signal Caddy's access log has to work with. If streams through this proxy start failing for no reason you can find, check whether your client's current IP is on the list before assuming something's broken:
```bash
sudo fail2ban-client status aios-mediaflow
```

**To test the jail properly**, use a genuinely separate machine with its own public IP (a phone on mobile data, a different VPS, a friend's connection), not this server itself:
```bash
curl -s -o /dev/null -w '%{http_code}\n' https://mediaflow.yourdomain.com/docs
```
Run it 3 times from the external machine, then check:
```bash
sudo fail2ban-client status aios-mediaflow
```
You should see that machine's IP listed as banned. To undo a test ban:
```bash
sudo fail2ban-client set aios-mediaflow unbanip <the-ip>
```

Remove the jail entirely with menu option 8. It only touches its own filter/jail files (`/etc/fail2ban/filter.d/aios-mediaflow.conf`, `/etc/fail2ban/jail.d/aios-mediaflow.conf`); any other jails on the server (SSH protection, etc.) are untouched.

---

## Everyday use / menu reference

Run `sudo bash setup-mediaflow.sh` from `~/aiostreams` any time for the menu: Status, Start, Stop, Reconfigure, Test, Show AIOStreams dashboard settings, Add/Remove fail2ban protection, Uninstall.

**Test** (option 5) checks two things in sequence: first that the container itself responds (via a throwaway `curlimages/curl` container on the same Docker network, since MediaFlow Proxy Light's image has no shell utilities of its own to exec into), then that the real public path works end to end (DNS, TLS, and Caddy, the same route your actual streaming client uses). If the first passes but the second fails, the problem is in DNS/cert/Caddy, not MediaFlow itself.

**Uninstall** removes the container, its Caddy site, the fail2ban jail if one was added, and saved config. Remember to switch AIOStreams' Proxy settings back off MediaFlow afterward if you don't have another proxy to point it at.
