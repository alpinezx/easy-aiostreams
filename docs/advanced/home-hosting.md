# Hosting from Home (Cloudflare Tunnel)

> In a hurry? [Basic guide](../basic/home-hosting.md) covers the same steps with no deep explanations.

## How it works

A VPS has a public IP, and visitors connect straight to Caddy on its ports 80 and 443. A home server usually can't take that: the router would need ports forwarded, the home IP changes, and with CGNAT there's no public IP of your own at all.

A Cloudflare Tunnel turns it around. `cloudflared`, one more container on your server, connects **out** to Cloudflare and keeps that connection open. Visitors reach Cloudflare, which holds your HTTPS certificates, and Cloudflare passes each request down the tunnel to Caddy. Nothing at home accepts a connection from outside.

```
Visitor --HTTPS--> Cloudflare --tunnel--> cloudflared --plain HTTP, inside Docker--> Caddy --> AIOStreams
```

Everything after Caddy is the same as on a VPS: the control panel, add-ons, the VPN layer, backups, phone alerts and Maintenance all work unchanged.

## What changes on the server

`setup-tunnel.sh` makes every change itself, and turning the tunnel off undoes them:

- **`cloudflared`** runs from `tunnel-state/` with its own compose file, on the `aios_shared` network like the add-ons. Its token is in `tunnel-state/token.env`, readable by root only, never printed or logged (its own log shows it as `*****`).
- **Caddy** gets one block at the top of the Caddyfile, between `# >>> Cloudflare Tunnel` and `# <<< Cloudflare Tunnel` lines. `auto_https off` and `https_port 80` make it serve every site as plain HTTP on port 80, with no certificates of its own. The site lines stay exactly as on a VPS, so the add-ons' and the panel's Caddy files don't change.
- **Ports 80 and 443** are no longer published on the server.
- **Network buffers**: `cloudflared` talks to Cloudflare over QUIC (UDP) and wants larger buffers than Linux allows by default. `/etc/sysctl.d/60-aiostreams-tunnel.conf` raises `net.core.rmem_max` and `net.core.wmem_max` to 7.5 MB, never lowering a higher setting you already have.

Turning it off puts the Caddyfile and compose file back exactly as a normal install writes them.

## The commands

With the tunnel on, the menu (`sudo bash /opt/aiostreams/setup-aiostreams.sh`) has option **11) Cloudflare Tunnel**; a server without it doesn't show the option. `sudo bash /opt/aiostreams/setup-aiostreams.sh tunnel` opens the same menu anywhere (downloading `setup-tunnel.sh` if it's missing), or run `setup-tunnel.sh` directly:

| Command | What it does |
|---|---|
| `on` | Asks for the token (hidden), starts `cloudflared`, switches Caddy over, waits until it's connected, and lists the routes needed. On an install that already has it, it just puts everything back in tunnel mode. |
| `off` | Asks first (`--yes` skips), then back to a normal server: ports, certificates from Let's Encrypt. Each site then needs an A record pointing at the server. |
| `status` | On or off, connected or not, and the hostnames that need a route. |
| `check` | Exit code only: 0 connected, 1 not connected, 2 off. The watchdog and status use it. |
| `routes` | The hostnames Caddy serves, each needing a route on the tunnel. |
| `token` | Paste a new token (after rotating it in Cloudflare, say). |
| `update` | Pulls the newest `cloudflared` and restarts it if there was one. Visitors wait a few seconds. |

## Real visitor addresses

Every request reaches Caddy from the `cloudflared` container, so without help AIOStreams would see that one address for every visitor, and its login lockout (5 wrong passwords per address) would lock everyone out at once. Cloudflare sends each visitor's real address in a `CF-Connecting-IP` header, and the block tells Caddy to use it, trusting it only from Docker's private networks. Nothing outside can reach Caddy to fake it: no ports are published.

## Routes, and the DNS records they make

Each hostname needs a route on the tunnel (**Networking → Tunnels → your tunnel → Routes → Add route → Published application**, Service URL `http://caddy:80`). Adding a route also creates its DNS record: in the domain's **DNS → Records** it shows as Type **Tunnel**, **Proxied** (orange cloud). Leave it proxied; a tunnel record only works that way.

Cloudflare's dashboard has a second, unrelated **Networking → Routes** page in the sidebar, for private networks (address ranges, WARP). It isn't this.

The DNS page also recommends records for `www` and the bare domain. Ignore those unless you serve something there.

## Installing, add-ons and the panel

On a fresh server the installer's first question is **Where is this server?** (`--home` answers it up front). **2) A computer at home** installs for a tunnel: it skips the "domain points at this server" check (it points at Cloudflare), asks for the token, and starts the tunnel before the stack, so Caddy never tries for certificates. A plain install never mentions the tunnel. Reconfigure keeps it.

The add-on scripts and the panel's `setup-ui.sh` skip their DNS check through a tunnel too, and remind you to add a route instead. Add the route first: if anything looks a name up before its record exists, resolvers can remember "doesn't exist" for up to 30 minutes (Cloudflare's negative-cache time).

## Changing the domain

Reconfigure (menu **6**) keeps the tunnel and skips the DNS check, so the new name needs its route before you switch: add it, Reconfigure, check the site, then delete the old route. The tunnel itself doesn't care which names it carries, as long as they're on the same Cloudflare account. For a domain on another account, make a tunnel there with a route for every name, then `setup-tunnel.sh token` and paste its token.

## Backups and restores

