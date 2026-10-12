# Notes for Claude sessions on this repo

## How changes get made

Every code change is tested on a real server before it's merged. When asking
for a test, give one step at a time, with the commands in code blocks and what
each should print. No em dashes in docs, script output or commit messages.

Documentation (README, `docs/`, this file) and comment-only edits to code
don't need a server test, as long as no behaviour changes. Go through `dev` and
a PR to `main` as usual. Two limits: a `#` line inside a heredoc is written
into the generated file, so it counts as code; and run `bash -n` on any edited
`.sh` file to catch a broken quote or block.

## Branches

- `main`: what users install. Changes reach it only by pull request from `dev`,
  merged with a merge commit. Don't push to `main` directly.
- `dev`: where work happens. Push here, then open a PR to `main` once it's been
  tested on a droplet.
- `migrate-to-opt`: frozen, one-off. Moves a pre-October-2026 install from
  `/root/aiostreams` to `/opt/aiostreams`, and restores pre-October backups.
  Its README only covers that. Fix it only for migration bugs.

Commits: author as `Claude <noreply@anthropic.com>`. The owner's own email is
private on GitHub, and pushes using it are rejected.

## Layout

Everything lives in `/opt/aiostreams` (mode 750, group = the sudo user who
installed it), with `~/aiostreams` and `/root/aiostreams` as shortcuts. Add-ons
keep their settings in `*-state/` folders inside it, and their Caddy sites in
`caddy.d/`. A different sudo user gets "Permission denied" there, by design.

## How the scripts depend on each other

- `setup-aiostreams.sh` hands menu options 7 and 8, `backup`, `restore`, and the
  backup offered before Update/Reconfigure to `setup-backup.sh`, downloading it
  from `RAW_BASE` when it's missing.
- `setup-backup.sh`'s restore calls back into `setup-aiostreams.sh`
  (`_remove-addons`, `restore_start_stack`) and into each add-on script
  (`start-mediaflow`, `start-relay`, `enable-boot-notify`,
  `control-panel/setup-ui.sh rebuild`). A change to one side usually needs the
  other. Test both together.
- Backups record what was running in `was-active-at-backup` markers, and the
  webhook's reboot notification in `webhook-relay-state/boot-notify-at-backup`.
  `backup-info` holds the format number (3 now). Bump it when adding a marker,
  and give older backups a reminder instead of guessing.
