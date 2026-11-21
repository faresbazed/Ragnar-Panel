import contextlib
import io
import os
import sys
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "core"))
import checker as C  # noqa: E402

SS_SAMPLE = """Recv-Q Send-Q Local Address:Port Peer Address:Port Process
0 0 127.0.0.1:109 127.0.0.1:51234 users:(("dropbear",pid=1234,fd=5))
\t cubic wscale:7,7 rto:204 bytes_sent:10485760 bytes_received:2048
0 0 10.0.0.5:22 1.2.3.4:5555 users:(("sshd",pid=55,fd=3),("sshd",pid=999,fd=3))
\t cubic bytes_sent:100 bytes_received:200
0 0 10.0.0.5:443 5.5.5.5:443 users:(("haproxy",pid=9,fd=1))
\t cubic bytes_sent:999999 bytes_received:999999
0 0 10.0.0.5:53100 9.9.9.9:443 users:(("sshd",pid=55,fd=9))
\t cubic bytes_sent:777777 bytes_received:888888
"""

SLOWDNS_SSH_SAMPLE = """Recv-Q Send-Q Local Address:Port Peer Address:Port Process
0 0 127.0.0.1:22 127.0.0.1:51234 users:(("sshd",pid=8888,fd=3))
\t cubic bytes_sent:4096 bytes_received:8192
0 0 127.0.0.1:109 127.0.0.1:51235 users:(("dropbear",pid=8889,fd=5))
\t cubic bytes_sent:100 bytes_received:200
"""


