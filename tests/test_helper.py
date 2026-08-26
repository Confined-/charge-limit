#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "helper.sh")
HOOK = os.path.join(HERE, "..", "confined.charge-limit.sh")
SETUP = os.path.join(HERE, "..", "setup-root.sh")

fails = []


def check(name, cond, extra=""):
    if not cond:
        fails.append(f"{name}  {extra}")


def make_sysfs(root):
    bat0 = os.path.join(root, "BAT0")
    os.makedirs(bat0)
    files = {
        "charge_control_end_threshold": "80",
        "charge_control_start_threshold": "75",
        "capacity": "73",
        "status": "Not charging",
    }
    for name, value in files.items():
        with open(os.path.join(bat0, name), "w") as fh:
            fh.write(value + "\n")
    bat1 = os.path.join(root, "BAT1")
    os.makedirs(bat1)
    with open(os.path.join(bat1, "capacity"), "w") as fh:
        fh.write("50\n")


def run(*args, dry=True, extra_env=None):
    env = dict(os.environ)
    if dry:
        env["CHARGE_LIMIT_DRY_RUN"] = "1"
    if extra_env:
        env.update(extra_env)
        if "BATTERY_SYSFS" in extra_env:
            env["CHARGE_LIMIT_TEST_MODE"] = "1"
    return subprocess.run(
        ["bash", HELPER, *args], capture_output=True, text=True, env=env
    )


