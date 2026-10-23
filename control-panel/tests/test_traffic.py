from types import SimpleNamespace

from app.traffic import Traffic

T0 = 1_800_000_000 - 1_800_000_000 % 3600     # an hour's start


def store(tmp_path, read=lambda: None):
    return Traffic(tmp_path / "vpn-traffic.json", read)


def test_minutes_and_hours(tmp_path):
    t = store(tmp_path)
    t.add(T0 + 1, (1000, 100))
    t.add(T0 + 61, (61000, 700))           # 60 kB down, 600 B up in the first minute
    t.add(T0 + 121, (61000, 700))          # a quiet minute still gets an entry
    assert t.minutes == {T0: [60000, 600], T0 + 60: [0, 0]}
    assert t.hours == {T0: [60000, 600, 60000, 600]}


def test_gaps_and_restarts(tmp_path):
    t = store(tmp_path)
    t.add(T0 + 1, (5000, 50))
    t.add(T0 + 61, None)                   # VPN off: nothing recorded, and no carry-over
    t.add(T0 + 121, (9000, 90))
    t.add(T0 + 181, (9500, 95))
    assert t.minutes == {T0 + 120: [500, 5]}
    t.add(T0 + 241, (300, 3))              # gluetun restarted: counted from zero
    assert t.minutes[T0 + 180] == [300, 3]
    t.add(T0 + 241 + 600, (900, 9))        # too long since the last reading: not counted
    assert len(t.minutes) == 2


def test_kept_a_day_and_saved(tmp_path):
    t = store(tmp_path)
    t.add(T0 + 1, (0, 0))
    t.add(T0 + 61, (10, 1))
    t.add(T0 + 86400 + 61, (20, 2))
    t.add(T0 + 86400 + 121, (30, 3))
    assert list(t.minutes) == [T0 + 86400 + 60]
    assert len(t.hours) == 2
    t.save()
    again = store(tmp_path)
    assert again.minutes == t.minutes and again.hours == t.hours and again.last == t.last
    v = again.view(T0 + 86400 + 130)
    assert v["minutes"] == [[T0 + 86400 + 60, 10, 1]] and len(v["hours"]) == 2


def test_sample_survives_a_failing_read(tmp_path):
    def boom():
        raise RuntimeError("docker down")
    t = store(tmp_path, boom)
    t.sample(T0)
    assert t.last is None and not t.minutes


def test_vpn_counters_reads_the_tunnel(tmp_path):
    from app import stack
    (tmp_path / "docker-compose.yml").write_text("services:\n  gluetun:\n    container_name: gluetun\n")
    dev = (b"Inter-|   Receive |  Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes\n"
           b"    lo: 46 6 0 0 0 0 0 0 46 6 0 0 0 0 0 0\n"
           b"  eth0: 140941795 105368 0 0 0 0 0 0 99963919 5611 0 0 0 0 0 0\n"
           b"  tun0: 136472936 104104 0 0 0 0 0 0 401160 3341 0 0 0 0 0 0\n")
    b = stack.Backend.__new__(stack.Backend)
    b._client = SimpleNamespace(containers=SimpleNamespace(get=lambda name: SimpleNamespace(
        exec_run=lambda cmd: SimpleNamespace(exit_code=0, output=dev))))
    b.p = lambda rel: tmp_path / rel
    assert b.vpn_counters() == (136472936, 401160)
    (tmp_path / "docker-compose.yml").write_text("services:\n  aiostreams: {}\n")
    assert b.vpn_counters() is None


ROUTE = ("Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n"
         "docker0\t000011AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0\n"
         "enp0s6\t00000000\t0100000A\t0003\t0\t0\t100\t00000000\t0\t0\t0\n"
         "wlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n")
DEV = ("Inter-|   Receive |  Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes\n"
       "    lo: 46 6 0 0 0 0 0 0 46 6 0 0 0 0 0 0\n"
       "enp0s6: 154551372173 51865695 0 0 0 0 0 0 150305308424 11893844 0 0 0 0 0 0\n"
       "docker0: 9 1 0 0 0 0 0 0 9 1 0 0 0 0 0 0\n")


def test_host_net_follows_the_default_route(tmp_path):
    from app.traffic import host_net
    (tmp_path / "route").write_text(ROUTE)
    (tmp_path / "dev").write_text(DEV)
    assert host_net(tmp_path) == (154551372173, 150305308424)   # the lowest metric's card, whatever it's called


def test_host_net_ipv6_only(tmp_path):
    from app.traffic import host_net
    (tmp_path / "route").write_text(ROUTE.splitlines()[0] + "\n")
    (tmp_path / "ipv6_route").write_text(
        "00000000000000000000000000000000 00 00000000000000000000000000000000 00 fe800000000000000000000000000001 00000400 00000001 00000000 00000003     lo\n"
        "00000000000000000000000000000000 00 00000000000000000000000000000000 00 fe800000000000000000000000000001 00000400 00000001 00000000 00000003 enp0s6\n")
    (tmp_path / "dev").write_text(DEV)
    assert host_net(tmp_path) == (154551372173, 150305308424)
    (tmp_path / "ipv6_route").write_text("")
    assert host_net(tmp_path) is None


def test_status_carries_the_counters():
    import os
    os.environ["UI_DEMO"] = "1"
    from fastapi.testclient import TestClient
    from app import main
    main.app.dependency_overrides[main.current_user] = lambda: "demo"
    try:
        net = TestClient(main.app).get("/api/status").json()["net"]
    finally:
        main.app.dependency_overrides.clear()
    assert len(net["host"]) == 2 and len(net["vpn"]) == 2 and net["t"] > 0


def test_clear_starts_again_from_now(tmp_path):
    t = store(tmp_path)
    t.add(T0 + 1, (0, 0))
    t.add(T0 + 61, (600, 60))
    v = t.view(T0 + 70)
    assert v["since"] == T0 and v["total"] == [600, 60]
    t.clear()
    assert store(tmp_path).view(T0 + 70)["since"] is None     # saved cleared
    t.add(T0 + 121, (900, 90))                                  # and the next minute counts
    assert t.minutes == {T0 + 60: [300, 30]}


def test_clear_endpoint():
    import os
    os.environ["UI_DEMO"] = "1"
    from fastapi.testclient import TestClient
    from app import main
    main.app.dependency_overrides[main.current_user] = lambda: "demo"
    try:
        c = TestClient(main.app)
        hdr = {"x-ui-request": "1"}
        assert c.post("/api/host/traffic/clear", headers=hdr).json() == {"cleared": True}
        assert c.get("/api/host/traffic").json()["since"] is None
        assert c.post("/api/nope/traffic/clear", headers=hdr).status_code == 404
    finally:
        main.app.dependency_overrides.clear()


def test_a_counter_that_jumps_is_not_traffic(tmp_path):
    t = store(tmp_path)
    t.add(T0 + 1, (1000, 1000))
    t.add(T0 + 61, (5 * 10**12, 1000))     # 5 TB in a minute: no card does that
    assert not t.minutes
    t.add(T0 + 121, (5 * 10**12 + 600, 1060))
    assert t.minutes == {T0 + 60: [600, 60]}
