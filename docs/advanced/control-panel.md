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
| `/opt/aiostreams/ui-state` | Its settings, login, unlock token, terminal key hash, activity history, terminal log, the Overview's and the rail's layouts (`overview-layout.json`, `rail-layout.json`) and traffic history (`host-traffic.json`, `vpn-traffic.json`). Part of every backup. |
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
- **Only Caddy reaches it.** The container publishes no ports. It takes the visitor's address and HTTPS from Caddy's forwarded headers only when they come from Caddy's own container, so nothing else on the Docker network can pose as a visitor (`app/proxy.py`).
- **Login.** Password hashed with scrypt, 7-day signed session cookie (HttpOnly, Secure). 5 wrong passwords locks that address out for 15 minutes.
- **SameSite=Lax** on both cookies, so a link opened from another app (tapping a phone alert) gets in. Browsers still never send them with another site's POSTs, and everything that changes something in the panel is a POST. A rebuild brings Caddy's site file up to date, reloading Caddy only if it changed.
- **No free-form commands.** The browser can only ask for actions from a fixed list (`app/actions.py`). It can't type a command, and logs are limited to the stack's own containers.
- **No secrets shown.** `SECRET_KEY` and logins are never sent to the browser. Backups can be listed, created and deleted (delete removes every copy, after a confirm; a locked backup can't be deleted until you unlock it), but not downloaded: copy them off with `scp`.
- **Web terminal (off by default).** Behind a second key, separate from the login and the unlock link. See below.
- **In the browser.** Every request that changes something needs the panel's own header and a same-site origin. A strict Content-Security-Policy allows only the panel's own scripts. Anything that comes from outside (container names, log lines, release notes from GitHub) is put on the page as plain text, never as HTML.

It is still root-equivalent on your server, because it has to run the scripts and talk to Docker (the container is privileged and shares the host's process namespace, so it can run scripts on the host through `nsenter`). Treat the unlock link and the password like SSH credentials.

Found a security problem? Please report it privately from the repository's **Security** tab (Report a vulnerability), not in a public issue.

## What each button runs

![Update or switch build, with a backup first](../images/control-panel/update-dialog.png)

| Button | Script and input |
| --- | --- |
| Start, Stop (AIOStreams' row), Restart stack | `setup-aiostreams.sh start`, `stop`, `restart` (menu options 3, 2, 4 without their questions) |
| Restart (per service) | restarts just that container through Docker; AIOStreams, MediaFlow, AIOMetadata and AIOManager only |
| Update | `setup-aiostreams.sh update`, with `--backup` and `--channel latest\|nightly` from the dialog (menu option 5 without its questions) |
| Back up now | `setup-aiostreams.sh backup` |
| Scheduled backups: Set, Off | `setup-backup.sh schedule daily HH:MM`, `weekly <1-7> HH:MM`, `off`, which writes `backup-schedule` and the systemd timer |
| MediaFlow: Start, Stop, Update | `setup-mediaflow.sh start-mediaflow`, `stop-mediaflow`, `update-mediaflow` (with `--backup` from the dialog; offered once the script on the server knows the command) |
| AIOMetadata: Start, Stop, Update | `setup-aiometadata.sh start-aiometadata`, `stop-aiometadata`, `update-aiometadata` (with `--backup` from the dialog) |
| AIOManager: Start, Stop, Update | `setup-aiomanager.sh start-aiomanager`, `stop-aiomanager`, `update-aiomanager` (with `--backup` from the dialog) |
| AIOManager: Sign-ups switch | `setup-aiomanager.sh signups open 30` (closes by itself after 30 minutes), `signups close` |
| Phone alerts: Start, Stop, Send test alert | `setup-watchdog.sh install-timer`, `stop` (with menu option 3 typed too, for older copies of the script), `test` |
| Add-ons: Uninstall (Phone alerts) | `setup-watchdog.sh uninstall` (menu option 9 without its question; the panel asks first) |
| Add-ons: Uninstall (AIOMetadata, AIOManager, MediaFlow) | `setup-aiostreams.sh backup` first if ticked, then the add-on's `uninstall`, with `remove-image` if ticked |
| Add-ons: Uninstall (the retired webhook relay) | `setup-aiostreams.sh remove-webhook-relay`, offered once the script has it; no backup, since a restore leaves the relay out, and its common Python image is left for Free up space |
| Phone alerts: Change topic | `setup-watchdog.sh set-topic`, with the topic on stdin (never on a command line or in Activity), then a test alert to it |
| Phone alerts: the switches, the check-in's day and time, Reset, Clear history | written straight to `watchdog-state/options`, `tally` and `events` (the script's `set-option` does the same over SSH) |
| Turn VPN on, Turn VPN off | `setup-vpn-gluetun.sh on`, `off` (the same steps as its menu options 2 and 3) |
| Change server, Update VPN | `setup-vpn-gluetun.sh addresses` for the list, then `use-address <ip>`; `update` (menu option 5) |
| Change config | `setup-vpn-gluetun.sh addresses <name>` for the new config's list, then `use-config <ip>` |
| Configs on this server: the list, Use, Delete | `list-configs`; `use-file <path> <ip>`; `delete-config <path>` |
| Add-ons: Uninstall (VPN) | `setup-aiostreams.sh backup` first if ticked, then `setup-vpn-gluetun.sh uninstall` with `remove-image` and `delete-confs` as ticked (menu option 7's questions) |
| Maintenance: Free up space | `setup-aiostreams.sh free-space`, which hands over to `setup-maintenance.sh` (as do the two below) |
| Maintenance: Scheduled server reboot, Set, Off | `setup-aiostreams.sh restart-schedule needed\|always daily HH:MM`, `... weekly <1-7> HH:MM`, `off` (handed to `setup-maintenance.sh`), which writes `restart-schedule` and the systemd timer |
| Maintenance: Clock, Change, Turn on time sync | `timedatectl set-timezone <zone>` (only a zone from `timedatectl list-timezones`) and `timedatectl set-ntp true`, on the host; nothing is installed or removed. A server with no time sync service at all (some Debian images) gets no button, but a line saying to install `systemd-timesyncd` |
| Maintenance: Install updates, Set limits | `setup-aiostreams.sh system-updates`, `log-limits`, run on the host as their own systemd unit (`aios-maintenance`) rather than under the panel: Docker restarting restarts the panel's container too. Output goes to `ui-state/maint.log`, the exit code to `maint.log.code` |
| Update (Scripts tab) | downloads GitHub's main copy through the API (raw links can be minutes stale), checks it against the SHA GitHub lists, then replaces the script on the host; the AIOStreams menu's also replaces `setup-backup.sh` and `setup-maintenance.sh` (fetching them if missing), and the watchdog's runs `setup-watchdog.sh refresh` so its timer's copy follows (starting nothing) |
| Remove (Scripts tab) | deletes an add-on's script from the install folder, only while that add-on's state folder is gone (it isn't set up) |

These commands ask nothing. Where the menu would ask whether to go on with the VPN set up but switched off, they stop instead and say so. After each command the panel also types the menu numbers that used to do the same job, which only an older script reads: one that doesn't know the command falls through to its menu. So the menu numbers the panel types (3, 2, 4 and 5, then 10 to exit; 3 then 10 for the add-ons' Stop) never change, and a panel test checks them against the scripts.

The scripts run on the host with a terminal attached, like an SSH session. The main script's Reconfigure and the add-ons' first-time setups have no button.

The version chip on the Overview tab is read from the running AIOStreams container's own `package.json`, once per container (an update recreates it, so the chip follows).

## Logs

![The Logs tab](../images/control-panel/logs.png)

Each line is split the way AIOStreams' own log viewer shows it: time, a dot for its JSON `level`, `[module]`, the message, then any other fields. The **INFO**, **WARN** and **ERROR** buttons show only the levels picked (none picked shows everything). For Caddy, **Hide noise** hides the lines that look alarming but are expected (a restart, the log viewer reconnecting) and says how many it is hiding; those lines are logged as warnings and errors themselves, so the level buttons can't do this. All of these are display filters only; they never change what's logged. **Clear** hides everything logged so far, and it stays hidden after a reload; Docker's own log file is left alone on purpose, since emptying it behind Docker's back breaks `docker logs`.

## Layouts: the Overview and the rail

![Edit menu: drag or hide the rail's pages](../images/control-panel/edit-menu.png)

**Edit** beside the Overview's headline and **Edit menu** at the rail's foot open the same drawer, on the right for the Overview's cards and on the left for the rail's pages. Each list is one layout for the install, saved on the server (`ui-state/overview-layout.json` and `rail-layout.json`), so a phone and a desktop match. Overview always stays first on the rail, and Edit menu, GitHub and Sign out stay at its foot. A card or page that isn't on this server (the VPN before it's set up, Phone alerts before the watchdog, an add-on not installed) keeps its place in the saved order but isn't listed, so nothing reads as missing; it shows up where it was once it's set up. **Reset to default** puts back the standard order. The rail's goes by use: Logs, Activity, Network, Backup & Restore, Maintenance, Add-ons, then each add-on's own page under it (VPN, Phone alerts), Scripts and Terminal.

**Colours**, at the top of the Overview's Edit drawer, sets System, Light, Dark or Slate (a softer, slate-grey dark). System follows the device's setting; the others override it in that browser only (saved in its local storage as `aios.theme`, not on the server), so a phone and a desktop can differ. A small script, `js/theme.js`, applies it before the page draws, so there's no flash of the other colours. The login page and the terminal follow it too.

## Network page

![The Network page: traffic over the last 24 hours, the last 7 days and each service](../images/control-panel/network.png)

Once a minute, whether or not the panel is open, it reads two sets of byte counters: the server's own network card (the one its default route leaves by, `eth0`, `ens3` and so on, from the host's `/proc/1/net`) and, with the VPN on, gluetun's tunnel (`tun0`). What went through since the last reading is added to that minute and that hour. Minutes are kept for a day and hours for 30 days, in `ui-state/host-traffic.json` and `ui-state/vpn-traffic.json`, saved every few minutes, so an update or reboot only loses the minutes in between, and a backup and restore carries the history. A minute with no reading (the VPN off, the panel not running) is a gap in the graph rather than zero. Counters starting again from zero (a reboot, gluetun restarting) are taken as a fresh start, not traffic.

**Whole server** and **VPN tunnel** (only once the VPN is set up) switch the Traffic card between the two. The graph is minute by minute over 1 hour, 5-minute averages over 24 hours and hourly averages over 7 days. **Clear history** empties the one shown and starts it again from now. **By service** is each container's speed from Docker's own counters, worked out from the panel's last two looks at them. AIOStreams on the VPN shares gluetun's network and has no counters of its own, so it's shown once, under the tunnel.

The Overview's **This server** shows the server's speed now and today's totals as its **Network** value, the VPN's card shows the tunnel's, and MediaFlow's card shows what's passing through MediaFlow now; all three link here.

Its figures are worked out the way AIOStreams' own dashboard does them, so the two pages agree: **CPU** is how busy all the cores were over the last few seconds, with Linux's load average under it, and every size and speed in the panel counts KB, MB and GB in thousands. On desktop, This server is two rows of four values, ending with Last backup, **Next reboot** (the [scheduled server reboot](#maintenance-page), its label a link to Maintenance) and HTTPS certificates, then **Reboot server** on a line of its own. The certificates open in a section of their own below the values, folded to the soonest one unless one needs a look. On phones the values are one per line, the certificates last so their list opens straight under them.

## VPN page

![The VPN page, with the configs on this server](../images/control-panel/vpn.png)

The VPN also gets a card on the Overview once it's set up, listed in Edit's drawer: whether the tunnel is connected, where traffic leaves, the server, and with the VPN on, its speed now and today's totals, with **Turn VPN off** (or on) and **Check now**. Turning it on with no config saved goes through this page, which asks for one.

AIOMetadata, AIOManager and MediaFlow each get a version card on the Overview once installed, like AIOStreams': the release they run, the newest, **Update** (with **Back up first**, and the previous release put back by itself if the new one doesn't start), **Check now** and **All releases**. AIOMetadata's and AIOManager's have links to their own pages beside the title; AIOManager's corner shows its logins, or **Sign-ups open** in amber, and MediaFlow's shows what's passing through it now. See each add-on's guide for the details.

It appears on the rail once `setup-vpn-gluetun.sh` has set the VPN up, on or off. It shows whether the tunnel is connected and, asked from inside the VPN container (`ipinfo.io`, falling back to plain IP lookups), where traffic leaves: the exit IP, city, country and network. It also shows the endpoint name and server address, read from `vpn-state`; the panel reads only those lines, never the keys. **DNS** makes a lookup inside gluetun and reads its open connections from `/proc/net/tcp`: DNS-over-TLS (port 853) to 1.1.1.1/1.0.0.1 or 9.9.9.9/149.112.112.112 shows as encrypted with Cloudflare or Quad9 named; plain DNS on port 53 shows amber; nothing seen shows nothing. It's the script's own "DNS: encrypted" check. A check is reused for a minute; **Check now** asks again. **Turn VPN off** keeps AIOStreams live through the switch and **Turn VPN on** waits for the tunnel before starting it; both are the script doing the work, with its own checks. **Change server** appears when the config's endpoint is a name: the script looks it up again, pings each address from the server and lists them fastest first; the address picked is the only thing sent back, and the panel accepts only an IPv4 address. **Update VPN** pulls the newest `qmcgaw/gluetun:v3` and restarts the stack only if the image changed and the VPN is on.

**Change config** sends the pasted config (or the file's contents, read in the browser) to the panel once, over HTTPS. The panel checks it has both sections, real-looking keys and a valid endpoint, saves it as `vpn-state/upload.conf` (root only, mode 600) and sends back only the endpoint and address; the paste box is emptied. The script's `use-config` then keeps the config in use, its server name and address in `vpn-state/previous/` (listed as **Previous config**), installs the new one as `vpn-state/wireguard.conf`, and switches with the usual tunnel check. If AIOStreams was running and the tunnel doesn't connect, it reports a failure and leaves AIOStreams stopped rather than unprotected; **Use** on Previous config goes back.

**Configs on this server** lists what `list-configs` finds: the pasted config, the previous one, an earlier paste, one pasted but not used yet, and `.conf` files in `/root` and the login user's home that have `[Interface]`, `[Peer]`, `PrivateKey` and `Endpoint` (the same files Reconfigure offers). Each shows its path and endpoint, never its keys. **Use** (any config not in use) copies it into `vpn-state` and switches to it as Change config does, so a file can be deleted afterwards; the config left becomes Previous config, so two can be swapped back and forth. On Previous config, the address it used is picked to start with. **Delete** takes only a path the list has just found, and the config in use only while the VPN is off; the script checks that again before deleting. Deleting that one also takes its key out of the saved VPN settings (`vpn-state/docker-compose.vpn.yml`), so no config is left: **Turn VPN on** then opens the paste dialog and turns the VPN on with the config given (`use-config <ip> on`).

Uninstalling the VPN is on the [Add-ons page](#add-ons-page). The script's `uninstall` switches to direct first, removes the gluetun container (and image, if ticked), and deletes `vpn-state` only once AIOStreams and Caddy are confirmed running, refusing otherwise with nothing deleted. **Delete the .conf files** deletes the ones the list shows in `/root` and the login user's home. The page disappears once the VPN is gone.

## Add-ons page

![The Add-ons page: a card for each add-on, with its links, hidden passwords and keys, and Uninstall](../images/control-panel/addons.png)

It appears on the rail once any optional add-on is installed: AIOMetadata, AIOManager, MediaFlow Proxy, the VPN or phone alerts (and the retired webhook relay, with only its address and Uninstall). Each gets a card with what its script's Status and Show options print, its subdomain's certificate and its memory use; the VPN's and Phone alerts' cards are short, since their own pages hold their settings. Links show their host and path, with Copy and open buttons. Secrets (AIOMetadata's addon password and admin key, MediaFlow's API password) aren't in the page: the panel reads each from the add-on's saved settings only when its eye or Copy is pressed, one at a time, sent with `Cache-Control: no-store`, and the page doesn't keep it. A MediaFlow outbound proxy shows without its login. The watchdog's topic stays masked here too. MediaFlow's card lists the three things AIOStreams' Proxy settings ask for, under the same names: **URL** (its address inside the server, Copy only), **Public URL** and **API password** (the **Credentials** field). AIOManager's card has the **sign-ups switch**: on opens them for 30 minutes (they close by themselves), off closes them now; while AIOManager restarts with the change, it shows **Opening…** or **Closing…** with a spinner.

**Uninstall** on each card asks for `uninstall` to be typed. **Back up first** runs a normal backup and stops if it fails (a backup holds the add-on's settings, so a restore brings it back). Tick boxes cover the script's own questions: removing the images, and the VPN's `.conf` files. Each script's question-free `uninstall` does exactly what its menu's Uninstall does; with **Back up first**, its output starts with the backup made and a link to the backup's own output. The card goes once the add-on has.

## Phone alerts page

![The Phone alerts page: status, the last 14 days, the optional alerts and recent events](../images/control-panel/alerts.png)

It appears on the rail once the [watchdog](./watchdog.md) has been set up over SSH (first-time setup asks you to subscribe in the ntfy app, so it stays a script job). It reads `watchdog-state/`: whether the timer is running, the last check, what it watches, the daily tally as 14 squares, the event list, and the two optional switches. The topic is only ever sent to the browser masked (its first five and last two characters). **Change topic** suggests a random topic in groups of four with no look-alike characters, with **Copy**, and links to it on ntfy.sh so you can subscribe first.

## Maintenance page

![The Maintenance page](../images/control-panel/maintenance.png)

Read when the page opens and kept for 5 minutes. **Free up space** counts untagged images and `viren070/aiostreams` images no container uses, by the space only they hold (layers shared with an image that stays aren't freed), build cache Docker would remove (not records shared with an image in use), and the journal beyond 100 MB (`journalctl --disk-usage`). Other tagged images, such as gluetun's while the VPN is off, are kept for when they're wanted again. **System updates** reads `apt list --upgradable` (security ones by their `-security` source), `/var/run/reboot-required` or, as Debian has no such file, a kernel installed since the last boot, and when the package lists were last refreshed. **Container logs** reads `/etc/docker/daemon.json` and each container's own log settings.

`system-updates` runs `apt-get update` and `apt-get upgrade --with-new-pkgs` non-interactively, keeping changed config files, then brings the stack back as Start would (AIOStreams has `restart: "no"` in VPN mode, so a Docker restart would otherwise leave it stopped; stopped on purpose stays stopped). `log-limits` adds `"log-opts": {"max-size": "10m", "max-file": "3"}` to `daemon.json`, keeping any other settings (with `python3`), checks it with `dockerd --validate` where Docker has that, restarts Docker (putting the old file back if it won't start), then recreates the stack, the running add-ons and the panel so they take it. `daemon.json` is outside `/opt/aiostreams`, so a backup doesn't carry it; on a new server the card shows **Not set** again.

**Scheduled server reboot** reads `restart-schedule` (absent: off) and `restart-last-run`, whether `aiostreams-restart.timer` is active and when it next fires, `timedatectl show` for the clock, and root's crontab for linux-aio-toolkit's own scheduled reboot (the `# aio-toolkit: scheduled-reboot` line), which it points out since both would run. At the set time the timer runs `setup-maintenance.sh scheduled-restart`: in **When needed** mode it does nothing unless a restart is needed (the same check as System updates), it skips a server started in the last 10 minutes, and it waits up to 30 minutes for any setup script or apt to finish, skipping if they're still going. Before restarting it leaves `watchdog-state/planned-restart`, so the watchdog's restart alert says it was the scheduled reboot and comes quietly. A time missed while the server was off isn't made up (`Persistent=false`), as that would restart it straight after starting. Changing the time zone moves every scheduled time with it: systemd timers go by the server's clock.

## Backups and restores

![The Backup & Restore tab](../images/control-panel/backups.png)

Backups are listed from root's home and the login user's home, merged by name. Locks and notes are kept in `ui-state/backup-meta.json`, which scheduled backups also read so they never remove a locked one. Over SSH, `setup-backup.sh keep` and `unkeep` change the same lock.

The **Scheduled backups** card reads `backup-schedule` and `backup-last-run` (see the [backup guide](./backup-restore.md#scheduled-backups)), and whether `aiostreams-backup.timer` is active; if the schedule is on but the timer isn't, it says so and **Set** starts it again. A name with `-scheduled-` gets the **Scheduled** label. The Overview's **Last backup** is the newest backup of any kind, read at most once a minute, amber only when the last scheduled run failed or was skipped.

A restore moves your current install aside to `/opt/aiostreams.pre-restore-<date>-<time>` as a rollback copy, and the script never removes it. Those folders show up under **Set aside by restores** with a Delete button. The panel only deletes folders with exactly that name, next to the install folder.

A restore run over SSH rebuilds the panel from the backup (if it was running when the backup was made), after checking its subdomain like the add-ons'. Run from the panel's own Terminal tab, the panel stays up so the restore isn't cut off; press **Restart panel** (Backup & Restore or Terminal tab) afterwards so it picks up the restored folder.

**Reboot server** (Overview, under "This server") restarts the whole machine. When installed updates need a restart, Maintenance's System updates card and the drawer that Install updates opens offer it too. You have to type `reboot` to confirm, and it refuses while an action is running. Everything uses `restart: unless-stopped`, so the stack and the panel come back by themselves.

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
