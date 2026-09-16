# Proxy Setup (built-in AIOStreams proxy)

> 🏃 In a hurry? [Basic guide](../basic/proxy-setup.md) covers the same steps with no deep explanations.

## What this is for

Some ISPs block or throttle direct connections to debrid services (TorBox,
Real-Debrid, etc.), causing streams to fail to load or time out. Sometimes
this happens inconsistently, since only some IP ranges get flagged. If a VPN
on your device "fixes" playback, this is usually why.

Rather than running a VPN client on every playback device, you can route just
the debrid traffic through your own VPS instead. Your VPS fetches the stream
from the debrid service and relays it to your device. Since your VPS has its
own clean IP, it sidesteps the same blocking a home ISP connection runs into.

This is a feature built into AIOStreams itself (not something this script
installs). This doc just covers where to find it and how to set it up sensibly.

> ⚠️ **Bandwidth note:** unlike the rest of this project, turning this on
> routes actual video data through your VPS (not just lightweight config/API
> traffic). Keep an eye on your VPS provider's bandwidth allowance if you use
> this heavily. This is the one part of the setup that can meaningfully add to
> your monthly data usage. If you also add the [VPN layer](./vpn-setup.md)
> later, this same data may additionally count against your VPN provider's
> allowance too.

---

## Important: this is per-config, not instance-wide

The proxy setting lives inside your saved AIOStreams config (the same JSON
object you'd get from Export Config), not in the container's environment
variables. Enabling it once does not apply automatically to every config
you might create in the future. If you build a second config from scratch
(rather than editing your existing one), you'll need to enable the proxy
on that config too.

For a typical single-user setup, you'll only ever have one config, so this
is a one-time step.

---

## Enabling it

1. Open your AIOStreams configure page and log in.
2. Go to the **Proxy** settings page (found alongside Deduplicator, Result
   Limits, etc.).
3. Toggle **Enable**.
4. Leave **Proxy Service** as `Builtin Proxy`. No separate proxy software
   needed, it runs as part of the AIOStreams container itself.
5. **Credentials**: only required if you set `AIOSTREAMS_AUTH` on your
   instance (this project's setup script always sets this). Enter the same
   `username:password` pair from your login here. It's not a new/separate
   credential, just confirming the one already configured.
6. **Public IP**: leave blank. This is only relevant if you're running the
   Builtin Proxy locally behind a separate proxy server. Not the case for a
   standard remote VPS install like this one.
7. Under **Proxy Controls → Proxied Services**, select your debrid
   service(s) (e.g. TorBox). This scopes proxying to just that service's
   streams, rather than proxying everything.
8. Leave **Proxied Addons** empty so the scoping is handled by the service
   filter above.
9. Save.

Test it by loading a stream that previously failed, with any client-side VPN
turned off. If it loads, the proxy is doing its job.

---

## Bandwidth note

Unlike the rest of this project, proxied streams route actual video data
through your VPS (not just lightweight config/API traffic). Keep an eye on
your VPS provider's bandwidth allowance if you use this heavily. This is the
one part of the setup that can meaningfully add to your monthly data usage.

⚠️ **If you're also using [Addon Proxy](./addon-proxy-setup.md)** with a
global (`*`) rule, be aware it can catch this feature's own video fetch
too, not just addon search calls, and route the full stream through
whatever's set as the addon proxy. See
[Addon Proxy Setup: overlap with the Built-in Proxy](./addon-proxy-setup.md#watch-for-overlap-with-the-built-in-proxy)
for the details and how to scope around it.

---

## Does the VPN layer cover addons and scrapers too, or just proxied streams?

If you've also set up the [VPN layer](./vpn-setup.md), it's easy to assume
the VPN only matters for whatever you've ticked under **Proxy Controls**.
It doesn't. It's broader than that, and it's worth being clear on why.

There are two genuinely separate things happening, at two different layers:

**1. The Docker network layer (the VPN)** covers everything AIOStreams does.
Because AIOStreams runs with `network_mode: "service:gluetun"`, the entire
container shares gluetun's network. Every outbound connection AIOStreams
itself makes goes through the tunnel when VPN mode is on (not just
proxied services). That includes:

- Every scraper addon call (Comet, Torrentio, StremThru Torz, Knaben, etc.)
  searching for results
- Every debrid provider API call (checking your account, your library,
  resolving a torrent to a stream link)
- Metadata lookups
- The actual proxied video data, if the Proxy setting is also on

None of this is configurable per-addon or per-service. It's a consequence
of which container gluetun wraps. Scrapers aren't separate containers with
their own network; they're addons AIOStreams calls out to over HTTP from
inside itself, so they inherit whatever network AIOStreams is on.

**2. The Proxy setting** covers only the final video-data hop to your device.
This is the narrower, separate thing documented above on this page. It
controls whether the actual video *bytes* get relayed through AIOStreams to
your **playback device**, versus your device fetching the stream directly
from the debrid service. It's per-debrid-service (via Proxied Services), and
it only affects that last leg. It doesn't affect whether AIOStreams' own
outbound calls use the VPN (they do regardless).

**In short:** the VPN protects everything AIOStreams does on your behalf
(searching, resolving, checking your account) no matter what the Proxy
setting is. The Proxy setting decides whether the big, ISP-visible video
data on the final hop to your device also gets that same protection, or
goes direct instead.

If what you actually need is fixing one specific blocked scraper rather
than routing everything, that's neither of these. See
[Addon Proxy Setup](./addon-proxy-setup.md), a free, surgical option that
doesn't require the VPN layer at all.

---

## Two viable setups, and the trade-off between them

Once you understand the split above, there are two sensible ways to run
this. Not one "correct" answer. Which one fits depends on your playback
devices and how much you care about VPS bandwidth.

### Scenario A: Proxy on, VPS VPN on (set-and-forget)

- Every playback device just works. No VPN app needed anywhere, including
  smart TVs, game consoles, and anything else that can't run a VPN client.
- One place to manage: toggle it once on the VPS, done.
- Your debrid provider sees your VPN's exit IP for everything, including
  playback.
- **Trade-off:** video data flows through your VPS twice (in from the
  debrid service, out to your device). See the bandwidth note above.

### Scenario B: Proxy off, VPS VPN on, VPN on your playback device

- Video data goes straight from your device to the debrid service.
  Doesn't touch your VPS at all, so no VPS bandwidth cost for streaming,
  and no double-hop latency.
- Your debrid provider sees your device's VPN exit IP instead for
  playback. Same protection, different path.
- AIOStreams' own scraper/API traffic is still protected by the VPS's VPN
  either way. This doesn't change based on the Proxy setting.
- **Trade-off:** every playback device needs its own working VPN connection
  turned on before you press play, and needs to actually support running
  one. This is the exact limitation the Proxy feature exists to route
  around in the first place, so this only works for devices capable of it.

Neither scenario changes what a debrid provider's no-logging claims are
worth taking at face value. Both only control what IP address they see,
not what they choose to do with that information once a request reaches
them.
