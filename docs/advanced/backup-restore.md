# Backup & Restore (same-server restore or server migration)

> In a hurry? [Basic guide](../basic/backup-restore.md) covers the same steps with no deep explanations.

> ⚠️ **Treat the backup file like a password.** It contains your
> `SECRET_KEY`, every login on the box, and (if present) your WireGuard
> private key. Store it encrypted, never share it, and delete old copies you
> no longer need .  on both the server and wherever you copy it to.

## What this is for

Most of the time, this isn't about moving servers at all .  it's a safety
net for the server you're already on: a tarball you take before an update
or a config change, in case you want to roll back. `setup-aiostreams.sh`
has a built-in **Backup** and **Restore** pair that covers that in two
commands, and the exact same tarball also happens to be everything needed
to move to a new VPS .  a provider switch, a resize that needs a rebuild, or
just replacing an aging box .  with your domain, login, `SECRET_KEY`, and
every stored user config coming back exactly as they were. Nothing to
recreate, no Stremio manifest URLs to reissue, whichever reason you're
using it for.

## What's included in a backup

- Both compose files (`docker-compose.yml`) .  these hold your `SECRET_KEY`
  and login
- `Caddyfile` and any drop-in site configs (`caddy.d/`)
- AIOStreams' own data directory (`./data`) .  every stored user config
- `vpn-state/`, if you ever set up the [VPN layer](./vpn-setup.md) .  this
  contains your WireGuard **private key**
- `watchdog-state/`, if you ever set up [Watchdog Alerts](./watchdog.md) . 
  this contains your ntfy topic name
- `webhook-relay-state/`, if you ever set up the [Webhook Relay](./webhook-relay.md) . 
  this contains your secret path token and ntfy topic
- Every install script (`setup-aiostreams.sh`, `setup-vpn-gluetun.sh`, `setup-watchdog.sh`, `setup-webhook.sh`) .  any `.sh` file in `~/aiostreams` is included automatically, which is why all install commands download there first

**Not included:** Caddy's HTTPS certificates. They're in Docker volumes, and Caddy re-issues them automatically once DNS resolves on the new server. No point bundling them.

## Creating a backup

From the management menu (existing install detected):

```
7) Backup (one tarball with everything needed for migration or safekeeping)
```

Or non-interactively, without going through the menu at all:

```bash
cd ~/aiostreams
sudo bash setup-aiostreams.sh backup
```

Either way, this writes a timestamped tarball, e.g.
`aiostreams-backup-YYYYMMDD-HHMMSS.tar.gz`, and prints the `scp` command
to copy it off the server. **Use the exact command it prints** .  it depends
on how you're logged in:

- **Logged in as root:** written to `/root`, printed as
  ```bash
  scp root@your-server-ip:~/aiostreams-backup-YYYYMMDD-HHMMSS.tar.gz .
  ```
- **Logged in as yourself, using `sudo`:** written to `/root` *and* to your
  own home directory (owned by you, not root), printed as
  ```bash
  scp your_user@your-server-ip:~/aiostreams-backup-YYYYMMDD-HHMMSS.tar.gz .
  ```
  The second copy exists specifically so you're not stuck needing root SSH
  access, which your box may not even permit if root login has been locked
  down. Both copies contain your `SECRET_KEY` and logins, so delete both
  once you're done, not just the one you copied off.

Do this now, before you decommission the old server .  the tarball on disk
is not itself an off-site backup. Any SFTP client (FileZilla, WinSCP,
Termius) works just as well as `scp` if you'd rather not use a terminal for
the transfer .  the file lives in the same place either way.

### Backing up as part of an update

The most common reason to reach for a backup isn't migration .  it's a
safety net right before an image update, in case a new release changes
something you'd rather roll back. Rather than running `backup` separately
beforehand, option **5) Update** in the management menu now asks first:

```
Update AIOStreams:
  1) Backup first, then update
  2) Update without backing up
  3) Cancel
```

Choosing **1** runs the exact same backup routine described above (same
tarball, same off-server `scp` instructions, same contents) and then
proceeds straight into the pull + recreate. Choosing **2** skips straight to
updating, and **3** returns to the menu without doing anything. This doesn't
change what's captured or how restore works .  it's the same backup, just
offered at a moment you're likely to want it.