def main():
    helper_src = open(HELPER).read()
    qml_path = os.path.join(HERE, "..", "BarWidget.qml")
    qml_src = open(qml_path).read()
    import re
    m_ver = re.search(r'^VERSION="([^"]+)"', helper_src, re.M)
    m_qml = re.search(r'helperVersion:\s*"([^"]+)"', qml_src)
    check("version contract: helper has VERSION", m_ver is not None)
    check("version contract: QML has helperVersion", m_qml is not None)
    if m_ver and m_qml:
        check(
            "version contract: QML expectation matches helper",
            m_ver.group(1) == m_qml.group(1),
            f"helper={m_ver.group(1)} qml={m_qml.group(1)}",
        )

    with tempfile.TemporaryDirectory() as tmp:
        fake_sys = os.path.join(tmp, "sys")
        make_sysfs(fake_sys)
        env = {"BATTERY_SYSFS": fake_sys}

        r = run("get", dry=False, extra_env=env)
        check("get exits 0", r.returncode == 0, r.stderr)
        data = json.loads(r.stdout)
        check("get ok true", data["ok"] is True)
        check("get supported", data["supported"] is True)
        check("get skips battery without limit attr", len(data["batteries"]) == 1, r.stdout)
        bat = data["batteries"][0]
        check("get battery fields", bat["name"] == "BAT0" and bat["end"] == 80 and bat["start"] == 75 and bat["capacity"] == 73, r.stdout)
        check("get charging false", data["charging"] is False)
        check("get reports installed flag", isinstance(data.get("installed"), bool))

        empty = run("get", dry=False, extra_env={"BATTERY_SYSFS": os.path.join(tmp, "empty")})
        edata = json.loads(empty.stdout)
        check("get unsupported tree", edata["supported"] is False and edata["batteries"] == [], empty.stdout)

        charging_tree = os.path.join(tmp, "charging", "BAT0")
        os.makedirs(charging_tree)
        for name, value in {"charge_control_end_threshold": "80", "capacity": "40", "status": "Charging"}.items():
            with open(os.path.join(charging_tree, name), "w") as fh:
                fh.write(value + "\n")
        cdata = json.loads(run("get", dry=False, extra_env={"BATTERY_SYSFS": os.path.join(tmp, "charging")}).stdout)
        check("get charging true", cdata["charging"] is True and cdata["pct"] == 40)

        renv = dict(env)
        r = run("set", "abc", extra_env=renv)
        check("set rejects non-numeric", r.returncode == 2 and json.loads(r.stdout)["ok"] is False)
        r = run("set", "19", extra_env=renv)
        check("set rejects below range", r.returncode == 2)
        r = run("set", "101", extra_env=renv)
        check("set rejects above range", r.returncode == 2)
        r = run("set", extra_env=renv)
        check("set rejects missing arg", r.returncode == 2)
        r = run("set", "60", "70", extra_env=renv)
        check("set rejects start above end", r.returncode == 2)

        r = run("set", "80", extra_env=renv)
        data = json.loads(r.stdout)
        check("set dry-run ok", data["ok"] is True, r.stdout + r.stderr)
        bats = data.get("batteries", [])
        check("set dry-run end", len(bats) >= 1 and bats[0].get("end") == 80, r.stdout)
        check(
            "set dry-run auto start",
            bats and bats[0].get("start") in (75, None),
            f"start={bats[0].get('start') if bats else None}",
        )

        r = run("set", "70", "60", extra_env=renv)
        data = json.loads(r.stdout)
        check("set pair dry-run ok", data["ok"] is True, r.stdout + r.stderr)
        bats = data.get("batteries", [])
        check(
            "set pair values",
            len(bats) >= 1 and bats[0].get("end") == 70 and bats[0].get("start") == 60,
            r.stdout,
        )

        r = run("set", "100", "0", extra_env=renv)
        data = json.loads(r.stdout)
        check("set disable pair ok", data["ok"] is True, r.stdout)

        rollback_tree = os.path.join(tmp, "rollback")
        for name in ("BAT0", "BAT1"):
            d = os.path.join(rollback_tree, name)
            os.makedirs(d)
            with open(os.path.join(d, "charge_control_end_threshold"), "w") as fh:
                fh.write("80\n")
            with open(os.path.join(d, "charge_control_start_threshold"), "w") as fh:
                fh.write("75\n")
        os.chmod(os.path.join(rollback_tree, "BAT1", "charge_control_end_threshold"), 0o444)
        renv_nb = {"BATTERY_SYSFS": rollback_tree, "CHARGE_LIMIT_TEST_MODE": "1"}
        r = subprocess.run(
            ["bash", HELPER, "set", "70", "60"],
            capture_output=True, text=True,
            env={**os.environ, **renv_nb},
        )
        data = json.loads(r.stdout)
        check("partial failure reported", r.returncode == 3 and data["ok"] is False, r.stdout)
        check("failure mentions rollback", "rolled back" in data.get("error", ""), r.stdout)
        bat0_end_after = open(os.path.join(rollback_tree, "BAT0", "charge_control_end_threshold")).read().strip()
        bat0_start_after = open(os.path.join(rollback_tree, "BAT0", "charge_control_start_threshold")).read().strip()
        check("BAT0 end rolled back", bat0_end_after == "80", f"end={bat0_end_after}")
        check("BAT0 start rolled back", bat0_start_after == "75", f"start={bat0_start_after}")
        os.chmod(os.path.join(rollback_tree, "BAT1", "charge_control_end_threshold"), 0o644)

        order_tree = os.path.join(tmp, "order")
        for name, (end_v, start_v) in {"BAT0": ("70", "60"), "BAT1": ("80", "75")}.items():
            d = os.path.join(order_tree, name)
            os.makedirs(d)
            with open(os.path.join(d, "charge_control_end_threshold"), "w") as fh:
                fh.write(end_v + "\n")
            with open(os.path.join(d, "charge_control_start_threshold"), "w") as fh:
                fh.write(start_v + "\n")
        os.chmod(os.path.join(order_tree, "BAT1", "charge_control_end_threshold"), 0o444)
        r = subprocess.run(
            ["bash", HELPER, "set", "80", "75"],
            capture_output=True, text=True,
            env={**os.environ, "BATTERY_SYSFS": order_tree, "CHARGE_LIMIT_TEST_MODE": "1"},
        )
        data = json.loads(r.stdout)
        check("higher-start failure reported", r.returncode == 3 and data["ok"] is False, r.stdout)
        bat0_end_after = open(os.path.join(order_tree, "BAT0", "charge_control_end_threshold")).read().strip()
        bat0_start_after = open(os.path.join(order_tree, "BAT0", "charge_control_start_threshold")).read().strip()
        check("60/70 end restored across raising transition", bat0_end_after == "70", f"end={bat0_end_after}")
        check("60/70 start restored across raising transition", bat0_start_after == "60", f"start={bat0_start_after}")
        os.chmod(os.path.join(order_tree, "BAT1", "charge_control_end_threshold"), 0o644)

    def parse_write_events(stderr):
        events = []
        import re
        for line in stderr.splitlines():
            m = re.match(r"dry-run: echo (\d+) > .*(charge_control_(start|end)_threshold)", line)
            if m:
                events.append((m.group(3), int(m.group(1))))
        return events

    def assert_invariant_walk(events, start0, end0, label):
        s, e = start0, end0
        for target, val in events:
            if target == "start":
                s = val
            else:
                e = val
            check(
                f"{label}: intermediate start<end after {target}={val}",
                s < e,
                f"state start={s} end={e}",
            )

    with tempfile.TemporaryDirectory() as trace_tmp:
        d = os.path.join(trace_tmp, "BAT0")
        os.makedirs(d)
        with open(os.path.join(d, "charge_control_end_threshold"), "w") as fh:
            fh.write("70\n")
        with open(os.path.join(d, "charge_control_start_threshold"), "w") as fh:
            fh.write("60\n")
        tenv = {"BATTERY_SYSFS": trace_tmp}

        r = run("set", "80", "75", extra_env=tenv)
        check("equality-boundary transition ok", json.loads(r.stdout)["ok"] is True, r.stdout + r.stderr)
        assert_invariant_walk(parse_write_events(r.stderr), 60, 70, "60/70 -> 75/80")

        r = run("set", "45", "40", extra_env=tenv)
        check("descending transition ok", json.loads(r.stdout)["ok"] is True, r.stdout + r.stderr)
        assert_invariant_walk(parse_write_events(r.stderr), 60, 70, "60/70 -> 40/45")

        r = run("set", "100", "0", extra_env=tenv)
        check("disable transition ok", json.loads(r.stdout)["ok"] is True, r.stdout + r.stderr)
        assert_invariant_walk(parse_write_events(r.stderr), 60, 70, "60/70 -> off")

        with open(os.path.join(d, "charge_control_end_threshold"), "w") as fh:
            fh.write("80\n")
        with open(os.path.join(d, "charge_control_start_threshold"), "w") as fh:
            fh.write("75\n")
        src = subprocess.run(
            [
                "bash", "-c",
                f'export BATTERY_SYSFS={trace_tmp} CHARGE_LIMIT_TEST_MODE=1 CHARGE_LIMIT_DRY_RUN=1; '
                f'set -- __lib__; source {HELPER}; '
                'restore_pair "$BATTERY_SYSFS/BAT0" 60 70',
            ],
            capture_output=True, text=True,
        )
        assert_invariant_walk(parse_write_events(src.stderr), 75, 80, "restore (75,80) -> (60,70)")

        r = run("version", dry=False)
        vdata = json.loads(r.stdout)
        check("version ok", vdata["ok"] is True and vdata["version"] == "7", r.stdout)
        src2 = subprocess.run(
            [
                "bash", "-c",
                f'export BATTERY_SYSFS={trace_tmp} CHARGE_LIMIT_TEST_MODE=1 CHARGE_LIMIT_DRY_RUN=1; '
                f'set -- __lib__; source {HELPER}; '
                'APPLIED_START=""; write_pair "$BATTERY_SYSFS/BAT0" 70 60 && restore_pair "$BATTERY_SYSFS/BAT0" 75 80',
            ],
            capture_output=True, text=True,
        )
        assert_invariant_walk(parse_write_events(src2.stderr), 60, 70, "write_pair+restore_pair round trip")

        root_env_test = subprocess.run(
            ["bash", HELPER, "get"],
            capture_output=True, text=True,
            env={**os.environ, "BATTERY_SYSFS": fake_sys},
        )
        check("unprivileged get works", root_env_test.returncode == 0)

        r = run("version", dry=False)
        vdata = json.loads(r.stdout)
        check("version ok", vdata["ok"] is True and vdata["version"] == "7", r.stdout)

        state = os.path.join(tmp, "state")
        senv = {"XDG_STATE_HOME": state}
        r = run("save-state", "on", extra_env=senv)
        check("save-state on ok", json.loads(r.stdout)["ok"] is True, r.stderr)
        limit_file = os.path.join(state, "battery-charge-limit", "limit")
        check("save-state on writes on", open(limit_file).read().strip() == "on")
        r = run("save-state", "off", extra_env=senv)
        check("save-state off writes off", open(limit_file).read().strip() == "off")
        r = run("save-state", "999", extra_env=senv)
        check("save-state rejects bad value", r.returncode == 2)
        r = run("save-state", "maybe", extra_env=senv)
        check("save-state rejects invalid", r.returncode == 2, r.stdout)

        marker = os.path.join(state, "battery-charge-limit", "apply-at-boot")
        r = run("boot-pref", "on", extra_env=senv)
        check("boot-pref on creates marker", os.path.exists(marker), r.stderr)
        r = run("boot-pref", "off", extra_env=senv)
        check("boot-pref off removes marker", not os.path.exists(marker))

        hook_sim = subprocess.run(
            [
                "bash", "-c",
                f"export XDG_STATE_HOME={state}; "
                f"printf '75 65\\n' > {state}/battery-charge-limit/limit; "
                f"touch {state}/battery-charge-limit/apply-at-boot; "
                f"CHARGE_LIMIT_DRY_RUN= bash -n {HOOK} && echo SYNTAX_OK",
            ],
            capture_output=True,
            text=True,
        )
        check("hook script syntax", "SYNTAX_OK" in hook_sim.stdout, hook_sim.stderr)

    syntax = subprocess.run(["bash", "-n", HELPER], capture_output=True, text=True)
    check("helper.sh syntax", syntax.returncode == 0, syntax.stderr)
    setup_syntax = subprocess.run(["bash", "-n", SETUP], capture_output=True, text=True)
    check("setup-root.sh syntax", setup_syntax.returncode == 0, setup_stderr := setup_syntax.stderr)

    if fails:
        print("\n".join(f"FAIL {f}" for f in fails))
        print(f"\n{len(fails)} failed")
        return 1
    print("ALL TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
