"""The VPN page's check of a pasted WireGuard config."""
import pytest

from app.wgconf import check_wireguard_conf

PRIV = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
PUB = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg="
GOOD = f"""[Interface]
PrivateKey = {PRIV}
Address = 10.5.0.2/16
DNS = 10.0.0.1

[Peer]
PublicKey = {PUB}
AllowedIPs = 0.0.0.0/0
Endpoint = nl.wg.example-vpn.net:51820
"""


def test_good_config_is_tidied_and_never_echoes_keys():
    messy = "  " + GOOD.replace("\n", "\r\n    ")
    body, info = check_wireguard_conf(messy)
    assert "\r" not in body and all(not l.startswith(" ") for l in body.splitlines())
    assert info == {"endpoint_host": "nl.wg.example-vpn.net", "endpoint_ip": None, "endpoint_port": "51820", "address": "10.5.0.2/16"}
    assert PRIV not in str(info) and PUB not in str(info)


def test_ip_endpoint():
    _, info = check_wireguard_conf(GOOD.replace("nl.wg.example-vpn.net", "203.0.113.16"))
    assert info["endpoint_ip"] == "203.0.113.16" and info["endpoint_host"] is None


@pytest.mark.parametrize("change, why", [
    (lambda t: t.replace("[Peer]", ""), "[Peer]"),
    (lambda t: t.replace(f"PublicKey = {PUB}\n", ""), "no PublicKey"),
    (lambda t: t.replace(PRIV, PRIV[:20]), "doesn't look like a WireGuard key"),
    (lambda t: t.replace(":51820", ""), "name-or-IPv4"),
    (lambda t: t.replace("nl.wg.example-vpn.net", "300.1.1.1"), "valid IPv4"),
    (lambda t: t.replace("nl.wg.example-vpn.net", "x;reboot"), "name-or-IPv4"),
    (lambda t: "hello", "[Interface]"),
])
def test_bad_configs_say_why(change, why):
    with pytest.raises(ValueError) as e:
        check_wireguard_conf(change(GOOD))
    assert why in str(e.value)
