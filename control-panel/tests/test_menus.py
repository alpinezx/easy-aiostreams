"""The panel runs the scripts' own commands, but older scripts don't know them
and fall through to their menus, reading the menu numbers the panel types
after the command. So the numbers are an interface: these tests fail if a
script's menu moves an option the panel types.

October 2026: Exit became the last option everywhere, so setup-aiostreams.sh's
and setup-mediaflow.sh's Exit moved from 10 to 11. The panel still types 10 to
leave: that only reaches scripts too old to know the commands, where 10 is
still Exit. (Panels older than 1.28.1 typed numbers alone, and need updating
before the scripts.) November 2026: with a Cloudflare Tunnel set up,
setup-aiostreams.sh shows it as 11 and Exit as 12; everywhere else Exit stays 11."""
import os
import re
from pathlib import Path

os.environ["UI_DEMO"] = "1"

from app import actions  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


def script_path(name: str) -> Path:
    """A script's place in the repo: scripts/core or scripts/others."""
    if "/" in name:
        return ROOT / name
    core = ROOT / "scripts" / "core" / name
    return core if core.exists() else ROOT / "scripts" / "others" / name


def menu(script: str) -> dict[str, str]:
    """The 'N) Label' lines of a script's main menu, the last one in the file, as {N: label}."""
    text = script_path(script).read_text(encoding="utf-8")
    return dict(re.findall(r'echo "\s*(\d+)\) ([^"]+)"', text[text.rindex("while true; do"):]))


def typed(action_id: str) -> list[str]:
    return actions.resolve(action_id).stdin.split("\n")


def test_aiostreams_menu_numbers_the_panel_types():
    text = script_path("setup-aiostreams.sh").read_text(encoding="utf-8")
    main = dict(re.findall(r'echo "\s*(\d+)\) ([^"]+)"', text[text.index('echo "What would you like to do?"'):text.index('read -rp "Select an option [1-$MENU_LAST]')]))
    assert main["2"].startswith("Stop AIOStreams")
    assert main["3"].startswith("Start AIOStreams")
    assert main["4"].startswith("Restart the stack")
    assert main["5"].startswith("Update")
    assert main["10"] == "Maintenance"
    # both menus: Exit last, 11 without a tunnel, 12 with one (11 its menu)
    assert 'echo " 11) Exit"' in text and 'echo " 11) Cloudflare Tunnel"' in text and 'echo " 12) Exit"' in text
    assert max(main, key=int) == "12"
    # the typed 10 below is for older scripts only, where 10 was Exit
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
        assert m["3"] == "Stop", script
        assert typed(action_id)[:2] == ["3", "10"], action_id
    assert menu("setup-aiometadata.sh")["10"] == "Exit"
    mf = menu("setup-mediaflow.sh")
    assert mf["10"].startswith("Update") and mf["11"] == "Exit"


def test_exit_is_last_in_every_menu():
    for script in ("setup-aiometadata.sh", "setup-aiomanager.sh", "setup-mediaflow.sh", "control-panel/setup-ui.sh"):
        m = menu(script)
        assert m[max(m, key=int)] == "Exit", script
    # The VPN's Exit is numbered in the script: after MediaFlow's option, with MediaFlow set up
    vpn = script_path("setup-vpn-gluetun.sh").read_text(encoding="utf-8")
    vpn = vpn[vpn.rindex("while true; do"):]
    assert vpn.index('echo "8) MediaFlow through the VPN') < vpn.index('echo "$EXIT_OPT) Exit"')
    assert menu("setup-vpn-gluetun.sh")["7"] == "Uninstall VPN layer"


def test_the_panel_runs_named_commands_the_scripts_know():
    aio = script_path("setup-aiostreams.sh").read_text(encoding="utf-8")
    assert re.search(r"^\s*stop\|start\|restart\|update\)", aio, re.M)
    for action_id, cmd in (("stack.start", "start"), ("stack.stop", "stop"), ("stack.restart", "restart")):
        assert actions.resolve(action_id).args == (cmd,)
    assert actions.build_update(True, "latest").args == ("update", "--backup", "--channel", "latest")
    assert actions.build_update(False, None).args == ("update",)
    assert '"${1:-}" == "stop-mediaflow"' in script_path("setup-mediaflow.sh").read_text(encoding="utf-8")
    assert actions.resolve("mediaflow.stop").args == ("stop-mediaflow",)
    meta = script_path("setup-aiometadata.sh").read_text(encoding="utf-8")
    for cmd in ("start-aiometadata", "stop-aiometadata", "update-aiometadata"):
        assert re.search(rf"^\s*{cmd}\)", meta, re.M), cmd
    assert actions.resolve("aiometadata.stop").args == ("stop-aiometadata",)
    assert actions.resolve("aiometadata.start").args == ("start-aiometadata",)