A backup holds `tunnel-state/` like everything else in `/opt/aiostreams`, token included, so treat backups as private as ever. A restore starts the tunnel again from it, with no questions, and skips the DNS checks a VPS restore makes (the panel's same-server restore included). Restoring a VPS's backup at home runs `setup-tunnel.sh on` once the backup is unpacked, before the DNS checks and the start, so it comes back behind the tunnel. A restore counts as for home when the installer's first question said so (**2**, then **2) Restore from a backup**), when the install it replaces had a tunnel (its `token.env` is carried over, so nothing is asked), or, for `setup-aiostreams.sh restore <file>` on a fresh server, when you answer **2** to the same question there. Before the tunnel starts it lists the backup's site names and offers new ones: the main site (Caddyfile, `BASE_URL`, the VPN layer's saved copies, `CREDENTIALS.txt`) and each add-on with a subdomain, the panel included, move together, so the routes it then lists are the new names. The panel's same-server restore never asks: it puts back exactly what the backup holds.

> [!WARNING]
> **Never run two servers with the same tunnel.** Both connect, and Cloudflare splits visitors between them, half each. When you restore onto a new box, switch the old one off (or its tunnel: `setup-tunnel.sh off`) first.

The buffer settings file is outside `/opt/aiostreams`, so it isn't in a backup; the restore's `on` writes it again.

## With the VPN layer

They don't touch each other: the tunnel is the way in, the [VPN layer](./vpn-setup.md) is AIOStreams' way out. Turning the VPN on or off swaps in its saved compose and Caddyfile, then has `setup-tunnel.sh` put the tunnel's block and closed ports back.

## MediaFlow Proxy and video

[MediaFlow](./mediaflow-proxy.md) (and AIOStreams' own proxy) send the video itself through your server, so through the tunnel it goes through Cloudflare. It works. Cloudflare's terms are unclear about serving video through its free plan, so it's your call; the script says so when you set it up. In practice your home upload speed limits it first.

MediaFlow's optional fail2ban jail can't work here: it bans addresses at the server's firewall, and tunnel visitors never reach the firewall (they all arrive from `cloudflared`). The script refuses it through a tunnel. MediaFlow's API password still protects it.

## Phone alerts and the control panel

The [watchdog](./watchdog.md) can't load the site through port 443, so through a tunnel it checks that `cloudflared` is connected (it's the only way in), then loads the site from Caddy over Docker's network, as `cloudflared` does. A tunnel that stays disconnected alerts as the site being down, saying so. The 6-hourly certificate check is skipped: Cloudflare renews those.

The [control panel](./control-panel.md) shows the tunnel first in the Request flow and Services (Visitors, Cloudflare Tunnel, Caddy, AIOStreams), with Logs and Restart; it turns amber when the tunnel loses Cloudflare. The certificate tile shows Cloudflare's certificate, the one visitors get. **Restart stack** restarts the tunnel with Caddy and AIOStreams.

## Troubleshooting

**The site "doesn't exist" in your browser, but Cloudflare shows the route.** A lookup made before the route existed got "doesn't exist", and something is remembering it, for up to 30 minutes. Some routers and ISPs answer every DNS lookup themselves from their own cache, whichever server you ask, so even `1.1.1.1` can give the stale answer. Wait it out, or try a phone on mobile data. A VPN on your computer usually brings its own DNS, which is why turning one on can "fix" it.

**`status` says not connected.** Usually the token: `setup-tunnel.sh token` and paste it again (only the `eyJ...` part). Check `sudo docker logs cloudflared` for the reason, and that the server has internet access.

**A lost or leaked token.** Lost: the server keeps it in `tunnel-state/token.env` (root only), every backup has it, and Cloudflare shows it again on the tunnel's **Overview** (choose **Docker** under **Select Operating System**; it's in the **Run tunnel with Docker** command, after `--token`). Leaked: **Rotate token** in the same page's **Refresh token** box. The old token stops working at once, so the site is down until `setup-tunnel.sh token` has the new one. Routes belong to the tunnel, not the token, so they stay.

**A route gives Cloudflare's error 1033 or 502.** 1033: the tunnel isn't connected. 502: it is, but the route's Service URL is wrong; it must be `http://caddy:80`, with the `http://`.

**Red lines in the tunnel's log: "stream canceled by remote with error code 0".** A visitor closed a connection that was still open: leaving a page that streams live (the panel's Logs, AIOStreams' dashboard) or stopping a video. Harmless; the control panel shows them in grey.

**"unexpected EOF" lines when AIOStreams or Caddy restarts.** An open AIOStreams dashboard keeps two live connections (`/api/v1/dashboard/.../stream`), the panel's Logs page one (`/api/logs/...`), and a restart cuts them. The panel greys those (or hides them, with **Hide noise** on), and the first half of every such pair (cloudflared logs each failure twice; only the second line names the address). A "Request failed" line for any other address stays red, as it's a real cut. So does "Unable to reach the origin service", which during a restart lasts a second or two, but otherwise means Caddy is down.

**"failed to sufficiently increase receive buffer size".** The network buffers above aren't raised; `setup-tunnel.sh on` raises them. Containers that block `sysctl` (some LXC setups) can't, and the tunnel then works a little slower.

**Can't reach the server on your network while your computer's VPN is on.** Not the tunnel: many VPN apps send local traffic into the VPN too. Look for a setting like "Allow LAN access" or "Bypass LAN".

**Going back to a VPS-style setup.** `setup-tunnel.sh off`, then in Cloudflare replace each Tunnel record with an A record to the server (grey cloud, DNS only, so Caddy can get its certificates), and forward ports 80 and 443 at your router if the server is at home.