class TestZivpnExpiry(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        base = self.temp.name
        paths = {"BASE": base, "DB_DIR": os.path.join(base, "db"),
                 "SETTINGS": os.path.join(base, "settings.json")}
        for key, filename in (("SSH_DB", "ssh.json"), ("XRAY_DB", "xray.json"),
                              ("ZIVPN_DB", "zivpn.json"),
                              ("XRAY_LAST_SEEN", "xray_last_seen.json")):
            paths[key] = os.path.join(base, "db", filename)
        self.stack.enter_context(patch.multiple(C.ragnar, **paths))
        self.stack.enter_context(patch.object(C, "run", return_value=""))
        self.commands = self.stack.enter_context(patch.object(C.ragnar.subprocess, "run"))
        self.output = io.StringIO()
        self.stack.enter_context(contextlib.redirect_stdout(self.output))

    def seed(self):
        for name, days in (("expired", -1), ("active", 1), ("today", 0),
                           ("disabled", -1)):
            C.ragnar.zivpn_add(name, name + "-password", days)
        C.ragnar.zivpn_edit("disabled", enable=False)
        self.config = os.path.join(C.ragnar.BASE, "zivpn", "config.json")
        C.ragnar._write_json(self.config, {"auth": {"config": [
            "expired-password", "active-password", "today-password"]}})

    def test_apply_disables_only_expired_and_refreshes_live_config(self):
        self.seed()
        with patch.object(sys, "argv", ["checker", "--apply"]):
            self.assertEqual(C.main(), 0)
            self.assertFalse(C.ragnar.load_zivpn()["expired"]["enabled"])
            self.assertTrue(C.ragnar.load_zivpn()["active"]["enabled"])
            self.assertTrue(C.ragnar.load_zivpn()["today"]["enabled"])
            self.assertEqual(C.ragnar._read_json(self.config, {})["auth"]["config"],
                             ["active-password", "today-password"])
            self.assertEqual(self.output.getvalue(), "zivpn/expired: remove (expired)\n")
            self.commands.assert_called_once()
            self.assertIn("zivpn", self.commands.call_args.args[0])
            self.commands.reset_mock()
            C.main()
            self.commands.assert_not_called()

    def test_dry_run_preserves_users_and_config(self):
        self.seed()
        with patch.object(sys, "argv", ["checker"]):
            C.main()
        self.assertEqual(self.output.getvalue(), "zivpn/expired: remove (expired)\n")
        self.assertTrue(C.ragnar.load_zivpn()["expired"]["enabled"])
        self.assertIn("expired-password", C.ragnar._read_json(self.config, {})["auth"]["config"])
        self.commands.assert_not_called()

    def test_renewal_restores_only_checker_disabled_zivpn_password(self):
        self.seed()
        with patch.object(sys, "argv", ["checker", "--apply"]):
            self.assertEqual(C.main(), 0)
        for name in ("expired", "disabled"):
            self.assertFalse(C.ragnar.load_zivpn()[name]["enabled"])
            self.assertEqual(C.ragnar.main(
                ["zivpn-edit", name, "--days", "30", "--extend"]), 0)
        users = C.ragnar.load_zivpn()
        self.assertTrue(users["expired"]["enabled"])
        self.assertFalse(users["disabled"]["enabled"])
        self.assertEqual(C.ragnar._read_json(self.config, {})["auth"]["config"],
                         ["active-password", "expired-password", "today-password"])

    def test_empty_users_do_not_restart(self):
        with patch.object(sys, "argv", ["checker", "--apply"]):
            C.main()
        self.assertEqual(self.output.getvalue(), "all users within limits\n")
        self.commands.assert_not_called()

    def test_nonfinite_quota_inputs_are_rejected(self):
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'web'))
        import webpanel

        for kind in ('ssh', 'xray'):
            add = getattr(C.ragnar, kind + '_add')
            edit = getattr(C.ragnar, kind + '_edit')
            load = getattr(C.ragnar, 'load_' + kind)
            if kind == 'ssh':
                add('existing', 'password', 30, 1, 0)
            else:
                add('existing', 30, 1, 0)
            for quota in ('inf', '1e309', 'nan', '-inf'):
                with self.subTest(kind=kind, quota=quota):
                    with self.assertRaisesRegex(ValueError, 'finite'):
                        if kind == 'ssh':
                            add('invalid', 'password', 30, quota, 0)
                        else:
                            add('invalid', 30, quota, 0)
                    with self.assertRaisesRegex(ValueError, 'finite'):
                        edit('existing', quota_gb=quota)
                    self.assertNotIn('invalid', load())
                    self.assertEqual(load()['existing']['quota_gb'], 1)
                    form = dict(op='create', user='invalid', password='password',
                                days='30', quota=quota, iplimit='0')
                    self.assertIn('finite', webpanel.do_user_action(kind, form))
                    form['user'] = 'existing'
                    self.assertIn('finite', webpanel.do_edit(kind, form))
                    self.assertEqual(load()['existing']['quota_gb'], 1)

    def test_stored_nonfinite_quotas_do_not_block_expiry(self):
        for kind in ('ssh', 'xray'):
            add = getattr(C.ragnar, kind + '_add')
            load = getattr(C.ragnar, 'load_' + kind)
            save = getattr(C.ragnar, 'save_' + kind)
            for i in range(4):
                if kind == 'ssh':
                    add(str(i), 'password', 30, 0, 0)
                else:
                    add(str(i), 30, 0, 0)
            users = load()
            for i, quota in enumerate((float('inf'), float('nan'),
                                       float('-inf'), 1e308)):
                users[str(i)]['quota_gb'] = quota
            save(users)
        C.ragnar.zivpn_add('expired', 'password', -1)
        with patch.object(sys, 'argv', ['checker', '--apply']):
            self.assertEqual(C.main(), 0)
        self.assertFalse(C.ragnar.load_zivpn()['expired']['enabled'])


class TestCounterDelta(unittest.TestCase):
    def test_normal_delta(self):
        self.assertEqual(C.counter_delta(100, 250), 150)

    def test_reset_counts_whole_reading(self):
        self.assertEqual(C.counter_delta(9000, 300), 300)

    def test_no_movement(self):
        self.assertEqual(C.counter_delta(50, 50), 0)


