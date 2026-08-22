# VPN Setup (optional .  server-side WireGuard via gluetun)

> In a hurry? [Basic guide](../basic/vpn-setup.md) covers the same steps with no deep explanations.

## What this is for

The [Proxy Setup](./proxy-setup.md) guide covers routing debrid traffic
through your VPS to dodge ISP blocking. This guide covers a different
layer: what to do if your **VPS's own IP** gets blocked .  by a scraper,
by a debrid provider, or by several things at once.

If it's specifically **one scraper or addon** that's blocked (Torrentio
returning nothing, a 403 in the logs, etc.), try
[Addon Proxy Setup](./addon-proxy-setup.md) first .  it's free, takes a few
minutes, and fixes just that addon without touching anything else about
your setup. This VPN layer is the broader tool: instead of routing one
addon's traffic, it puts *everything* AIOStreams does behind a VPN tunnel
at once .  every scraper, every debrid API call, all of it, unconditionally.
That's more than most single-blocked-scraper situations actually need, but
it's the right call if multiple things are getting blocked at once, or
you'd rather route everything through a VPN by default instead of managing
proxy rules addon-by-addon.

`setup-vpn-gluetun.sh` adds this VPN tunnel that only the
AIOStreams container uses. Flip it on, and AIOStreams' outbound traffic (to
TorBox, scrapers, etc.) exits through a WireGuard VPN server instead of
your VPS's own IP. Flip it off, and it goes back to exiting through your
VPS directly.

