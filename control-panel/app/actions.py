"""The ONLY things this UI can run on the server.

Each action maps to one of the existing setup-*.sh scripts, driven the same
way a person would drive it: either through the script's own non-interactive
entry point (e.g. 'backup', 'start-relay') or by typing the menu choices.
The scripts get a pseudo-terminal for stdin, exactly like an SSH session.
That matters: do_backup ends with '[[ -t 0 ]] && read ...', which returns
failure (and kills the script under set -e) when stdin is not a terminal.
On a terminal it waits for Enter, which the "\n" answers below supply.
Nothing here accepts free text from the browser; the only inputs are an
action id and, for update, two validated options (for the VPN's Change
server, one validated IPv4 address).
"""
from __future__ import annotations

import ipaddress
import re
from dataclasses import dataclass


@dataclass(frozen=True)
class Action:
    id: str
    label: str            # shown on buttons and in activity history
    running: str          # "Restarting"
    done: str             # "Restart finished"
    script: str           # file inside INSTALL_DIR
    args: tuple[str, ...] = ()
    stdin: str = ""
    timeout: int = 600
    confirm: str | None = None   # confirmation text; None = no modal
    needs: tuple[str, ...] = ()  # paths (relative to INSTALL_DIR) that must exist
    env: tuple[str, ...] = ()    # extra NAME=value for the script


# Extra "N" before the final exit choice absorbs the one y/N prompt that
# setup-aiostreams.sh may show ("VPN is OFF, continue in direct mode?").
# Answering N cancels safely. If the prompt doesn't appear, the "N" lands on
# the menu, which prints "Not a valid option" (filtered from the output).
_PAD = "N\n"

AIO = "setup-aiostreams.sh"

_STATIC: dict[str, Action] = {a.id: a for a in [
    Action("stack.start", "Start", "Starting", "Start finished", AIO,
           stdin="3\n" + _PAD + "10\n", timeout=300, needs=(AIO,)),
    Action("stack.stop", "Stop", "Stopping", "Stop finished", AIO,
           stdin="2\n10\n", timeout=180, needs=(AIO,),
           confirm="Stop AIOStreams? Caddy stays up, so visitors get a 502 until you start it again."),
    Action("stack.restart", "Restart", "Restarting", "Restart finished", AIO,
           stdin="4\n" + _PAD + "10\n", timeout=420, needs=(AIO,),
           confirm="Restart the whole stack? Streams stop loading for a few seconds."),
    Action("stack.backup", "Back up now", "Backing up", "Backup finished", AIO,
           args=("backup",), stdin="\n", timeout=300, needs=(AIO,),
           confirm="Make a backup of your AIOStreams setup now? It is saved on this server and takes a few seconds."),

    Action("mediaflow.start", "Start", "Starting", "Start finished", "setup-mediaflow.sh",
           args=("start-mediaflow",), timeout=300,
           needs=("setup-mediaflow.sh", "mediaflow-state/docker-compose.yml")),
    Action("mediaflow.stop", "Stop", "Stopping", "Stop finished", "setup-mediaflow.sh",
           stdin="3\n10\n", timeout=120,
           needs=("setup-mediaflow.sh", "mediaflow-state/docker-compose.yml"),
           confirm="Stop MediaFlow Proxy? Streams that use it will stop playing."),

    Action("webhook.start", "Start", "Starting", "Start finished", "setup-webhook.sh",
           args=("start-relay",), timeout=300,
           needs=("setup-webhook.sh", "webhook-relay-state/docker-compose.yml")),
    Action("webhook.stop", "Stop", "Stopping", "Stop finished", "setup-webhook.sh",
           stdin="3\n10\n", timeout=120,
           needs=("setup-webhook.sh", "webhook-relay-state/docker-compose.yml"),
           confirm="Stop the webhook relay? Incoming webhooks will be rejected until it starts again."),

    # The VPN's own checks run in the script: the tunnel is confirmed before
    # AIOStreams starts, the boot hook follows the mode, and a failed switch
    # stops with the stack as it was. "off" keeps AIOStreams live throughout.
    Action("vpn.on", "Turn VPN on", "Turning the VPN on", "VPN on", "setup-vpn-gluetun.sh",
           args=("on",), timeout=420, needs=("setup-vpn-gluetun.sh", "vpn-state/active"),
           confirm="AIOStreams waits for the tunnel to connect before it starts again, "
                   "so streams pause for up to a minute. This page reconnects by itself."),
    Action("vpn.off", "Turn VPN off", "Turning the VPN off", "VPN off", "setup-vpn-gluetun.sh",
           args=("off",), timeout=420, needs=("setup-vpn-gluetun.sh", "vpn-state/active"),
           confirm="AIOStreams switches to a direct connection, so its traffic leaves from "
                   "this server's own IP from now on. Streams pause for a few seconds, and this page reconnects by itself."),
    Action("vpn.update", "Update VPN", "Updating the VPN", "VPN update finished", "setup-vpn-gluetun.sh",
           args=("update",), timeout=600, needs=("setup-vpn-gluetun.sh", "vpn-state/active"),
           confirm="Pulls the newest gluetun v3 release. If there is one and the VPN is on, the stack restarts "
                   "and streams pause for up to a minute. Already on the newest, nothing restarts."),
    Action("watchdog.start", "Start", "Starting", "Start finished", "setup-watchdog.sh",
           args=("install-timer",), timeout=60,
           needs=("setup-watchdog.sh", "watchdog-state/config")),
    Action("watchdog.stop", "Stop", "Stopping", "Stop finished", "setup-watchdog.sh",
           stdin="3\n7\n", timeout=60,
           needs=("setup-watchdog.sh", "watchdog-state/config")),
    Action("watchdog.test", "Send test alert", "Sending", "Test alert sent", "setup-watchdog.sh",
           args=("test",), timeout=60,
           needs=("setup-watchdog.sh", "watchdog-state/config")),
]}


