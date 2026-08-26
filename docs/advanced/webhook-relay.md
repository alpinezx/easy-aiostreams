# Webhook Relay (optional — turn any site's webhook into a phone alert)

> In a hurry? [Basic guide](../basic/webhook-relay.md) covers the same steps with no deep explanations.

## What this is for

Plenty of status pages, monitoring tools, and self-hosted dashboards offer a "Webhook" notification channel alongside email/Discord/ntfy, but a webhook isn't a topic name you can just type in — it needs an actual HTTPS endpoint that's already running, ready to accept a `POST`, before you can point anything at it. `setup-webhook.sh` gives you that endpoint on the same server and domain you already have running AIOStreams, and relays whatever it receives to [ntfy.sh](https://ntfy.sh), the same delivery mechanism the [watchdog](./watchdog.md) uses.

It requires `setup-aiostreams.sh` already installed and running — it reuses that install's Docker network and Caddy instance rather than standing up its own.

---

## Architecture

This runs as a **separate, standalone Docker Compose stack**, not an addition to the main `docker-compose.yml`. Deliberately so: a bug here can't take down AIOStreams or its Caddy instance, and there's nothing to merge or conflict with on an Update/Reconfigure of the main install.

The two stacks talk to each other through the `aios_shared` external Docker network, which `setup-aiostreams.sh` already creates. The relay container joins it under a fixed name (`aios-webhook-relay`), and a file gets dropped into `~/aiostreams/caddy.d/` (the drop-in directory the main Caddyfile already `import`s), so the main Caddy instance picks up automatic HTTPS for the new subdomain without its own Caddyfile ever being touched.

The receiver itself is stdlib-only Python (`http.server`), mounted into an unmodified `python:3-alpine` image rather than a custom-built one — nothing to build, nothing to publish, one file to read if you want to see exactly what it does.

---

## The verification handshake

Sites that offer a webhook channel almost always verify the endpoint before saving it, so they're not blindly POSTing to something that doesn't exist. This one (IbbyLabs Uptime Tracker) does it by POSTing a JSON body like:

```json
{"type": "verification", "challenge": "d6e3225265fa33fa62e7ed25237c2d75"}
```

...and expects that exact `challenge` value echoed straight back in the response, not just any `200`. The relay checks every incoming POST body for a `challenge` field before doing anything else — if present, it responds immediately with `{"challenge": "<same value>"}` and does **not** relay that particular request to ntfy (it's not a real event, just a handshake). Anything without a `challenge` field falls through to the normal path: forward a summary to ntfy, then ACK with a plain `ok`.

If you're hooking up a different site and its verification handshake doesn't match this shape, the relay script (`~/aiostreams/webhook-relay-state/webhook_relay.py` once installed, or the `write_app_script` function in `setup-webhook.sh` before that) is the one place to adjust it — the `challenge` check happens early in `do_POST`.

---

## Why the token is in the URL path, not a header

Some sites' webhook fields only accept a single URL, with no way to add custom headers. Putting the secret in the path (`/hook/<token>`) keeps this working everywhere, at the cost of the token showing up in that site's saved config and any of its own logs. Anything hitting a path other than `/hook/<the-configured-token>` gets a plain `404`, not `403` — deliberately, so a stray request can't even confirm the path format is right.

---

## Applying script updates

Two different things get written to two different places, and it matters which one you touch:

- **`setup-webhook.sh` on disk** is just the installer. Downloading a new version does nothing on its own.
- **The actual running app** (`webhook_relay.py`) only gets rewritten when you run **2) Start** or **4) Reconfigure** from the menu — both call the same `write_app_script` function, then recreate the container so the new code is actually loaded, not just sitting on disk unused.

So: pull a new `setup-webhook.sh`, then hit **Start** (keeps existing config) or **Reconfigure** (lets you change settings too) — either applies it. A bare `docker restart aios-webhook-relay` does **not** pick up script changes, since restart doesn't touch the bind-mounted file, it just re-runs whatever was already there.

---

## Backup, restore, and domain migrations

The relay's config, token, and code all live under `~/aiostreams/webhook-relay-state/`, a plain subfolder of the main install, so a normal `setup-aiostreams.sh` backup captures it automatically with no extra step. Restoring onto the same server, or a new server under the **same** domain, brings the relay back exactly as it was, no action needed.

**One gap worth knowing:** restoring under a genuinely *different* domain rewrites the main site's domain automatically (that's `check_restored_domain_dns` in `setup-aiostreams.sh`), but does not touch the relay's own subdomain, since it isn't necessarily derived from the main domain and there's no safe way to guess a replacement. After that kind of restore, the relay comes back up pointed at its old subdomain until you manually run **Reconfigure** here. Full details → [Backup & Restore advanced guide](./backup-restore.md#migrating-to-a-new-server).

---



*(Run these from `~/aiostreams` — `cd ~/aiostreams` first if you're not already there.)*

**`curl -I https://yoursubdomain...` returns `501`**
Expected, not a bug — `curl -I` sends a `HEAD` request, and the receiver only implements `GET`/`HEAD`(health checks) and `POST` (the real path). Use a plain `curl https://yoursubdomain...` (should return `ok`) or test with `POST` instead.

**Site says "challenge mismatch" or similar verification failure**
Almost always means the running container is on an older version of the script than the one you think you're testing. Confirm with **1) Status**, then see "Applying script updates" above — a container `restart` alone won't fix this, you need **Start** or **Reconfigure**.

**Test event (option 5) succeeds but the real site's request never arrives**
The relay itself is fine; the problem is between the site and your server. Check:
- `curl https://yoursubdomain...` from an *external* machine, not the VPS itself, confirms DNS + firewall + Caddy are actually reachable from the outside.
- `docker logs caddy --tail 50` for TLS/routing errors on that specific domain.
- **6) View recent events** — if genuinely nothing arrived, the site never sent the request at all; check its own webhook config for typos in the URL.

**Reconfigure ran, but the old settings still seem active**
Fixed as of the version that added this: Reconfigure now recreates the running container immediately with the new token/topic/domain. If you're on an older copy of the script, run **Start** afterward to force it.

**ntfy notification never arrives, but Status shows the relay is running**
Confirm you're subscribed to the *exact* topic shown in Status, and that the server can reach ntfy.sh at all: `curl -v https://ntfy.sh` from the VPS. Same failure mode as the [watchdog's equivalent case](./watchdog.md#troubleshooting).

**New subdomain never gets a cert / stays on plain HTTP**
Caddy only picks up a new `caddy.d/` file on restart, which the script already does automatically after Start/Reconfigure/Uninstall. If you edited the drop-in file by hand instead, run `docker compose restart caddy` from `~/aiostreams` yourself.

---

## Removing it

Run from `~/aiostreams`: `sudo bash setup-webhook.sh` → **7) Uninstall** — stops and removes the relay container, deletes its Caddy drop-in file (restarting caddy to apply that), and clears all saved state (including your token and event history). Nothing about `setup-aiostreams.sh`, `setup-vpn-gluetun.sh`, or `setup-watchdog.sh` is affected.
