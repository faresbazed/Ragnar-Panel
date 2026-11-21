"""Loopback DNSTT tunnel test. Set DNSTT_BIN_DIR to built client/server binaries."""
from contextlib import contextmanager
import os
from pathlib import Path
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import unittest


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        while data := self.request.recv(4096):
            self.request.sendall(data)


class DNSRelay(socketserver.BaseRequestHandler):
    def handle(self):
        packet, sock = self.request
        if self.client_address == self.server.upstream:
            self.server.responses.append((len(packet), packet[3] & 15))
            sock.sendto(packet, self.server.client)
        else:
            self.server.client = self.client_address
            # DNSTT appends a single empty OPT record; model recursive resolvers
            # that replace its advertised size or strip EDNS entirely.
            assert packet[-11:-8] == b"\0\0)" and packet[10:12] == b"\0\1"
            if self.server.limit is None:
                packet = packet[:10] + b"\0\0" + packet[12:-11]
            else:
                packet = packet[:-8] + struct.pack("!H", self.server.limit) + packet[-6:]
            sock.sendto(packet, self.server.upstream)


@contextmanager
def serving(server):
    with server:
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join()


def free_address(kind):
    with socket.socket(type=kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()


def endpoint(address):
    return "%s:%d" % address


@contextmanager
def process(args, log):
    with log.open("wb") as fh, subprocess.Popen(args, stdout=fh, stderr=fh) as proc:
        try:
            yield proc
        finally:
            proc.terminate()
            proc.wait(timeout=5)


@unittest.skipUnless(os.getenv("DNSTT_BIN_DIR"), "set DNSTT_BIN_DIR to run the real tunnel")
class SlowDNSResolverTests(unittest.TestCase):
    def test_tunnel_respects_each_resolver_limit_at_mtu_1484(self):
        bindir = Path(os.environ["DNSTT_BIN_DIR"])
        address = free_address(socket.SOCK_DGRAM)
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            key, pub = tmp / "key", tmp / "pub"
            server_log = tmp / "server.log"
            subprocess.run([bindir / "dnstt-server", "-gen-key", "-privkey-file", key,
                            "-pubkey-file", pub], check=True, capture_output=True)
            with serving(socketserver.ThreadingTCPServer(("127.0.0.1", 0), Echo)) as echo:
                with process([bindir / "dnstt-server", "-udp", endpoint(address), "-mtu", "1484",
                              "-privkey-file", key, "t.example.test", endpoint(echo.server_address)], server_log):
                    for limit in (None, 512, 1232, 4096):
                        with self.subTest(advertised=limit):
                            self.exchange(bindir, tmp, pub, server_log, address, limit)

    def exchange(self, bindir, tmp, pub, server_log, address, limit):
        listen = free_address(socket.SOCK_STREAM)
        client_log = tmp / "client.log"
        with serving(socketserver.UDPServer(("127.0.0.1", 0), DNSRelay)) as relay:
            relay.upstream, relay.limit, relay.responses = address, limit, []
            with process([bindir / "dnstt-client", "-udp", endpoint(relay.server_address), "-pubkey-file", pub,
                          "t.example.test", endpoint(listen)], client_log) as client:
                deadline = time.monotonic() + 5
                while True:
                    try:
                        conn = socket.create_connection(listen, timeout=5)
                        break
                    except ConnectionRefusedError:
                        if client.poll() is not None or time.monotonic() >= deadline:
                            self.fail(client_log.read_text())
                        time.sleep(0.05)
                with conn:
                    payload = b"ragnar slowdns\n" * 512
                    conn.sendall(payload)
                    received = bytearray()
                    try:
                        while len(received) < len(payload):
                            chunk = conn.recv(4096)
                            if not chunk:
                                break
                            received.extend(chunk)
                    except TimeoutError:
                        pass
                    rcode = sorted({code for _, code in relay.responses})
                    max_reply = max((size for size, _ in relay.responses), default=0)
                    details = f"advertised={limit}, rcodes={rcode}, max_reply={max_reply}, echoed={len(received)}"
                    print(details, flush=True)
                    self.assertTrue(received == payload, details + "\n" + server_log.read_text()[-2000:])
                    self.assertEqual(rcode, [0], details)
                    self.assertLessEqual(max_reply, min(limit or 512, 1484), details)
                    if limit and limit > 512:
                        self.assertGreater(max_reply, 512, details)


if __name__ == "__main__":
    unittest.main()
