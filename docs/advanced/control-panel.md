# Control Panel: Advanced Guide

> [!NOTE]
> **Beta.** The control panel is new. It's been used day to day, but not yet on every kind of setup. If something looks wrong, [open an issue](https://github.com/alpinezx/easy-aiostreams/issues).

A private web dashboard for the Easy AIOStreams stack. It shows what's running, lets you start, stop, restart, update and back up, and tails container logs. Every button runs your existing `setup-*.sh` scripts, so the panel can't drift from what the scripts do.

> Just want it running? → [Basic guide](../basic/control-panel.md)

---

## Where it lives

| Path | What's there |
| --- | --- |
| `/opt/aiostreams/control-panel` | The panel's code and `setup-ui.sh`. It's built straight from here. |
| `/opt/aiostreams/ui-state` | Its settings, login, unlock token, terminal key hash, activity history and terminal log. Part of every backup. |
| `/opt/aiostreams/caddy.d/60-ui.caddy` | Its Caddy site, picked up by the main Caddy through the drop-in folder. |

It runs as one container, `aios-ui`, on the shared `aios_shared` network, with no published ports: only Caddy can reach it.

`setup-ui.sh` only runs from `/opt/aiostreams/control-panel`. Run from anywhere else, it stops and says where it belongs.

## Install, update, uninstall

Install is a download into place, then the first run of `setup-ui.sh`:

```bash
curl -fsSL https://github.com/alpinezx/easy-aiostreams/archive/refs/heads/main.tar.gz | sudo tar xz -C /opt/aiostreams --strip-components=1 easy-aiostreams-main/control-panel
sudo bash /opt/aiostreams/control-panel/setup-ui.sh
```

After that the same command opens the menu. **4) Update** downloads the newest `control-panel` folder from the `main` branch into place (replacing `app/`, `web/` and `tests/` so removed files don't linger) and rebuilds with the new copy of `setup-ui.sh`. Answer **n** to rebuild from the files already there instead, for example after editing them. Login, unlock link and terminal key are kept. A failed or incomplete download changes nothing. To try the `dev` branch: `sudo AIOS_UI_BRANCH=dev bash /opt/aiostreams/control-panel/setup-ui.sh`.

**9) Uninstall** stops and removes the container, its Caddy site and its image, and deletes `ui-state` (login, unlock token, terminal key, history). It then asks whether to delete `control-panel` too: say **n** to reinstall straight away from the same files, **y** to leave nothing behind. AIOStreams isn't touched either way. Delete the panel's DNS record afterwards if you're not reinstalling.

## How it's locked down

