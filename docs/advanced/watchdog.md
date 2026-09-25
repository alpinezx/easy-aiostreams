# Watchdog Alerts (optional: get pinged if the VPN tunnel, AIOStreams or MediaFlow goes down)

> In a hurry? [Basic guide](../basic/watchdog.md) covers the same steps with no deep explanations.

## What this is for

The [kill switch](./vpn-setup.md) already guarantees a dropped tunnel can't leak; it just goes silent instead. That's the safe outcome, but "silent" also means you might not notice AIOStreams is down until you go to watch something. `setup-watchdog.sh` closes that gap: it runs a set of checks every couple of minutes and sends a push notification (via [ntfy.sh](https://ntfy.sh)) if something's down, saying what failed and how to fix it, and again once it's back. It also watches MediaFlow Proxy, which can fail on its own without anything else looking wrong.

It needs at least one of the [VPN layer](./vpn-setup.md) or [MediaFlow Proxy](./mediaflow-proxy.md) set up. Each group of checks only runs when the thing it checks is actually in use.

---

## What it checks

### In VPN mode

1. **gluetun's tunnel health.** Gluetun exposes its own health status on an internal endpoint (`127.0.0.1:9999` inside the container), the same thing gluetun's own auto-restart logic watches. The watchdog polls it via `docker exec gluetun wget ...`. This also fails if gluetun has crashed or been removed, since `docker exec` against a missing container fails too.
2. **AIOStreams is running.** In VPN mode AIOStreams is set to `restart: "no"` (so it can never start before the tunnel is confirmed), which also means nothing restarts it if it crashes. This check catches that.
3. **AIOStreams is reachable through gluetun.** The watchdog asks for `http://127.0.0.1:3000/` from *inside* gluetun. If gluetun's container ever restarts on its own, it gets a fresh network namespace and AIOStreams is left stranded in the old one: still "running", but unreachable by Caddy and with no internet. Only this check catches that. Any HTTP answer at all counts as reachable (even a 401 from the login page); only "nothing there" counts as down.

### Whenever MediaFlow Proxy is set up (VPN on or off)

4. **Caddy is running.** Checked first, since Caddy being down takes out the main site and the public MediaFlow URL together.
5. **MediaFlow's container is running.**
6. **MediaFlow answers its health check.** MediaFlow has no published port, so the watchdog asks for `http://mediaflow-proxy-light:8888/health` from inside the Caddy container, over the shared `aios_shared` network.

---

## How the timing works

- **It needs 2 consecutive failed checks before alerting**, not one. A single failed check could just be a few-second blip; gluetun often self-heals faster than that. Requiring two in a row (roughly 4 minutes worst case, up to 6 depending on when the failure lands between checks) filters that out. If you want to change this, `FAIL_THRESHOLD` and `CHECK_INTERVAL`/`CHECK_INTERVAL_MIN` are plain variables near the top of the script.
- **It alerts once per state change, not once per check.** A saved `alert-state` file tracks whether the last alert sent was "down" or "up", so something that's been down for an hour doesn't page you every 2 minutes. You get exactly one "down" message, then silence until it recovers, then exactly one "back up" message.
- **One failure at a time.** Checks run in the order above and stop at the first failure, so the alert names the first thing that broke. If two things are down at once, you'll see the second after fixing the first.

## When it stays quiet on purpose

- **In direct mode, the VPN checks (1–3) are skipped.** It reads the same `vpn-state/active` marker `setup-vpn-gluetun.sh` uses, so turning the VPN off on purpose doesn't trigger a false alarm. MediaFlow is still checked, since it runs the same in either mode.
- **With the VPN off and no MediaFlow, the whole check is skipped.** Status shows `SKIPPED` in that case.
- **Deliberate stops don't alert.** Stop AIOStreams in `setup-aiostreams.sh` and Stop in `setup-mediaflow.sh` each leave a small `stopped-on-purpose` marker, and the watchdog skips that check while it's there. Stopping with a plain `docker stop` leaves no marker, so it alerts, same as a crash. The marker clears itself as soon as the watchdog sees the container running again, however it got started.

---

## Why ntfy instead of email

Most VPS providers block outbound port 25 by default, which makes plain SMTP unreliable without an authenticated relay and its own credentials. ntfy sidesteps that: one outbound HTTPS call to a topic name, no account needed, delivered as a push notification instead of sitting in an inbox.

**Trade-off:** the topic name is a private URL, not a true secret. Anyone who knows it can read your alerts (just which service is up or down, nothing sensitive) or post to it. Pick something long and hard to guess. ntfy also offers self-hosting or a paid tier with access control if you want stronger guarantees.

---

## Troubleshooting

*(Run these from `~/aiostreams`; `cd ~/aiostreams` first if you're not already there.)*

**No alert arrives during a real outage**
Check `sudo systemctl status aiostreams-watchdog.timer` is active, and `sudo journalctl -u aiostreams-watchdog.service -n 50` for the last several check attempts. Or run `sudo bash setup-watchdog.sh` → **1) Status**, which shows the last check's result (including the failure reason) and the current alert state directly.

**Status shows no "Last check" line at all**
The check has never run. Confirm with `sudo systemctl is-active aiostreams-watchdog.timer` and check the journal for errors.

**"Last check" is frozen on an old timestamp**
If you stopped the watchdog, that's expected: Status prints `STOPPED` and holds there until you Start again. If it's supposed to be running, confirm the timer has a scheduled next run: `systemctl list-timers aiostreams-watchdog.timer --all` should show a real value under `NEXT`, not a bare `-`. Re-running **Start** regenerates the timer and usually clears this.

**Updated the script, but the new checks don't seem to run**
The timer runs a saved copy of the script, not the one you downloaded. Run **2) Start** once after any update to refresh that copy.

**Test alert doesn't arrive, but Status looks fine**
That's a delivery problem, not a detection problem. Confirm you're subscribed to the *exact* topic shown in Status, and that the server can reach ntfy.sh at all: `curl -v https://ntfy.sh` from the VPS.

**No DOWN alert, even though something is clearly down**
Two usual causes. You're in direct mode, where the VPN checks are skipped by design (`sudo bash setup-vpn-gluetun.sh` → **1) Status** confirms which mode is live). Or the thing was stopped from its own script's menu, which leaves a stopped-on-purpose marker that suppresses alerts until it's running again.

**Testing without waiting for a real failure**
Use **4) Send test alert** for pure delivery testing any time. To test full detection:

- **Tunnel:** `sudo docker stop gluetun` for about 5 minutes, confirm the DOWN alert, then restore with `sudo bash setup-vpn-gluetun.sh` → **2) Turn VPN ON** (not a plain `docker start gluetun`, which skips the clean recreate) and confirm the recovery alert follows.
- **AIOStreams (VPN mode):** `cd /root/aiostreams && sudo docker compose stop aiostreams`, wait for the alert, then `sudo bash setup-aiostreams.sh` → **4) Restart the stack**.
- **MediaFlow:** `sudo docker stop mediaflow-proxy-light`, wait for the alert, then `sudo bash setup-mediaflow.sh` → **2) Start**. Stopping it with **3) Stop** in that menu instead should produce *no* alert, which confirms the stopped-on-purpose marker works.

---

## Removing it

Run from `~/aiostreams`: `sudo bash setup-watchdog.sh` → **6) Uninstall**. That stops and removes the systemd timer/service and all saved state (including your ntfy topic). Nothing about the other scripts is affected. Uninstalling AIOStreams itself with `setup-aiostreams.sh` also removes the watchdog automatically.
