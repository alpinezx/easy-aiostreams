# Changelog

Notable changes to easy-aiostreams, newest first. Control panel versions are in brackets. Each entry links to its pull request for the full detail.

## Unreleased

- **Docs:** the README's Reddit links point to the new update posts on r/StremioAddons and r/nuvioaddons.

## 26 October 2026

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
