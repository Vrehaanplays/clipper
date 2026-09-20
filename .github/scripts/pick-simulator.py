#!/usr/bin/env python3
"""Print the UDID of the newest available iPhone simulator on this runner.

The simulator lineup changes with every Xcode release, so the workflow picks one at
runtime rather than pinning a device name that will rot.
"""

import json
import subprocess
import sys


def version_tuple(runtime_identifier: str) -> tuple:
    """`com.apple.CoreSimulator.SimRuntime.iOS-18-2` -> (18, 2)."""
    tail = runtime_identifier.rsplit(".", 1)[-1]
    digits = [part for part in tail.replace("iOS-", "").split("-") if part.isdigit()]
    return tuple(int(part) for part in digits)


def main() -> int:
    raw = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        capture_output=True, text=True, check=True,
    ).stdout
    devices = json.loads(raw)["devices"]

    best = None
    for runtime, entries in devices.items():
        if "iOS" not in runtime:
            continue
        version = version_tuple(runtime)
        for device in entries:
            if not device.get("isAvailable"):
                continue
            if "iPhone" not in device.get("name", ""):
                continue
            key = (version, device["name"])
            if best is None or key > best[0]:
                best = (key, device)

    if best is None:
        print("No available iPhone simulator on this runner", file=sys.stderr)
        subprocess.run(["xcrun", "simctl", "list", "runtimes"], check=False)
        return 1

    key, device = best
    print(f"Using {device['name']} on iOS {'.'.join(str(p) for p in key[0])}", file=sys.stderr)
    print(device["udid"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
