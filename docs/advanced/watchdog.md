# Watchdog Alerts (optional .  get pinged if the VPN tunnel drops)

> In a hurry? [Basic guide](../basic/watchdog.md) covers the same steps with no deep explanations.

## What this is for

The [kill switch](./vpn-setup.md) already guarantees a dropped tunnel can't leak .  it just goes silent instead. That's the safe outcome, but "silent" also means you might not notice AIOStreams is down until you go to watch something. `setup-watchdog.sh` closes that gap: it checks gluetun's tunnel health every couple of minutes and sends a push notification (via [ntfy.sh](https://ntfy.sh)) if it's down, and again once it's back.

It requires the [VPN layer](./vpn-setup.md) already set up .  the one check it ships with is gluetun's tunnel health, so there's nothing to watch without it.

---

## How the check works

Gluetun exposes its own health status on an internal HTTP endpoint (`127.0.0.1:9999` inside the container) .  the same mechanism Docker's own healthcheck would use, and the same thing gluetun's internal auto-restart logic watches. The watchdog just polls that from outside, every 2 minutes, via `docker exec gluetun wget ...`.

Two things worth knowing about the timing:

- **It needs 2 consecutive failed checks before alerting**, not one. A single failed check could just be a few-second blip .  gluetun often self-heals faster than that on its own. Requiring two in a row (roughly 4 minutes worst-case) filters that out. If you want to change this, `FAIL_THRESHOLD` and `CHECK_INTERVAL`/`CHECK_INTERVAL_MIN` are plain variables near the top of the script.
- **It alerts once per state change, not once per check.** A saved `alert-state` file tracks whether the last alert sent was "down" or "up," so a tunnel that's been down for an hour doesn't page you every 2 minutes .  you get exactly one "down" message, then silence until it recovers, then exactly one "back up" message.

It also **skips the check entirely while you're in direct mode** (reads the same `vpn-state/active` marker `setup-vpn-gluetun.sh` uses) .  turning the VPN off on purpose shouldn't trigger a false alarm.

One side effect worth knowing: because the check is `docker exec gluetun ...`, it also fires if gluetun itself has crashed or been removed, not just if it's running-but-unhealthy .  `docker exec` against a missing container fails too, which the watchdog treats the same as a failed health check.

---

## Why ntfy instead of email

Most VPS providers block outbound port 25 by default, which makes plain SMTP unreliable without an authenticated relay and its own credentials. ntfy sidesteps that: one outbound HTTPS call to a topic name, no account needed, delivered as a push notification instead of sitting in an inbox.

**Trade-off:** the topic name is a private URL, not a true secret .  anyone who knows it can read your alerts (just "tunnel up/down," nothing sensitive) or post to it. Pick something long and hard to guess. ntfy also offers self-hosting or a paid tier with access control if you want stronger guarantees.

---

## Troubleshooting

*(Run these from `~/aiostreams` .  `cd ~/aiostreams` first if you're not already there.)*

**No alert arrives during a real outage**
Check `sudo systemctl status aiostreams-watchdog.timer` is active, and `sudo journalctl -u aiostreams-watchdog.service -n 50` for the last several check attempts. Or run `sudo bash setup-watchdog.sh` → **1) Status**, which shows the last check's result and current tunnel state directly.

**Status shows no "Last check" line at all**
The check has never run. Confirm with `sudo systemctl is-active aiostreams-watchdog.timer` and check the journal for errors.

**"Last check" is frozen on an old timestamp**
If you stopped the watchdog, that's expected .  Status prints `STOPPED` and holds there until you Start again. If it's supposed to be running, confirm the timer has a scheduled next run: `systemctl list-timers aiostreams-watchdog.timer --all` should show a real value under `NEXT`, not a bare `-`. Re-running **Start** regenerates the timer and usually clears this.

**Test alert doesn't arrive, but Status looks fine**
That's a delivery problem, not a detection problem. Confirm you're subscribed to the *exact* topic shown in Status, and that the server can reach ntfy.sh at all: `curl -v https://ntfy.sh` from the VPS.

**No DOWN alert, even though the tunnel is clearly down**
Confirm you're actually in VPN mode .  the watchdog silently skips checks in direct mode by design. `sudo bash setup-vpn-gluetun.sh` → **1) Status** confirms which mode is live.

**Testing without waiting for a real failure**
Use **4) Send test alert** for pure delivery testing any time. To test full detection, `docker stop gluetun` for ~5 minutes, confirm the DOWN alert, then restore with `sudo bash setup-vpn-gluetun.sh` → **2) Turn VPN ON** (not a plain `docker start gluetun` .  that does a full clean recreate) and confirm the recovery alert follows.

---

## Removing it

Run from `~/aiostreams`: `sudo bash setup-watchdog.sh` → **6) Uninstall** .  stops and removes the systemd timer/service and all saved state (including your ntfy topic). Nothing about `setup-aiostreams.sh` or `setup-vpn-gluetun.sh` is affected.
