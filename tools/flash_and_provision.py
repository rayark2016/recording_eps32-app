#!/usr/bin/env python3
"""Flash the common recorder firmware, then provision a new board by UID.

The same script is intentionally safe to rerun: a board already registered
with the same UID and device code reports `already_provisioned` and is not
renumbered.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="ESP32-S3 USB serial/JTAG port")
    parser.add_argument(
        "--registry",
        type=Path,
        default=PROJECT_ROOT / "docs/device-registry.csv",
        help="Registry CSV allocation authority",
    )
    parser.add_argument("--skip-flash", action="store_true", help="Only run UID provisioning")
    args = parser.parse_args()

    if not args.skip_flash:
        subprocess.run(
            ["pio", "run", "--target", "upload", "--upload-port", args.port],
            cwd=PROJECT_ROOT,
            check=True,
        )

    subprocess.run(
        [
            sys.executable,
            str(PROJECT_ROOT / "tools/provision_device.py"),
            "--port",
            args.port,
            "--registry",
            str(args.registry),
            "--auto",
        ],
        cwd=PROJECT_ROOT,
        check=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
