# Changelog

Notable changes to easy-aiostreams, newest first. Control panel versions are in brackets. Each entry links to its pull request for the full detail.

## 13 November 2026

- **New:** the request flow's Restart stack sits under the flow at the bottom right, as Reboot server does on This server, instead of beside the title. Folded, This server keeps Reboot server as a quiet link in its corner, as the request flow does with Restart stack. (Panel 1.55.12, [#177](https://github.com/alpinezx/easy-aiostreams/pull/177))

## 12 November 2026

- **New:** Stop, Remove, Reboot server and the like look like every other button, with no red edge. They all ask first, and the dialog's red button is the warning. Services drops its Logs buttons (the Logs page and Recent warnings have them) and lists services by their buttons, so they line up: none, then Restart, then Stop and Restart, with AIOStreams and the other AIOs together, then the VPN tunnel, then any other add-on. The VPN tunnel's row gets Stop (Turn VPN off) and Restart (Restart stack, as the VPN can't restart on its own), each saying so, and stays listed while off, with Start. Recent warnings leaves out lines logged during the panel's own actions (Restart stack, updates, VPN switches, backups) and a minute after, such as the tunnel not reaching Caddy while it restarts; the Logs page keeps them. Its Recent CPU graph is wider on desktop and shows about 3.5 minutes. Screenshots retaken. (Panel 1.55.11, [#176](https://github.com/alpinezx/easy-aiostreams/pull/176))
- **New:** the Network page clears its history from a bin in the heading, as Logs does: this view, or with the VPN set up both views at once. The Clear history button under the graph is gone. Reboot server asks a plain "Reboot the server?" instead of making you type reboot. The Cloudflare Tunnel's "Application error 0x0 (remote)" pair is now noise: Cloudflare closing one connection with no error, back within seconds. Buttons like Stop, Remove and Reboot server have plain text and a red edge instead of red text. (Panel 1.55.10, [#175](https://github.com/alpinezx/easy-aiostreams/pull/175))
- **Fixed:** after updating the panel from the Scripts tab, the page could show "Updating…" and "Last update … didn't finish" until refreshed: it reloaded a second before the update job had ended. It now waits for the job, and a page that catches one still running checks again until it's over. (Panel 1.55.9, [#174](https://github.com/alpinezx/easy-aiostreams/pull/174))
- **Fixed:** two links open the guide at the part that matters, not the top of the page: Scripts' "Switch it on over SSH" (Turning on the terminal) and Backup & Restore's "done over SSH" (Migrating to a new server). (Panel 1.55.8, [#173](https://github.com/alpinezx/easy-aiostreams/pull/173))
- **Fixed:** with the web terminal off, the Scripts tab showed an amber note as if something was wrong. Keeping it off is a choice, so it's now a plain line under "Checked against GitHub", with the link to switch it on. The "Last update" line only appears when a panel update didn't finish. (Panel 1.55.7, [#172](https://github.com/alpinezx/easy-aiostreams/pull/172))
- **Fixed:** after a restart or reboot, the Cloudflare Tunnel's "already connected to this server, trying another address" pair showed as errors on the Overview and in Logs. It's a connection moving to another Cloudflare server, so it's now noise, hidden by Hide noise. (Panel 1.55.6, [#171](https://github.com/alpinezx/easy-aiostreams/pull/171))
- **New:** notes like the one at the top of Backup & Restore are a card like the others with a soft glowing amber edge (fainter in Light), instead of an amber wash that looked brown in Dark. The same goes for warnings inside dialogs. (Panel 1.55.5, [#170](https://github.com/alpinezx/easy-aiostreams/pull/170))
- **Fixed:** the Overview's Request flow card had a slightly different background and edge from the other cards (lighter in Dark and Slate, darker in Light). It now matches them. (Panel 1.55.4, [#169](https://github.com/alpinezx/easy-aiostreams/pull/169))
- **New:** opened, the Overview's Services card keeps the line it shows folded beside its title: how many are running, any that aren't, and their CPU and memory together. Fold all cards, What's new and Edit at the top are plain words like the cards' own links, and Fold all has an arrow that points the way the cards' do. (Panel 1.55.3, [#168](https://github.com/alpinezx/easy-aiostreams/pull/168))

## 11 November 2026

- **Fixed:** through a Cloudflare Tunnel, the panel could open with no styles or scripts for a few minutes: one visit without the panel's unlock cookie got a "Not found" for its stylesheet, which Cloudflare kept and served to everyone. Cloudflare is now told never to keep it. On a phone, the Rebooting and Updating notices are a smaller box with room around it. (Panel 1.55.2, [#167](https://github.com/alpinezx/easy-aiostreams/pull/167))
- **New:** the Overview's VPN card says how long the tunnel has been up, counted from gluetun's last reconnect. On a phone, Services shows each service's CPU and memory under its name, and folded, the CPU and memory of them all. This server's memory and disk read used / total (`1.7 GB / 4.3 GB`), folded too. (Panel 1.55.0, [#166](https://github.com/alpinezx/easy-aiostreams/pull/166))
- **New:** a tidier panel, on phones especially. Every Overview card starts folded on a phone, **Fold all cards** sits beside What's new, and a fold's arrow points down while there's more to open. Maintenance has **List updates** (each waiting package and its versions), shows the first few on the System updates card on a desktop (or what the last install brought), and lays out Scheduled server reboot like a list with **Set schedule**; Scheduled backups does the same. Recent warnings starts with AIOStreams and the add-ons switched off in its cog (their first warnings are mostly settings not entered yet). The Scripts tab puts a dot before each script, amber when it's downloaded but not set up. AIOStreams' channel is a word beside its version, notes are shorter, links in them don't break across lines, and Logs' Wrap starts off. (Panel 1.54.0, [#165](https://github.com/alpinezx/easy-aiostreams/pull/165))
- **Fixed:** release checks are kept across a panel restart, so a few updates in a row no longer use up GitHub's hourly limit and leave every card saying Couldn't check. The Cloudflare Tunnel's "Error shutting down control stream" while it stops counts as noise. (Panel 1.54.0, [#165](https://github.com/alpinezx/easy-aiostreams/pull/165))

## 9 November 2026

- **Fixed:** the VPN's DNS retries no longer show as warnings: every gluetun `[dns]` line about renewing its encrypted DNS connection counts as noise now, timeouts included, on the Logs page and in Recent warnings. Real DNS trouble still shows (errors, and the VPN's health check restarting it). (Panel 1.53.2, [#164](https://github.com/alpinezx/easy-aiostreams/pull/164))
- **New:** the Overview's VPN card comes straight after the add-ons' version cards by default, above Phone alerts. Layouts already saved keep their order: **Reset to default** in Edit moves it. (Panel 1.53.1, [#163](https://github.com/alpinezx/easy-aiostreams/pull/163))
- **New:** **Update VPN** puts the earlier gluetun back by itself if the new release doesn't connect, and its dialog has **Back up first**. The Cloudflare Tunnel's cloudflared does the same when it updates. AIOStreams' Update no longer updates gluetun: only Update VPN does, safely. The Overview's VPN card shows gluetun's version and whether a newer v3 release is out, laid out like AIOStreams' card, with Update and All releases. (Panel 1.53.0, [#162](https://github.com/alpinezx/easy-aiostreams/pull/162))
- **New:** **Recent warnings & errors** has a cog to pick which services' logs it reads (saved for every device), and it now sits straight under the request flow by default. Folded cards show Update and Restart stack as quiet links in their corner instead of buttons, and folded **This server** shows CPU, memory, disk and the network's speed. On phones, backup and VPN buttons line up evenly and the restore dialog is much shorter. (Panel 1.52.0, [#161](https://github.com/alpinezx/easy-aiostreams/pull/161))

## 8 November 2026

- **New:** the Overview has a **Recent warnings & errors** card, between This server and Services: the latest warnings and errors from every service's log over the last day, with the same noise left out as on the Logs page and repeats grouped with a count. Five show, up to five more behind **Show more**, and a row opens that log with WARN and ERROR picked. On the Logs page the bin now asks whether to clear the log shown or **All logs**, and a clear empties the card's rows too. (Panel 1.51.0, [#160](https://github.com/alpinezx/easy-aiostreams/pull/160))
- **Fixed:** scheduled server reboots happen again with the VPN on. Since v1.6.0 they were skipped every time ("setup-vpn-gluetun.sh was still running after 30 minutes"), because the VPN's always-running route watcher was mistaken for a job in progress. ([#159](https://github.com/alpinezx/easy-aiostreams/pull/159))
- **New:** the Logs page has a **NOISE** button beside the levels on Caddy's, the Cloudflare Tunnel's and the VPN's logs, showing only the grey lines Hide noise would hide, and the VPN log gets a fold-out on what's noise and what's worth a look. With Wrap on, long lines use the full width; on phones each entry's message sits under its time with the dot first, Wrap starts on, and the log fits the screen under the filters. (Panel 1.50.4, [#158](https://github.com/alpinezx/easy-aiostreams/pull/158))
- **Fixed:** the VPN's "creating connection … EOF" DNS lines, seen as it comes up, are grey and hidden by **Hide noise**, like its other EOF retries. (Panel 1.50.4, [#158](https://github.com/alpinezx/easy-aiostreams/pull/158))
- **Fixed:** the Logs page greys the VPN's "renewing dead connection … EOF" DNS lines, gluetun's newer wording for a DNS server closing an idle connection, and **Hide noise** hides them. Timeouts stay amber. (Panel 1.50.3, [#157](https://github.com/alpinezx/easy-aiostreams/pull/157))
- **Docs:** the control panel, AIOMetadata, AIOManager and MediaFlow guides say to add a tunnel route instead of an A record when hosting from home, the firewall guides say there's nothing to open through a tunnel, and Backup & Restore points a move home at the home guide. MediaFlow's basic guide no longer says its video can't go through the VPN. ([#156](https://github.com/alpinezx/easy-aiostreams/pull/156))
- **New:** tidier Edit drawers and What's new. Colours sits in the Edit drawer's head instead of a card, the hint above the list is one line ("≡ changes the order."), and on phones the rows are tighter, so every card fits on one screen. What's new reads "Latest repo changes, newest first", no longer repeats "New:" under its NEW badge, and on phones puts each badge on the entry's first line. (Panel 1.50.2, [#155](https://github.com/alpinezx/easy-aiostreams/pull/155))
- **Fixed:** each service's CPU in Services is its share of the whole server, the same scale as This server's CPU, so 100% is the real ceiling and a busy service no longer reads over 100%. It's live again rather than a half-minute average, so a burst such as skipping through a video settles straight away. (Panel 1.50.1, [#154](https://github.com/alpinezx/easy-aiostreams/pull/154))
- **New:** the control panel has its own row at the top of Services, with its CPU, memory, **Logs** and **Restart**. The Network lists show it first and keep the VPN tunnel, with whatever it carries, together at the bottom. (Panel 1.50.0, [#153](https://github.com/alpinezx/easy-aiostreams/pull/153))
- **Fixed:** the Logs page greys the tunnel's "Incoming request ended abruptly: context canceled" lines, left by a reload or a closed tab, and **Hide noise** hides them. (Panel 1.50.0, [#153](https://github.com/alpinezx/easy-aiostreams/pull/153))
- **New:** lines and separators stand out more in every theme, and Light's cards have a visible edge, so each part of a page is easier to tell apart. (Panel 1.49.8, [#152](https://github.com/alpinezx/easy-aiostreams/pull/152))
- **New:** speeds from 10 KB/s up show whole numbers ("852 KB/s"). In This server's Network list and on the Network page (Last 7 days, By service) the arrows keep to one line and every figure starts right after its arrow; on phones each service's speeds sit under its name. (Panel 1.49.8, [#152](https://github.com/alpinezx/easy-aiostreams/pull/152))
- **Fixed:** opening a folded part of the Overview, such as Network or HTTPS certificates, opens it downwards instead of pushing the page up. Speeds no longer run past the card's edge with larger text on phones, on the Overview or the Network page. (Panel 1.49.8, [#152](https://github.com/alpinezx/easy-aiostreams/pull/152))

## 7 November 2026

- **Fixed:** the scp command printed after a backup over SSH uses the server's public address on a VPS behind NAT (Oracle, AWS), where it used to print a private one. At home it keeps the local address. ([#151](https://github.com/alpinezx/easy-aiostreams/pull/151))
- **Fixed:** **What's new** lists a newer panel's changes as soon as Check now finds it, before you update, instead of up to 3 hours later. (Panel 1.49.7, [#150](https://github.com/alpinezx/easy-aiostreams/pull/150))
- **Fixed:** on a server at home through a Cloudflare Tunnel, Backup & Restore's **Copy scp command** uses the server's local address, so it no longer times out. (Panel 1.49.6, [#149](https://github.com/alpinezx/easy-aiostreams/pull/149))
- **New:** **What's new** sits beside Edit on the Overview too, opening the same list of changes as the Scripts tab. (Panel 1.49.5, [#148](https://github.com/alpinezx/easy-aiostreams/pull/148))
- **New:** the Overview's Network list starts with All traffic, the server's own speed, above each service. The Network page's Whole server is now called All traffic too. (Panel 1.49.3, [#147](https://github.com/alpinezx/easy-aiostreams/pull/147))
- **New:** the version cards' Up to date, or newer release, is smaller and sits quietly in the middle, and a newer release is amber on every card. (Panel 1.49.2, [#146](https://github.com/alpinezx/easy-aiostreams/pull/146))
- **New:** on phones, Services has more room between each service's name and its buttons. (Panel 1.49.2, [#146](https://github.com/alpinezx/easy-aiostreams/pull/146))
- **New:** every service's speed is in one list under This server's **Network** on the Overview, opened with its arrow, instead of spread across the cards. This server's values are reordered so CPU, Memory and Disk come first. (Panel 1.49.1, [#145](https://github.com/alpinezx/easy-aiostreams/pull/145))
- **Fixed:** the Logs page greys gluetun's start-up version check failing with GitHub's 403, which is harmless. (Panel 1.49.1, [#145](https://github.com/alpinezx/easy-aiostreams/pull/145))

## 6 November 2026

- **New:** MediaFlow can go through the VPN with one switch on the VPN page or in the VPN script's menu, so its video leaves from the same address as AIOStreams, with the same kill switch. It stays attached through restarts, updates, restores and reboots. (Panel 1.49.0, [#144](https://github.com/alpinezx/easy-aiostreams/pull/144))
- **New:** the request flow is now a simple tree on desktop and phone, showing what sits behind the VPN at a glance. (Panel 1.49.0, [#144](https://github.com/alpinezx/easy-aiostreams/pull/144))
- **Fixed:** a same-server restore with the VPN on left AIOStreams running from the folder it had just set aside, so it ignored the restored data until its next restart. (Panel 1.49.0, [#144](https://github.com/alpinezx/easy-aiostreams/pull/144))
- **Fixed:** with the VPN on, AIOStreams now reconnects by itself if gluetun restarts or crashes, instead of staying down until Restart stack. (Panel 1.49.0, [#144](https://github.com/alpinezx/easy-aiostreams/pull/144))
- **Fixed:** the Services CPU figure is a half-minute average and Recent CPU has a higher scale, so small bursts like the VPN's own health check no longer look alarming. (Panel 1.49.0, [#144](https://github.com/alpinezx/easy-aiostreams/pull/144))
- **Fixed:** the Logs page hides MediaFlow's password, which it writes into some request lines. (Panel 1.49.0, [#144](https://github.com/alpinezx/easy-aiostreams/pull/144))
- **Fixed:** the Logs page greys the VPN's clean shutdown line, which only means it was asked to stop, as a restart or reboot does. Hide noise hides it too. (Panel 1.48.19, [#143](https://github.com/alpinezx/easy-aiostreams/pull/143))
- **Fixed:** the VPN's exit location no longer shows Unknown when ipinfo.io refuses a lookup, which can happen because a VPN's exit address is shared with other people. The panel now tries ifconfig.co and GeoJS next, one at a time through the tunnel. (Panel 1.48.18, [#142](https://github.com/alpinezx/easy-aiostreams/pull/142))
- **Fixed:** the Logs page greys the VPN's harmless DNS reconnect lines that end in EOF, so Hide noise hides them too. Timeouts stay amber, as a run of those is worth seeing. (Panel 1.48.17, [#141](https://github.com/alpinezx/easy-aiostreams/pull/141))
- **New:** clearer VPN labels: Exit location for where traffic comes out, and VPN server so it can't be mistaken for your own server. (Panel 1.48.16, [#140](https://github.com/alpinezx/easy-aiostreams/pull/140))
- **Fixed:** the panel's terminal now spots itself in its default shell, so Stop, Update and Uninstall are refused there, as they were always meant to be, rather than cutting the terminal off halfway. A restore run from it leaves the panel running too. (Panel 1.48.15, [#139](https://github.com/alpinezx/easy-aiostreams/pull/139))
- **New:** on phones and tablets the panel's terminal has a row of the keys a phone keyboard lacks: Ctrl, Esc, Tab and the arrows. When a VPN switch or restore restarts Caddy, the terminal now reconnects by itself and shows what it missed. The Scripts tab is tidier, with one Check now and Control panel beside AIOStreams, Restart sits furthest right in Services, and quieter buttons always show their border. (Panel 1.48.15, [#139](https://github.com/alpinezx/easy-aiostreams/pull/139))

## 5 November 2026

- **Tidied:** the scripts moved to `scripts/core` (the main script and the three it uses) and `scripts/others` (the add-ons). Servers still keep them all in `/opt/aiostreams`, and the old link for `setup-aiostreams.sh` still works. Update the control panel first, then any scripts it shows as differing. (Panel 1.48.14, [#138](https://github.com/alpinezx/easy-aiostreams/pull/138))
- **Fixed:** stopping the VPN's first setup part-way no longer leaves it half there, with no way to remove it: the script now clears up after itself, and the Scripts tab offers Remove on a server already in that state. On phones, Remove no longer runs off the Scripts tab and address tags fit the VPN dialog, a config with one address no longer leaves its button greyed out, and cancelling MediaFlow's first setup no longer restarts AIOStreams. (Panel 1.48.13, [#137](https://github.com/alpinezx/easy-aiostreams/pull/137))

## 4 November 2026

- **Fixed:** the Add-ons and Maintenance pages update after a very quick job too, so an uninstalled add-on's card goes without a reload. (Panel 1.48.11, [#135](https://github.com/alpinezx/easy-aiostreams/pull/135))

## 3 November 2026

- **Fixed:** a WireGuard config that lists both IPv4 and IPv6 addresses now connects on a server without IPv6, instead of leaving the VPN stopped. Pages also update after a very quick job, so a deleted VPN config no longer stays listed until a reload. (Panel 1.48.10, [#134](https://github.com/alpinezx/easy-aiostreams/pull/134))
- **New:** moving from a VPS to a computer at home takes one restore. It asks where the server is when it can't tell, keeps a tunnel the computer already has, and can give AIOStreams, the control panel and any add-ons new names on a domain that's on Cloudflare. Also fixed: removing the control panel no longer forgets which backups are locked. (Panel 1.48.9, [#133](https://github.com/alpinezx/easy-aiostreams/pull/133))
- **Docs:** the Hosting from home guides say how to get a lost Cloudflare Tunnel token back, and what to do if it leaks. ([#132](https://github.com/alpinezx/easy-aiostreams/pull/132))
- **Fixed:** Sign out asks first, so a stray click no longer signs you out. (Panel 1.48.8, [#131](https://github.com/alpinezx/easy-aiostreams/pull/131))

- **Fixed:** with an add-on installed, Restart stack's confirm says add-ons aren't restarted, and to use Restart on their row in Services. (Panel 1.48.7, [#130](https://github.com/alpinezx/easy-aiostreams/pull/130))

- **Fixed:** Restart stack's confirm names only what it restarts on this server ("Restart AIOStreams, Caddy and the Cloudflare Tunnel?"), and a few other messages read more simply: the Network page's By service note, MediaFlow's Uninstall warning, the tunnel's warning on a working VPS, and the AIOManager line after a restore to a new domain. The Scripts tab's first row says AIOStreams instead of AIOStreams menu. (Panel 1.48.6, [#129](https://github.com/alpinezx/easy-aiostreams/pull/129))

## 2 November 2026

- **Fixed:** the Logs page reads the VPN tunnel's own levels, so its "Wireguard setup is complete" note no longer shows in red, and its harmless DNS retries ("exchanging over tls connection ... EOF") are grey, with a Hide noise switch like Caddy's and the Cloudflare Tunnel's. (Panel 1.48.5, [#128](https://github.com/alpinezx/easy-aiostreams/pull/128))
- **Fixed:** the Logs page also greys the Cloudflare Tunnel's "unexpected EOF" lines from AIOStreams or Caddy restarting under an open AIOStreams dashboard. Real failures, like a cut video or Caddy being down, stay red. The tunnel's log gets Caddy's Hide noise switch and a fold-out saying which of its errors are fine after a restart and which are worth a look, and Caddy's expected lines are grey as well. The live log no longer shows every line twice after reconnecting (when the panel restarts, for example). (Panel 1.48.4, [#127](https://github.com/alpinezx/easy-aiostreams/pull/127))
- **Fixed:** two of the control panel's tests caught up with features added since they were written (the VPN page's DNS check, MediaFlow's address on its Add-ons card), so the whole suite passes again. Tests only, nothing changes on a server. ([#126](https://github.com/alpinezx/easy-aiostreams/pull/126))
- **Docs:** the Hosting from home guide says where Add a domain is in Cloudflare, and how to find the nameserver steps for registrars other than Porkbun. ([#125](https://github.com/alpinezx/easy-aiostreams/pull/125))
- **Docs:** the Hosting from home guide, walked through as a new user: Cloudflare's clicks spelled out for routes and Always Use HTTPS, and a new part on changing your domain. The README mentions hosting from home among what you get. At home, the installer's domain question now asks for the tunnel route's full name, and Reconfigure's messages no longer contradict a "without backing up" choice. ([#124](https://github.com/alpinezx/easy-aiostreams/pull/124))
- **Panel base image updated:** Python 3.15, from the monthly dependency check. Also fixed: the Cloudflare Tunnel's harmless "stream canceled" lines show in grey on the Logs page, as they were meant to, instead of red. (Panel 1.48.3, [#123](https://github.com/alpinezx/easy-aiostreams/pull/123))

## 1 November 2026

- **Fixed:** Uninstall also removes the control panel, the add-ons' images (when you choose to remove images) and the shared network, and refuses to run from the panel's own terminal. A restore onto a fresh server no longer warns about an existing install when the folder only holds the downloaded scripts. ([#121](https://github.com/alpinezx/easy-aiostreams/pull/121))
- **Changed:** hosting from home is kept out of a VPS's way. A fresh install first asks where the server is, a VPS or a computer at home, and only the home answer sets up the Cloudflare Tunnel (a VPS's backup restored at home is put behind it too). The menu shows the tunnel's option only on servers that use it, so a VPS's Exit is 11 again. ([#120](https://github.com/alpinezx/easy-aiostreams/pull/120))
- **Docs:** the README is about VPS hosting again, with one pointer to the Hosting from home guide, which now covers home users from start to finish. ([#119](https://github.com/alpinezx/easy-aiostreams/pull/119))
- **Fixed:** turning the Cloudflare Tunnel on (menu 11) on a server whose site already works directly, like a VPS, now warns first: the site would be offline until its route exists in Cloudflare. Saying no changes nothing, and an install carries on as a normal one. ([#118](https://github.com/alpinezx/easy-aiostreams/pull/118))
- **Fixed:** the Scripts tab's AIOStreams Update stopped with "Couldn't write setup-tunnel.sh" on servers that didn't have it yet. A helper script new to the server now gets the same permissions as the others. (Panel 1.48.1, [#117](https://github.com/alpinezx/easy-aiostreams/pull/117))
- **New: hosting from home through a Cloudflare Tunnel.** Run it on a computer at home with nothing forwarded at your router and no VPS. The installer asks how people reach the server, and menu option 11 turns the tunnel on or off later. The control panel, add-ons, VPN, backups, restores and phone alerts all work through it, and the Overview shows the tunnel. With the VPN set up but switched off, the panel's Start, Restart stack, Update and restore now say so and go ahead when you confirm, instead of sending you to SSH. Guide: [Hosting from home](./docs/basic/home-hosting.md). (Panel 1.48.0, [#116](https://github.com/alpinezx/easy-aiostreams/pull/116))
- **Fixed:** Restart stack's confirm now says what it restarts (AIOStreams and Caddy, and the VPN if it's on) instead of "the whole stack". Maintenance shows System updates and Scheduled server reboot first, and System updates names the server's system (Ubuntu 26.04, Debian 13) in place of an old note about AIOStreams. (Panel 1.47.5, [#115](https://github.com/alpinezx/easy-aiostreams/pull/115))

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