Right after this backup prompt (either choice), Update also asks whether to
switch build channel .  `latest` (stable) or `nightly`. Switching *to* nightly
is low-risk. Switching *from* nightly back to stable is flagged as a
downgrade and prompts you again with a stronger warning, since nightly can
move ahead of stable on config/database format before a given change lands
in a stable release; a backup taken just before that switch is your rollback
if the downgrade doesn't read stored data cleanly. The image tag itself is
just the `image:` line in `docker-compose.yml` .  restoring a backup brings
back whatever tag was active when that backup was taken.

### Backing up as part of Reconfigure

Option **6) Reconfigure** offers the same prompt before changing your domain
or login. Note this is *in addition to* Reconfigure's existing automatic
backup of just `docker-compose.yml`/`Caddyfile` (kept as `.bak_TIMESTAMP`
files) .  that lightweight one always happens regardless of your choice here.
Picking **1) Backup first** on top of it also gets you the full tarball
(`./data`, `vpn-state`, everything) for a real off-server safety net.

## Restoring onto the same server (rollback, no migration)

This is the everyday case: rolling an existing install back to an earlier
backup, on the same box, with no new server and no DNS change involved. The
script detects the existing `~/aiostreams` directory, warns you that
restoring will **replace** it (including its `SECRET_KEY`), and moves the
current one aside (e.g. `~/aiostreams.pre-restore-YYYYMMDD-HHMMSS`) rather
than deleting it outright, so you can recover if you picked the wrong
tarball.

From the management menu, choose **8) Restore from backup**, then pick your
tarball from the list. That's it .  the script finds tarballs sitting in the
same directory or your home folder automatically (newest first, if there's
more than one).

Prefer to skip the menu entirely? This does the same thing
non-interactively:
```bash
sudo bash setup-aiostreams.sh restore aiostreams-backup-YYYYMMDD-HHMMSS.tar.gz
```

---

## Migrating to a new server

Everything below is specific to moving your install to a *different* VPS.
If you're restoring on the same server, you're already done .  see above.

### Update your DNS record .  do this before restoring, not after

This is the one step the script *can't* do for you, and it's worth doing
**before** you run the restore on the new server rather than after.

Your domain's DNS A record still points at the **old** server's IP until you
change it:

1. Log in to your domain/DNS provider and update the A record for your
   domain to point at the **new** server's IP address.
2. DNS propagation isn't instant .  give it a few minutes, and check with
   `dig +short yourdomain.com` to confirm it's pointing at the new IP.

⚠️ **Why order matters here:** Caddy requests an HTTPS certificate as soon
as the stack comes up on the new server. If DNS is still pointing at the
old server at that moment, the certificate request fails, and you're left
troubleshooting a site that "won't load" for a reason that has nothing to
do with the restore itself. Kicking off the DNS change first .  while you
transfer the backup file over in the next step .  means propagation has
usually already finished by the time you actually restore, so Caddy gets a
valid certificate on the first try.

### Restoring on a new server

This is **one run of the script**, not two, and it does not involve
Reconfigure. Restore recreates your compose files, Caddyfile, and data
directory exactly as they were on the old server .  domain, login, and
`SECRET_KEY` all come back with them. Reconfigure is a separate,
unrelated option for deliberately *changing* your domain or login on an
already-running install; there's nothing to reconfigure right after a
restore, since nothing about your setup has changed.

