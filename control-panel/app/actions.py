"""The ONLY things this UI can run on the server.

Each action maps to one of the existing setup-*.sh scripts, driven the same
way a person would drive it: either through the script's own non-interactive
entry point (e.g. 'backup', 'start-relay') or by typing the menu choices.
The scripts get a pseudo-terminal for stdin, exactly like an SSH session.
That matters: do_backup ends with '[[ -t 0 ]] && read ...', which returns
failure (and kills the script under set -e) when stdin is not a terminal.
On a terminal it waits for Enter, which the "\n" answers below supply.
Nothing here accepts free text from the browser; the only inputs are an
action id and, for update, two validated options.
"""
from __future__ import annotations

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

    Action("watchdog.start", "Start", "Starting", "Start finished", "setup-watchdog.sh",
           args=("install-timer",), timeout=60,
           needs=("setup-watchdog.sh", "watchdog-state/config")),
    Action("watchdog.stop", "Stop", "Stopping", "Stop finished", "setup-watchdog.sh",
           stdin="3\n7\n", timeout=60,
           needs=("setup-watchdog.sh", "watchdog-state/config")),
    Action("watchdog.test", "Send test alert", "Sending", "Test alert sent", "setup-watchdog.sh",
           stdin="4\n7\n", timeout=60,
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


def resolve(action_id: str, params: dict | None = None) -> Action:
    params = params or {}
    if action_id == "stack.update":
        return build_update(params.get("backup", True), params.get("channel"))
    act = _STATIC.get(action_id)
    if act is None:
        raise BadAction("unknown action")
    return act


def catalog() -> list[Action]:
    return list(_STATIC.values()) + [build_update(True, None)]


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
