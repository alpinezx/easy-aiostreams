# Notes for Claude sessions on this repo

## How changes get made

Every code change is tested on a real server before it's merged. No em dashes
in docs, script output or commit messages.

Documentation (README, `docs/`, this file) and comment-only edits to code
don't need a server test, as long as no behaviour changes. Go through `dev` and
a PR to `main` as usual. Two limits: a `#` line inside a heredoc is written
into the generated file, so it counts as code; and run `bash -n` on any edited
`.sh` file to catch a broken quote or block.

## Branches

- `main`: what users install. Changes reach it only by pull request from `dev`,
  merged with a merge commit. Don't push to `main` directly. To undo something
  on `main`, revert it; don't rewrite its history.
- `dev`: where work happens. Push here, then open a PR to `main` once it's been
  tested on a server.
- `migrate-to-opt`: frozen, one-off. Moves a pre-October-2026 install from
  `/root/aiostreams` to `/opt/aiostreams`, and restores pre-October backups.
  Its README only covers that. Fix it only for migration bugs. Don't delete
  it: `main`'s scripts and docs link to it, and `setup-backup.sh` downloads
  from it (`MIGRATE_SCRIPT_URL`).

Commits: author as `Claude <noreply@anthropic.com>`.

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

## Testing on a server

- Pin downloads to a commit hash
  (`raw.githubusercontent.com/alpinezx/easy-aiostreams/<sha>/...`).
  Branch URLs are cached for minutes after a push.
- Testing `dev` on a fresh server: put `setup-aiostreams.sh` and
  `setup-backup.sh` from the commit next to the backup, and run with
  `sudo AIOS_BRANCH=dev bash setup-aiostreams.sh restore <file>`.
- While testing `dev`, don't run the README's "swap every script for main's"
  loop. It quietly puts main's scripts back. If a test prints wording `dev`
  doesn't have, check which script versions are in `/opt/aiostreams` first.
- Domain mismatches: point a test record at `192.0.2.1` (reserved, never a real
  server), wait out the 600s TTL, check with `dig +short`.
- Rebuilding a server in place usually keeps its IP, so DNS stays valid, but
  the host key changes: `ssh-keygen -R <ip>` on the PC.
- Before a restore test, check the server is in the state you think it is
  (`docker ps`, `systemctl is-active aiostreams-watchdog.timer`, which scripts
  are in `/opt/aiostreams`).

Testing the panel's own Update from `dev`: run `sudo AIOS_UI_BRANCH=dev bash
setup-ui.sh rebuild` once, then use Check now and Update on the Scripts tab
for each push. This needs `dev`'s `VERSION` to be higher than the panel's; if
it isn't, build the panel with a lower `VERSION` by hand first. GitHub's raw
files are cached for about 5 minutes after a push, so wait before Check now.
Afterwards, rebuild once without `AIOS_UI_BRANCH` to point it back at `main`.

## Docs screenshots

Screenshots in `docs/images/control-panel/` come from the panel's demo mode
(`UI_DEMO=1`, `streams.example.com`), never a real install. Leave the Demo
data chip visible so they don't pass for a real install (the panel hides it on
phone widths, so force it on for phone shots). Shoot desktop views at 1366
wide: the header hides the version chip at 1280 and below.

## Known pitfalls

AIOStreams' nightly builds can migrate its database past what stable
understands ("Database is at migration 46 but this build only knows up to
42"), and stable then restart-loops. Switching back with Update can't fix it;
restoring the backup made before the switch to nightly does.
