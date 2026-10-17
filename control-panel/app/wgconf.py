"""Checks a pasted WireGuard config for the VPN page's Change config."""
from __future__ import annotations

import re

_WG_KEY = re.compile(r"[A-Za-z0-9+/]{42,43}=")


def check_wireguard_conf(text: str) -> tuple[str, dict]:
    """A pasted WireGuard config, tidied (no CRs or leading spaces) and checked
    the way setup-vpn-gluetun.sh reads it. Returns the tidy text and what the
    VPN page may show (endpoint, port, address), never the keys. Raises
    ValueError with a reason to show."""
    lines = [l.strip() for l in text.replace("\r", "").split("\n")]
    body = "\n".join(lines).strip() + "\n"
    def val(key):
        m = re.search(rf"^{key}\s*=\s*(.+)$", body, re.M | re.I)
        return m.group(1).strip() if m else ""
    if not (re.search(r"^\[Interface\]", body, re.M | re.I) and re.search(r"^\[Peer\]", body, re.M | re.I)):
        raise ValueError("That isn't a whole WireGuard config: it needs an [Interface] and a [Peer] section.")
    missing = [k for k in ("PrivateKey", "Address", "PublicKey", "Endpoint") if not val(k)]
    if missing:
        raise ValueError(f"That config has no {' or '.join(missing)} line.")
    if not _WG_KEY.fullmatch(val("PrivateKey").replace(" ", "")) or not _WG_KEY.fullmatch(val("PublicKey").replace(" ", "")):
        raise ValueError("Its PrivateKey or PublicKey doesn't look like a WireGuard key. Check it was copied whole.")
    m = re.fullmatch(r"([A-Za-z0-9.-]+):(\d{1,5})", val("Endpoint").replace(" ", ""))
    if not m:
        raise ValueError("Its Endpoint should look like name-or-IPv4:51820.")
    host, port = m.group(1), m.group(2)
    is_ip = re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", host) is not None
    if is_ip and any(int(x) > 255 for x in host.split(".")):
        raise ValueError("Its Endpoint isn't a valid IPv4 address.")
    address = val("Address").split(",")[0].strip()
    if not re.fullmatch(r"[0-9a-fA-F.:/]+", address):
        raise ValueError("Its Address line doesn't look right.")
    return body, {"endpoint_host": None if is_ip else host, "endpoint_ip": host if is_ip else None,
                  "endpoint_port": port, "address": address}
