#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "helper.sh")

fails = []


def check(name, cond, extra=""):
    if not cond:
        fails.append(f"{name}  {extra}")


def run(*args, dry=True):
    env = dict(os.environ)
    if dry:
        env["CHARGE_LIMIT_DRY_RUN"] = "1"
    return subprocess.run(
        ["bash", HELPER, *args], capture_output=True, text=True, env=env
    )


def main():
    r = run("get", dry=False)
    check("get exits 0", r.returncode == 0, r.stderr)
    data = json.loads(r.stdout)
    check("get ok true", data["ok"] is True)
    check("get reports a battery", data["supported"] is True and data["batteries"], r.stdout)
    check("get reports installed flag", isinstance(data.get("installed"), bool))

    r = run("version", dry=False)
    vdata = json.loads(r.stdout)
    check("version ok", vdata["ok"] is True and vdata["version"] == "2", r.stdout)

    r = run("set", "abc")
    check("set rejects non-numeric", r.returncode == 2 and json.loads(r.stdout)["ok"] is False)
    r = run("set", "19")
    check("set rejects below range", r.returncode == 2)
    r = run("set", "101")
    check("set rejects above range", r.returncode == 2)
    r = run("set")
    check("set rejects missing arg", r.returncode == 2)

    r = run("set", "80")
    data = json.loads(r.stdout)
    check("set dry-run ok", data["ok"] is True, r.stdout + r.stderr)
    bats = data.get("batteries", [])
    check("set dry-run reports battery", len(bats) >= 1 and bats[0].get("end") == 80, r.stdout)

    r = run("set", "70", "60")
    data = json.loads(r.stdout)
    check("set pair dry-run ok", data["ok"] is True, r.stdout + r.stderr)
    bats = data.get("batteries", [])
    check(
        "set pair values",
        len(bats) >= 1 and bats[0].get("end") == 70 and bats[0].get("start") == 60,
        r.stdout,
    )

    r = run("set", "60", "70")
    check("set rejects start above end", r.returncode == 2 and json.loads(r.stdout)["ok"] is False)

    r = run("set", "100", "0")
    data = json.loads(r.stdout)
    check("set disable pair ok", data["ok"] is True, r.stdout)

    with tempfile.TemporaryDirectory() as state:
        os.environ["XDG_STATE_HOME"] = state

        r = run("save-state", "75")
        check("save-state ok", json.loads(r.stdout)["ok"] is True, r.stderr)
        limit_file = os.path.join(state, "battery-charge-limit", "limit")
        check(
            "save-state wrote value",
            os.path.exists(limit_file) and open(limit_file).read().split() == ["75", "0"],
        )

        r = run("save-state", "75", "65")
        check(
            "save-state wrote pair",
            open(limit_file).read().split() == ["75", "65"],
        )

        r = run("save-state", "999")
        check("save-state rejects bad value", r.returncode == 2)

        marker = os.path.join(state, "battery-charge-limit", "apply-at-boot")
        r = run("boot-pref", "on")
        check("boot-pref on creates marker", os.path.exists(marker), r.stderr)
        r = run("boot-pref", "off")
        check("boot-pref off removes marker", not os.path.exists(marker))

    hook_test = subprocess.run(
        ["bash", "-c", f"CHARGE_LIMIT_DRY_RUN= bash -n {os.path.join(HERE, '..', 'post-boot.sh')}"],
        capture_output=True,
        text=True,
    )
    check("post-boot.sh syntax valid", hook_test.returncode == 0, hook_test.stderr)
    setup_test = subprocess.run(
        ["bash", "-n", os.path.join(HERE, "..", "setup-root.sh")],
        capture_output=True,
        text=True,
    )
    check("setup-root.sh syntax valid", setup_test.returncode == 0, setup_test.stderr)

    if fails:
        print("\n".join(f"FAIL {f}" for f in fails))
        print(f"\n{len(fails)} failed")
        return 1
    print("ALL TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