def test_aiomanager_has_the_commands_the_panel_runs():
    """A new script: the panel only runs its named commands, never menu numbers."""
    mgr = script_path("setup-aiomanager.sh").read_text(encoding="utf-8")
    for cmd in ("start-aiomanager", "stop-aiomanager", "update-aiomanager", "signups", "uninstall"):
        assert re.search(rf"^\s*{cmd}\)", mgr, re.M), cmd
    for sub in ("open", "close"):
        assert re.search(rf"^\s*{sub}\)", mgr, re.M), sub
    assert actions.resolve("aiomanager.stop").args == ("stop-aiomanager",)
    assert actions.resolve("aiomanager.start").args == ("start-aiomanager",)
    m = menu("setup-aiomanager.sh")
    assert (m["2"], m["3"], m["8"], m["11"]) == ("Start", "Stop", "Uninstall", "Exit")
    assert m["10"].startswith("Sign-ups")


def test_mediaflow_update_is_a_named_command():
    """The panel's MediaFlow Update runs update-mediaflow, never the menu (where it's 10)."""
    assert '"${1:-}" == "update-mediaflow"' in script_path("setup-mediaflow.sh").read_text(encoding="utf-8")


def test_the_add_ons_uninstall_is_a_named_command():
    """The Add-ons page's Uninstall runs each script's "uninstall"; the menus keep their numbers."""
    meta = script_path("setup-aiometadata.sh").read_text(encoding="utf-8")
    assert re.search(r"^\s*uninstall\)", meta, re.M)
    assert '"${1:-}" == "uninstall"' in script_path("setup-mediaflow.sh").read_text(encoding="utf-8")
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
    aio = script_path("setup-aiostreams.sh").read_text(encoding="utf-8")
    assert re.search(r"^\s*remove-webhook-relay\)", aio, re.M)
    assert not script_path("setup-webhook.sh").exists()


def test_scripts_sit_in_their_folders():
    """The panel and the scripts fetch them from here: core is what the main script needs, others the add-ons."""
    from app.stack import WITH_MAIN
    core = {p.name for p in (ROOT / "scripts" / "core").glob("*.sh")}
    others = {p.name for p in (ROOT / "scripts" / "others").glob("*.sh")}
    assert core == {"setup-aiostreams.sh", *WITH_MAIN}
    assert others == {f for _, _, f in actions.SCRIPTS} - core
    js = (ROOT / "control-panel" / "web" / "js" / "scripts.js").read_text(encoding="utf-8")
    assert all(f'"{f}"' in js[js.index("const UPDATE_WITH"):js.index("const CORE")] for f in WITH_MAIN)


def test_panel_terminal_is_spotted_in_a_login_shell():
    """AIOS_UI_TERMINAL doesn't survive runuser or sudo, so each guard needs the namespace check too."""
    for name in ("control-panel/setup-ui.sh", "setup-backup.sh", "setup-aiostreams.sh"):
        text = script_path(name).read_text(encoding="utf-8")
        assert '"$(readlink /proc/self/ns/cgroup)" != "$(readlink /proc/1/ns/cgroup)"' in text, name


def test_only_the_redirect_is_left_in_the_root():
    """Old links land on it, so it must go on fetching the real script from scripts/core."""
    assert [p.name for p in ROOT.glob("*.sh")] == ["setup-aiostreams.sh"]
    text = (ROOT / "setup-aiostreams.sh").read_text(encoding="utf-8")
    assert "/scripts/core/setup-aiostreams.sh" in text
    assert "SELF_SCRIPT_PATH" in script_path("setup-aiostreams.sh").read_text(encoding="utf-8")
