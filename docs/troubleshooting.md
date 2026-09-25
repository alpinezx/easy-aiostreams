# Troubleshooting

## All Guides

Every guide in this repo, basic and advanced. Jump straight to whichever one you need.

| Guide | Basic | Advanced |
|---|---|---|
| Firewall & Ports | [Basic](./basic/firewall-ports.md) | [Advanced](./advanced/firewall-ports.md) |
| Addon Proxy Setup | [Basic](./basic/addon-proxy-setup.md) | [Advanced](./advanced/addon-proxy-setup.md) |
| Proxy Setup | [Basic](./basic/proxy-setup.md) | [Advanced](./advanced/proxy-setup.md) |
| MediaFlow Proxy | [Basic](./basic/mediaflow-proxy.md) | [Advanced](./advanced/mediaflow-proxy.md) |
| VPN Setup | [Basic](./basic/vpn-setup.md) | [Advanced](./advanced/vpn-setup.md) |
| Watchdog Alerts | [Basic](./basic/watchdog.md) | [Advanced](./advanced/watchdog.md) |
| Webhook Relay | [Basic](./basic/webhook-relay.md) | [Advanced](./advanced/webhook-relay.md) |
| Backup & Restore | [Basic](./basic/backup-restore.md) | [Advanced](./advanced/backup-restore.md) |

## Most Likely Issues

A quick-reference list pulled from the advanced guides' own troubleshooting sections. The ones most likely to actually come up. Click through for the full fix.

1. **DNS not pointing at your server yet, or ports 80/443 blocked, so the HTTPS cert fails.** The two most common snags, on a first install and on a [restore](./advanced/backup-restore.md#troubleshooting) alike. Confirm DNS first with `dig +short yourdomain.com`; if that matches but it's still stuck, check [Firewall & Ports](./advanced/firewall-ports.md), especially if you're on Oracle Cloud.

2. **VPN status shows "unhealthy," or the tunnel won't connect.** Almost always a stale endpoint IP.
   → [VPN Setup: Troubleshooting](./advanced/vpn-setup.md#troubleshooting)

3. **The `Endpoint =` line in your `.conf` file is a hostname, not an IP.** gluetun requires a literal IP address here. Resolve it with `dig` first.
   → [Important: gluetun needs an IP, not a hostname](./advanced/vpn-setup.md#important-gluetun-needs-an-ip-not-a-hostname)

4. **`docker compose logs gluetun` shows "using plaintext DNS."** Looks like a leak, isn't one, it's a one-time startup message before gluetun's own encrypted resolver finishes booting. **Status** and **Turn VPN ON** both now check the real thing (a live connection on :853) and print `DNS: encrypted` once confirmed, ignore the log line.
   → [VPN Setup: Confirming DNS is actually encrypted](./advanced/vpn-setup.md#confirming-dns-is-actually-encrypted-not-just-the-tunnel)

5. **A scraper/addon still returns a 403 or zero results after adding a proxy.** Double-check the hostname in **Addon proxy config** matches exactly what that addon actually uses. A mismatch means the rule never fires.
   → [Addon Proxy Setup: Testing it](./advanced/addon-proxy-setup.md#testing-it)

6. **A free proxy doesn't clear the block.** Free IPs are shared across many users, so there's a real chance the one you picked is already flagged. Try another from the pool.
   → [Get a free proxy](./advanced/addon-proxy-setup.md#1-get-a-free-proxy)

7. **Orphan container warnings, or containers stuck after an interrupted VPN mode switch.** Use **Force cleanup** from the `setup-vpn-gluetun.sh` menu, then switch to the mode you want.
   → [VPN Setup: Troubleshooting](./advanced/vpn-setup.md#troubleshooting)

8. **Restore says "that archive doesn't look like a backup made by this script."** Either the wrong file was passed in, or the tarball is corrupted. Re-copy it from source and try again.
   → [Backup & Restore: Troubleshooting](./advanced/backup-restore.md#troubleshooting)

9. **Restored fine, but the VPN layer doesn't come back.** It's only included in the backup if the [VPN layer](./advanced/vpn-setup.md) was already set up on the old server before the backup was taken.
   → [Backup & Restore: Troubleshooting](./advanced/backup-restore.md#troubleshooting)

10. **Restored under a new domain, but the webhook relay's URL still points at the old one.** Expected, not a bug, only the main domain rewrites automatically during a restore.
    → [Backup & Restore: Troubleshooting](./advanced/backup-restore.md#troubleshooting)

11. **Watchdog never alerts during a real outage.** Confirm the timer is active (`sudo systemctl status aiostreams-watchdog.timer`) and check the journal for the last check attempts.
    → [Watchdog: Troubleshooting](./advanced/watchdog.md#troubleshooting)

12. **Test alert works, but you never get a DOWN alert.** Either you're in direct mode, where the VPN checks are skipped by design (MediaFlow is still checked), or the service was stopped from its own script's menu, which deliberately suppresses alerts until it's running again.
    → [Watchdog: Troubleshooting](./advanced/watchdog.md#troubleshooting)

13. **A site's webhook verification fails with a challenge/mismatch error.** The running relay container is almost always still on an older version of the code than you think. A plain `docker restart` doesn't pick up script updates, run **Start** or **Reconfigure** from `setup-webhook.sh` instead.
    → [Webhook Relay: Troubleshooting](./advanced/webhook-relay.md#troubleshooting)

14. **`curl -I` against the webhook relay's domain returns `501`.** Expected, not a bug, `curl -I` sends a `HEAD` request and the receiver only implements `GET`/`HEAD` health checks and `POST`. Use a plain `curl` (no `-I`) to test instead.
    → [Webhook Relay: Troubleshooting](./advanced/webhook-relay.md#troubleshooting)

15. **A stream hangs right after toggling MediaFlow Proxy or the VPN layer, but works again later without you changing anything else.** Not confirmed as a reproducible bug, one report, and a retest of the same toggle came back clean, but cheap enough to rule out first: refresh the stream list in your Stremio-based client (not a full addon reinstall) before digging further. AIOStreams reads its proxy setting live on each stream request, so a stale, already-displayed stream list is the most likely explanation for a one-off hang like this, not a config or networking problem.
    → [MediaFlow Proxy (advanced): What you lose: visibility](./advanced/mediaflow-proxy.md#what-you-lose-visibility)

16. **`docker compose logs gluetun` shows a `WARN` about a TLS/DoT connection reset to `149.112.112.112:853` or `1.1.1.1:853` during startup**, something like `read tcp ...: read: connection reset by peer`. Looks alarming, isn't, same idea as item 4 above. Gluetun's configured with two independent DoT resolvers (Cloudflare and Quad9) specifically so one hiccuping doesn't matter, and this warning is just that: one of the two dropping a single query while the setup carries on. Only worth investigating if the lines right after it never reach `[dns] ready`, or if **Status**/**Turn VPN ON** never actually confirms `DNS: encrypted`, that's the one thing that can't be faked here.
    → [VPN Setup: Confirming DNS is actually encrypted](./advanced/vpn-setup.md#confirming-dns-is-actually-encrypted-not-just-the-tunnel)

For bugs in the script itself: [open an issue](https://github.com/alpinezx/easy-aiostreams/issues). For setup questions not covered here or in the linked guides, check out these Reddit threads [r/streamioaddons](https://www.reddit.com/r/StremioAddons/comments/1vo6a5q/self_hosted_aiostreams_easy_install_script/) - [r/nuvioaddons](https://www.reddit.com/r/nuvioaddons/comments/1vsud3b/self_hosted_aiostreams_easy_install_script_nuvio/)

[← Back to main README](../README.md)
