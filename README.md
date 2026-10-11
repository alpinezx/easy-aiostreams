# Easy AIOStreams: move to /opt

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

> [!IMPORTANT]
> **This is the `migrate-to-opt` branch.** It only exists to move an install made before October 2026 from `/root/aiostreams` to `/opt/aiostreams`. Do it once, then go back to the [main branch](https://github.com/alpinezx/easy-aiostreams) for installing, updating and everything else.

## Move an existing install

```bash
curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/migrate-to-opt/setup-aiostreams.sh -o ~/setup-aiostreams-migrate.sh
sudo bash ~/setup-aiostreams-migrate.sh migrate
rm ~/setup-aiostreams-migrate.sh
```

What it does:

- Takes a backup first
- Stops the stack for about a minute
- Moves everything to `/opt/aiostreams`, and points the add-ons, systemd units and control panel at the new path
- Starts back up whatever was running

Afterwards `/root/aiostreams` and your `~/aiostreams` become shortcuts to the new folder. Your old `~/aiostreams` is removed only if it held nothing but copies of the scripts (an older `setup-aiostreams.sh` counts, since the new one replaces it); otherwise it's renamed to `~/aiostreams.old-<time>`.

To put everything back the way it was:

```bash
sudo bash /opt/aiostreams/setup-aiostreams.sh migrate undo
```

## Restore a pre-October 2026 backup onto a new server

Use this version for that restore too. It puts the backup in `/opt/aiostreams` and points its add-ons there. The last line then puts the current script from the main branch in place:

```bash
curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/migrate-to-opt/setup-aiostreams.sh -o ~/setup-aiostreams-migrate.sh
sudo bash ~/setup-aiostreams-migrate.sh restore aiostreams-backup-YYYYMMDD-HHMMSS.tar.gz
rm ~/setup-aiostreams-migrate.sh
sudo curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-aiostreams.sh -o /opt/aiostreams/setup-aiostreams.sh
```

If you're moving to a new server, remember to update your domain's A record afterwards. The [backup & restore guide](https://github.com/alpinezx/easy-aiostreams/blob/main/docs/basic/backup-restore.md) on main covers that.

## Everything else

Installing, updating, the management menu, troubleshooting and the other scripts are all on the [main branch README](https://github.com/alpinezx/easy-aiostreams). Bugs: [open an issue](https://github.com/alpinezx/easy-aiostreams/issues).

## License

MIT, see [LICENSE](./LICENSE). Provided as-is, no warranty; you're responsible for your own server, keys, and data.
