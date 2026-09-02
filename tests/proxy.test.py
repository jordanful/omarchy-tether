#!/usr/bin/env python3
"""Run with: python3 tests/proxy.test.py

Exercises tether-proxy against real sockets, because everything it does is a
syscall and a mock would only prove the mock works.

Test sockets live under $XDG_RUNTIME_DIR rather than /tmp on purpose: /tmp is
world-writable, and the relay refuses a chain like that. That refusal is the
feature, so the tests have to use a directory shaped like the real one.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY = os.path.join(HERE, "..", "tether-proxy")

failures = []


def check(name, actual, expected):
    if actual != expected:
        failures.append(name)
        print("FAIL %s\n  expected %r\n  got      %r" % (name, expected, actual))


def workdir():
    base = os.environ.get("XDG_RUNTIME_DIR")
    if not base:
        print("SKIP: XDG_RUNTIME_DIR is unset, and /tmp cannot pass the chain check")
        sys.exit(0)
    path = os.path.join(base, "tether-proxy-test")
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(path, mode=0o700)
    return path


def serve(sock_path, script, received):
    """A stand-in tetherd. `script` is a list of raw byte blobs to send."""
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    os.chmod(sock_path, 0o755)
    server.listen(1)
    conn, _ = server.accept()
    for blob in script:
        conn.sendall(blob)
    conn.settimeout(2.0)
    try:
        received.append(conn.recv(65536))
    except (socket.timeout, OSError):
        received.append(b"")
    try:
        conn.close()
    finally:
        server.close()


def run_proxy(path, stdin=b"", timeout=10):
    proc = subprocess.Popen([sys.executable, PROXY, path],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    out, _ = proc.communicate(input=stdin, timeout=timeout)
    frames = []
    for line in out.decode(errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            frames.append(json.loads(line))
        except ValueError:
            frames.append({"UNPARSED": line[:80]})
    return proc.returncode, frames


def commands(frames):
    return [f.get("command") for f in frames]


root = workdir()

# ---- the checks that reject an endpoint ------------------------------------

code, frames = run_proxy("relative/path.sock")
check("relative path is refused", (code, frames[0]["reason"]), (2, "path-not-absolute"))

code, frames = run_proxy(os.path.join(root, "absent.sock"))
check("missing socket is refused", (code, frames[0]["reason"]), (2, "socket-missing"))

plain = os.path.join(root, "not-a-socket")
open(plain, "w").close()
code, frames = run_proxy(plain)
check("a regular file is refused", (code, frames[0]["reason"]), (2, "not-a-socket"))

# A socket is worthless if a stranger can replace it, so the whole chain above
# it is checked, not just the socket.
loose = os.path.join(root, "loose")
os.makedirs(loose, mode=0o700)
# Explicit chmod: makedirs' mode is masked by umask, which on a normal login
# turns 0777 into 0755 and quietly makes this test prove nothing.
os.chmod(loose, 0o777)
loose_sock = os.path.join(loose, "t.sock")
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(loose_sock)
srv.listen(1)
code, frames = run_proxy(loose_sock)
check("a group/world-writable ancestor is refused",
      (code, frames[0]["reason"]), (2, "ancestor-writable"))
srv.close()

# ---- relaying --------------------------------------------------------------

sock_path = os.path.join(root, "ok.sock")
received = []
payload = [
    b'{"command":"state_snapshot"}\n',
    b'{"command":"bt_status","enabled":true}\n',
]
thread = threading.Thread(target=serve, args=(sock_path, payload, received), daemon=True)
thread.start()
time.sleep(0.3)
code, frames = run_proxy(sock_path, stdin=b'{"command":"subscribe"}\n')
thread.join(timeout=5)

check("a verified socket relays cleanly", code, 0)
check("it announces itself before relaying", commands(frames)[0], "proxy_ready")
check("frames arrive in order",
      commands(frames)[1:3], ["state_snapshot", "bt_status"])
check("a closed peer is reported", commands(frames)[-1], "proxy_closed")
check("stdin reaches the daemon", received[0], b'{"command":"subscribe"}\n')
# The check QML cannot make at all.
check("peer uid is verified", frames[0]["peer_uid"], os.getuid())

# ---- the ceiling -----------------------------------------------------------

# 300 KB with no delimiter anywhere. This is the case a QML-side length check
# cannot catch, because the frame never finishes arriving.
flood_path = os.path.join(root, "flood.sock")
received2 = []
flood = [b"x" * (300 * 1024)]
thread = threading.Thread(target=serve, args=(flood_path, flood, received2), daemon=True)
thread.start()
time.sleep(0.3)
code, frames = run_proxy(flood_path)
thread.join(timeout=5)

check("a frame with no delimiter ends the relay", code, 3)
check("overflow is reported, not swallowed", commands(frames)[-1], "proxy_overflow")
check("the reported limit is the enforced one", frames[-1]["limit"], 256 * 1024)
# Nothing partial may reach the shell, or the ceiling has leaked.
check("no partial frame is forwarded",
      [c for c in commands(frames) if not str(c).startswith("proxy_")], [])

shutil.rmtree(root, ignore_errors=True)

if failures:
    print("%d failing" % len(failures))
    sys.exit(1)
print("all proxy tests pass")
