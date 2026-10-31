# Changelog

Notable changes to easy-aiostreams, newest first. Control panel versions are in brackets. Each entry links to its pull request for the full detail.

## 31 October 2026

- **Fixed:** the Overview no longer sits mostly blank for a second or two while it opens. The browser now fetches all the panel's scripts at once, asks for your login and the server's status together, the server's first reading no longer pauses to measure CPU, and Caddy compresses the panel's files to about a quarter of their size. The Overview then appears all at once, with no empty card frames first. Caddy picks up the compression when the panel updates. (Panel 1.47.4, [#114](https://github.com/alpinezx/easy-aiostreams/pull/114))

## 30 October 2026

- **Backup & Restore:** backups no longer show an AIOStreams version on their row. A backup holds the add-ons too, so one version could mislead; the Restore confirmation still names it. (Panel 1.47.2, [#113](https://github.com/alpinezx/easy-aiostreams/pull/113))
- **Menus: Exit is always last.** In `setup-aiostreams.sh`, Maintenance is now **10** and Exit **11**; in `setup-mediaflow.sh`, Update is **10** and Exit **11**. The menus' long lines are shorter too, with the detail in the guides. A control panel from before 19 October (older than 1.28.1) should be updated before the scripts. (Panel 1.47.1, [#112](https://github.com/alpinezx/easy-aiostreams/pull/112))
- **What's new:** the Scripts tab's **What's new** lists the changes since your panel's version, from this changelog, each tagged New, Fixed or Docs. It's beside the panel's Check now, and under the scripts when one differs from GitHub. If GitHub can't be reached, it says so after at most 10 seconds and the rest of the panel carries on. (Panel 1.47.0, [#111](https://github.com/alpinezx/easy-aiostreams/pull/111))
- **Dropdowns match the panel:** every dropdown opens the panel's own list in its colours. On phones they used to open the phone's picker in the phone's theme. (Panel 1.46.5, [#111](https://github.com/alpinezx/easy-aiostreams/pull/111))
- **Fixed:** the Overview's Services title sits inside its card, like every other card's. Docs screenshots retaken. (Panel 1.46.5, [#111](https://github.com/alpinezx/easy-aiostreams/pull/111))
- **Docs:** the Reddit thread links are gone from the README, troubleshooting guide, contributing guide and new-issue page; setup questions go to the guides, then an issue. The new-issue page's troubleshooting link works again. ([#111](https://github.com/alpinezx/easy-aiostreams/pull/111))

## 29 October 2026

- **Panel packages updated:** FastAPI 0.162 and websockets 17.3, from the first monthly dependency check. (Panel 1.46.4, [#110](https://github.com/alpinezx/easy-aiostreams/pull/110))
- **Keeping the panel's parts current:** Dependabot opens one pull request a month against `dev` when the control panel's Python packages or its base image have something newer, and every panel update now builds on the newest Python 3.13 base image, so its Debian and Python get their security fixes. (Panel 1.46.3, [#108](https://github.com/alpinezx/easy-aiostreams/pull/108))
- **Fixed:** Maintenance's Scheduled server reboot option over SSH (option 11, then 4) went back to the main menu before showing its choices, on any server without linux-aio-toolkit's own reboot. ([#107](https://github.com/alpinezx/easy-aiostreams/pull/107))
- **Debian:** scheduled server reboots tested on Debian 13. On a server with no time sync service at all, as some Debian images ship, the Scheduled server reboot card now says how to add one. (Panel 1.46.2, [#106](https://github.com/alpinezx/easy-aiostreams/pull/106))
- **Next reboot on the Overview:** This server shows the scheduled server reboot beside Last backup, linking to Maintenance. HTTPS certificates come last on desktop as on phones, and Reboot server has a line of its own. Docs screenshots retaken. (Panel 1.46.1, [#105](https://github.com/alpinezx/easy-aiostreams/pull/105))
- **Scheduled server reboot:** a new card on Maintenance reboots the server at a set time, daily or weekly, either only when an update needs it (a new kernel, say) or every time. It never reboots during a backup or an update, a missed time isn't made up, and Phone alerts says it was planned. The card also shows whether the clock is in sync and changes the time zone. Off until you pick one. Backup format 7. (Panel 1.46.0, [#104](https://github.com/alpinezx/easy-aiostreams/pull/104))
- **Maintenance has its own script,** `setup-maintenance.sh`, as backup and restore have `setup-backup.sh`. Option 11 and every command work as before, and the script is fetched when it's missing. ([#104](https://github.com/alpinezx/easy-aiostreams/pull/104))
- **Fixed:** shell scripts keep Unix line endings in a Windows checkout, so one copied to a server straight from a PC runs. ([#104](https://github.com/alpinezx/easy-aiostreams/pull/104))

- **Reboot server after updates:** when installed updates need a restart, the Install updates drawer and Maintenance's System updates card offer Reboot server, so there's no trip back to the Overview. Restart needed on Maintenance is always checked fresh. (Panel 1.45.0, [#103](https://github.com/alpinezx/easy-aiostreams/pull/103))

## 28 October 2026

- **README:** the control panel's Overview in Light and Slate too, in a fold-out under the main screenshot. ([#102](https://github.com/alpinezx/easy-aiostreams/pull/102))

- **Slate colours:** a softer, slate-grey dark joins System, Light and Dark in the Overview's Edit drawer, saved per browser. (Panel 1.44.0, [#101](https://github.com/alpinezx/easy-aiostreams/pull/101))
- **A quieter Overview:** the headline is a size smaller and reads "All running", and Request flow's title matches the other cards'. Docs screenshots retaken. (Panel 1.43.3, [#101](https://github.com/alpinezx/easy-aiostreams/pull/101))

## 27 October 2026

- **Phone alerts:** a site check that lands while Caddy is restarting tries again after 5 seconds, so a restart no longer leaves a failed check (often logged as a bad certificate) in the history. ([#100](https://github.com/alpinezx/easy-aiostreams/pull/100))
- **Phone alerts on Debian:** the security-updates alert checks whether the server installs updates by itself and says so, rather than assuming Ubuntu; the panel, menu and docs no longer say Ubuntu. (Panel 1.43.2, [#99](https://github.com/alpinezx/easy-aiostreams/pull/99))
- **Fixed:** a new add-on's certificate no longer shows "Can't check" for 5 minutes after install; a failed check is retried after 1. (Panel 1.43.2, [#99](https://github.com/alpinezx/easy-aiostreams/pull/99))
- **Fixed:** MediaFlow's Uninstall leaves no Caddy log mount behind, and a watchdog check during it no longer logs MediaFlow as down. ([#99](https://github.com/alpinezx/easy-aiostreams/pull/99))
- **Fixed:** Caddy no longer logs "Caddyfile input is not formatted": the Caddyfile is written with tabs, and existing ones are tidied on the next start or restart. ([#99](https://github.com/alpinezx/easy-aiostreams/pull/99))
- **Phone alerts says when a problem is over:** once checks pass again, today's square turns green with an amber band and the line reads "failed earlier. All passing now". Between a failed check and the next one, if everything is back up, the Result says "Looks fine now" instead of "Failed". (Panel 1.43.1, [#98](https://github.com/alpinezx/easy-aiostreams/pull/98))
- **Fixed:** a same-server restore of an older backup no longer puts back an older control panel; the server's newer panel stays, with its settings from the backup. ([#98](https://github.com/alpinezx/easy-aiostreams/pull/98))
- **Fixed:** the VPN script's `on` command restarts a tunnel that has stopped, instead of saying the VPN is already on. ([#98](https://github.com/alpinezx/easy-aiostreams/pull/98))
- **Docs:** every control panel screenshot retaken at panel 1.43.1. ([#98](https://github.com/alpinezx/easy-aiostreams/pull/98))
- **CPU and memory match AIOStreams' dashboard:** This server shows CPU as a percentage, with the load average under it, and every size in the panel counts in thousands, so the two pages agree. (Panel 1.43.0, [#97](https://github.com/alpinezx/easy-aiostreams/pull/97))
- **Security hardening:** the panel takes the visitor's address only from Caddy, so another container can't get round the login lockout. Every setup script now passes ShellCheck, and the control panel guide's "How it's locked down" covers more. (Panel 1.42.2, [#97](https://github.com/alpinezx/easy-aiostreams/pull/97))
- **Debian:** the README says how to add `dig`, which a fresh Debian doesn't have. A full install, restore and reboot was tested on Debian 13. ([#97](https://github.com/alpinezx/easy-aiostreams/pull/97))

## 26 October 2026

- **Contributing guide:** `CONTRIBUTING.md` explains how pull requests get in (target `dev`, tested on a real server) and the project's habits. The issue form's setup questions link now points to the new Reddit post. ([#96](https://github.com/alpinezx/easy-aiostreams/pull/96))
- **Docs:** the README's Reddit links point to the new update posts on r/StremioAddons and r/nuvioaddons. ([#95](https://github.com/alpinezx/easy-aiostreams/pull/95))

- **Restart needed now works on Debian.** Maintenance's Restart tile and the script's "A restart is needed" line only checked a file Ubuntu writes, so on Debian they always said not needed. Both now also notice a kernel installed since the last boot. (Panel 1.42.1, [#94](https://github.com/alpinezx/easy-aiostreams/pull/94))
- **Changelog:** this file, starting from [#72](https://github.com/alpinezx/easy-aiostreams/pull/72). ([#94](https://github.com/alpinezx/easy-aiostreams/pull/94))

- **README:** the prerequisites now ask for at least 2 GB of RAM, with 3 to 4 GB or a swap file suggested for the full set of add-ons. ([#93](https://github.com/alpinezx/easy-aiostreams/pull/93))

## 25 October 2026

- **Colours switch:** the Overview's Edit drawer can set the panel to System, Light or Dark, remembered per browser. (Panel 1.42.0, [#92](https://github.com/alpinezx/easy-aiostreams/pull/92))
- **New add-on: AIOManager.** A private AIOManager on its own subdomain, pinned to a release, with Update and rollback, backups and restores, a watchdog check and an Overview card. Sign-ups close once your account exists and can be reopened for 30 minutes from the panel. Backup format 6. (Panel 1.41.0, [#90](https://github.com/alpinezx/easy-aiostreams/pull/90))
- **MediaFlow is pinned to a release,** with Update and rollback, an optional new-release alert and an Overview card with its live speed. Existing installs are pinned to the newest release at their next Start. ([#90](https://github.com/alpinezx/easy-aiostreams/pull/90))
- **Docs:** the control panel is listed first among the other scripts. ([#91](https://github.com/alpinezx/easy-aiostreams/pull/91))

## 24 October 2026

- **Network page:** the up speed under Now is shown at the same size as down. (Panel 1.40.4, [#88](https://github.com/alpinezx/easy-aiostreams/pull/88))
- **Docs:** the control panel's basic guide cut to the essentials. ([#89](https://github.com/alpinezx/easy-aiostreams/pull/89))

## 23 October 2026

- **Speeds shown as AIOStreams shows them** (MB/s and KB/s), and Services' CPU and memory refresh about every 3 seconds instead of 10. (Panel 1.40.3, [#87](https://github.com/alpinezx/easy-aiostreams/pull/87))
- **HTTPS certificates** sit on This server's bottom row, and come last on phones. The Scripts tab lists add-ons in a fixed order. (Panel 1.40.1 and 1.40.2, [#85](https://github.com/alpinezx/easy-aiostreams/pull/85), [#86](https://github.com/alpinezx/easy-aiostreams/pull/86))
- **Webhook relay retired.** Its script and guides are gone. An installed relay can be removed with `setup-aiostreams.sh remove-webhook-relay` or Uninstall on the Add-ons page, and a restore leaves it out. (Panel 1.40.0, [#84](https://github.com/alpinezx/easy-aiostreams/pull/84))
- **Fixed:** an add-on whose setup was cancelled part-way can now be removed from the Scripts tab. (Panel 1.39.3, [#83](https://github.com/alpinezx/easy-aiostreams/pull/83))
- **VPN card, traffic history and a Network page.** The VPN gets its own Overview card. The panel records the server's and the VPN tunnel's traffic (a day by the minute, 30 days by the hour) with live speeds, shown on a new Network page. Edit menu reorders or hides the rail's pages. (Panel 1.36 to 1.39.2, [#81](https://github.com/alpinezx/easy-aiostreams/pull/81), docs [#82](https://github.com/alpinezx/easy-aiostreams/pull/82))

## 22 October 2026

- **New add-on: AIOMetadata.** Installs AIOMetadata and Redis on their own subdomain, with Update and rollback, backups and restores, a watchdog check and an optional release alert. Backup format 5. ([#78](https://github.com/alpinezx/easy-aiostreams/pull/78))
- **Every site's HTTPS certificate** is checked by the watchdog and listed in the panel, and add-ons get an Add-ons page. (Panel 1.31.3 to 1.35.1, [#78](https://github.com/alpinezx/easy-aiostreams/pull/78))
- **Webhook relay marked as being retired.** ([#80](https://github.com/alpinezx/easy-aiostreams/pull/80))
- **Updates waiting leaves out Ubuntu's phased updates,** which Install updates can't install yet, so the count now goes down after installing. The same applies to the watchdog's weekly check-in. (Panel 1.31.3, [#77](https://github.com/alpinezx/easy-aiostreams/pull/77))
- **The latest release is centred on the AIOStreams version card.** (Panel 1.31.2, [#76](https://github.com/alpinezx/easy-aiostreams/pull/76))
- **Docs:** README and phone screenshots show the request flow folded. ([#79](https://github.com/alpinezx/easy-aiostreams/pull/79))

## 21 October 2026

- **Every Overview card folds** to one line, cards stack full width, and AIOStreams' card links straight to its Dashboard and Configure pages. (Panel 1.31.1, [#75](https://github.com/alpinezx/easy-aiostreams/pull/75))
- **Choose and reorder the Overview's cards** with Edit beside the headline. (Panel 1.30.0, [#74](https://github.com/alpinezx/easy-aiostreams/pull/74))
- **Fixed:** a restore no longer loses backup locks and notes added after the restored backup was made. ([#73](https://github.com/alpinezx/easy-aiostreams/pull/73))
- **The request flow card folds** to one line, with a dot per service. (Panel 1.29.1, [#72](https://github.com/alpinezx/easy-aiostreams/pull/72))
