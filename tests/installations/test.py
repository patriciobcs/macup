#!/usr/bin/env python3
"""Real npm + built CLI, isolated home, two prefixes, exact selection, update and removal.

Usage: python3 tests/installations/test.py path/to/MacUp.app/Contents/MacOS/MacUp
Needs the npm registry. Lifecycle scripts, audit and update notifications are disabled in this test.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid


def main():
    app = Path(sys.argv[1]).resolve()
    npm = shutil.which("npm")
    node = shutil.which("node")
    assert app.is_file() and npm and node, "Built app, npm and node are required"
    suite = "macup.installation-e2e." + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="macup-installations-e2e-") as temporary:
        home = Path(temporary).resolve()
        active, other = home / "active prefix", home / ".npm-global"
        for directory in [home / "state", home / "system", home / "bin"]:
            directory.mkdir()
        env = {
            "HOME": str(home), "USER": os.environ.get("USER", "runner"), "SHELL": "/bin/zsh",
            "PATH": ":".join([str(Path(node).parent), str(Path(npm).parent), "/usr/bin", "/bin", "/usr/sbin", "/sbin"]),
            "TMPDIR": tempfile.gettempdir(), "NO_COLOR": "1",
            "MACUP_STATE_DIR": str(home / "state"), "MACUP_DEFAULTS_SUITE": suite,
            "MACUP_DISCOVERY_ROOT": str(home / "system"),
            "npm_config_prefix": str(active), "NPM_CONFIG_PREFIX": str(active),
            "npm_config_cache": str(home / "cache"), "npm_config_ignore_scripts": "true",
            "npm_config_audit": "false", "npm_config_fund": "false", "npm_config_update_notifier": "false",
        }
        if "LLVM_PROFILE_FILE" in os.environ:
            env["LLVM_PROFILE_FILE"] = os.environ["LLVM_PROFILE_FILE"]

        def run(args, expected=0):
            result = subprocess.run([str(arg) for arg in args], env=env, capture_output=True, text=True, timeout=120)
            assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
            return result.stdout

        def version(prefix):
            return json.loads((prefix / "lib/node_modules/is-odd/package.json").read_text())["version"]

        try:
            for prefix in [active, other]:
                run([npm, "install", "--global", "--prefix", prefix, "is-odd@2.0.0", "--ignore-scripts"])
            inventory = json.loads(run([app, "inventory", "npm", "--json"]))["installations"]
            copies = [item for item in inventory if item["name"] == "is-odd"]
            assert len(copies) == 2 and len({item["id"] for item in copies}) == 2, copies
            selected = next(item for item in copies if Path(item["path"]).resolve().is_relative_to(active))
            print("PASS real discovery distinguishes two npm prefixes", flush=True)
            run([app, "upgrade", "--now", "--installation=is-odd", "--dry-run"], expected=64)
            preview = run([app, "upgrade", "--now", "--installation=" + selected["id"], "--dry-run"])
            assert active.name in preview and "--prefix" in preview and version(active) == version(other) == "2.0.0", preview
            print("PASS ambiguous selection rejected and dry-run changes nothing", flush=True)
            output = run([app, "upgrade", "--now", "--installation=" + selected["id"]])
            assert "Updated 1 package" in output and version(active) != "2.0.0" and version(other) == "2.0.0", output
            print("PASS real update changes only the selected prefix", flush=True)
            history = json.loads((home / "state/history.json").read_text())
            assert any(item.get("packageID") == selected["id"] and item["succeeded"] for item in history), history
            inventory = json.loads(run([app, "inventory", "npm", "--json"]))["installations"]
            assert next(item for item in inventory if item["id"] == selected["id"])["version"] == version(active)
            print("PASS rescan and persisted history agree with the installed version", flush=True)
            preview = run([app, "remove", selected["id"], "--dry-run"])
            assert active.name in preview and "--prefix" in preview and version(active) != "2.0.0"
            run([app, "remove", selected["id"]])
            assert not (active / "lib/node_modules/is-odd").exists() and version(other) == "2.0.0"
            print("PASS real removal leaves the other prefix intact", flush=True)
        finally:
            subprocess.run(["/usr/bin/defaults", "delete", suite], capture_output=True)


if __name__ == "__main__":
    main()
