"""This server's CPU figure: how busy all the cores were between two looks."""
import os

os.environ["UI_DEMO"] = "1"

from app import stack


def lines(*rows):
    it = iter(rows)
    return lambda: next(it)


def test_busy_share_between_two_looks(monkeypatch):
    # user nice system idle iowait irq softirq steal: 100 of 400 ticks busy
    monkeypatch.setattr(stack, "_proc_stat_cpu", lines("cpu 100 0 0 900 0 0 0 0 0 0",
                                                       "cpu 180 0 20 1200 0 0 0 0 0 0"))
    monkeypatch.setattr(stack.time, "sleep", lambda s: None)
    b = object.__new__(stack.Backend)
    assert b._cpu_pct() == 25.0


def test_iowait_counts_as_idle(monkeypatch):
    monkeypatch.setattr(stack, "_proc_stat_cpu", lines("cpu 0 0 0 0 0 0 0 0",
                                                       "cpu 10 0 0 50 40 0 0 0"))
    monkeypatch.setattr(stack.time, "sleep", lambda s: None)
    b = object.__new__(stack.Backend)
    assert b._cpu_pct() == 10.0


def test_no_ticks_keeps_last_figure(monkeypatch):
    monkeypatch.setattr(stack, "_proc_stat_cpu", lines("cpu 0 0 0 0 0 0 0 0", "cpu 10 0 0 90 0 0 0 0",
                                                       "cpu 10 0 0 90 0 0 0 0"))
    monkeypatch.setattr(stack.time, "sleep", lambda s: None)
    b = object.__new__(stack.Backend)
    assert b._cpu_pct() == 10.0
    assert b._cpu_pct() == 10.0