- The panel's Restore button runs `setup-aiostreams.sh restore --same-server
  <file>`, which runs `restore_check` (also `restore --check`) and refuses
  unless the restore would ask nothing, then restores with no questions and
  stdin closed. Any new question in the restore needs a matching check in
  `restore_check` and an unattended answer, or the panel's restore can't
  handle it.
- The control panel has a version in `control-panel/VERSION`, copied into its
  image. Its Update compares that with `VERSION` on GitHub (its update branch:
  `main`, or `AIOS_UI_BRANCH` at its last rebuild), so **bump `VERSION` in every
  PR that changes `control-panel/`**: the last number for fixes and wording, the
  middle one for features. Without a bump, nobody is offered the change. The
  button runs `setup-ui.sh update-unattended` through `systemd-run`, outside
  the panel's container (which it replaces), logging to
  `ui-state/last-update.log`.
- Anything outside `/opt/aiostreams` (systemd units, fail2ban jails) isn't in a
  backup. A restore has to recreate it from a marker, or the summary has to say
  how to.

## Testing on a droplet

- Pin downloads to a commit hash
  (`raw.githubusercontent.com/alpinezx/easy-aiostreams/<sha>/...`).
  Branch URLs are cached for minutes after a push.
- Testing `dev` on a fresh server: put `setup-aiostreams.sh` and
  `setup-backup.sh` from the commit next to the backup, and run with
  `sudo AIOS_BRANCH=dev bash setup-aiostreams.sh restore <file>`
  (`AIOS_UI_BRANCH=dev` does the same for the panel's Update).
- While testing `dev`, don't run the README's "swap every script for main's"
  loop. It quietly puts main's scripts back. If a test prints wording `dev`
  doesn't have, check which script versions are in `/opt/aiostreams` first.
- Domain mismatches: point a test record at `192.0.2.1` (reserved, never a real
  server), wait out the 600s TTL, check with `dig +short`.
- DigitalOcean "Rebuild" keeps the IP, so DNS stays valid. The host key changes:
  `ssh-keygen -R <ip>` on the PC.
- Before a restore test, check the server is in the state you think it is
  (`docker ps`, `systemctl is-active aiostreams-watchdog.timer`, which scripts
  are in `/opt/aiostreams`).

## Tested on 11 October 2026

Migrate, undo and migrate again on a sudo-user install; pre-October backup
restored through `migrate-to-opt`; `dev`'s restore refusing a pre-October
backup, restoring over a running install, and restoring onto a rebuilt droplet
with every domain wrong (main domain and all three add-ons moved during the
restore). Merged as PR #11.

Later the same day: a backup from the version that records the AIOStreams
build in `backup-info` and sorts the archive (`backup-info` read in 0.01s),
restored over a running install with the control panel stopped, rebuilt and
reported running again.

Then the panel's Restore button: `restore --check` passing on a current
backup; `restore --same-server` refusing a copy with its main domain changed
(exit 3, nothing changed, no set-aside folder), and the panel showing the same
refusal; a real restore started from the panel, which left the panel running,
finished on Restore finished, and came back after Restart panel.

## Tested on 12 October 2026

A restore run as plain root (`sudo env -u SUDO_USER -u SUDO_UID -u SUDO_GID
...`) leaving `/opt/aiostreams` at `root:ubuntu 750`; the Scripts tab's Run in
terminal typing commands into the panel's shell; and the panel updating
itself three times from `dev` (0.9.0 to 1.0.0, then 1.0.1, then 1.0.2) through
its own Update button, each reloading by itself. Merged as PRs #24 to #26.

Testing the panel's Update from `dev`: build it with a lower `VERSION` by hand
and `sudo AIOS_UI_BRANCH=dev bash setup-ui.sh rebuild`; afterwards, rebuild
once without `AIOS_UI_BRANCH` to point it back at `main`. GitHub's raw files
are cached for about 5 minutes after a push, so wait before Check now.

Docs screenshots in `docs/images/control-panel/` come from the panel's demo
mode (`UI_DEMO=1`, `streams.example.com`), never a real install.

## Tested on 13 October 2026

Started late on 12 October. The panel updated itself four times from `dev`
through its own Update button (1.0.2 to 1.0.3, then 1.0.4, 1.0.5 and 1.0.6),
each reloading by itself. Checked on the server: the shorter Backup & Restore
tab with backups as separate cards, the Scripts tab's Optional add-ons section
with grey Not installed, the 3-hour update checks (`sudo docker exec aios-ui
grep -h "^FRESH" app/panelupdate.py app/releases.py app/scriptsync.py` printed
`FRESH = 3 * 3600` three times), and no Phone alerts card on a server without
the watchdog. Merged as PR #30.

When `dev` already has a higher `VERSION` than the panel, there's no need to
lower it by hand: `sudo AIOS_UI_BRANCH=dev bash setup-ui.sh rebuild` once,
then Check now and Update for each push.

Docs screenshots refreshed for 1.0.6 (PR #31), with the Demo data chip left
visible so they don't pass for a real install. Desktop shots are 1366 wide:
the header hides the version chip at 1280 and below.

## Lessons

Lesson from 11 October: nightly can migrate AIOStreams' database past what
stable understands ("Database is at migration 46 but this build only knows up
to 42"), and stable then restart-loops. Switching back with Update can't fix
it; restoring the backup made before the switch to nightly does.
