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

- **Caddy gate.** Without the unlock cookie, every URL on the subdomain returns a bare 404. The login page isn't even discoverable. Opening `/unlock/<token>` once sets the cookie. Menu option 5 makes a new token, which also signs out every browser.
- **Login.** Password hashed with scrypt, 7-day signed session cookie (HttpOnly, Secure, SameSite=Strict). 5 wrong passwords locks that address out for 15 minutes.
- **No free-form commands.** The browser can only ask for actions from a fixed list (`app/actions.py`). It can't type a command, and logs are limited to the stack's own containers.
- **No secrets shown.** `SECRET_KEY` and logins are never sent to the browser. Backups can be listed, created and deleted (delete removes every copy, after a confirm; a locked backup can't be deleted until you unlock it), but not downloaded: copy them off with `scp`.
- **Web terminal (off by default).** Behind a second key, separate from the login and the unlock link. See below.

It is still root-equivalent on your server, because it has to run the scripts and talk to Docker (the container is privileged and shares the host's process namespace, so it can run scripts on the host through `nsenter`). Treat the unlock link and the password like SSH credentials.

## What each button runs

| Button | Script and input |
| --- | --- |
| Start, Stop, Restart | `setup-aiostreams.sh` menu options 3, 2, 4 |
| Restart (per service) | restarts just that container through Docker; AIOStreams, MediaFlow and the webhook relay only |
| Update | menu option 5, with the backup and build-channel answers from the dialog |
| Back up now | `setup-aiostreams.sh backup` |
| MediaFlow, webhook relay | `start-mediaflow`, `start-relay`, and menu option 3 for Stop |
| Phone alerts | `install-timer`, and menu options 3 and 4 |

The scripts run on the host with a terminal attached, like an SSH session. Reconfigure, VPN switching and uninstall have no button. Restore is run from the Terminal tab or SSH.

The version chip on the Overview tab is read from the running AIOStreams container's own `package.json`, once per container (an update recreates it, so the chip follows).

## Logs

On the Caddy tab, **Hide noise** hides the log lines that look alarming but are expected (a restart, the log viewer reconnecting) and says how many it is hiding. **Hide warnings** (on every tab) hides every warn-level line, while errors still show. Both are display filters only; they never change what's logged. Lines are coloured by their JSON `level`. **Clear** hides everything logged so far, and it stays hidden after a reload; Docker's own log file is left alone on purpose, since emptying it behind Docker's back breaks `docker logs`.

## Backups and restores

Backups are listed from root's home and the login user's home, merged by name. Locks and notes are kept in `ui-state/backup-meta.json`.

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
