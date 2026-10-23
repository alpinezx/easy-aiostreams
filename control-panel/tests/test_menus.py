"""The panel runs the scripts' own commands, but older scripts don't know them
and fall through to their menus, reading the menu numbers the panel types
after the command. Older panels type only those numbers. So the numbers are an
interface: these tests fail if a script's menu moves an option the panel types."""
import os
import re
from pathlib import Path

os.environ["UI_DEMO"] = "1"

from app import actions  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


def menu(script: str) -> dict[str, str]:
    """The 'N) Label' lines of a script's main menu, the last one in the file, as {N: label}."""
    text = (ROOT / script).read_text(encoding="utf-8")
    return dict(re.findall(r'echo "\s*(\d+)\) ([^"]+)"', text[text.rindex("while true; do"):]))


def typed(action_id: str) -> list[str]:
    return actions.resolve(action_id).stdin.split("\n")


def test_aiostreams_menu_numbers_the_panel_types():
    text = (ROOT / "setup-aiostreams.sh").read_text(encoding="utf-8")
    main = dict(re.findall(r'echo "\s*(\d+)\) ([^"]+)"', text[text.index('echo "What would you like to do?"'):text.index('read -rp "Select an option [1-11]')]))
    assert main["2"].startswith("Stop AIOStreams")
    assert main["3"].startswith("Start AIOStreams")
    assert main["4"].startswith("Restart the stack")
    assert main["5"].startswith("Update")
    assert main["10"] == "Exit"
    assert typed("stack.stop")[0] == "2" and typed("stack.stop")[-2] == "10"
    assert typed("stack.start")[0] == "3" and typed("stack.start")[-2] == "10"
    assert typed("stack.restart")[0] == "4" and typed("stack.restart")[-2] == "10"
    # Update's own questions: backup first or not, then the channel
    assert "1) Backup first, then update" in text and "2) Update without backing up" in text
    assert "1) Stable (latest)" in text and "2) Nightly" in text
    up = actions.build_update(True, "nightly").stdin.split("\n")
    assert up[:2] == ["5", "1"] and up[-2] == "10"


def test_addon_menu_numbers_the_panel_types():
    for script, action_id in (("setup-mediaflow.sh", "mediaflow.stop"), ("setup-aiometadata.sh", "aiometadata.stop")):
        m = menu(script)
        assert m["3"] == "Stop" and m["10"] == "Exit", script
        assert typed(action_id)[:2] == ["3", "10"], action_id


def test_the_panel_runs_named_commands_the_scripts_know():
    aio = (ROOT / "setup-aiostreams.sh").read_text(encoding="utf-8")
    assert re.search(r"^\s*stop\|start\|restart\|update\)", aio, re.M)
    for action_id, cmd in (("stack.start", "start"), ("stack.stop", "stop"), ("stack.restart", "restart")):
        assert actions.resolve(action_id).args == (cmd,)
    assert actions.build_update(True, "latest").args == ("update", "--backup", "--channel", "latest")
    assert actions.build_update(False, None).args == ("update",)
    assert '"${1:-}" == "stop-mediaflow"' in (ROOT / "setup-mediaflow.sh").read_text(encoding="utf-8")
    assert actions.resolve("mediaflow.stop").args == ("stop-mediaflow",)
    meta = (ROOT / "setup-aiometadata.sh").read_text(encoding="utf-8")
    for cmd in ("start-aiometadata", "stop-aiometadata", "update-aiometadata"):
        assert re.search(rf"^\s*{cmd}\)", meta, re.M), cmd
    assert actions.resolve("aiometadata.stop").args == ("stop-aiometadata",)
    assert actions.resolve("aiometadata.start").args == ("start-aiometadata",)


def test_the_add_ons_uninstall_is_a_named_command():
    """The Add-ons page's Uninstall runs each script's "uninstall"; the menus keep their numbers."""
    meta = (ROOT / "setup-aiometadata.sh").read_text(encoding="utf-8")
    assert re.search(r"^\s*uninstall\)", meta, re.M)
    assert '"${1:-}" == "uninstall"' in (ROOT / "setup-mediaflow.sh").read_text(encoding="utf-8")
    assert menu("setup-aiometadata.sh")["8"] == "Uninstall"
    assert menu("setup-mediaflow.sh")["9"] == "Uninstall"
    assert actions.resolve("aiometadata.uninstall", {"remove_image": True}).args == ("uninstall", "remove-image")
    assert actions.resolve("mediaflow.uninstall", {"remove_image": True}).args == ("uninstall", "remove-image")
    assert actions.resolve("mediaflow.uninstall", {"remove_image": "yes"}).args == ("uninstall",)

    # The retired webhook relay's Uninstall is setup-aiostreams.sh's, offered only
    # once the script on the server knows the command (an older one would open its menu)
    relay = actions.resolve("webhook.uninstall", {"remove_image": True})
    assert relay.script == "setup-aiostreams.sh" and relay.args == ("remove-webhook-relay",)
    assert relay.script_has == "remove-webhook-relay"
    aio = (ROOT / "setup-aiostreams.sh").read_text(encoding="utf-8")
    assert re.search(r"^\s*remove-webhook-relay\)", aio, re.M)
    assert not (ROOT / "setup-webhook.sh").exists()
