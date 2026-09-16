# Firewall & Ports (Basic Guide)

For getting ports 80 and 443 open, and confirming they're actually reachable, so the HTTPS certificate step doesn't get stuck. Steps 1-2 (opening the ports) are fine to do before running the installer. Step 3 (confirming they're reachable) only works after the installer's already running, see the warning there.

> Want the full explanation of why this happens, or hit a snag? → [Advanced guide](../advanced/firewall-ports.md)

---

## Why this matters

Caddy needs actual inbound access on ports 80 and 443 to get your HTTPS certificate, a matching DNS record alone isn't enough. If either port is blocked, on the server itself or by your cloud provider, the install sits at "not confirmed yet" indefinitely, even though DNS is completely fine.

---

## 1. Check the server's own firewall

**This does:** confirms the OS-level firewall (if any) isn't blocking these ports.

If you're using `ufw`:
```bash
sudo ufw status
```
You should see `80/tcp` and `443/tcp` listed as `ALLOW`. If not:
```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

Not running `ufw` (or any firewall) at all? This step doesn't apply, skip to the next one.

---

## 2. Check your provider's own firewall (separate from the server)

**This does:** catches the layer most people miss, a cloud-level firewall in your provider's web console, completely separate from anything configured on the server itself.

**Using Oracle Cloud?** This is almost always the cause. Fix:
1. OCI console → **Networking** → **Virtual Cloud Networks** → your VCN
2. **Security Lists** → the default list
3. Add **Ingress Rules** allowing TCP **80** and TCP **443** from `0.0.0.0/0`

Other providers (AWS, GCP, DigitalOcean, Vultr, etc.) have their own equivalent, usually called a "security group" or "firewall rules" section in their console. If the server's own firewall looks fine but the cert still won't confirm, this is the next thing to check.

---

## 3. Confirm it's actually open

**This does:** proves the port is reachable from the outside world, not just that you think you configured it right. No phone terminal or second device needed, just a browser.

⚠️ Only run this after you've already tried the installer at least once. On a totally fresh server with nothing installed yet, this will show Timed-Out even with a perfectly open firewall, since there's nothing listening on 80/443 to answer yet. Steps 1 and 2 above are safe to do proactively before running the installer, this step isn't.

1. Get your server's IP, run this **on the server**:
   ```bash
   curl -4 ifconfig.me
   ```
2. Head to [dnschecker.org's port scanner](https://dnschecker.org/port-scanner.php)
3. **Domain / IP**: replace the pre-filled value with your server's IP
4. **Port Type**: leave as `Custom Ports`
5. **Ports**: enter `80,443`
6. Click **Check**

**Open** (green) means that port's reachable. **Timed-Out** (orange) means it's still blocked somewhere, either the server's own firewall or your provider's console.

---

## What this actually looks like in the logs

Option **1) View status** in the script's menu prints Caddy's recent certificate log lines. If ports 80/443 are being blocked, it looks like this:

```
caddy | {"level":"info","logger":"tls.obtain","msg":"obtaining certificate","identifier":"yourdomain.example.com"}
caddy | {"level":"error","logger":"tls.obtain","msg":"could not get certificate from issuer","identifier":"yourdomain.example.com","issuer":"acme-v02.api.letsencrypt.org-directory","error":"HTTP 400 urn:ietf:params:acme:error:connection - YOUR.SERVER.IP: Timeout during connect (likely firewall problem)"}
```

That error line is Let's Encrypt's own server telling you directly what's wrong, `Timeout during connect (likely firewall problem)` means it tried to reach your server on port 80 to verify the domain and got nothing back. That's not a guess on the script's part, it's the ACME server reporting the timeout itself.

Once the port's actually open, this stops happening, you won't see any more `could not get certificate` error lines. Caddy doesn't log a single clear "success" line you can grep for, so the real confirmation is simpler: visit `https://yourdomain.example.com` in a browser and check it loads without a certificate warning.

---

Once both ports are confirmed open, you don't need to reinstall or Reconfigure, nothing about the install itself was wrong. Just re-run `sudo bash setup-aiostreams.sh`, and from the menu pick **4) Restart the stack** to make Caddy retry right away, then **1) View status** to confirm (it shows Caddy's recent certificate log lines). Or just wait a few minutes and check status anyway, Caddy retries on its own in the background regardless.

Something still not working? → [Advanced guide](../advanced/firewall-ports.md)