class TestSocketAccounting(unittest.TestCase):
    def setUp(self):
        C._pid_user = lambda pid: {1234: "fares", 55: "channel",
                                   999: "root", 8888: "dns-user",
                                   8889: "dns-user"}.get(pid)

    def test_parse_only_daemon_sockets(self):
        # haproxy socket excluded (not a daemon), the sshd outbound
        # socket to a forwarded target excluded (ephemeral local port,
        # would double-count the relay), root monitor pid skipped in
        # favour of the per-user child pid.
        socks = C.parse_socket_bytes(SS_SAMPLE)
        self.assertEqual(len(socks), 2)
        self.assertEqual(
            socks[("fares", "127.0.0.1:109", "127.0.0.1:51234")],
            (10485760, 2048))
        self.assertEqual(
            socks[("channel", "10.0.0.5:22", "1.2.3.4:5555")], (100, 200))

    def test_deltas_accumulate_and_new_socket_counts_all(self):
        key = "fares|127.0.0.1:109|127.0.0.1:51234"
        per_user, state = C.socket_usage_deltas(SS_SAMPLE, {key: (10000000, 1000)})
        self.assertEqual(per_user["fares"], 485760 + 1048)
        self.assertEqual(per_user["channel"], 300)
        self.assertEqual(state[key], [10485760, 2048])

    def test_slowdns_forwarded_ssh_is_counted_for_authenticated_user(self):
        per_user, state = C.socket_usage_deltas(SLOWDNS_SSH_SAMPLE, {})
        self.assertEqual(per_user, {"dns-user": 12588})
        self.assertEqual(
            state["dns-user|127.0.0.1:22|127.0.0.1:51234"], [4096, 8192])
        self.assertEqual(
            state["dns-user|127.0.0.1:109|127.0.0.1:51235"], [100, 200])

    def test_live_ips_and_kick_isolation(self):
        # channel has client 1.2.3.4 (pid 55) + outbound forwarded 9.9.9.9
        # plus second client 8.8.4.4 (pid 56); haproxy is pid 9; fares is 1234.
        C._pid_user = lambda pid: {1234: "fares", 55: "channel", 56: "channel",
                                   999: "root", 9: "haproxy"}.get(pid)
        sample = SS_SAMPLE + (
            '0 0 10.0.0.5:22 8.8.4.4:6000 users:(("sshd",pid=56,fd=3),("sshd",pid=999,fd=3))\n'
        )
        live = C.ssh_live_ips(sample)
        # 9.9.9.9:443 is outbound (local port 53100), NOT a client source IP!
        self.assertEqual(live[("ssh", "channel")], ["1.2.3.4", "8.8.4.4"])
        # Kicking channel's extra IPs keeping {"1.2.3.4"} must ONLY return [56]
        # — never haproxy (pid 9), root (pid 999), or fares (pid 1234).
        self.assertEqual(C.pids_to_kick(sample, "channel", {"1.2.3.4"}), [56])


