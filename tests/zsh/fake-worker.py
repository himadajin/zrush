#!/usr/bin/env python3
"""Test-only zrush launcher with controllable persistent-worker failures."""

import os
import sys
import threading
import time
from pathlib import Path


REAL = os.environ["ZRUSH_REAL_BIN"]
CONTROL = Path(os.environ["ZRUSH_FAKE_CONTROL"])
STATE = Path(os.environ["ZRUSH_FAKE_STATE"])
COUNT = STATE.with_suffix(".count")
DRAIN_TAIL_BYTES = 8 * 1024 * 1024


def mode() -> str:
    try:
        return CONTROL.read_text().strip()
    except FileNotFoundError:
        return "proxy"


def note(line: str) -> None:
    with STATE.open("a") as out:
        out.write(line + "\n")


def next_session() -> int:
    try:
        value = int(COUNT.read_text()) + 1
    except FileNotFoundError:
        value = 1
    COUNT.write_text(str(value))
    return value


def read_netstring(stream) -> bytes | None:
    digits = bytearray()
    while True:
        byte = stream.read(1)
        if not byte:
            return None if not digits else fail("truncated length")
        if byte == b":":
            break
        if byte < b"0" or byte > b"9":
            fail("invalid length")
        digits += byte
    if not digits or (len(digits) > 1 and digits[0] == ord("0")):
        fail("noncanonical length")
    size = int(digits)
    payload = stream.read(size)
    if len(payload) != size or stream.read(1) != b",":
        fail("truncated payload")
    return payload


def fields(payload: bytes) -> list[bytes]:
    result: list[bytes] = []
    from io import BytesIO

    stream = BytesIO(payload)
    while stream.tell() < len(payload):
        field = read_netstring(stream)
        if field is None:
            fail("missing field")
        result.append(field)
    return result


def netstring(payload: bytes) -> bytes:
    return str(len(payload)).encode() + b":" + payload + b","


def message(*items: bytes) -> bytes:
    return netstring(b"".join(netstring(item) for item in items))


def fail(reason: str):
    note("fake-error " + reason)
    raise SystemExit(18)


def watchdog(control_fd: int) -> None:
    while True:
        try:
            os.read(control_fd, 1)
        except InterruptedError:
            continue
        except OSError:
            os._exit(1)
        os._exit(1)


def worker(control_fd: int) -> None:
    os.set_inheritable(1, False)
    thread = threading.Thread(target=watchdog, args=(control_fd,), daemon=True)
    thread.start()
    session = next_session()
    note(f"start {session}")
    hello = read_netstring(sys.stdin.buffer)
    if hello is None or fields(hello) != [b"hello", b"7"]:
        fail("bad hello")
    sys.stdout.buffer.write(message(b"ready", b"7"))
    sys.stdout.buffer.flush()
    note(f"ready {session}")

    while True:
        payload = read_netstring(sys.stdin.buffer)
        if payload is None:
            note(f"eof {session}")
            if mode() == "drain":
                # Deliberately not a protocol frame. Healthy transport shutdown
                # must keep stdout open and drain bytes without parsing them.
                # Eight MiB is well above the largest default pipe capacity in
                # the supported macOS/Linux matrix, including Linux systems
                # with 64 KiB pages. Flush therefore cannot finish unless the
                # parent actively drains stdout.
                tail = b"x" * DRAIN_TAIL_BYTES
                sys.stdout.buffer.write(tail)
                sys.stdout.buffer.flush()
                note(f"tail {session} {len(tail)}")
            note(f"exit {session}")
            return
        request = fields(payload)
        request_id = request[1].decode("ascii") if len(request) > 1 else "missing"
        note(f"request {session} {request_id}")
        action = mode()
        if action == "hold":
            note(f"hold {session} {request_id}")
            while action == "hold":
                time.sleep(0.01)
                action = mode()
        if action == "die":
            note(f"die {session} {request_id}")
            os._exit(19)
        if action in ("error", "drain"):
            sys.stdout.buffer.write(
                message(b"error", request_id.encode(), b"invalid-request")
            )
            sys.stdout.buffer.flush()
            note(f"{action} {session} {request_id}")
            continue
        fail("unknown control " + action)


if len(sys.argv) < 2:
    os.execv(REAL, [REAL, *sys.argv[1:]])
if sys.argv[1] != "worker" or mode() == "proxy":
    os.execv(REAL, [REAL, *sys.argv[1:]])
if len(sys.argv) != 4 or sys.argv[2] != "--control-fd":
    fail("bad worker argv")
try:
    control = int(sys.argv[3])
except ValueError:
    fail("bad control fd")
if control <= 2:
    fail("bad control fd")
worker(control)
