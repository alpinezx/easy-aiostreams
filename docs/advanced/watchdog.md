# Watchdog Alerts (optional — get pinged if the VPN tunnel drops)

> 🏃 In a hurry? [Basic guide](../basic/watchdog.md) covers the same steps with no deep explanations.

## What this is for

The [kill switch](./vpn-setup.md) already guarantees a dropped tunnel can't leak — it just goes silent instead. That's the safe outcome, but "silent" also means you might not notice AIOStreams is down until you go to watch something. `setup-watchdog.sh` closes that gap: it checks gluetun's tunnel health every couple of minutes and sends a push notification (via [ntfy.sh](https://ntfy.sh)) if it's down, and again once it's back.

It requires the [VPN layer](./vpn-setup.md) already set up — the one check it ships with is gluetun's tunnel health, so there's nothing to watch without it.

---

## How the check works

Gluetun exposes its own health status on an internal HTTP endpoint (`127.0.0.1:9999` inside the container) — the same mechanism Docker's own healthcheck would use, and the same thing gluetun's internal auto-restart logic watches. The watchdog just polls that from outside, every 2 minutes, via `docker exec gluetun wget ...`.

Two things worth knowing about the timing:

- **It needs 2 consecutive failed checks before alerting**, not one. A single failed check could just be a few-second blip — gluetun often self-heals faster than that on its own. Requiring two in a row (roughly 4 minutes worst-case) filters that out. If you want to change this, `FAIL_THRESHOLD` and `CHECK_INTERVAL`/`CHECK_INTERVAL_MIN` are plain variables near the top of the script.
- **It alerts once per state change, not once per check.** A saved `alert-state` file tracks whether the last alert sent was "down" or "up," so a tunnel that's been down for an hour doesn't page you every 2 minutes — you get exactly one "down" message, then silence until it recovers, then exactly one "back up" message.

It also **skips the check entirely while you're in direct mode** (reads the same `vpn-state/active` marker `setup-vpn-gluetun.sh` uses) — turning the VPN off on purpose shouldn't trigger a false alarm.

One side effect worth knowing: because the check is `docker exec gluetun ...`, it also fires if gluetun itself has crashed or been removed, not just if it's running-but-unhealthy — `docker exec` against a missing container fails too, which the watchdog treats the same as a failed health check.

---

## Why ntfy instead of email

Most VPS providers block outbound port 25 by default (anti-spam abuse prevention), which makes plain SMTP from the box unreliable without extra setup — an authenticated relay, credentials to manage, and a real risk of landing in spam even when it does go through. ntfy sidesteps all of that: it's a single outbound HTTPS `curl` call to a topic name, no account, no credentials, delivered as an actual push notification rather than something that might sit unread in an inbox.

The trade-off: your topic name is effectively a private URL, not a true secret. Anyone who knows it can read your alerts (nothing sensitive in them — just "tunnel up/down") or, in principle, post to it. Pick something long and hard to guess, same as you would a password you don't expect to type often. If you want stronger guarantees, ntfy supports self-hosting or a paid tier with access control — out of scope for this script, but worth knowing it exists.

---

## Why it's one file with baked-in state, not a config system

This was a deliberate scope call: a plain list of checks (a name + a command that exits 0 for healthy) is enough generality to add a second check later — server reachability, a specific container's status — without a rewrite. Building a config-file-driven plugin system before there's a second real check to justify it would be solving a problem that doesn't exist yet. See `run_checks()` near the top of the script if you want to add one.

---

## Three systemd/bash quirks this script works around

None of these are specific to this project — they're general systemd/bash gotchas worth knowing if you ever edit the script:

- **`$HOME` isn't set for root-owned systemd units** unless `User=` is explicitly specified in the unit file — even though the service *is* running as root. Without working around this, any script relying on `$HOME` (like this one, for finding `~/aiostreams`) crashes instantly and silently under the timer, every single run. The generated `.service` file bakes in `Environment=HOME=...` explicitly at install time to sidestep this.
- **Piping `/dev/urandom` through `tr | head -c`** (a common way to generate a random string) kills the writing process with `SIGPIPE` the instant `head` closes the pipe early. Combined with `pipefail` — which this script needs for its other error-checking — that silently kills the whole script. The random topic suggestion uses bash's built-in `$RANDOM` instead, which needs no pipe at all.
- **Monotonic timers (`OnBootSec`/`OnUnitActiveSec`) can silently stop scheduling on cloud VMs.** Those settings are calculated off the system's boot-time monotonic clock, which suspend, snapshot/restore, or live migration can invalidate — when that happens, systemd stops computing a next run at all (visible as `NextElapseUSecMonotonic=infinity` in `systemctl show`), and no amount of restarting the timer fixes it; only a reboot does. The generated `.timer` file uses `OnCalendar=*:0/N` (wall-clock scheduling) instead, which reads the system clock rather than a monotonic reference and isn't vulnerable to this. `Persistent=true` still catches up on any run missed while the box was off, same safety net as before.

  **Side benefit:** because scheduling is wall-clock based, changing the server's timezone (e.g. `UTC` → `Europe/London`) is safe at any time — the timer just keeps firing every N minutes by whatever the clock reads afterward. Worst case is one skipped or doubled tick in the exact minute of a clock jump (a DST change or a manual time change), which self-corrects on the very next cycle.

---

## Troubleshooting

**No alert arrives during a real outage**
Check `sudo systemctl status aiostreams-watchdog.timer` to confirm it's actually enabled and running, and `sudo journalctl -u aiostreams-watchdog.service -n 50` to see the last several check attempts and their results. Also run `./setup-watchdog.sh` → **1) Status** — it shows the last check's timestamp/result and the current tunnel state directly, no digging required.

**Status shows no "Last check" line at all, no matter how long you wait**
The check has never successfully run once — something's wrong with the timer itself, not the debounce timing. Confirm with `sudo systemctl is-active aiostreams-watchdog.timer` and check the journal for errors. If you edited the script by hand, double-check nothing reintroduced a dependency on an environment variable systemd won't provide (see the `$HOME` note above).

**"Last check" keeps showing an old timestamp/result well after you know a check should have run**
First rule out the simple case: after **Stop**, the script writes a `STOPPED (watchdog disabled — no checks running)` line to `Last check` immediately, so if you see that, it's accurate, not stale — it just means no check has run *since* you stopped it. If instead you're **Running** and the timestamp is genuinely old and frozen, confirm the timer actually has a next run scheduled: `systemctl list-timers aiostreams-watchdog.timer --all` should show a real value in `NEXT`, not a bare `-`. A `-` there (or `NextElapseUSecMonotonic=infinity` from `systemctl show aiostreams-watchdog.timer -p NextElapseUSecMonotonic`) means systemd isn't scheduling the unit at all — see the monotonic-clock quirk above. Re-running **Start** on a script version with the `OnCalendar` fix regenerates the timer unit and clears this.

**The test alert (option 4) doesn't arrive, but the check logic seems fine**
This isolates to a delivery problem, not a detection problem. Confirm you're subscribed to the *exact* topic name shown in Status, and confirm the server can actually reach ntfy.sh at all: `curl -v https://ntfy.sh` from the VPS. If that hangs or fails, it's a network/DNS/firewall issue on the box, unrelated to this script.

**No indication the tunnel is down, even though it clearly is**
Check you're actually in VPN mode — the watchdog silently skips checking while in direct mode by design. `./setup-vpn-gluetun.sh` → **1) Status** will confirm which mode is live.

**Testing without waiting for a real failure or a full 4-minute window**
Use option 4 (Send test alert) for pure delivery testing any time. To test the full detection path for real, `docker stop gluetun` for at least ~5 minutes (giving margin past the ~4-minute worst case), confirm the DOWN alert, then bring it back with `./setup-vpn-gluetun.sh` → **2) Turn VPN ON** (not a plain `docker start gluetun` — that script's toggle does a full clean recreate rather than trusting a lone container restart) and confirm the recovery alert follows.

---

## Removing it

`./setup-watchdog.sh` → **6) Uninstall** — stops and removes the systemd timer/service and all saved state (including your ntfy topic). Nothing about `setup-aiostreams.sh` or `setup-vpn-gluetun.sh` is affected.
