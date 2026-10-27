# Watchdog Alerts (optional: get pinged when your AIOStreams server needs you)

> In a hurry? [Basic guide](../basic/watchdog.md) covers the same steps with no deep explanations.

## What this is for

Most things that go wrong on a server go wrong quietly: the site stops answering, Caddy can't renew a certificate, the disk fills up, or (with the [VPN layer](./vpn-setup.md)) the tunnel drops and the kill switch, doing its job, makes AIOStreams go silent. You find out when you go to watch something. `setup-watchdog.sh` closes that gap: it runs a set of checks every couple of minutes and sends a push notification (via [ntfy.sh](https://ntfy.sh)) when something's wrong, saying what failed and how to fix it, and again once it's fine.

It works on any install. The site, disk and certificate checks always run; the VPN, MediaFlow, AIOMetadata and AIOManager checks join in when those are set up.

---

## What it checks

### Every 2 minutes, always

1. **The site answers.** It loads `https://<your domain>/` the way a visitor would, HTTPS and certificate included, but through this server's own port 443 (`curl --resolve`) rather than DNS, so a DNS hiccup elsewhere, or a cloud that can't reach its own public IP, doesn't count as the site being down. Any answer below 500 means it's up. The alert says which way it failed: nothing answering on 443 (Caddy is down), an invalid certificate, a 502/503/504 (Caddy is up but AIOStreams isn't answering behind it), another server error, or no answer within 15 seconds.

### Every 2 minutes, in VPN mode

2. **gluetun's tunnel health.** Gluetun exposes its own health status on an internal endpoint (`127.0.0.1:9999` inside the container), the same thing gluetun's own auto-restart logic watches. The watchdog polls it via `docker exec gluetun wget ...`. This also fails if gluetun has crashed or been removed, since `docker exec` against a missing container fails too.
3. **AIOStreams is running.** In VPN mode AIOStreams is set to `restart: "no"` (so it can never start before the tunnel is confirmed), which also means nothing restarts it if it crashes. This check catches that.
4. **AIOStreams is reachable through gluetun.** The watchdog asks for `http://127.0.0.1:3000/` from *inside* gluetun. If gluetun's container ever restarts on its own, it gets a fresh network namespace and AIOStreams is left stranded in the old one: still "running", but unreachable by Caddy and with no internet. Only this check catches that. Any HTTP answer at all counts as reachable (even a 401 from the login page); only "nothing there" counts as down.

### Every 2 minutes, whenever MediaFlow Proxy is set up

5. **Caddy is running**, **MediaFlow's container is running**, and **MediaFlow answers its health check.** MediaFlow has no published port, so the watchdog asks for `http://mediaflow-proxy-light:8888/health` from inside the Caddy container, over the shared `aios_shared` network.

### Every 2 minutes, whenever AIOMetadata is set up

The same as check 5, for AIOMetadata: **Caddy is running**, **AIOMetadata's container is running**, and **AIOMetadata answers its health check** (`http://aiometadata:3232/health/live`, the one its image uses), asked from inside the Caddy container in the same way. See the [AIOMetadata guide](./aiometadata.md#phone-alerts).

### Every 2 minutes, whenever AIOManager is set up

The same again for AIOManager: **Caddy is running**, **AIOManager's container is running**, and **AIOManager answers `http://aiomanager:1610/api/health`** (what its own health check asks, and it fails if AIOManager's database isn't healthy), asked from inside the Caddy container. See the [AIOManager guide](./aiomanager.md#phone-alerts).

### Warnings (alert once each way)

6. **Disk nearly full.** The disk holding `/opt/aiostreams` at 90% used or more. The all-clear comes once it's back under 85%, so a disk hovering around 90% doesn't send a stream of alerts. A full disk is a common way for a Docker server to break quietly (old images and logs pile up, then nothing can write).
7. **Certificate not renewing.** Every 6 hours, the certificate of every site this server serves (the main domain and each add-on's subdomain: MediaFlow, AIOMetadata, AIOManager, the control panel), asked of this server's port 443. Each site alerts once each way on its own, naming it, so a second site going bad still alerts while the first is. Caddy renews well before it runs out (with 30 days left on a 90-day certificate, about 15 on a 45-day one), so under 10 days left means renewal has been failing. An already expired or broken certificate fails the site check above instead.

### Once per boot, if switched on

8. **Server restarted** (`set-option reboots on`; off for new setups, and a watchdog set up before it was a switch keeps it on). A small boot-time service (`aiostreams-watchdog-boot.service`) stays active until the server shuts down, and records the time as it does. After a clean restart the alert says how long the server was down, to the second. With no record (a crash, a power cut, a forced reset by the host) it says the shutdown wasn't clean and when the server was last seen, from the last check before it went. Each boot is reported once (by the kernel's boot ID), and only within 15 minutes of booting, so starting the service by hand never sends one. With the switch off, the restart is still recorded in the events and counted in the weekly check-in.

### Optional, off until switched on

Switched from the script's **6) Extra alerts** menu, the control panel's Phone alerts page, or over SSH with `sudo bash setup-watchdog.sh set-option <name> <value>`:

9. **A new AIOStreams release** (`set-option updates on`). Every 6 hours it asks GitHub for the latest release on the server's channel, compares it with the build running, and alerts once per new release, with how to update (its Open panel button opens the panel's Overview, where Update is). On stable that's one per release; on nightly, one per nightly build, at most 4 a day since it asks every 6 hours. A server pinned to a version gets none.
10. **Script updates** (`set-option scripts on`). Every 6 hours it compares each `setup-*.sh` in `/opt/aiostreams` with GitHub's copy by its Git blob hash, as the control panel's Scripts tab does, on the branch the panel follows for its own updates (`main` without a panel). It alerts once per new set of differences and at most once a day, and says a script "differs" rather than "is out of date": a hash can't tell older from newer, and testing a script from another branch makes it differ on purpose.
11. **Scheduled backup made** (`set-option backups on`). [Scheduled backups](./backup-restore.md#scheduled-backups) leave how each run went in `/opt/aiostreams/backup-last-run`, which every check reads. A good run alerts only with this on, with its file name and size; a **failed or skipped** one always alerts (high priority), with the reason, since that's what makes a schedule safe to forget. One still marked running after an hour counts as failed. Each run is reported once (`watchdog-state/backup-seen`), and a watchdog seeing the file for the first time only reports a run from the last 10 minutes.
12. **Security updates waiting** (`set-option security on`). With automatic updates (`unattended-upgrades`, Ubuntu's default), security updates install themselves every day, so one that waits means that has stopped, a package is held back, or something needs a hand; the alert says which case it is, from whether `unattended-upgrades` is installed and switched on. A plain Debian has no automatic updates, and its package lists aren't refreshed by themselves either, so the alert only sees updates after something refreshes them (Install updates on the panel, `apt update`). Every 6 hours it reads `apt list --upgradable` (read-only, from the package lists the system last refreshed), takes the ones from a `-security` source, and records when it first saw each package and version (`watchdog-state/security-seen`). Once any has waited 3 days, one alert (high priority) with how many and which, and how to install them (the panel's Maintenance page, or `setup-aiostreams.sh system-updates`); then a reminder each week while any still wait. Once none wait, the next time starts afresh.
13. **Weekly check-in** (`set-option weekly on`). Once a week: the last 7 days' checks (from the daily tally), alerts and restarts (from the event list), disk space, how old the newest backup is, and how many updates are waiting ("Updates waiting: 12 (2 for security)."). It goes out on the first check at or after the chosen time on the chosen day (so within 2 minutes of it), `set-option weekly_day 1-7` (Monday to Sunday) and `set-option weekly_time HH:MM`, Sunday 10:00 to start with (a `weekly_hour` saved by an older copy still counts, as that hour on the dot), by the **server's clock**: `timedatectl` shows its time zone, `sudo timedatectl set-timezone Europe/London` (your own Area/City) changes it. Its real job is to fail visibly: a watchdog that has stopped working shows by the check-in not arriving.
14. **A new AIOMetadata release** (`set-option metadata on`), listed only once AIOMetadata is installed (option 8 in **6) Extra alerts**). Every 6 hours it asks GitHub for AIOMetadata's latest release and compares it with the one running (the container's image tag, or the pinned release while it's stopped). Its releases come up to twice a day, so it sends at most one alert a day, naming the newest.
15. **A new AIOManager release** (`set-option manager on`), listed only once AIOManager is installed (option 9). The same check, every 6 hours; its releases are months apart, so one alert per release.
16. **A new MediaFlow Proxy release** (`set-option mediaflow on`), listed only once MediaFlow is set up (option 10). The same again, one alert per release. A MediaFlow set up before its releases were pinned runs "latest", so it gets none until its next Start pins it.

---

## How the timing works

- **It needs 2 consecutive failed checks before alerting**, not one. A single failed check could just be a few-second blip; gluetun often self-heals faster than that. Requiring two in a row (roughly 4 minutes worst case, up to 6 depending on when the failure lands between checks) filters that out. If you want to change this, `FAIL_THRESHOLD` and `CHECK_INTERVAL`/`CHECK_INTERVAL_MIN` are plain variables near the top of the script, next to the disk and certificate thresholds.
- **It alerts once per state change, not once per check.** A saved `alert-state` file tracks whether the last alert sent was "down" or "up", so something that's been down for an hour doesn't page you every 2 minutes. You get exactly one "down" message, then silence until it recovers, then exactly one "back up" message. The warnings work the same way, each with its own state file.
- **One failure at a time.** Checks run in the order above and stop at the first failure, so the alert names the first thing that broke. If two things are down at once, you'll see the second after fixing the first.

## How alerts look

Each alert has a title, an icon and a priority, so your phone can treat them differently:

| Alert | Priority |
|---|---|
| 🚨 AIOStreams is down | urgent (5): sounds even on quieter notification settings |
| ⚠️ Disk nearly full, ⚠️ Certificate not renewing, ⚠️ Scheduled backup failed or skipped, 🔒 Security updates waiting | high (4) |
| ✅ AIOStreams is back, 🔄 Server restarted, 📦 Update available, 🔔 Test alert | normal (3) |
| ✅ disk or certificate fine again, 📄 Script updates, 💾 Backup made, 📅 Weekly check-in | low (2): arrives quietly |

In the ntfy app's default settings, urgent, high and normal alerts make a sound and low ones arrive silently. To change that on your phone, give each priority its own sound: on Android, Settings, Apps, ntfy, Notifications lists a category per priority.

With the [control panel](./control-panel.md) installed, each alert has an **Open panel** button that opens its Phone alerts page (the update alert's opens the Overview, the script updates alert's the Scripts tab). Tapping the alert itself just opens it in ntfy.

## When it stays quiet on purpose

- **In direct mode, the VPN checks (2–4) are skipped.** It reads the same `vpn-state/active` marker `setup-vpn-gluetun.sh` uses, so turning the VPN off on purpose doesn't trigger a false alarm.
- **Deliberate stops don't alert.** Stop AIOStreams (in `setup-aiostreams.sh` or the control panel) and Stop in `setup-mediaflow.sh`, `setup-aiometadata.sh` and `setup-aiomanager.sh` each leave a small `stopped-on-purpose` marker, and the watchdog skips the checks that depend on it while it's there: with AIOStreams stopped on purpose, the site check is skipped too. Stopping with a plain `docker stop` leaves no marker, so it alerts, same as a crash. The marker clears itself as soon as the watchdog sees the container running again, however it got started.

---

## What it keeps

Everything is in `/opt/aiostreams/watchdog-state/`, so a [backup](./backup-restore.md) holds it and a restore brings it back:

- `config`: the ntfy topic. `options`: the optional alerts and the check-in's day and hour.
- `events`: what happened, newest last (first failure, alert sent, recovered, started, stopped, test alert, topic changed, restarted, disk, certificate, update, scripts, backup, security, weekly), the last 200, never the topic itself.
- `tally`: how many checks passed and failed each day, the last 14 days.
- Small state files: `last-check`, `alert-state`, `failcount`, `disk-state`, `cert-state` (bad while any site's certificate is; each site's own in `cert-hosts/`), `last-alive`, `shutdown-at`, `boot-reported`, and when the certificate and updates were last looked at.

The systemd units live outside it (`aiostreams-watchdog.timer`, `.service`, and `aiostreams-watchdog-boot.service`), so a restore recreates them when the watchdog was running at backup time.

## The control panel's Phone alerts page

With the [control panel](./control-panel.md), the watchdog gets a page of its own, on the rail once it's set up. It reads the files above and shows whether it's watching, the last check, what it watches, the 14 days as squares (green all passed, amber some failed) with **Reset**, recent events with **Clear history**, and the optional switches with the check-in's day and time.

**Change topic** suggests a new random topic (three groups of four, with no look-alike characters), has **Copy** for pasting into the ntfy app, then saves it with the script's `set-topic` and sends a test alert to it straight away. The topic goes to the script on stdin, so it never appears in a command line or in the panel's Activity, and the page only ever shows it masked.

## Why ntfy instead of email

Most VPS providers block outbound port 25 by default, which makes plain SMTP unreliable without an authenticated relay and its own credentials. ntfy sidesteps that: one outbound HTTPS call to a topic name, no account needed, delivered as a push notification instead of sitting in an inbox.

**Trade-off:** the topic name is a private URL, not a true secret. Anyone who knows it can read your alerts (just which service is up or down, nothing sensitive) or post to it. Pick something long and hard to guess. ntfy also offers self-hosting or a paid tier with access control if you want stronger guarantees.

## What it can't tell you

If the whole server goes down (the host has an outage, the network goes), nothing running on it can send an alert; the restart alert only arrives once it's back. For that, point an outside uptime monitor at your domain as well. Many are free, and many can send to ntfy too.

---

## Troubleshooting

*(Run these from `/opt/aiostreams`; `cd /opt/aiostreams` first if you're not already there.)*

**No alert arrives during a real outage**
Check `sudo systemctl status aiostreams-watchdog.timer` is active, and `sudo journalctl -u aiostreams-watchdog.service -n 50` for the last several check attempts. Or run `sudo bash setup-watchdog.sh` → **1) Status**, which shows the last check's result (including the failure reason) and the current alert state directly. `sudo bash setup-watchdog.sh check` runs every check once and prints the result, without saving anything or sending an alert.

**Status shows no "Last check" line at all**
The check has never run. Confirm with `sudo systemctl is-active aiostreams-watchdog.timer` and check the journal for errors.

**"Last check" is frozen on an old timestamp**
If you stopped the watchdog, that's expected: Status prints `STOPPED` and holds there until you Start again. If it's supposed to be running, confirm the timer has a scheduled next run: `systemctl list-timers aiostreams-watchdog.timer --all` should show a real value under `NEXT`, not a bare `-`. Re-running **Start** regenerates the timer and usually clears this.

**Updated the script, but the new checks don't seem to run**
The timer runs a saved copy of the script, not the one you downloaded. Run **2) Start** once after any update (or Start on the Phone alerts page) to refresh that copy and the systemd units.

**Test alert doesn't arrive, but Status looks fine**
That's a delivery problem, not a detection problem. Confirm you're subscribed to the *exact* topic shown in Status (one wrong character and nothing arrives; the panel's Change topic has Copy for this), and that the server can reach ntfy.sh at all: `curl -v https://ntfy.sh` from the VPS.

**No restart alert after a reboot**
Check `systemctl is-enabled aiostreams-watchdog-boot.service` says `enabled` (Start turns it on, Stop turns it off), and `sudo journalctl -u aiostreams-watchdog-boot.service -b` for this boot's run.

**The weekly check-in comes at the wrong time**
It goes by the server's clock: `timedatectl` shows the time zone, and `sudo timedatectl set-timezone Europe/London` (your own Area/City) changes it.

**No DOWN alert, even though something is clearly down**
Usually it was stopped from its own script's menu (or the panel), which leaves a stopped-on-purpose marker that suppresses alerts until it's running again. In direct mode the VPN checks are skipped by design (`sudo bash setup-vpn-gluetun.sh` → **1) Status** confirms which mode is live).

**Testing without waiting for a real failure**
Use **4) Send test alert** for pure delivery testing any time. To test full detection:

- **The site:** `sudo docker stop aiostreams` (a plain stop, no marker) for about 5 minutes, confirm the DOWN alert ("isn't answering behind it (HTTP 502)"), then `sudo docker start aiostreams` and confirm the recovery alert follows.
- **Tunnel:** `sudo docker stop gluetun` for about 5 minutes, confirm the DOWN alert, then restore with `sudo bash setup-vpn-gluetun.sh` → **2) Turn VPN ON** (not a plain `docker start gluetun`, which skips the clean recreate) and confirm the recovery alert follows.
- **AIOStreams (VPN mode):** `cd /opt/aiostreams && sudo docker compose stop aiostreams`, wait for the alert, then `sudo bash /opt/aiostreams/setup-aiostreams.sh` → **4) Restart the stack**.
- **MediaFlow:** `sudo docker stop mediaflow-proxy-light`, wait for the alert, then `sudo bash setup-mediaflow.sh` → **2) Start**. Stopping it with **3) Stop** in that menu instead should produce *no* alert, which confirms the stopped-on-purpose marker works.
- **AIOMetadata:** `sudo docker stop aiometadata`, wait for the alert, then `sudo bash setup-aiometadata.sh` → **2) Start**. As with MediaFlow, its own **3) Stop** should produce no alert.
- **AIOManager:** `sudo docker stop aiomanager`, wait for the alert, then `sudo bash setup-aiomanager.sh` → **2) Start**. Its own **3) Stop** should produce no alert either.
- **Restart:** `sudo reboot`. The alert should say it shut down cleanly and how long it was down.

---

## Removing it

Run `sudo bash /opt/aiostreams/setup-watchdog.sh` → **9) Uninstall**, or use **Uninstall** on Phone alerts' card on the control panel's Add-ons page. That stops and removes the systemd timer and services and all saved state (including your ntfy topic). Nothing about the other scripts is affected. Uninstalling AIOStreams itself with `setup-aiostreams.sh` also removes the watchdog automatically.