class BadAction(ValueError):
    pass


def build_update(backup: bool, channel: str | None) -> Action:
    """Update flow of setup-aiostreams.sh option 5, answered up front."""
    if not isinstance(backup, bool):
        raise BadAction("backup must be true or false")
    if channel not in (None, "latest", "nightly"):
        raise BadAction("channel must be latest or nightly")
    # Nightly can migrate AIOStreams' database past what stable understands; the backup is the way back.
    if channel == "nightly" and not backup:
        raise BadAction("Switching to nightly needs Back up first: that backup is the way back to stable.")
    answers = ["5", "1" if backup else "2"]
    if backup:
        answers.append("")   # Enter at "Continue now that you've read this..." after the backup
    if channel:
        # "Switch build channel?" y, choose, confirm y
        answers += ["y", "1" if channel == "latest" else "2", "y"]
    else:
        answers += ["N"]
    answers += ["N", "10"]  # VPN-off prompt absorber, then exit
    confirm = "Pull the latest AIOStreams image and recreate the container? "
    confirm += "Streams stop loading for a minute." if not channel else (
        f"This also switches the build channel to {channel}.")
    return Action("stack.update", "Update", "Updating", "Update finished", AIO,
                  stdin="\n".join(answers) + "\n", timeout=1200, needs=(AIO,),
                  confirm=confirm)


def build_restore(path: str) -> Action:
    """A same-server rollback to the backup at path, which the caller has
    matched against the backups actually on the server. --same-server runs
    the check first and refuses rather than asks. AIOS_UI_TERMINAL tells it
    the panel is running it, so it leaves the panel running."""
    return Action("stack.restore", "Restore", "Restoring", "Restore finished", AIO,
                  args=("restore", "--same-server", path), timeout=1800, needs=(AIO,),
                  env=("AIOS_UI_TERMINAL=1",))


def build_use_address(ip) -> Action:
    """Points the VPN config in use at another of its server's addresses (the
    script re-checks it's an IPv4 address and that the config's endpoint is a
    name). The address list on the VPN page is the confirmation, so no modal."""
    try:
        addr = ipaddress.IPv4Address(str(ip))
    except ValueError:
        raise BadAction("Pick one of the listed addresses.")
    return Action("vpn.use", "Change server", "Switching server", "Server switched", "setup-vpn-gluetun.sh",
                  args=("use-address", str(addr)), timeout=420,
                  needs=("setup-vpn-gluetun.sh", "vpn-state/active", "vpn-state/endpoint-host"))


def build_use_config(ip, on: bool = False) -> Action:
    """Switches to the config the VPN page checked and staged in vpn-state,
    at the server address picked (IPv4 only); the script keeps the old one."""
    try:
        addr = ipaddress.IPv4Address(str(ip))
    except ValueError:
        raise BadAction("Pick one of the listed addresses.")
    return Action("vpn.config", "Change config", "Changing the VPN config", "VPN config changed", "setup-vpn-gluetun.sh",
                  args=("use-config", str(addr), *(("on",) if on is True else ())), timeout=420,
                  needs=("setup-vpn-gluetun.sh", "vpn-state/active"))


