#!/usr/bin/env python3
"""End-to-end test of the SSH WebSocket proxy against a fake SSH server."""
import base64
import hashlib
import os
import socket
import struct
import subprocess
import sys
import threading
import time
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..")


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def run_wsproxy_suite():
    ssh_port = _free_port()
    ws_port = _free_port()
    received = []
    ready = threading.Event()

    def _serve(conn):
        try:
            conn.sendall(b"SSH-2.0-FakeSSH\r\n")
            data = conn.recv(262144)
            if data:
                received.append(data)
                conn.sendall(b"echo:" + data)
            time.sleep(0.3)
        except OSError:
            pass
        finally:
            conn.close()

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", ssh_port))
    srv.listen(16)

    def fake_ssh():
        ready.set()
        while True:
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            threading.Thread(target=_serve, args=(conn,), daemon=True).start()

    threading.Thread(target=fake_ssh, daemon=True).start()
    ready.wait(timeout=2)

    env = dict(os.environ,
               RAGNAR_WSPORT=str(ws_port),
               RAGNAR_SSH_BACKENDS=f"127.0.0.1:{ssh_port}")
    proc = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "core", "wsproxy.py")],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        for _ in range(40):
            try:
                probe = socket.create_connection(("127.0.0.1", ws_port), timeout=0.5)
                probe.close()
                break
            except OSError:
                time.sleep(0.05)

        cli = socket.create_connection(("127.0.0.1", ws_port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        cli.sendall((f"GET /ragnar-sshwsf HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
                     f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                     f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += cli.recv(4096)
        assert b"101" in resp.split(b"\r\n")[0], resp
        accept = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        assert accept in resp, "Sec-WebSocket-Accept mismatch"

        def read_frame(s):
            hdr = b""
            while len(hdr) < 2:
                hdr += s.recv(2 - len(hdr))
            ln = hdr[1] & 0x7F
            if ln == 126:
                ext = b""
                while len(ext) < 2:
                    ext += s.recv(2 - len(ext))
                ln = struct.unpack(">H", ext)[0]
            elif ln == 127:
                ext = b""
                while len(ext) < 8:
                    ext += s.recv(8 - len(ext))
                ln = struct.unpack(">Q", ext)[0]
            payload = bytearray()
            while len(payload) < ln:
                payload.extend(s.recv(ln - len(payload)))
            return bytes(payload)

        banner = read_frame(cli)
        assert banner.startswith(b"SSH-2.0-"), banner

        # send a masked client frame (including odd length for _xor_mask alignment)
        payload = b"hello-ssh-odd"
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        cli.sendall(struct.pack("BB", 0x82, 0x80 | len(payload)) + mask + masked)
        echo = read_frame(cli)
        assert echo == b"echo:" + payload, echo
        assert received and received[0] == payload, received
        cli.close()
        print("FRAMED MODE PASSED (handshake, banner, masked frame round-trip)")

        # ---- large extended-length masked frame (32 KB) -------------------
        received.clear()
        cli_big = socket.create_connection(("127.0.0.1", ws_port), timeout=5)
        cli_big.sendall((f"GET /ragnar-sshwsf HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
                         f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                         f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += cli_big.recv(4096)
        assert read_frame(cli_big).startswith(b"SSH-2.0-")
        big_payload = os.urandom(32771)
        mask = os.urandom(4)
        masked_big = bytes(b ^ mask[i % 4] for i, b in enumerate(big_payload))
        cli_big.sendall(
            struct.pack(">BBH", 0x82, 0x80 | 126, len(big_payload)) + mask + masked_big)
        echo_big = read_frame(cli_big)
        assert echo_big == b"echo:" + big_payload
        cli_big.close()
        print("LARGE FRAMED PAYLOAD PASSED (32 KB vectorized unmask)")

        # ---- payload-app mode: no Sec-WebSocket-Key, raw bytes after 101 --
        cli2 = socket.create_connection(("127.0.0.1", ws_port), timeout=5)
        cli2.sendall(b"GET / HTTP/1.1\r\nHost: example.com\r\n"
                     b"Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += cli2.recv(4096)
        assert b"101" in resp.split(b"\r\n")[0], resp
        banner = cli2.recv(64)
        assert banner.startswith(b"SSH-2.0-"), banner
        cli2.sendall(b"raw-ssh-bytes")
        echo = cli2.recv(64)
        assert echo == b"echo:raw-ssh-bytes", echo
        cli2.close()
        print("RAW PAYLOAD MODE PASSED (no key, 101, raw banner + raw echo)")

        # ---- payload with LF-only line endings ----------------------------
        cli3 = socket.create_connection(("127.0.0.1", ws_port), timeout=5)
        cli3.sendall(b"GET / HTTP/1.0\nHost: x\nUpgrade: websocket\n\n")
        resp = cli3.recv(4096)
        assert b"101" in resp.split(b"\n")[0], resp
        assert cli3.recv(64).startswith(b"SSH-2.0-")
        cli3.close()
        print("LF PAYLOAD MODE PASSED")

        # ---- chained decoy payload ----------------------------------------
        received.clear()
        chained_payload = (
            b"GET / HTTP/1.1\r\nHost: www.hse.ie \r\n\r\n"
            b"CF-RAY / HTTP/1.1\r\nHost: spain.example.com:80\r\n"
            b"Upgrade: websocket\r\nConnection: Keep-Alive\r\n"
            b"User-Agent: test-agent\r\nUpgrade: websocket\r\n\r\n")
        cli4 = socket.create_connection(("127.0.0.1", ws_port), timeout=5)
        cli4.sendall(chained_payload)
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += cli4.recv(4096)
        assert resp.count(b"HTTP/1.1 101") == 1 and b"101" in resp.split(b"\r\n")[0], resp
        assert cli4.recv(64).startswith(b"SSH-2.0-")
        cli4.sendall(b"chained-ok")
        assert cli4.recv(64) == b"echo:chained-ok"
        assert all(b"CF-RAY" not in r and b"hse.ie" not in r for r in received), received
        cli4.close()
        print("CHAINED DECOY PAYLOAD PASSED (decoy + CF-RAY heads swallowed, SSH clean)")

        # ---- same payload, split across two packets -----------------------
        received.clear()
        cli5 = socket.create_connection(("127.0.0.1", ws_port), timeout=5)
        cli5.sendall(chained_payload[:36])
        time.sleep(0.15)
        cli5.sendall(chained_payload[36:])
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += cli5.recv(4096)
        assert b"101" in resp.split(b"\r\n")[0], resp
        assert cli5.recv(64).startswith(b"SSH-2.0-")
        cli5.sendall(b"split-ok")
        assert cli5.recv(64) == b"echo:split-ok"
        assert all(b"CF-RAY" not in r for r in received), received
        cli5.close()
        print("SPLIT CHAINED PAYLOAD PASSED")

        # ---- auto mode, banner-first client -------------------------------
        received.clear()
        cli6 = socket.create_connection(("127.0.0.1", ws_port), timeout=5)
        cli6.sendall(b"CF-RAY / HTTP/1.1\r\nHost: spain.example.com:80\r\n"
                     b"Upgrade: websocket\r\nConnection: Keep-Alive\r\n\r\n")
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += cli6.recv(4096)
        assert b"101" in resp.split(b"\r\n")[0], resp
        cli6.settimeout(0.8)
        body = b""
        try:
            while True:
                d = cli6.recv(4096)
                if not d:
                    break
                body += d
        except socket.timeout:
            pass
        assert body == b"SSH-2.0-FakeSSH\r\n", f"banner must arrive once, got {body!r}"
        cli6.settimeout(5)
        cli6.sendall(b"SSH-2.0-ClientProbe\r\n")
        assert cli6.recv(64) == b"echo:SSH-2.0-ClientProbe\r\n"
        cli6.close()
        print("AUTO MODE BANNER-FIRST PASSED (banner exactly once, stream in sync)")
        print("ALL WSPROXY TESTS PASSED")
    finally:
        proc.terminate()
        proc.wait(timeout=5)
        srv.close()


class WsProxyEndToEnd(unittest.TestCase):
    def test_wsproxy_modes(self):
        run_wsproxy_suite()


if __name__ == "__main__":
    run_wsproxy_suite()
