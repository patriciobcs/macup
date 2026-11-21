#!/usr/bin/env python3
"""Patch a disposable copy of signed Node through the built MacUp CLI. Requires nodejs.org.

The host runtime is only read; npm/global package markers in the temporary prefix must survive.
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
    source = Path(shutil.which("node")).resolve()
    before = subprocess.check_output([source, "--version"], text=True).strip()
    suite = "macup.runtime-e2e." + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="macup-runtime-e2e-") as temporary:
        home = Path(temporary).resolve()
        prefix = home / ".local/share/node" / before
        (prefix / "bin").mkdir(parents=True)
        shutil.copy2(source, prefix / "bin/node")
        marker = prefix / "lib/node_modules/keep-me/package.json"
        marker.parent.mkdir(parents=True)
        marker.write_text('{"name":"keep-me","version":"1.2.3"}')
        (prefix / "include/node").mkdir(parents=True)
        (prefix / "include/node/old-marker.h").write_text("old headers")
        (home / "system").mkdir()
        env = {
            "HOME": str(home), "USER": os.environ.get("USER", "runner"), "SHELL": "/bin/zsh",
            "PATH": str(prefix / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "MACUP_USER_PATH": str(prefix / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": tempfile.gettempdir(), "NO_COLOR": "1",
            "MACUP_STATE_DIR": str(home / "state"), "MACUP_DEFAULTS_SUITE": suite,
            "MACUP_DISCOVERY_ROOT": str(home / "system"),
        }
        def run(args):
            result = subprocess.run([str(app)] + args, env=env, capture_output=True, text=True, timeout=180)
            assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
            return result.stdout
        try:
            items = json.loads(run(["inventory", "runtimes", "--json"]))["installations"]
            assert len(items) == 1, items
            item = items[0]
            assert item["latest"].split(".")[0] == before.lstrip("v").split(".")[0], item
            if item["latest"] == before.lstrip("v"):
                print("SKIP real Node patch: installed runtime already matches the latest same-major release")
                return
            output = run(["upgrade", "--now", "--installation=" + item["id"]])
            assert "Verified checksum, signing identity and runtime version" in output, output
            after = subprocess.check_output([prefix / "bin/node", "--version"], text=True).strip()
            assert after == "v" + item["latest"] and after != before, (before, after, output)
            assert json.loads(marker.read_text())["version"] == "1.2.3"
            assert (prefix / "include/node/node.h").is_file()
            assert not list((prefix / "bin").glob(".macup-*"))
            assert subprocess.check_output([source, "--version"], text=True).strip() == before
            print("PASS real signed Node patch", before, "→", after)
            print("PASS vendor checksum, signature, version verification, headers, global-package preservation and host isolation")
        finally:
            subprocess.run(["/usr/bin/defaults", "delete", suite], capture_output=True)


if __name__ == "__main__":
    main()
