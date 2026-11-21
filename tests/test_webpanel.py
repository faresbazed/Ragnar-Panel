"""Smoke tests for web/webpanel.py against a fixture RAGNAR_DIR.

Starts the real server (plain HTTP - the fixture has no certs) on a
scratch port and drives it with urllib: login flow, dashboard, user
create/list over HTTP, and the Xray links page.
"""
import http.cookiejar
import html
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
import urllib.error

ROOT = os.path.join(os.path.dirname(__file__), "..")
PORT = 18099
BASE_URL = f"http://127.0.0.1:{PORT}"


class WebPanelSmoke(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="ragnar-web-")
        env = dict(os.environ, RAGNAR_DIR=cls.tmp,
                   RAGNAR_WEB_PORT=str(PORT),
                   RAGNAR_HOST="203.0.113.7", RAGNAR_DOMAIN="example.com")
        # seed fixture users through the core itself
        seed = subprocess.run(
            [sys.executable, "-c", """
import sys; sys.path.insert(0, 'core')
import ragnar
ragnar.ssh_add('webuser', 'pw123456', 30, 0, 0)
ragnar.xray_add('xuser', 30, 0, 0)
ragnar.zivpn_add('zuser', 'zpw12345', 30)
for name in ('sales&support', 'sales#support', 'sales+support', 'sales support', 'sales"<support>'):
    ragnar.xray_add(name, 30, 0, 0)
    ragnar.zivpn_add(name, 'zpw12345', 30)
"""], cwd=ROOT, env=env, capture_output=True, text=True)
        assert seed.returncode == 0, seed.stderr
        subprocess.run([sys.executable, os.path.join(ROOT, "web", "webpanel.py"),
                        "--set-password", "admin", "testpass123"],
                       env=env, capture_output=True, text=True, check=True)
        cls.proc = subprocess.Popen(
            [sys.executable, os.path.join(ROOT, "web", "webpanel.py")],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True)
        no_proxy_opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}))
        for _ in range(50):
            try:
                no_proxy_opener.open(BASE_URL + "/login", timeout=1).close()
                break
            except Exception:
                time.sleep(0.2)
        else:
            raise RuntimeError("web panel did not start: "
                               + cls.proc.stdout.read())

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(timeout=5)
        if cls.proc.stdout:
            cls.proc.stdout.close()

    def opener(self):
        cj = http.cookiejar.CookieJar()
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(cj))

    def login(self, op):
        data = urllib.parse.urlencode(
            {"username": "admin", "password": "testpass123"}).encode()
        return op.open(BASE_URL + "/login", data=data)

    def test_login_flow_and_pages(self):
        import urllib.parse
        op = self.opener()
        # dashboard redirects to login when unauthenticated
        page = op.open(BASE_URL + "/login").read().decode()
        self.assertIn("RAGNAR", page)
        self.assertIn('class="login-split"', page)
        # wrong password rejected
        bad = urllib.parse.urlencode(
            {"username": "admin", "password": "nope"}).encode()
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            op.open(BASE_URL + "/login", data=bad)
        self.assertEqual(ctx.exception.code, 401)
        # right password -> dashboard
        self.login(op)
        dash = op.open(BASE_URL + "/").read().decode()
        self.assertIn("Dashboard", dash)
        self.assertIn('class="topbar"', dash)
        self.assertIn('id="theme-toggle"', dash)
        self.assertIn('class="node-strip"', dash)
        self.assertIn('class="nav-icon"', dash)
        self.assertIn('aria-current="page"', dash)
        self.assertIn('class="metric-icon"', dash)
        self.assertIn('id="main"', dash)
        self.assertIn("Service status", dash)
        self.assertIn("grid-template-columns", dash)
        self.assertIn("Bandwidth today", dash)
        self.assertIn("Bandwidth month", dash)
        self.assertNotIn("RX ", dash)
        self.assertNotIn("TX ", dash)
        # seeded users visible
        ssh_page = op.open(BASE_URL + "/ssh").read().decode()
        self.assertIn("webuser", ssh_page)
        # create a user over HTTP (needs the CSRF token from the form)
        csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', ssh_page).group(1)
        form = urllib.parse.urlencode(
            {"csrf": csrf, "op": "create", "user": "made-by-web",
             "password": "pw999999", "days": "15", "quota": "0",
             "iplimit": "0"}).encode()
        op.open(BASE_URL + "/ssh/action", data=form)
        ssh_page = op.open(BASE_URL + "/ssh").read().decode()
        self.assertIn("made-by-web", ssh_page)
        # xray links page carries real URIs
        links = op.open(BASE_URL + "/xray/links?u=xuser").read().decode()
        self.assertIn("vless://", links)
        self.assertIn("anytls://", links)
        xray_page = op.open(BASE_URL + "/xray").read().decode()
        self.assertIn('name="uuid"', xray_page)
        self.assertIn("Auto-generated if blank", xray_page)

    def test_reserved_account_links(self):
        op = self.opener()
        self.login(op)
        names = ('sales&support', 'sales#support', 'sales+support',
                 'sales support', 'sales"<support>')
        for kind in ('zivpn', 'xray'):
            page = op.open(BASE_URL + '/' + kind).read().decode()
            for name in names:
                row = next(row for row in page.split('<tr ')
                           if f'<b>{html.escape(name)}</b>' in row)
                for href in re.findall(r'href="([^"]+)"', row):
                    href = html.unescape(href)
                    with self.subTest(kind=kind, name=name, href=href):
                        response = op.open(BASE_URL + urllib.parse.quote(
                            href, safe='/?=&%#+'))
                        body = response.read().decode()
                        if name == 'sales&support':
                            edit_form = 'name="days"' in body
                            print(f'{kind}: GET {href} -> HTTP {response.status}; '
                                  f'edit_form={edit_form}; '
                                  f'not_found={"not found" in body}')
                        self.assertEqual(urllib.parse.parse_qs(
                            urllib.parse.urlsplit(href).query), {'u': [name]})
                        self.assertNotIn('not found', body)
                        if '/edit?' in href:
                            self.assertIn('name="days"', body)
                            self.assertIn('value="' + html.escape(name) + '"', body)

    def test_custom_uuid_xray_create_action(self):
        custom_uuid = "123e4567-e89b-42d3-a456-426614174000"
        code = f"""
import sys
sys.path[:0] = ['core', 'web']
import ragnar, webpanel
webpanel.ragnar.apply_configs = lambda: None
msg = webpanel.do_user_action('xray', {{
    'op': 'create', 'user': 'custom-web', 'days': '30',
    'quota': '0', 'iplimit': '0', 'uuid': '{custom_uuid}'
}})
assert msg == "User 'custom-web' created.", msg
assert ragnar.load_xray()['custom-web']['uuid'] == '{custom_uuid}'
"""
        env = dict(os.environ, RAGNAR_DIR=self.tmp)
        result = subprocess.run([sys.executable, "-c", code], cwd=ROOT,
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_edit_flows(self):
        import urllib.parse
        op = self.opener()
        self.login(op)
        dash = op.open(BASE_URL + "/").read().decode()
        self.assertIn("tblwrap", dash)  # scrollable table wrapper
        # --- xray edit: quota + extend --------------------------------
        page = op.open(BASE_URL + "/xray/edit?u=xuser").read().decode()
        self.assertIn("Edit", page)
        csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', page).group(1)
        form = urllib.parse.urlencode(
            {"csrf": csrf, "user": "xuser", "days": "10", "quota": "50",
             "iplimit": "3", "enabled": "yes"}).encode()
        op.open(BASE_URL + "/xray/edit", data=form)
        lst = op.open(BASE_URL + "/xray").read().decode()
        self.assertIn("50.00 GB", lst)          # quota applied
        self.assertIn("40d", lst)               # 30 + 10 days
        self.assertIn(">Edit</a>", lst)         # edit button in the row
        # --- zivpn edit: extend + password ----------------------------
        page = op.open(BASE_URL + "/zivpn/edit?u=zuser").read().decode()
        csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', page).group(1)
        form = urllib.parse.urlencode(
            {"csrf": csrf, "user": "zuser", "days": "5",
             "password": "newpass99", "enabled": "yes"}).encode()
        op.open(BASE_URL + "/zivpn/edit", data=form)
        lst = op.open(BASE_URL + "/zivpn").read().decode()
        self.assertIn("35d", lst)               # 30 + 5 days
        # --- ssh edit page renders with all fields --------------------
        page = op.open(BASE_URL + "/ssh/edit?u=webuser").read().decode()
        for field in ('name="days"', 'name="quota"', 'name="iplimit"',
                      'name="password"', 'name="enabled"'):
            self.assertIn(field, page)

    def test_api_status_ssh_info_and_quick_actions(self):
        import gzip
        import json
        import urllib.parse
        op = self.opener()
        self.login(op)
        # /api/status JSON telemetry
        raw = op.open(BASE_URL + "/api/status").read().decode()
        payload = json.loads(raw)
        self.assertIn("info", payload)
        self.assertIn("services", payload)
        self.assertIn("stats", payload)
        self.assertIn("cpu_pct", payload["info"])
        # /api/update-status JSON endpoint
        upd_raw = op.open(BASE_URL + "/api/update-status").read().decode()
        upd_payload = json.loads(upd_raw)
        self.assertIn("version", upd_payload)
        self.assertIn("status", upd_payload)
        self.assertIn("tail", upd_payload)
        # /ssh/info connection sheet
        info_page = op.open(BASE_URL + "/ssh/info?u=webuser").read().decode()
        self.assertIn("Connection details for webuser", info_page)
        self.assertIn("HTTP Custom / NPV Payload", info_page)
        # gzip compression when requested
        req = urllib.request.Request(
            BASE_URL + "/", headers={"Accept-Encoding": "gzip"})
        with op.open(req) as resp:
            self.assertEqual(resp.headers.get("Content-Encoding"), "gzip")
            html_body = gzip.decompress(resp.read()).decode()
            self.assertIn("Dashboard", html_body)
        # +30d renew30 and disable/enable on a dedicated zivpn user
        zpage = op.open(BASE_URL + "/zivpn").read().decode()
        csrf = re.search(r'name="csrf" value="([0-9a-f]+)"', zpage).group(1)
        op.open(BASE_URL + "/zivpn/action", data=urllib.parse.urlencode(
            {"csrf": csrf, "op": "create", "user": "zquick",
             "password": "zpw99999", "days": "10"}).encode())
        zpage_off = op.open(BASE_URL + "/zivpn/action",
                            data=urllib.parse.urlencode(
                                {"csrf": csrf, "op": "disable",
                                 "user": "zquick"}).encode()).read().decode()
        self.assertIn(">disabled<", zpage_off)
        op.open(BASE_URL + "/zivpn/action", data=urllib.parse.urlencode(
            {"csrf": csrf, "op": "enable", "user": "zquick"}).encode())
        zpage_ext = op.open(BASE_URL + "/zivpn/action",
                            data=urllib.parse.urlencode(
                                {"csrf": csrf, "op": "renew30",
                                 "user": "zquick"}).encode()).read().decode()
        self.assertIn("extended by 30 days", zpage_ext)
        self.assertIn("40d", zpage_ext)

    def test_base_path_mode(self):
        """The HAProxy-fronted setup: app under /panel, loopback, HTTP."""
        import urllib.parse
        env = dict(os.environ, RAGNAR_DIR=self.tmp,
                   RAGNAR_WEB_PORT="18100", RAGNAR_WEB_BIND="127.0.0.1",
                   RAGNAR_WEB_NO_TLS="1", RAGNAR_WEB_BASE="/panel",
                   RAGNAR_HOST="203.0.113.7", RAGNAR_DOMAIN="example.com")
        proc = subprocess.Popen(
            [sys.executable, os.path.join(ROOT, "web", "webpanel.py")],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True)
        no_proxy_opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}))
        try:
            base = "http://127.0.0.1:18100/panel"
            for _ in range(50):
                try:
                    page = no_proxy_opener.open(base + "/login",
                                                timeout=1).read().decode()
                    break
                except Exception:
                    time.sleep(0.2)
            else:
                raise RuntimeError("base-path server did not start")
            self.assertIn('action="/panel/login"', page)
            op = self.opener()
            data = urllib.parse.urlencode(
                {"username": "admin", "password": "testpass123"}).encode()
            op.open(base + "/login", data=data)
            dash = op.open(base + "/").read().decode()
            self.assertIn("Dashboard", dash)
            self.assertIn('href="/panel/ssh"', dash)
            ssh_page = op.open(base + "/ssh").read().decode()
            self.assertIn("webuser", ssh_page)
            self.assertIn('action="/panel/ssh/action"', ssh_page)
        finally:
            proc.terminate()
            proc.wait(timeout=5)
            if proc.stdout:
                proc.stdout.close()


if __name__ == "__main__":
    unittest.main()