class TestCheckerLocks(unittest.TestCase):
    def setUp(self):
        fixture = tempfile.TemporaryDirectory()
        self.addCleanup(fixture.cleanup)
        self.ragnar = C.ragnar
        paths = {key: os.path.join(fixture.name, key)
                 for key in ("SSH_DB", "XRAY_DB", "ZIVPN_DB", "XRAY_LAST_SEEN")}
        overrides = patch.multiple(self.ragnar, BASE=fixture.name, **paths)
        overrides.start()
        self.addCleanup(overrides.stop)

    def apply_checker(self):
        with patch.object(sys, "argv", ["checker.py", "--apply"]), \
             patch.object(C, "run", return_value=""), \
             patch.object(C.subprocess, "run"), \
             patch.object(self.ragnar, "apply_configs"), \
             patch.object(self.ragnar, "sync_udp_custom"), \
             contextlib.redirect_stdout(io.StringIO()) as log:
            self.assertEqual(C.main(), 0)
        return log.getvalue()

    def test_usage_save_preserves_concurrent_add(self):
        self.ragnar.xray_add("alice", 30)
        loaded = threading.Event()
        added = threading.Event()
        load = self.ragnar.load_xray

        def delayed_load():
            users = load()
            loaded.set()
            added.wait(timeout=0.2)
            return users

        def add_user():
            self.assertTrue(loaded.wait(timeout=2))
            self.ragnar.xray_add("bob", 30)
            added.set()

        with patch.object(C, "run", return_value=""), \
             patch.object(C, "ensure_iptables_rules"), \
             patch.object(C, "xray_deltas", return_value={"alice": 100}), \
             patch.object(self.ragnar, "load_xray", side_effect=delayed_load):
            with ThreadPoolExecutor(2) as pool:
                usage = pool.submit(C.accumulate_usage, "")
                add = pool.submit(add_user)
                usage.result(timeout=5)
                add.result(timeout=5)
        self.assertEqual(set(load()), {"alice", "bob"})
        self.assertEqual(load()["alice"]["used_bytes"], 100)

    def ssh_edit(self, user, *args):
        with patch.object(self.ragnar.subprocess, "run") as run, \
             patch.object(self.ragnar, "sync_udp_custom"), \
             patch.object(self.ragnar, "fmt_ssh_info", return_value=""), \
             contextlib.redirect_stdout(io.StringIO()):
            run.return_value.returncode = 0
            self.assertEqual(self.ragnar.main(["ssh-edit", user, *args]), 0)
        return [call.args[0] for call in run.call_args_list]

    def test_ssh_cli_renewal_unlocks_only_checker_disabled_accounts(self):
        for user in ("ragnar-test-expired", "ragnar-test-admin", "ragnar-test-override"):
            self.ragnar.ssh_add(user, "testpw", -1, 0, 0)
        self.ssh_edit("ragnar-test-admin", "--disable")
        log = self.apply_checker()
        self.assertIn("ssh/ragnar-test-expired: lock (expired)", log)
        self.assertIn("ssh/ragnar-test-override: lock (expired)", log)
        self.assertNotIn("ragnar-test-admin", log)
        self.ssh_edit("ragnar-test-override", "--disable")

        for user, enabled in (("ragnar-test-expired", True),
                              ("ragnar-test-admin", False),
                              ("ragnar-test-override", False)):
            with self.subTest(user=user):
                self.assertFalse(self.ragnar.load_ssh()[user]["enabled"])
                commands = self.ssh_edit(user, "--days", "30", "--extend")
                record = self.ragnar.load_ssh()[user]
                self.assertEqual(record["expiry"], self.ragnar.expiry_from_days(30))
                self.assertEqual(record["enabled"], enabled)
                self.assertIn(["usermod", "-U" if enabled else "-L", user], commands)

    def test_ssh_checker_lock_only_clears_after_both_limits_are_fixed(self):
        self.ragnar.ssh_add("ragnar-test-over", "testpw", -1, 1, 0)
        users = self.ragnar.load_ssh()
        users["ragnar-test-over"]["used_bytes"] = 2 * 1024 ** 3
        self.ragnar.save_ssh(users)
        self.assertIn("ssh/ragnar-test-over: lock (expired)", self.apply_checker())

        self.ssh_edit("ragnar-test-over", "--days", "30", "--extend")
        self.assertFalse(self.ragnar.load_ssh()["ragnar-test-over"]["enabled"])
        self.ssh_edit("ragnar-test-over", "--quota-gb", "2")
        self.assertFalse(self.ragnar.load_ssh()["ragnar-test-over"]["enabled"])
        commands = self.ssh_edit("ragnar-test-over", "--quota-gb", "0")
        record = self.ragnar.load_ssh()["ragnar-test-over"]
        self.assertTrue(record["enabled"])
        self.assertEqual(record["used_bytes"], 2 * 1024 ** 3)
        self.assertIn(["usermod", "-U", "ragnar-test-over"], commands)


if __name__ == "__main__":
    unittest.main()
