# Firewall & Ports (Advanced Guide)

> In a hurry? [Basic guide](../basic/firewall-ports.md) covers the same steps with no deep explanation.

## What's actually happening

Caddy uses Let's Encrypt's HTTP-01 challenge by default to get your HTTPS certificate. Roughly: Let's Encrypt makes an outbound HTTP request to your domain on port 80, Caddy answers it to prove you actually control that domain and server, and only then issues the certificate that ends up served over 443. If port 80 is blocked, that exchange never completes and Caddy just keeps retrying quietly in the background, which is what shows up on screen as "not confirmed yet" during the install.

This is why a correct, propagated DNS record isn't enough on its own. DNS tells Let's Encrypt where to send the request, it doesn't guarantee the request can actually get through.

---

## Two separate firewalls, not one

Most people only think to check one firewall: the one on the server itself (`ufw`, `iptables`, `firewalld`). Several providers layer a second one on top, at the account/console level, which blocks inbound traffic before it even reaches the server's network interface. Opening the port with `ufw` does nothing if this outer layer is still dropping the connection first.

**Oracle Cloud is the most common example of this in practice.** Every Virtual Cloud Network (VCN) ships with a default Security List that blocks inbound traffic on most ports, including 80 and 443, regardless of what the instance's own firewall allows. This trips people up specifically because the server-side firewall looks completely fine, `ufw status` shows the ports open, and it still doesn't work, because the block is happening one network hop earlier, before traffic ever reaches the instance at all.

Fix: OCI console → Networking → Virtual Cloud Networks → your VCN → Security Lists → default security list → Ingress Rules → add rules allowing TCP 80 and TCP 443 from `0.0.0.0/0` (Let's Encrypt's challenge servers aren't a fixed IP range, so this needs to stay broadly open, not locked to one IP).

Other providers with a similar two-layer setup: AWS (Security Groups + Network ACLs), Google Cloud (VPC Firewall Rules), and most managed container platforms. On a provider not listed here and stuck, search for "security group" or "firewall rules" in their console, that's almost always the equivalent.

---

## Troubleshooting

*(Run these from `~/aiostreams`, `cd ~/aiostreams` first if you're not already there. Everything below assumes you've already run the installer at least once and Caddy is trying to get a certificate. Before that point, nothing's listening on 80/443 yet, so these checks won't tell you anything, run the installer first, then come back here if it hangs.)*

**Cert stuck at "not confirmed yet" for more than a few minutes, DNS already matches**
The installer itself now tries to work this out for you once it times out at 90s, checking whether Caddy's actually bound to 80/443 and whether DNS matches this server, and telling you directly if it looks like a provider firewall. To confirm that diagnosis yourself, or if you're in the case it couldn't narrow down, check the actual Caddy logs:
```bash
docker compose logs caddy
```
Look for a line like `could not get certificate from issuer ... Timeout during connect (likely firewall problem)`, that's Let's Encrypt's own server reporting the timeout, not a guess. Any other timeout, connection refused, or Let's Encrypt error tells you exactly what failed instead of just "still waiting."

**`ufw status` shows both ports open, but it still doesn't work**
That confirms it's the provider-level firewall, not the server's own. See the Oracle Cloud section above (or your provider's equivalent) even if you're not on Oracle.

**Testing from outside without a second machine**
⚠️ Only run this after you've already tried the installer at least once. On a totally fresh server with nothing installed yet, this will show Timed-Out even with a perfectly open firewall, since there's nothing listening on 80/443 to answer. It only means something once Caddy is actually up and trying to bind.

No phone terminal or second device needed, a browser does this too:
1. Get your server's IP, run this **on the server**:
   ```bash
   curl -4 ifconfig.me
   ```
2. Head to [dnschecker.org's port scanner](https://dnschecker.org/port-scanner.php)
3. **Domain / IP**: replace the pre-filled value with your server's IP
4. **Port Type**: leave as `Custom Ports`
5. **Ports**: enter `80,443`
6. Click **Check**

**Open** (green) means that port's reachable from the outside. **Timed-Out** (orange) means it's still blocked somewhere between you and the server, note that this reads the same whether nothing's listening yet or a firewall is actively dropping the traffic, the scanner can't tell those two apart, so treat it as "not reachable, go check both firewall layers" either way.

**It worked before, and now a Reconfigure or restart broke it**
Almost certainly unrelated to firewalls, if it worked once, the ports are open and stay open unless you changed something at the provider level yourself. Check `docker compose ps` for container status and `docker compose logs caddy` for what actually changed.

**Once the port's actually open**
No need to Reconfigure or reinstall, nothing about the install itself was wrong. Re-run `sudo bash setup-aiostreams.sh`, pick **4) Restart the stack** to make Caddy retry immediately instead of waiting on its own backoff timer, then **1) View status** to confirm (it prints Caddy's recent certificate log lines).

---

[← Back to Troubleshooting](../troubleshooting.md)
