#!/usr/bin/env python3
"""Provision one ESP32 Pico Recorder with an immutable PR device code.

The Registry file is the allocation authority. This utility holds an
exclusive lock while it reads the board, reserves a code, provisions the
board, verifies the locked NVS identity, and records the completed allocation.
"""

from __future__ import annotations

import argparse
import csv
import fcntl
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

try:
    import serial
except ImportError as error:  # pragma: no cover - depends on operator host
    raise SystemExit("pyserial is required: python3 -m pip install pyserial") from error


REGISTRY_FIELDS = [
    "device_code", "hardware_uid", "ble_name", "ble_address",
    "firmware_version", "sd_card_id", "owner", "location", "status",
    "last_health_check", "notes",
]
DEVICE_CODE_RE = re.compile(r"^[A-Z0-9-]{3,24}$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="USB serial port, e.g. /dev/cu.usbmodem1201")
    parser.add_argument("--registry", type=Path, required=True, help="CSV Registry allocation authority")
    assignment = parser.add_mutually_exclusive_group(required=True)
    assignment.add_argument(
        "--inspect",
        action="store_true",
        help="Read UID/NVS and compare Registry without writing NVS or editing the CSV",
    )
    assignment.add_argument("--auto", action="store_true", help="Allocate first unused PR-001 through PR-030")
    assignment.add_argument("--device-code", help="Allocate this explicit unused device code")
    assignment.add_argument(
        "--complete-reservation",
        action="store_true",
        help="Write the matching Registry hold/reserved row to this unassigned board",
    )
    return parser.parse_args()


def normalize_code(value: str) -> str:
    code = value.strip().upper()
    if not DEVICE_CODE_RE.fullmatch(code):
        raise ValueError("device code must contain A-Z, 0-9, hyphen; length 3-24")
    return code


def initialize_registry(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=REGISTRY_FIELDS)
        writer.writeheader()
        for number in range(1, 31):
            writer.writerow({"device_code": f"PR-{number:03d}", "ble_name": f"Pico PR-{number:03d}", "status": "unassigned"})


def load_registry(path: Path) -> list[dict[str, str]]:
    if not path.exists() or path.stat().st_size == 0:
        initialize_registry(path)
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None or "device_code" not in reader.fieldnames:
            raise ValueError("Registry must have a device_code column")
        return [{field: row.get(field, "") for field in REGISTRY_FIELDS} for row in reader]


def save_registry(path: Path, rows: list[dict[str, str]]) -> None:
    with tempfile.NamedTemporaryFile("w", newline="", encoding="utf-8", dir=path.parent, delete=False) as handle:
        writer = csv.DictWriter(handle, fieldnames=REGISTRY_FIELDS)
        writer.writeheader()
        writer.writerows(rows)
        temporary = Path(handle.name)
    os.replace(temporary, path)


def read_json_line(board: serial.Serial, command: str, prefix: str, timeout: float = 10.0) -> dict[str, Any]:
    board.reset_input_buffer()
    board.write((command + "\n").encode("ascii"))
    board.flush()
    deadline = time.monotonic() + timeout
    received: list[str] = []
    while time.monotonic() < deadline:
        line = board.readline().decode("utf-8", errors="replace").strip()
        if line:
            received.append(line)
        if not line.startswith(prefix):
            continue
        try:
            return json.loads(line[len(prefix):])
        except json.JSONDecodeError as error:
            raise RuntimeError(f"invalid {prefix[:-1]} response: {line}") from error
    detail = "; ".join(received[-8:]) if received else "no serial data received"
    raise TimeoutError(f"timed out waiting for {prefix[:-1]} ({detail})")


def wait_for_command_loop(board: serial.Serial, grace_seconds: float = 2.0, timeout: float = 35.0) -> None:
    """Wait only when opening USB catches the recorder while it is booting.

    A stable recorder is normally silent and can receive commands immediately.
    If opening the USB port catches boot text, wait for the firmware's explicit
    ready marker before sending a provisioning command. SD initialization can
    take substantially longer than the old fixed 1.2-second delay.
    """
    deadline = time.monotonic() + timeout
    grace_deadline = time.monotonic() + grace_seconds
    saw_boot_output = False
    received: list[str] = []
    while time.monotonic() < deadline:
        line = board.readline().decode("utf-8", errors="replace").strip()
        if line:
            saw_boot_output = True
            received.append(line)
            if line == "READY:RECORDER_SD_V1" or line.startswith("ERR:PDM_INIT_FAILED"):
                return
            continue
        if not saw_boot_output and time.monotonic() >= grace_deadline:
            return
    detail = "; ".join(received[-8:]) if received else "no serial data received"
    raise TimeoutError(f"recorder boot did not reach command loop ({detail})")


def read_identity_when_ready(board: serial.Serial, timeout: float = 35.0) -> dict[str, Any]:
    """Poll IDENTITY until the freshly flashed recorder can accept commands.

    Some USB-serial adapters open after the ESP32 has already printed its boot
    banner, so waiting for text alone is insufficient.  The successful
    IDENTITY response is the actual readiness condition.  Retrying this
    read-only command is safe; provisioning itself is still sent exactly once.
    """
    deadline = time.monotonic() + timeout
    last_error: TimeoutError | None = None
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        try:
            return read_json_line(board, "IDENTITY", "IDENTITY:", timeout=min(3.0, remaining))
        except TimeoutError as error:
            last_error = error
    raise TimeoutError(f"recorder did not become ready for IDENTITY ({last_error})")


def first_unused_code(rows: list[dict[str, str]]) -> str:
    used = {
        row["device_code"]
        for row in rows
        if row["hardware_uid"].strip() or row["status"].strip().lower() not in {"", "unassigned"}
    }
    for number in range(1, 31):
        candidate = f"PR-{number:03d}"
        if candidate not in used:
            return candidate
    raise RuntimeError("all PR-001 through PR-030 have already been allocated")


def assert_code_unused(rows: list[dict[str, str]], code: str) -> None:
    for row in rows:
        if row["device_code"] == code and (row["hardware_uid"].strip() or row["status"].strip().lower() not in {"", "unassigned"}):
            raise RuntimeError(f"{code} is already allocated in the Registry")


def reserved_code_for_uid(rows: list[dict[str, str]], uid: str) -> str:
    """Return the one safe unfinished reservation for this exact board."""
    matches = [row for row in rows if row["hardware_uid"].strip().upper() == uid]
    if len(matches) != 1:
        raise RuntimeError("complete-reservation requires exactly one matching hardware_uid in the Registry")
    row = matches[0]
    if row["status"].strip().lower() not in {"hold", "reserved"}:
        raise RuntimeError("matching Registry row must have status hold or reserved")
    code = normalize_code(row["device_code"])
    if any(other is not row and other["device_code"] == code for other in rows):
        raise RuntimeError(f"Registry has duplicate device_code {code}")
    return code


def upsert_provisioned_row(rows: list[dict[str, str]], identity: dict[str, Any]) -> None:
    code = str(identity["device_code"])
    uid = str(identity["hardware_uid"])
    row = next((item for item in rows if item["device_code"] == code), None)
    if row is None:
        row = {field: "" for field in REGISTRY_FIELDS}
        row["device_code"] = code
        rows.append(row)
    row.update({
        "hardware_uid": uid,
        "ble_name": f"Pico {code}",
        "firmware_version": str(identity.get("firmware_version", "")),
        "status": "provisioned",
        "last_health_check": time.strftime("%Y-%m-%d"),
    })


def main() -> int:
    args = parse_args()
    registry = args.registry.expanduser().resolve()
    registry.parent.mkdir(parents=True, exist_ok=True)
    # This lock makes assignment safe on the designated provisioning Mac.
    lock_path = registry.with_suffix(registry.suffix + ".lock")
    with lock_path.open("a+", encoding="utf-8") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        try:
            rows = load_registry(registry)
            with serial.Serial(args.port, 115200, timeout=0.25) as board:
                wait_for_command_loop(board)
                identity = read_identity_when_ready(board)
                uid = str(identity.get("hardware_uid", "")).upper()
                if not re.fullmatch(r"[0-9A-F]{12}", uid):
                    raise RuntimeError(f"board returned invalid hardware_uid: {uid!r}")
                registered_rows = [
                    row for row in rows if row["hardware_uid"].strip().upper() == uid
                ]
                if args.inspect:
                    if len(registered_rows) > 1:
                        raise RuntimeError(f"hardware_uid {uid} occurs more than once in the Registry")
                    registry_row = registered_rows[0] if registered_rows else None
                    registry_code = registry_row["device_code"] if registry_row else ""
                    print(json.dumps({
                        "status": "registered" if registry_row else "new_uid",
                        "hardware_uid": uid,
                        "device_code": identity.get("device_code", ""),
                        "provision_locked": bool(identity.get("provision_locked")),
                        "registry_device_code": registry_code,
                        "registry_status": registry_row["status"] if registry_row else "",
                        "registry_matches_nvs": bool(registry_row and registry_code == identity.get("device_code")),
                        "suggested_device_code": "" if registry_row else first_unused_code(rows),
                        "registry": str(registry),
                    }))
                    return 0
                if identity.get("provision_locked"):
                    if len(registered_rows) == 1 and (
                        registered_rows[0]["device_code"] == identity.get("device_code")
                    ):
                        print(json.dumps({
                            "status": "already_provisioned",
                            "device_code": identity["device_code"],
                            "hardware_uid": uid,
                            "registry": str(registry),
                        }))
                        return 0
                    raise RuntimeError(f"board is already locked as {identity.get('device_code')}; no change was made")

                has_registered_uid = bool(registered_rows)
                if args.complete_reservation:
                    code = reserved_code_for_uid(rows, uid)
                else:
                    if has_registered_uid:
                        raise RuntimeError(
                            f"hardware_uid {uid} is already in the Registry; "
                            "use --complete-reservation only for its hold/reserved row"
                        )
                    code = first_unused_code(rows) if args.auto else normalize_code(args.device_code)
                    assert_code_unused(rows, code)
                response = read_json_line(board, f"PROVISION:{code}", "PROVISION:")
                if response.get("status") != "success":
                    raise RuntimeError(f"provisioning failed: {response.get('message', response)}")

                verified = read_identity_when_ready(board, timeout=10.0)
                if (verified.get("hardware_uid") != uid or verified.get("device_code") != code or
                        verified.get("provision_locked") is not True):
                    raise RuntimeError("post-provision IDENTITY verification failed")

                upsert_provisioned_row(rows, verified)
                save_registry(registry, rows)
                print(json.dumps({
                    "status": "provisioned",
                    "device_code": code,
                    "hardware_uid": uid,
                    "registry": str(registry),
                }))
                return 0
        finally:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, TimeoutError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