def build_delete_config(path: str) -> Action:
    """Deletes one config from the VPN page's list. main.py has matched the
    path against the list just made, and the script checks it again."""
    return Action("vpn.delete", "Delete this config", "Deleting a VPN config", "VPN config deleted", "setup-vpn-gluetun.sh",
                  args=("delete-config", path), timeout=60, needs=("setup-vpn-gluetun.sh", "vpn-state/active"))


def build_use_file(path: str, ip, on: bool = False) -> Action:
    """Switches to a listed config not in use (a .conf file, the previous config,
    an earlier paste) at the address picked; like Change config."""
    try:
        addr = ipaddress.IPv4Address(str(ip))
    except ValueError:
        raise BadAction("Pick one of the listed addresses.")
    return Action("vpn.file", "Use this config", "Changing the VPN config", "VPN config changed", "setup-vpn-gluetun.sh",
                  args=("use-file", path, str(addr), *(("on",) if on is True else ())), timeout=420, needs=("setup-vpn-gluetun.sh", "vpn-state/active"))


def build_vpn_uninstall(remove_image: bool, delete_confs: bool) -> Action:
    """Uninstall VPN layer (the script's option 7), its two questions answered up front.
    main.py also wants "uninstall" typed, like the restore's "restore"."""
    opts = (("remove-image",) if remove_image is True else ()) + (("delete-confs",) if delete_confs is True else ())
    return Action("vpn.uninstall", "Uninstall VPN", "Uninstalling the VPN", "VPN uninstalled", "setup-vpn-gluetun.sh",
                  args=("uninstall", *opts), timeout=600, needs=("setup-vpn-gluetun.sh", "vpn-state/active"))


# ntfy topics: letters, digits, - and _; at least 12 so it stays private (the script checks the same)
TOPIC_RE = re.compile(r"^[A-Za-z0-9_-]{12,64}$")


def build_set_topic(topic) -> Action:
    """Phone alerts' Change topic: the script's set-topic, then a test alert to the
    new topic. The topic goes in on stdin, so it's never in a command line, the
    panel's Activity or its history."""
    topic = str(topic or "").strip()
    if not TOPIC_RE.match(topic):
        raise BadAction("Use 12 to 64 letters, numbers, - and _ for the topic.")
    return Action("watchdog.topic", "Change alert topic", "Changing the alert topic", "Alert topic changed", "setup-watchdog.sh",
                  args=("set-topic",), stdin=topic + "\n", timeout=60,
                  needs=("setup-watchdog.sh", "watchdog-state/config"))


# Each add-on script's state folder: while it's there, the add-on is set up and its script stays
ADDON_STATE = {"vpn": "vpn-state", "mediaflow": "mediaflow-state", "watchdog": "watchdog-state", "webhook": "webhook-relay-state"}


def resolve(action_id: str, params: dict | None = None) -> Action:
    params = params or {}
    if action_id == "stack.update":
        return build_update(params.get("backup", True), params.get("channel"))
    if action_id == "vpn.use":
        return build_use_address(params.get("ip"))
    if action_id == "vpn.uninstall":
        return build_vpn_uninstall(params.get("remove_image") is True, params.get("delete_confs") is True)
    if action_id == "watchdog.topic":
        return build_set_topic(params.get("topic"))
    if action_id == "vpn.config":
        return build_use_config(params.get("ip"), params.get("on") is True)
    act = _STATIC.get(action_id)
    if act is None:
        raise BadAction("unknown action")
    return act


def catalog() -> list[Action]:
    return list(_STATIC.values()) + [build_update(True, None), build_use_address("192.0.2.1"), build_use_config("192.0.2.1"),
                                     build_delete_config("/"), build_use_file("/", "192.0.2.1"), build_vpn_uninstall(False, False),
                                     build_set_topic("aios-example-topic")]


# The stack's scripts, in the order the Terminal tab lists them. Only the first
# is always there; the others are downloaded on their own, so the panel checks.
# setup-backup.sh isn't listed: the AIOStreams menu runs it (options 7 and 8)
# and the Terminal tab updates it together with setup-aiostreams.sh.
SCRIPTS = [
    ("aiostreams", "AIOStreams menu", "setup-aiostreams.sh"),
    ("vpn", "VPN (Gluetun)", "setup-vpn-gluetun.sh"),
    ("mediaflow", "MediaFlow Proxy", "setup-mediaflow.sh"),
    ("watchdog", "Phone alerts", "setup-watchdog.sh"),
    ("webhook", "Webhook relay", "setup-webhook.sh"),
]
