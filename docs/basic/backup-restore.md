# Backup & Restore .  Basic Guide

For backing up your current setup, rolling back to an earlier backup on the same server, or moving AIOStreams to a new server entirely.

> ⚠️ **Treat the backup file like a password.** It contains your login and `SECRET_KEY` .  store it somewhere safe, don't share it, and delete old copies (including off the server) once you don't need them.

> Want to know exactly what's inside the backup, or something went wrong? → [Advanced guide](../advanced/backup-restore.md)

---

## 1. Back up your current server

**This does:** packs everything (your domain settings, login, `SECRET_KEY`, and every saved config) into one file.

> The backup tars up the entire `~/aiostreams` folder, not just the app data .  so `setup-vpn-gluetun.sh`, `setup-watchdog.sh`, and any other install scripts sitting in that folder come along automatically too. Nothing to move by hand.

```bash
cd ~/aiostreams
sudo bash setup-aiostreams.sh backup
```
This prints a file name like `aiostreams-backup-YYYYMMDD-HHMMSS.tar.gz` and a ready-to-use `scp` command to copy it off the server .  **use the exact command it prints**, don't copy the one below blind. It differs depending on how you're logged in:
- **Logged in as root:** the file lives in `/root`, and it prints something like
  ```bash
  scp root@your-server-ip:~/aiostreams-backup-YYYYMMDD-HHMMSS.tar.gz .
  ```
  The script also drops a copy in your home directory (owned by you), printed as:
  ```bash
  scp your_user@your-server-ip:~/aiostreams-backup-YYYYMMDD-HHMMSS.tar.gz .
  ```
  This matters if root SSH login is disabled on your box.

Run the printed command **now**, from your own computer .  or, if you'd rather not use a terminal, open an SFTP app (FileZilla, WinSCP, Termius) and download the same file from your home directory on the server.

---

## Restoring on the same server

Just rolling back to an earlier backup on the server you're already on .  no migration involved? From the management menu, pick **8) Restore from backup**, then select your tarball. The script moves your current install aside automatically before restoring, so nothing is lost if you picked the wrong file.

That's it .  no DNS changes, no second server, no other setup needed.

---

## Bonus: back up before an update, in one step

You don't need to run the steps above just to be safe before an update. From
the management menu:

```
5) Update (pull latest images + restart; can also switch stable/nightly)
```

picking this now shows:

```
Update AIOStreams:
  1) Backup first, then update
  2) Update without backing up
  3) Cancel
```

Choose **1** and it runs the same backup as step 1 above, then goes straight
into the update .  one prompt, no separate steps.

Right after that, it also asks whether to switch build channel (stable/nightly)
before pulling. If you say yes to switching **from nightly back to stable**,
it'll warn you that's a downgrade and nudge you to back up first .  worth
listening to, since that's the one direction where newer data written by
nightly might not be something stable knows how to read yet. Going the other
way, stable → nightly, is safe either way.

**6) Reconfigure** offers the same backup-first prompt before changing your domain/login.

---

## Migrating to a new server

Moving AIOStreams to a different VPS .  a provider switch, a resize that needs a rebuild, or just replacing an aging box. This picks up from the backup you made in step 1 above.

### 2. Point your domain at your new server .  do this now

**This does:** starts DNS propagation early, so it's already pointing at the new server by the time you restore. The script can't do this step for you.

⚠️ **Do this before you restore, not after.** DNS changes can take a few minutes to spread across the internet. If you restore before DNS has caught up, the restore script will pause and offer to wait for you, fix a typo'd domain, or let you continue anyway .  see the note in step 4. Doing this now just means you likely won't be shown that prompt at all.

1. Log in to your domain/DNS provider.
2. Update the A record for your domain to the **new** server's IP address.
3. Wait a few minutes, then check it's updated:
```bash
dig +short yourdomain.com
```
Keep going with steps 3–4 below while you wait .  no need to sit and watch it.

---

### 3. Send the script and backup to your new server

**This does:** gets what the new server needs to rebuild everything.

```bash
scp setup-aiostreams.sh aiostreams-backup-YYYYMMDD-HHMMSS.tar.gz root@your-new-server-ip:~
```
(Not using root over SSH? Send them to your own home directory instead .  `scp setup-aiostreams.sh aiostreams-backup-....tar.gz your_user@your-new-server-ip:~` .  the restore step below will still find the tarball automatically either way.)

Prefer not to use a terminal for this? An SFTP app (FileZilla, WinSCP, Termius) works just as well .  upload both files to the same location (your home directory, or `/root` if you're logging in as root).

---

### 4. Restore on the new server

**This does:** rebuilds your whole setup .  same domain, login, and configs.

Before running this, double check `dig +short yourdomain.com` (from step 2) is showing your **new** server's IP. If it's not there yet, wait a bit longer .  restoring before DNS has caught up is the most common cause of a stuck HTTPS certificate.

Run this from wherever step 3 uploaded the files (your home directory, or `/root` if you're logging in as root .  `~/aiostreams` doesn't exist yet on a fresh server, so this is the one script command in these docs that *isn't* run from there):
```bash
sudo bash setup-aiostreams.sh
```
- **Brand-new server, nothing installed yet:** pick **2) Restore from a backup** on the first-run screen.
- **Server already has an install on it** (e.g. you ran a fresh install here earlier): pick **8) Restore from backup** from the management menu instead.

Either way, select your backup file from the list.

(Or skip the menu entirely: `sudo bash setup-aiostreams.sh restore aiostreams-backup-YYYYMMDD-HHMMSS.tar.gz`)

**If DNS hasn't caught up yet (or the domain looks wrong), the script will pause and ask before starting anything:**
```
What would you like to do?
  1) Re-check DNS now (do this after updating your A record)
  2) Wait and auto-retry every 15s (up to 10 min) while DNS propagates
  3) Enter a different domain (fixes a typo, or use a new domain for this restore)
  4) Continue anyway (not recommended .  cert will likely fail)
  5) Abort restore
```
- Just updated DNS a moment ago? Pick **2** and let it poll for you.
- Realize the domain in the backup isn't the one you want live on this server (e.g. testing under a separate subdomain)? Pick **3** and type the correct one .  it rewrites the config on the spot and re-checks immediately.
- Nothing here will start Docker or touch your certificates until you choose .  it's safe to sit and think.

⚠️ If you also use the [Webhook Relay](./webhook-relay.md) and you're restoring under a **different domain than before**, its subdomain doesn't update automatically here, it needs a manual Reconfigure afterward on the new server. See the [advanced guide](../advanced/backup-restore.md#migrating-to-a-new-server) for the exact steps. Doesn't apply if you're restoring on the same server or keeping the same domain.

That's it .  no other setup needed.

---

### 5. Confirm everything works

- Visit `https://yourdomain.com` .  should load with a valid padlock/HTTPS.
- Log in with your existing username/password.
- Play a stream from a device that already had the addon installed .  if it plays, the move worked.
- **Keep the old server running** until you've confirmed this. It's your safety net if something looks wrong.

---

Something not loading, or want the full detail on what's inside a backup? → [Advanced guide](../advanced/backup-restore.md)
