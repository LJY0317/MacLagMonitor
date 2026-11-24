#!/usr/bin/env python3
"""Regression for observed PowerLog counter resets and unsigned input artifacts.

Run with the installed or locally built native executable as the sole argument.
All databases and runtime paths are synthetic and temporary.
"""
import gzip
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).expanduser().resolve()
base = 1767225600  # 2026-01-01T00:00:00Z
power_table = "PLBatteryAgent_EventBackward_Adapter"
battery_table = "PLBatteryAgent_EventBackward_Battery"
sleep_table = "PLSleepWakeAgent_EventForward_PowerState"
idle_table = "PLSleepWakeAgent_EventForward_UserIdle"
power = [
    (0, 10000, 0, 0, 0, 0),
    (60, 10000, 600000, 60, 720000, 60),
    (120, 10000, 1200000, 120, 1440000, 120),
    (180, 0, 1800000, 180, 4296407296, 121),
    (240, 0, 2400000, 240, 8591374592, 122),
    (300, 10000, 3000000, 300, 8592094592, 182),
    (360, 10000, 3600000, 360, 8592814592, 242),
    (420, 10000, 10000, 1, 12000, 1),  # counter reset
]
battery = [
    (0, 1, 1, 1000), (60, 1, 1, 1000), (120, 1, 1, 1000),
    (180, 0, 0, -500), (240, 0, 0, -500),
    (300, 1, 0, 0), (360, 1, 0, 0), (420, 1, 0, 0),
]
sleep = [(0, 0, 6), (180, 1, 1), (240, 5, 0), (300, 0, 6)]
idle = [(0, 0), (120, 1), (360, 0)]

def database(path, lo, hi):
    with sqlite3.connect(path) as c:
        c.execute(f"CREATE TABLE {power_table}(timestamp REAL,SystemLoad INTEGER,AccumulatedSystemLoad INTEGER,SystemLoadAccumulatorCount INTEGER,AccumulatedSystemPowerIn INTEGER,SystemPowerInAccumulatorCount INTEGER,PowerTelemetryErrorCount INTEGER)")
        c.executemany(f"INSERT INTO {power_table} VALUES(?,?,?,?,?,?,0)",
                      [(base+t, w, s, n, si, ni) for t,w,s,n,si,ni in power if lo <= t <= hi])
        c.execute(f"CREATE TABLE {battery_table}(timestamp REAL,ExternalConnected INTEGER,IsCharging INTEGER,Level INTEGER,Voltage INTEGER,InstantAmperage INTEGER)")
        c.executemany(f"INSERT INTO {battery_table} VALUES(?,?,?,80,12000,?)",
                      [(base+t, ac, charging, current) for t,ac,charging,current in battery if lo <= t <= hi])
        c.execute(f"CREATE TABLE {sleep_table}(timestamp REAL,State INTEGER,Event INTEGER)")
        c.executemany(f"INSERT INTO {sleep_table} VALUES(?,?,?)", [(base+t,s,e) for t,s,e in sleep if lo <= t <= hi])
        c.execute(f"CREATE TABLE {idle_table}(timestamp REAL,Idle INTEGER)")
        c.executemany(f"INSERT INTO {idle_table} VALUES(?,?)", [(base+t,s) for t,s in idle if lo <= t <= hi])

with tempfile.TemporaryDirectory(prefix="maclagmonitor-test-") as d:
    root = Path(d)
    logs = root / "powerlog"
    archives = logs / "Archives"
    archives.mkdir(parents=True)
    db = root / "archive.sqlite"
    database(db, 0, 180)
    (archives / "powerlog_2026-01-01_fixture.PLSQL.gz").write_bytes(gzip.compress(db.read_bytes()))
    db.unlink()
    database(logs / "CurrentPowerlog.PLSQL", 180, 420)
    runtime = root / "runtime"
    runtime.mkdir()
    env = dict(os.environ, MLM_POWERLOG_ROOT=str(logs))
    def query(topic, *args, source=env):
        return json.loads(subprocess.check_output(
            [str(binary), "query", str(runtime), topic, "--from", "2026-01-01T00:00:00Z",
             "--to", "2026-01-01T00:07:00Z", *args, "--json"], env=source))
    before = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()}
    p = query("power", "--group-by", "hour")
    system = p["summary"]["system_load"]
    external = p["summary"]["external_dc_input"]
    assert p["status"] == "partial"
    assert abs(system["energy_wh"] - 1.0) < 1e-9, system
    assert system["covered_seconds"] == 360
    assert external["covered_seconds"] == 240, external
    assert abs(external["energy_wh"] - 0.6) < 1e-9, external
    assert p["coverage_gaps"]["system_load"]["missing_seconds"] == 60
    assert p["coverage_gaps"]["external_dc_input"]["missing_seconds"] == 180
    assert abs(p["summary"]["battery_discharge_estimate"]["energy_wh"] - 0.1) < 1e-9
    assert {s["state"] for s in p["states"]} >= {"awake_active", "awake_idle", "sleep", "dark_wake"}
    assert sum(s["duration_seconds"] for s in p["states"]) == 420
    assert p["point_samples"]["max_observed_system_load_w"] == 10
    missing = query("power", source=dict(env, MLM_POWERLOG_ROOT=str(root / "missing")))
    assert missing["status"] == "unavailable"
    assert missing["summary"]["system_load"]["energy_wh"] is None
    assert before == {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()}
print("PASS: archive overlap, signed input artifact, reset, battery direction, state durations, missing intervals, read-only query")
