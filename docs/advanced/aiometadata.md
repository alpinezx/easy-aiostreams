# AIOMetadata (advanced)

> New to this? Start with the [basic guide](../basic/aiometadata.md).

## What it runs

`setup-aiometadata.sh` adds a small stack of its own next to AIOStreams, the same way MediaFlow Proxy does:

- **`aiometadata`**: [AIOMetadata](https://github.com/cedya77/aiometadata)'s image (`ghcr.io/cedya77/aiometadata`), pinned to an exact release such as `3.6.1`, never `latest`. Updates change the pin (see [Updates](#updates-and-going-back)).
- **`aiometadata_redis`**: Redis 8 (AIOMetadata needs 8 or newer), capped at 256 MB. A cache only: nothing in it needs keeping.

Both sit on the shared `aios_shared` Docker network with no published ports. Caddy serves the subdomain (`caddy.d/55-aiometadata.caddy`) and reverse-proxies to `aiometadata:3232`, with the HTTPS certificate handled like your main site's.

Everything it keeps is in `/opt/aiostreams/aiometadata-state/`:

| | |
|---|---|
| `config` | subdomain, addon password, admin key and the pinned release (root only, mode 600) |
| `aiometadata.env` | the settings AIOMetadata reads (mode 600) |
| `docker-compose.yml` | its two containers |
| `data/` | its database (`db.sqlite`), plus lookup files it downloads itself (about 50 MB) |

On a first run it used about 440 MB of memory, and Redis about 20 MB.

## How it's kept private

- **Addon password (required).** Creating or deleting a configuration needs it. The configure page still opens, but won't save without it. Configurations you've made keep working in your apps through their install links, and each has its own password for editing it. Change the addon password with **4) Reconfigure**.
- **The Dashboard is locked.** It opens only with the **admin key**, and guest mode is switched off (`DISABLE_GUEST_MODE=true`), so its stats, analytics and settings answer nobody else. The key is generated once and kept: AIOMetadata also signs its artwork links with it, so changing it would break links it has already handed out.
- **No page-level login.** AIOMetadata's only whole-site lock (`AUTH_REQUIRE_SIGNIN`) needs a single sign-on provider, which is more than this setup takes on, and a Caddy password in front would break your apps, which use the same addresses as the configure page. The addon password and the locked Dashboard are what keep it yours.

## API keys: Built-in rows only

The Dashboard's **Settings → API Keys** has two kinds of rows, and they behave very differently:

- **Built-in ... rows** (e.g. **Built-in TMDB Key**, `BUILT_IN_TMDB_API_KEY`) stay on your server. Any configuration without a key of its own uses them, and the configure page hides its own TMDB field once one is set. Saved in AIOMetadata's database, so backups include them.
- **Plain rows** (e.g. **TMDB API Key**) are **published**: AIOMetadata hands them to anyone who asks, without a login, and the configure page fills them in for every visitor.

So use the Built-in rows. With the addon password set, your instance is private, which is when AIOMetadata's own docs say Built-in keys (even the per-request MDBList and Gemini ones) are fine.

To check nothing is published, ask it as a stranger would:

```bash
curl -s https://meta.yourdomain.com/api/config
```

The plain keys (`tmdb` and so on) should be empty, and `hasBuiltInTmdb` should be `true`.

## Updates and going back

Releases are pinned, so nothing changes until you update. Three ways, all the same underneath:

- The control panel: **Update** on AIOMetadata's card, with **Back up first** ticked.
- The menu: **7) Update**, which also lets you pick an older version.
- A command, which asks nothing:

```bash
sudo bash /opt/aiostreams/setup-aiometadata.sh update-aiometadata [--backup] [--version X.Y.Z]
```

It pulls the release, restarts AIOMetadata and waits up to 90 seconds for it to report healthy. If it doesn't, it shows the last log lines, puts the previous release back and removes the one that failed. A version that doesn't exist is refused before anything changes. Going back to an older release warns you first, since a newer release may have changed its database.

Restoring a backup made with **Back up first** brings back the release from before that update, as the backup is taken before switching.

The control panel checks GitHub for new releases at most every 3 hours, only while you have it open, like AIOStreams' own. Releases come out often (up to twice a day), so a newer one shows as a plain line on the card, not an amber one or a blue button.

## Backups

A backup holds `aiometadata-state/`: its settings, database (configurations, your Built-in keys, Dashboard settings) and a note of whether it was running. To get a consistent copy of the database, AIOStreams and AIOMetadata are paused together for a few seconds while it's copied.

Left out: the lookup files in `data/` (`*.cache`, `imdb-ratings.bin`), which AIOMetadata downloads again by itself after a restore, and Redis, which is only a cache.

A restore checks AIOMetadata's subdomain points at the server, then starts it again if it was running. Restoring over SSH on a new server or domain offers to move it to a new subdomain: its address, its Caddy site and its certificate all follow. Its configurations then live at a new address, so install them in your apps again. The control panel's **Restore** is for rolling the same server back only, and refuses a backup whose AIOMetadata subdomain differs from this server's.

Backups from before AIOMetadata was added (format 4 or older) can't say whether it was running, so a restore leaves it off and prints the command to start it.

More on backups in general: [Backup & Restore (advanced)](./backup-restore.md).

## Phone alerts

With the [watchdog](./watchdog.md) set up, AIOMetadata joins its checks by itself once installed:

- **Every 2 minutes:** Caddy is running, AIOMetadata's container is running, and it answers its own health check (`/health/live`, asked through Caddy). Two failures in a row send the usual down alert, saying what failed; the all-clear follows when it passes again. **3) Stop** leaves a marker, so stopping it on purpose doesn't alert.
- **New releases (optional):** off until you switch it on, on the control panel's Phone alerts page or as option 8 in the watchdog's Extra alerts menu. At most one alert a day, naming the newest release, checked every 6 hours.

## Control panel

Once AIOMetadata is installed, the [control panel](./control-panel.md) shows:

- **Its own Overview card**, under AIOStreams': the release it runs, the newest one, **Update**, **Check now**, **All releases** (the release notes, in the same drawer as AIOStreams'), and **Dashboard** and **Configure** links beside its title. It folds and can be hidden or moved with **Edit**, like the other cards.
- **A row in Services** with **Logs**, **Restart** and **Stop** / **Start**, and its branch off Caddy in the request flow.
- **A row on the Scripts tab**, as an optional add-on.

The panel reads only the subdomain and the pinned release from `config`, never the password or key in the same file.

## Menu reference

```bash
sudo bash /opt/aiostreams/setup-aiometadata.sh
```

1. **Status**: running or not, address, release, and whether a newer one is out
2. **Start**: brings it up (installs it, the first time)
3. **Stop**: stops both containers, keeping everything, and leaves the "stopped on purpose" marker
4. **Reconfigure**: change the subdomain or addon password
5. **Test**: checks it answers inside the server and over HTTPS
6. **Show address, password and admin key**
7. **Update**: the newest release, or an older one, with a backup first if you like
8. **Uninstall**: type `uninstall` to confirm. Removes both containers, the Redis cache, the Caddy site and `aiometadata-state/`, and optionally the downloaded images. Only the script itself stays.
9. **Show recent logs**
10. **Exit**

The commands the control panel uses ask nothing: `start-aiometadata`, `stop-aiometadata` and `update-aiometadata`.

---

[← Basic guide](../basic/aiometadata.md) · [All guides](../troubleshooting.md#all-guides)
