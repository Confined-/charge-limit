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
    return subprocess.run(
        ["bash", HELPER, *args], capture_output=True, text=True, env=env
    )


def main():
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

        r = run("version", dry=False)
        vdata = json.loads(r.stdout)
        check("version ok", vdata["ok"] is True and vdata["version"] == "3", r.stdout)

        state = os.path.join(tmp, "state")
        senv = {"BATTERY_SYSFS": fake_sys, "XDG_STATE_HOME": state}
        r = run("save-state", "75", extra_env=senv)
        check("save-state ok", json.loads(r.stdout)["ok"] is True, r.stderr)
        limit_file = os.path.join(state, "battery-charge-limit", "limit")
        check("save-state default start", open(limit_file).read().split() == ["75", "0"])

        r = run("save-state", "75", "65", extra_env=senv)
        check("save-state wrote pair", open(limit_file).read().split() == ["75", "65"])

        r = run("save-state", "999", extra_env=senv)
        check("save-state rejects bad value", r.returncode == 2)

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