1. **Get the script and the tarball onto the new server.** Any transfer
   method works .  `scp`, or an SFTP app (FileZilla, WinSCP, Termius) if
   you'd rather not use a terminal .  drop both into `/root` if you're
   logging in as root, or your own home directory if you're using `sudo`
   (wherever you'll run the script from either way):
   ```bash
   scp setup-aiostreams.sh aiostreams-backup-YYYYMMDD-HHMMSS.tar.gz root@your-new-server-ip:~
   # or, without root SSH access:
   scp setup-aiostreams.sh aiostreams-backup-YYYYMMDD-HHMMSS.tar.gz your_user@your-new-server-ip:~
   ```
2. **Before running the script, double-check DNS has caught up:**
   ```bash
   dig +short yourdomain.com
   ```
   It should already show your new server's IP, from the DNS step above. If
   it doesn't yet, it's fine to wait a bit longer here .  there's no rush on
   the restore itself.
3. **Run the script.** Which menu you land on depends on whether this
   server already has AIOStreams installed:

   - **Brand-new server, nothing installed yet** .  you'll land on the
     first-run screen:
     ```bash
     sudo bash setup-aiostreams.sh
     ```
     Choose **2) Restore from a backup**.

   - **Server already has an install on it** (e.g. you ran a fresh install
     here earlier, or you're rolling back on the same box) .  you'll land on
     the management menu instead:
     ```bash
     sudo bash setup-aiostreams.sh
     ```
     Choose **8) Restore from backup**.

   Either way, if the tarball is sitting in the same directory or your home
   folder, the script finds it automatically and lists it (newest first, if
   there's more than one) .  just pick it by number instead of typing a path.

   Prefer to skip the prompts entirely? This does the same thing
   non-interactively:
   ```bash
   sudo bash setup-aiostreams.sh restore aiostreams-backup-YYYYMMDD-HHMMSS.tar.gz
   ```
4. **That's it for the script.** It installs Docker if needed, extracts the
   backup, and starts the stack. Because DNS is already pointing at this
   server and the `SECRET_KEY` and data came over intact, Caddy issues a
   valid HTTPS certificate immediately and every existing user config and
   installed Stremio manifest URL keeps working without you touching
   anything else.

### Verifying the move worked

- Visit `https://yourdomain.com` and confirm it loads over HTTPS with a
  valid certificate.
- Log in with your existing username/password.
- Play a stream from a device that already had the Stremio addon installed
  from before the move .  if it plays, the manifest URL and `SECRET_KEY`
  carried over correctly.
- **Keep the old server running** until this is confirmed. It's your
  rollback if anything looks wrong .  just point DNS back at it.

If the backup was taken while the [VPN layer](./vpn-setup.md) was active,
gluetun comes back up automatically as part of the restored stack .  no
extra step needed there either.

⚠️ **If the [Webhook Relay](./webhook-relay.md) was active, and you're
restoring under a genuinely different domain** (not just a new IP for the
same domain): the relay container comes back up automatically same as
everything else, but it comes back pointed at its **old** subdomain, e.g.
`hooks.olddomain.top`, not anything derived from the new one. Nothing
rewrites this automatically the way the main domain gets rewritten above,
since the relay's subdomain isn't necessarily related to the main one and
there's no safe way to guess a replacement. Point DNS at the new server for
whichever subdomain you want to keep using, then run `sudo bash
setup-webhook.sh` → **4) Reconfigure** on the new server to update it (and
re-paste the resulting URL into whatever third-party site was using it,
since the old one won't resolve here anymore). Restoring onto the same
server, or a new server under the same domain, isn't affected by this at
all.

---

## Troubleshooting

**"That archive doesn't look like a backup made by this script"**
The restore command validates that the tarball actually contains
`aiostreams/docker-compose.yml` before touching anything. This means either
the wrong file was passed in, or the archive is corrupted .  re-copy it from
source and try again.

**Restored, but the site won't load**
Almost always DNS. Confirm the A record actually points at the new server's
IP (`dig +short yourdomain.com`) before assuming anything else is wrong . 
Caddy can't get a certificate for a domain that isn't resolving to it yet.
Not applicable if you restored on the same server .  DNS never changed.

**Restored fine, but the VPN layer doesn't come back**
It's self-contained within the backup .  as long as `vpn-state/` existed on
the old server, it's included automatically and starts along with the main
stack. If it's missing, the backup was likely taken before the
[VPN layer](./vpn-setup.md) was set up on the old server.

**Restored under a new domain, but the webhook relay's URL still points at the old one**
Expected, not a bug .  see the callout above. Only the main domain gets
rewritten automatically during a domain-mismatch restore; the
[Webhook Relay's](./webhook-relay.md) subdomain needs `setup-webhook.sh` →
**Reconfigure** run manually afterward, once DNS for the new subdomain
points here.
