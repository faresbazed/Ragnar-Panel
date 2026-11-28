"""Negotiate real TLS through both stages of the shipped HAProxy config."""
from contextlib import ExitStack
from pathlib import Path
import re
import shutil
import socket
import socketserver
import ssl
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


class Backend(socketserver.StreamRequestHandler):
    def handle(self):
        if self.server.reply.startswith(b"HTTP/"):
            while (line := self.rfile.readline()) not in (b"\r\n", b"\n"):
                if not line:  # HAProxy health check
                    return
        self.wfile.write(self.server.reply)


@unittest.skipUnless(shutil.which("haproxy") and shutil.which("openssl"),
                     "requires HAProxy and OpenSSL")
class TestTLSRouting(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        stack = ExitStack()
        cls.addClassCleanup(stack.close)
        tmp = Path(stack.enter_context(tempfile.TemporaryDirectory()))
        cls.cert = tmp / "cert.pem"
        key = tmp / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", key, "-out", cls.cert, "-days", "1", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost"], check=True, capture_output=True)
        pem = tmp / "haproxy.pem"
        pem.write_bytes(cls.cert.read_bytes() + key.read_bytes())

        ports = {}
        for port, reply in {109: b"SSH-2.0-test\r\n", 2053: b"HTTP/1.1 200 Panel\r\n\r\n",
                            10080: b"HTTP/1.1 200 Landing\r\n\r\n",
                            10005: b"HTTP/1.1 101 Switching Protocols\r\n\r\n"}.items():
            server = stack.enter_context(socketserver.ThreadingTCPServer(("127.0.0.1", 0), Backend))
            ports[port] = server.server_address[1]
            server.reply = reply
            threading.Thread(target=server.serve_forever, args=(0.05,), daemon=True).start()
            stack.callback(server.shutdown)

        config = (ROOT / "configs/haproxy.cfg").read_text()
        config = config.replace("/etc/ragnar/certs/haproxy.pem", str(pem))
        config = config.replace("/run/haproxy/admin.sock", str(tmp / "admin.sock"))
        # Remap every endpoint, including unused health checks, away from host services.
        with ExitStack() as reservations:
            def loopback(match):
                port = int(match[1])
                if port not in ports:
                    owner = reservations if port in (80, 443, 10443) else stack
                    sock = owner.enter_context(socket.socket())
                    sock.bind(("127.0.0.1", 0))
                    ports[port] = sock.getsockname()[1]
                return f"127.0.0.1:{ports[port]}"

            config = re.sub(r"(?:127\.0\.0\.1:|:::)(\d+)(?: v4v6)?", loopback, config)
            cfg = tmp / "haproxy.cfg"
            cfg.write_text(config)
        cls.address = ("127.0.0.1", ports[443])
        log = stack.enter_context((tmp / "haproxy.log").open("w+"))
        proxy = subprocess.Popen(["haproxy", "-db", "-f", cfg], stderr=log)
        stack.callback(proxy.wait)
        stack.callback(proxy.terminate)
        deadline = time.monotonic() + 5
        while proxy.poll() is None and time.monotonic() < deadline:
            try:
                with socket.create_connection(cls.address, timeout=0.1):
                    return
            except ConnectionRefusedError:
                time.sleep(0.02)
        log.seek(0)
        raise RuntimeError("HAProxy did not start: " + log.read())

    def route(self, version, *chunks):
        ctx = ssl.create_default_context(cafile=str(self.cert))
        ctx.minimum_version = ctx.maximum_version = version
        with socket.create_connection(self.address, timeout=3) as tcp:
            with ctx.wrap_socket(tcp, server_hostname="localhost") as tls:
                self.assertEqual(tls.version(), version.name.replace("_", "."))
                for i, chunk in enumerate(chunks):
                    if i:
                        time.sleep(0.05)
                    tls.sendall(chunk)
                with tls.makefile("rb") as body:
                    return body.readline().rstrip()

    def test_ssh_banner_without_client_payload(self):
        for version in (ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3):
            with self.subTest(version=version):
                self.assertEqual(self.route(version), b"SSH-2.0-test")

    def test_short_https_requests(self):
        for path, backend in ((b"/panel", b"Panel"), (b"/", b"Landing")):
            with self.subTest(path=path):
                request = b"GET " + path + b" HTTP/1.1\r\nHost: localhost\r\n\r\n"
                self.assertEqual(self.route(ssl.TLSVersion.TLSv1_3, request),
                                 b"HTTP/1.1 200 " + backend)

    def test_websocket_upgrade_across_tls_records(self):
        result = self.route(ssl.TLSVersion.TLSv1_3, b"GET / HTTP/1.1\r\nHost: localhost\r\n",
                            b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
                            b"Sec-WebSocket-Version: 13\r\n"
                            b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
        self.assertEqual(result, b"HTTP/1.1 101 Switching Protocols")


if __name__ == "__main__":
    unittest.main()