- **Caddy gate.** Without the unlock cookie, every URL on the subdomain returns a bare 404. The login page isn't even discoverable. Opening `/unlock/<token>` once sets the cookie, and every visit sets it again. Menu option 5 makes a new token, which also signs out every browser.
- **Login.** Password hashed with scrypt, 7-day signed session cookie (HttpOnly, Secure). 5 wrong passwords locks that address out for 15 minutes.
- **SameSite=Lax** on both cookies, so a link opened from another app (tapping a phone alert) gets in. Browsers still never send them with another site's POSTs, and everything that changes something in the panel is a POST. A rebuild brings Caddy's site file up to date, reloading Caddy only if it changed.
- **No free-form commands.** The browser can only ask for actions from a fixed list (`app/actions.py`). It can't type a command, and logs are limited to the stack's own containers.
- **No secrets shown.** `SECRET_KEY` and logins are never sent to the browser. Backups can be listed, created and deleted (delete removes every copy, after a confirm; a locked backup can't be deleted until you unlock it), but not downloaded: copy them off with `scp`.
- **Web terminal (off by default).** Behind a second key, separate from the login and the unlock link. See below.

It is still root-equivalent on your server, because it has to run the scripts and talk to Docker (the container is privileged and shares the host's process namespace, so it can run scripts on the host through `nsenter`). Treat the unlock link and the password like SSH credentials.

## What each button runs

| Button | Script and input |
| --- | --- |
| Start, Stop (AIOStreams' row), Restart stack | `setup-aiostreams.sh` menu options 3, 2, 4 |
| Restart (per service) | restarts just that container through Docker; AIOStreams, MediaFlow and the webhook relay only |
| Update | menu option 5, with the backup and build-channel answers from the dialog |
| Back up now | `setup-aiostreams.sh backup` |
| Scheduled backups: Set, Off | `setup-backup.sh schedule daily HH:MM`, `weekly <1-7> HH:MM`, `off`, which writes `backup-schedule` and the systemd timer |
| MediaFlow, webhook relay | `start-mediaflow`, `start-relay`, and menu option 3 for Stop |
| Phone alerts: Start, Stop, Send test alert | `setup-watchdog.sh install-timer`, `stop` (with menu option 3 typed too, for older copies of the script), `test` |
| Phone alerts: Uninstall | `setup-watchdog.sh uninstall` (menu option 9 without its question; the panel asks first) |
| Phone alerts: Change topic | `setup-watchdog.sh set-topic`, with the topic on stdin (never on a command line or in Activity), then a test alert to it |
| Phone alerts: the switches, the check-in's day and time, Reset, Clear history | written straight to `watchdog-state/options`, `tally` and `events` (the script's `set-option` does the same over SSH) |
| Turn VPN on, Turn VPN off | `setup-vpn-gluetun.sh on`, `off` (the same steps as its menu options 2 and 3) |
| Change server, Update VPN | `setup-vpn-gluetun.sh addresses` for the list, then `use-address <ip>`; `update` (menu option 5) |
| Change config | `setup-vpn-gluetun.sh addresses <name>` for the new config's list, then `use-config <ip>` |
| Configs on this server: the list, Use, Delete | `list-configs`; `use-file <path> <ip>`; `delete-config <path>` |
| Uninstall VPN | `setup-aiostreams.sh backup` first if ticked, then `setup-vpn-gluetun.sh uninstall` with `remove-image` and `delete-confs` as ticked (menu option 7's questions) |
| Maintenance: Free up space | `setup-aiostreams.sh free-space` |
| Maintenance: Install updates, Set limits | `setup-aiostreams.sh system-updates`, `log-limits`, run on the host as their own systemd unit (`aios-maintenance`) rather than under the panel: Docker restarting restarts the panel's container too. Output goes to `ui-state/maint.log`, the exit code to `maint.log.code` |
| Update (Scripts tab) | downloads GitHub's main copy through the API (raw links can be minutes stale), checks it against the SHA GitHub lists, then replaces the script on the host; the AIOStreams menu's also replaces `setup-backup.sh`, and the watchdog's runs `setup-watchdog.sh refresh` so its timer's copy follows (starting nothing) |
| Remove (Scripts tab) | deletes an add-on's script from the install folder, only while that add-on's state folder is gone (it isn't set up) |

The scripts run on the host with a terminal attached, like an SSH session. The main script's Reconfigure, the VPN's first-time setup and the other add-ons' uninstalls have no button.

The version chip on the Overview tab is read from the running AIOStreams container's own `package.json`, once per container (an update recreates it, so the chip follows).

## Logs

Each line is split the way AIOStreams' own log viewer shows it: time, a dot for its JSON `level`, `[module]`, the message, then any other fields. The **INFO**, **WARN** and **ERROR** buttons show only the levels picked (none picked shows everything). For Caddy, **Hide noise** hides the lines that look alarming but are expected (a restart, the log viewer reconnecting) and says how many it is hiding; those lines are logged as warnings and errors themselves, so the level buttons can't do this. All of these are display filters only; they never change what's logged. **Clear** hides everything logged so far, and it stays hidden after a reload; Docker's own log file is left alone on purpose, since emptying it behind Docker's back breaks `docker logs`.

## VPN page

It appears on the rail once `setup-vpn-gluetun.sh` has set the VPN up, on or off. It shows whether the tunnel is connected and, asked from inside the VPN container (`ipinfo.io`, falling back to plain IP lookups), where traffic leaves: the exit IP, city, country and network. It also shows the endpoint name and server address, read from `vpn-state`; the panel reads only those lines, never the keys. **DNS** makes a lookup inside gluetun and reads its open connections from `/proc/net/tcp`: DNS-over-TLS (port 853) to 1.1.1.1/1.0.0.1 or 9.9.9.9/149.112.112.112 shows as encrypted with Cloudflare or Quad9 named; plain DNS on port 53 shows amber; nothing seen shows nothing. It's the script's own "DNS: encrypted" check. A check is reused for a minute; **Check now** asks again. **Turn VPN off** keeps AIOStreams live through the switch and **Turn VPN on** waits for the tunnel before starting it; both are the script doing the work, with its own checks. **Change server** appears when the config's endpoint is a name: the script looks it up again, pings each address from the server and lists them fastest first; the address picked is the only thing sent back, and the panel accepts only an IPv4 address. **Update VPN** pulls the newest `qmcgaw/gluetun:v3` and restarts the stack only if the image changed and the VPN is on.

**Change config** sends the pasted config (or the file's contents, read in the browser) to the panel once, over HTTPS. The panel checks it has both sections, real-looking keys and a valid endpoint, saves it as `vpn-state/upload.conf` (root only, mode 600) and sends back only the endpoint and address; the paste box is emptied. The script's `use-config` then keeps the config in use, its server name and address in `vpn-state/previous/` (listed as **Previous config**), installs the new one as `vpn-state/wireguard.conf`, and switches with the usual tunnel check. If AIOStreams was running and the tunnel doesn't connect, it reports a failure and leaves AIOStreams stopped rather than unprotected; **Use** on Previous config goes back.

**Configs on this server** lists what `list-configs` finds: the pasted config, the previous one, an earlier paste, one pasted but not used yet, and `.conf` files in `/root` and the login user's home that have `[Interface]`, `[Peer]`, `PrivateKey` and `Endpoint` (the same files Reconfigure offers). Each shows its path and endpoint, never its keys. **Use** (any config not in use) copies it into `vpn-state` and switches to it as Change config does, so a file can be deleted afterwards; the config left becomes Previous config, so two can be swapped back and forth. On Previous config, the address it used is picked to start with. **Delete** takes only a path the list has just found, and the config in use only while the VPN is off; the script checks that again before deleting. Deleting that one also takes its key out of the saved VPN settings (`vpn-state/docker-compose.vpn.yml`), so no config is left: **Turn VPN on** then opens the paste dialog and turns the VPN on with the config given (`use-config <ip> on`).

**Uninstall VPN** asks for `uninstall` to be typed, like a restore, and runs the script's `uninstall`: it switches to direct first, removes the gluetun container (and image, if ticked), and deletes `vpn-state` only once AIOStreams and Caddy are confirmed running, refusing otherwise with nothing deleted. **Delete the .conf files** deletes the ones the list shows in `/root` and the login user's home. **Back up first** runs a normal backup and stops if it fails. The page disappears once the VPN is gone.

## Phone alerts page

It appears on the rail once the [watchdog](./watchdog.md) has been set up over SSH (first-time setup asks you to subscribe in the ntfy app, so it stays a script job). It reads `watchdog-state/`: whether the timer is running, the last check, what it watches, the daily tally as 14 squares, the event list, and the two optional switches. The topic is only ever sent to the browser masked (its first five and last two characters). **Change topic** suggests a random topic in groups of four with no look-alike characters, with **Copy**, and links to it on ntfy.sh so you can subscribe first.

## Maintenance page

Read when the page opens and kept for 5 minutes. **Free up space** counts untagged images and `viren070/aiostreams` images no container uses, by the space only they hold (layers shared with an image that stays aren't freed), build cache Docker would remove (not records shared with an image in use), and the journal beyond 100 MB (`journalctl --disk-usage`). Other tagged images, such as gluetun's while the VPN is off, are kept for when they're wanted again. **System updates** reads `apt list --upgradable` (security ones by their `-security` source), `/var/run/reboot-required`, and when the package lists were last refreshed. **Container logs** reads `/etc/docker/daemon.json` and each container's own log settings.

`system-updates` runs `apt-get update` and `apt-get upgrade --with-new-pkgs` non-interactively, keeping changed config files, then brings the stack back as Start would (AIOStreams has `restart: "no"` in VPN mode, so a Docker restart would otherwise leave it stopped; stopped on purpose stays stopped). `log-limits` adds `"log-opts": {"max-size": "10m", "max-file": "3"}` to `daemon.json`, keeping any other settings (with `python3`), checks it with `dockerd --validate` where Docker has that, restarts Docker (putting the old file back if it won't start), then recreates the stack, the running add-ons and the panel so they take it. `daemon.json` is outside `/opt/aiostreams`, so a backup doesn't carry it; on a new server the card shows **Not set** again.

## Backups and restores

Backups are listed from root's home and the login user's home, merged by name. Locks and notes are kept in `ui-state/backup-meta.json`, which scheduled backups also read so they never remove a locked one.

The **Scheduled backups** card reads `backup-schedule` and `backup-last-run` (see the [backup guide](./backup-restore.md#scheduled-backups)), and whether `aiostreams-backup.timer` is active; if the schedule is on but the timer isn't, it says so and **Set** starts it again. A name with `-scheduled-` gets the **Scheduled** label. The Overview's **Last backup** is the newest backup of any kind, read at most once a minute, amber only when the last scheduled run failed or was skipped.

A restore moves your current install aside to `/opt/aiostreams.pre-restore-<date>-<time>` as a rollback copy, and the script never removes it. Those folders show up under **Set aside by restores** with a Delete button. The panel only deletes folders with exactly that name, next to the install folder.

A restore run over SSH rebuilds the panel from the backup (if it was running when the backup was made), after checking its subdomain like the add-ons'. Run from the panel's own Terminal tab, the panel stays up so the restore isn't cut off; press **Restart panel** (Backup & Restore or Terminal tab) afterwards so it picks up the restored folder.

**Reboot server** (Overview, under "This server") restarts the whole machine. You have to type `reboot` to confirm, and it refuses while an action is running. Everything uses `restart: unless-stopped`, so the stack and the panel come back by themselves.

## Web terminal

Off until you switch it on: menu option 8, then "Turn on". It prints a terminal key **once** (only a hash is stored).

- The key is separate from the login. 3 wrong keys locks that address out for an hour.
- The key is swapped for a one-time ticket (60 seconds) that opens the WebSocket. It never goes in a URL.
- **Open the shell as** your login user (the one with a `~/aiostreams` shortcut, e.g. `ubuntu`) or root. As the user it's the same as SSHing in as them. The unlock screen says whether that user's sudo needs a password; the panel never changes sudo settings. **Switch to ...** in the terminal bar ends the shell and opens one as the other user.
- On phones and tablets, swipe to scroll. Long-press for **Paste** or **Select text**.
- **Stay unlocked while I'm signed in on this device** means you type the key once per login. It's a signed cookie tied to that login and the current key, and never contains the key.
- One session at a time. It closes after 10 idle minutes (output counts as activity, so a running restore isn't cut off) or 2 hours. Closing the tab doesn't kill the shell; unlock again and you're back in it with recent output replayed. A shell nobody returns to is closed after 30 minutes.
- Sessions (opened, closed, address, length) are logged to `ui-state/terminal.log`. Keystrokes are not.

From inside the web terminal, `setup-ui.sh` refuses stop, rebuild, password change and uninstall, since they would cut off the shell running them. Do those over SSH.

---

[← Basic guide](../basic/control-panel.md) · [Other Scripts](../other-scripts.md)
