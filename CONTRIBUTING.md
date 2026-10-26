# Contributing

Thanks for wanting to help. This is a one-person project, so here's how changes get in.

## Before you start

- **Open an issue first** for anything bigger than a small fix, so we can agree it fits before you spend time on it.
- **Bugs:** use the bug report template, with the logs it asks for.
- **Setup questions** belong in the Reddit threads linked in the README, not in issues or pull requests.

## Pull requests

- **Target `dev`, not `main`.** `main` is what people install, and only takes tested changes from `dev`.
- **Every change is tested on a real server** before it reaches `main`, so a pull request can take a while. Say in its description what you tested and on which OS (Ubuntu 24.04+ or Debian 13).
- **Keep it focused:** one fix or feature per pull request.
- **Not every pull request will be merged.** Sometimes an idea is good but doesn't fit how the project works, and it may be rewritten instead. That's nothing personal, and you'll be credited.

## How the project works

- **Plain bash**, readable before it's run. No new dependencies without a good reason.
- **Everything lives in `/opt/aiostreams`**, whoever runs the script. Don't rely on `~` or `$HOME`.
- **Never renumber an existing menu option.** The control panel types menu numbers into older scripts, so new options go at the end.
- **Run `bash -n`** on every script you edit.
- **Backups and restores:** anything new that needs keeping has to be backed up and restored too. Anything outside `/opt/aiostreams` (a systemd unit, a fail2ban jail) has to be recreated on restore.
- **Control panel changes:** bump `control-panel/VERSION` (the last number for fixes, the middle one for features), or nobody is offered the update.
- **Add a line to `CHANGELOG.md`**, a sentence or two in its style.

## Security

These scripts run as root on other people's servers, so every line of a pull request is read before it's merged. Please don't add downloads from new places, piped installers or anything that sends data off the server without explaining why in the description.

To report a security problem privately, use the repository's **Security** tab (Report a vulnerability) rather than a public issue.