> ⚠️ **Two things worth knowing before you set this up:**
>
> 1. **The proxy and the VPN protect different traffic.** AIOStreams'
>    own outbound calls .  scraper searches, debrid API calls, metadata
>    lookups .  always exit through your VPS, and therefore through this VPN
>    once it's on, regardless of whether the [proxy](./proxy-setup.md) is
>    enabled. The proxy is a separate, additional layer that only matters
>    for the final video-data hop to your playback device .  turn it on too
>    if you also want your debrid provider to see the VPN's IP rather than
>    your VPS's during actual playback.
> 2. **Proxied video data uses real bandwidth**, on both ends now: your
>    VPS's own allowance, and potentially your VPN provider's too if they
>    cap data (many don't, but check). This was already true with the
>    proxy alone; adding the VPN tunnel doesn't change the *amount* of data,
>    just where it counts against.

> [!NOTE]
> This is an unblocking layer, not an anonymity layer .  see
> [Anonymity, if that's actually your goal](#anonymity-if-thats-actually-your-goal)
> below if you're after the stricter goal of your debrid provider never
> seeing your real IP at all.

**Can't lock you out:** SSH, Caddy, and everything else stay on your VPS's normal network. Only the AIOStreams container's traffic is affected. See [How it works](#how-it-works) for the full picture.

---

## Prerequisites

- This project's main setup already run (`setup-aiostreams.sh`) .  you need
  a working AIOStreams install first.
- A VPN provider that supports **WireGuard**, with a way to export a
  `.conf` config file (most major providers support this .  check their
  site or app for an "advanced," "manual setup," or "WireGuard" section).
- That `.conf` file uploaded somewhere on the VPS (SFTP works fine .  see
  [Getting your config onto the server](#getting-your-config-onto-the-server)).

---

## Getting a WireGuard config from your VPN provider

Steps vary by provider, but you're looking for a **WireGuard configuration
file** (not their regular desktop app installer). Most providers offer this
under an "advanced," "manual setup," or "router setup" section of their
site or app, often letting you generate one for a specific server/location.

⚠️ **Test the file works before uploading it to the VPS.** Import it into
any WireGuard-compatible client on your desktop first (the official
WireGuard app, or a third-party client) and confirm it connects. This
confirms the file itself is valid before we involve Docker at all .  if
something's wrong, it's much easier to diagnose on a desktop client than
inside a container.

If you test it locally, **disconnect it on your desktop before running it on
the VPS** .  using the identical key from two places at once can cause the
provider to disconnect one side.

---

## Important: gluetun needs an IP, not a hostname

Open your `.conf` file and look at the `Endpoint =` line under `[Peer]`.

If it looks like this, you're fine:
```
Endpoint = 212.15.80.116:51820
```

If it looks like this, you have one extra step first:
```
Endpoint = new-york.us.wg.someprovider.net:51820
```

gluetun's custom-provider mode requires a literal IP address here . 
domain/hostnames aren't supported (this is a known gluetun limitation, not
a bug in this script). Resolve it once and edit the file:

```bash
dig +short new-york.us.wg.someprovider.net
```

Take the IP that comes back and replace the hostname in the `Endpoint` line,
keeping the port (`:51820`) as-is.

Some providers' regional hostnames (like the example above) load-balance across multiple servers, so the IP you resolve today might change if you resolve it again in a few months. If the tunnel mysteriously stops connecting later, re-run `dig` and update the endpoint. Regional hostnames have this issue; server-specific ones don't.

---

## Getting your config onto the server

Any file transfer method works .  SFTP (e.g. via Termius, FileZilla, WinSCP)
is the easiest for most people. Drop the `.conf` file directly into your
home directory on the server .  no special folder needed. Where that is
depends on how you log in to run the script:
- **Logged in as root:** `/root/myvpn.conf`
- **Logged in as yourself, using `sudo` to run the script:** your own home
  directory, e.g. `/home/your_user/myvpn.conf`

The script auto-detects `.conf` files in either location (it checks both
`/root` and the invoking sudo user's home), so just remember the path in
case auto-detect doesn't find it .  you'll be asked for it either way.

---

## Installing the script

From the same directory as your AIOStreams install (`~/aiostreams`):

```bash
cd ~/aiostreams
curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-vpn-gluetun.sh -o setup-vpn-gluetun.sh
sudo bash setup-vpn-gluetun.sh
```

## First-time setup

The first run detects it hasn't been configured yet and walks you through
setup automatically:

1. Reads your existing domain/login straight out of your current
   `docker-compose.yml` .  nothing to re-enter.
2. Asks for the path to your `.conf` file (from the step above).
3. Backs up your current config.
4. Builds both a "direct" and a "VPN" version of your stack, and switches
   you into VPN mode.
5. Waits for the tunnel to connect and shows you gluetun's detected exit IP.

If the tunnel doesn't confirm within the wait period, the script tells you
exactly which log command to check and which commands would roll you back.

## Day-to-day usage

Run the script again any time and you'll get a menu instead of the setup
flow:

```bash
cd ~/aiostreams
sudo bash setup-vpn-gluetun.sh
```

```
1) Status
2) Turn VPN ON
3) Turn VPN OFF (direct connection)
4) Reconfigure VPN (change WireGuard server/config)
5) Update gluetun (pull latest image; safe restart if VPN is on)
6) Force cleanup (remove stray containers if a toggle got wedged)
7) Uninstall VPN layer (clean removal, back to plain AIOStreams + Caddy)
8) Exit
```

- **Status** .  shows current mode, container health, and (in VPN mode)
  gluetun's live exit IP. It also cross-checks that the live config still
  matches the mode it claims to be in, and warns you with instructions if
  something else has rewritten it (see
  [Changing your domain or login later](#changing-your-domain-or-login-later)).
- **Turn VPN ON / OFF** .  instantly swaps between your two saved configs and
  restarts the stack (a few seconds of downtime either way). Switching modes
  fully removes whatever the other mode was running .  nothing is left idling
  in the background.
- **Reconfigure** .  swap in a different `.conf` file (e.g. a different
  country/server) without redoing the whole setup.
- **Update gluetun** .  pulls the latest gluetun image. In VPN mode it then
  safely restarts the stack so the new image takes effect; in direct mode
  nothing restarts .  the fresh image simply gets used next time you turn the
  VPN on. (Note: the main script's **Update** option already refreshes
  gluetun too whenever VPN mode happens to be on, since it updates
  everything in the running stack. This option exists for updating gluetun
  on its own .  especially useful if you've been in direct mode a while.)
- **Force cleanup** .  a recovery tool, **not** routine maintenance. Only
  reach for it if a mode switch got interrupted (Ctrl+C, dropped SSH,
  reboot mid-switch) and containers look stuck or mismatched. It removes
  any stray containers by name so a normal toggle can bring things back
  cleanly. If everything is behaving, you should never need it.
- **Uninstall VPN layer** .  removes gluetun and its saved state entirely,
  switching back to a plain AIOStreams + Caddy stack first if VPN mode is
  currently on. Along the way it offers to also remove the gluetun Docker
  image and to delete your original `.conf` file (both are optional . 
  the `.conf` file contains your private key in plain text, so deleting it
  once you're done is worth doing). AIOStreams and Caddy themselves are
  untouched; running the script again afterward starts first-time VPN
  setup from scratch.

---

## After a reboot

Nothing to do .  **whatever mode you were in before the reboot comes back
automatically**, in both directions. In VPN mode, all three containers
(gluetun included) restart on their own and AIOStreams reconnects through
the tunnel. In direct mode, the gluetun container doesn't exist at all (the
toggle removes it entirely, rather than just stopping it), so a reboot can
never accidentally resurrect the VPN .  only AIOStreams and Caddy come back.

One rare edge case: on a slow boot in VPN mode, AIOStreams can occasionally
come up before the tunnel is fully ready and get stuck. If your site isn't
responding a minute or two after a reboot, just run the script, check
**Status**, or do a quick **Turn VPN ON** .  the toggle recreates everything
in the right order and fixes it every time.

---

## Changing your domain or login later

If you ever change your domain or login using the **main** script's
Reconfigure option (`setup-aiostreams.sh`, option 6), be aware it rewrites
`docker-compose.yml` in the plain no-VPN layout .  it doesn't know about the
VPN layer's saved configs.

> ⚠️ **After any main-script Reconfigure, run this script and choose
> option 4 (Reconfigure VPN)**, then toggle to whichever mode you want.
> That refreshes the VPN layer's saved configs with your new domain/login.
> If you forget, nothing breaks silently .  the **Status** option detects the
> mismatch and tells you exactly this, and it also catches the subtler case
> where the saved configs have merely gone stale.

---

## Verifying it's actually working

The quickest check: run the script and choose **Status** .  it prints
gluetun's exit IP directly. For the full side-by-side comparison against
your VPS's own IP:

From the VPS terminal:

```bash
# Your VPS's own IP .  should NOT change, ever, regardless of VPN mode
curl ifconfig.me
echo

# The AIOStreams/gluetun container's IP .  changes based on VPN mode
docker exec gluetun wget -qO- ifconfig.me/ip
echo
```

The `echo` after each command just forces a clean newline before the next
prompt. Without it, the IP and your next shell prompt can print on the same
line and look like the terminal is stuck when it isn't .  the command has
actually already finished.

In VPN mode, these two should be different. In direct mode, they'll match
(since without the tunnel, the container just uses the VPS's own IP).

Then confirm end to end: load `https://yourdomain`, log in, and try a stream
that previously needed a client-side VPN to work, with any VPN on your
playback device turned off.

---

## Proving the kill switch actually blocks traffic

The IP comparison above confirms the tunnel is up *right now*. It doesn't
confirm what happens if it ever goes *down* .  and that's the scenario that
actually matters, since a VPN that silently falls back to your VPS's real
IP the moment it drops is arguably worse than no VPN layer at all (it looks
protected when it isn't).

The only way to actually know is to break it on purpose and watch what
happens:

```bash
docker stop gluetun
```

Since AIOStreams shares gluetun's network namespace
(`network_mode: "service:gluetun"`), this doesn't just kill the tunnel .  it
removes AIOStreams' only network path entirely. Try loading
`https://yourdomain` or playing a stream:

- **A Caddy 502 Bad Gateway**, or the stream simply failing to load .  this
  is the kill switch working. Caddy tried to reach the aiostreams/gluetun
  bubble and found nothing there. No partial success, no fallback to your
  VPS's real IP.
- **The site or stream keeps working anyway** .  this would mean something
  is bypassing the VPN layer entirely, and is worth investigating
  immediately (double-check `docker compose ps` shows the `aiostreams`
  service really is using gluetun's network, and that you're testing while
  VPN mode is genuinely active .  see Status above).

The logic here matters as much as the result: if killing the tunnel breaks
playback, that's proof playback was *actually* routed through the tunnel
under normal conditions .  not just that the kill switch works in
isolation. A silent leak the whole time would mean stopping gluetun changes
nothing.

Restore properly afterward .  **not** a plain `docker start gluetun`:
```bash
cd ~/aiostreams
sudo bash setup-vpn-gluetun.sh
```
Choose **2) Turn VPN ON**. This does a full teardown/recreate and verifies
all three containers actually come back running, rather than trusting a
lone container restart to leave things in a consistent state.

What this test covers: stopping gluetun entirely tests the strongest guarantee. It doesn't exercise gluetun's internal iptables kill switch (for a WireGuard tunnel dropping while the container stays up), but that's harder to trigger cleanly. The practical question most people care about ("can a dead tunnel leak my real IP") is already answered by stopping the whole container.

**Want this checked automatically instead of by hand?** See
[Watchdog Alerts](./watchdog.md) .  a separate script that polls gluetun's
health every couple of minutes and pushes a phone notification if it ever
goes down for real, so you find out immediately rather than the next time
you happen to test it.

---

## Anonymity, if that's actually your goal
<a id="anonymity-if-thats-actually-your-goal"></a>

Everything above is about **unblocking** .  getting your VPS's own IP off scrapers' and debrid providers' block lists. If what you actually want is for your debrid provider to never see your real IP at all, that's a stricter, different goal, and this VPN layer alone doesn't achieve it.

It hides your VPS's IP going forward. It does not retroactively hide an account that's ever connected from somewhere else, and it isn't a one-time setup .  it needs to hold on *every* connection to that account, forever:

- **Opening the debrid provider's app or website directly** on your phone, laptop, or any device that isn't going through this VPS uses your real residential IP.
- **Logging into the account from anywhere not behind a VPN** .  mobile data, a friend's house, a work laptop .  does the same.

Either one, even once, puts your real IP on that provider's logs against that account, permanently .  nothing here can undo it afterward. For the goal to actually hold, the account itself would need to be created and always used from behind a VPN from the very first login, ideally paid for in a way that doesn't tie back to you (e.g. Monero).

This VPN layer only closes one piece of that: it guarantees the VPS side never connects unprotected (see [the kill switch proof](#proving-the-kill-switch-actually-blocks-traffic) above). It's an ingredient, not the whole recipe .  treat true anonymity as its own research topic, separate from this script.

---

## How it works

Two independent things are happening on your server, working separately:

- **The host** (SSH, Caddy, the firewall, the VPS itself) .  always on your
  VPS's normal IP. None of this setup ever touches it.
- **The AIOStreams container** .  shares its network with the `gluetun`
  container (`network_mode: "service:gluetun"` in Docker terms). When VPN
  mode is on, this whole bubble's outbound traffic exits through gluetun's
  WireGuard tunnel. When it's off, this bubble just uses the VPS's own
  network like everything else.

Because SSH was never part of that bubble, toggling VPN mode on/off can
never affect your ability to access the server .  worst case if something's
wrong with the tunnel is that AIOStreams itself stops responding, which you
fix by switching back to direct mode from the menu.

### Traffic flow, with Proxy + VPN both on

```
┌────────────┐        HTTPS         ┌───────────────────────────────┐
│  Playback  │ ───────────────────▶ │  Your VPS                     │
│  device    │ ◀─────────────────── │  ┌───────────┐  ┌───────────┐ │
│ (Stremio)  │   video data back     │  │  Caddy    │─▶│ AIOStreams│ │
└────────────┘                       │  └───────────┘  └─────┬─────┘ │
                                      │                       │       │
                                      │            shares network with│
                                      │                       ▼       │
                                      │                  ┌─────────┐  │
                                      │                  │ gluetun │  │
                                      │                  └────┬────┘  │
                                      └───────────────────────┼───────┘
                                                               │ WireGuard
                                                               ▼ tunnel
                                                      ┌──────────────────┐
                                                      │   VPN provider    │
                                                      │  (exit IP shown)  │
                                                      └─────────┬──────────┘
                                                                │
                                                                ▼
                                                      ┌──────────────────┐
                                                      │  Debrid provider  │
                                                      └──────────────────┘
```

**Who sees what:**

| Party                | Sees                                            | Does NOT see                          |
|-----------------------|--------------------------------------------------|----------------------------------------|
| Your ISP              | You connecting to your VPS domain (HTTPS)        | Anything past your VPS .  debrid, VPN, etc. |
| Debrid provider       | The VPN provider's exit IP + your account        | Your VPS's IP, your home IP            |
| VPN provider          | Your VPS's IP connecting to the tunnel           | What's inside the tunnel (which service, which account .  it's encrypted) |
| VPS provider          | Everything running on the box (it's their box)   | .                                       |

Each hop only sees the party immediately adjacent to it .  nobody in the
chain sees the full picture end-to-end (device → debrid account).

If the Proxy is off, delete the whole left/middle section of the diagram:
the playback device talks to the debrid provider directly, and neither your
VPS nor gluetun are involved in that traffic at all.

## Relationship to the Proxy setting

This VPN layer only affects traffic that already passes through your VPS.
If the [built-in AIOStreams proxy](./proxy-setup.md) is turned **off**,
playback devices connect to your debrid service directly .  bypassing your
VPS (and therefore gluetun) entirely for that traffic. The proxy needs to
be on for VPN mode to have any effect on your actual stream playback.

That said, this only applies to the final video-data hop to your playback
device. Every scraper addon call and debrid API call AIOStreams itself
makes .  searching, resolving links, checking your account .  always goes
through this VPN layer regardless of the Proxy setting, since the whole
AIOStreams container shares gluetun's network. For the full breakdown of
what's covered where, and the two viable ways to combine these two
settings, see [Proxy Setup: does the VPN layer cover addons and scrapers
too?](./proxy-setup.md#does-the-vpn-layer-cover-addons-and-scrapers-too-or-just-proxied-streams)

If you only need to fix one specific blocked scraper rather than route
everything, [Addon Proxy Setup](./addon-proxy-setup.md) is the lighter,
free alternative .  see [Where this leaves the VPN
layer](./addon-proxy-setup.md#where-this-leaves-the-vpn-layer) for how the
two compare directly.

---

## Troubleshooting

*(Run these from `~/aiostreams` .  `cd ~/aiostreams` first if you're not already there.)*

**"Couldn't confirm the tunnel came up" / status shows unhealthy**
Check the raw logs: `docker compose logs gluetun`. Look for connection
errors near the `[wireguard] Connecting to ...` line. A stale endpoint IP
(see the hostname section above) is the most common cause.

**Orphan container warnings when switching modes**
Mode switches tear down the currently running stack *before* swapping
configs (with `--remove-orphans` on both the way down and the way back up),
so switching to direct mode fully removes gluetun rather than leaving it
idling in the background. If a switch ever gets interrupted partway
(Ctrl+C, dropped SSH, reboot mid-toggle) and containers look stuck or don't
match the current mode, use **Force cleanup** (option 6) from the menu,
then toggle to the mode you want.

**Rolling back entirely**
Choose option 3 (Turn VPN OFF) from the menu .  this returns you to a plain
AIOStreams + Caddy stack, identical to before this script ever ran.

---

## Knowing if the tunnel goes down without checking manually

Everything above covers confirming the VPN is working *right now*. If you'd
rather get a phone notification the moment it isn't .  rather than finding
out when a stream fails to load .  see
[Watchdog Alerts](./watchdog.md), a separate bolt-on script that polls
gluetun's health and pings you via [ntfy.sh](https://ntfy.sh) on both the
way down and the way back up.
