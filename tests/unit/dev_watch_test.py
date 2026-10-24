#!/usr/bin/env python3
"""Unit tests for scripts/dev.py: debounce, file watchers, and build-failure handling with a fake build."""
from pathlib import Path
import importlib.util
import queue
import sys
import tempfile
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
FAKE_BUILD = ROOT / "tests" / "fixtures" / "dev" / "fake_build.py"

spec = importlib.util.spec_from_file_location("goose_dev", ROOT / "scripts" / "dev.py")
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


class DebounceTest(unittest.TestCase):
    def test_batch_is_due_after_quiet_period(self):
        clock = FakeClock()
        debouncer = dev.Debouncer(quiet=0.15, max_wait=1.0, clock=clock)
        self.assertEqual(debouncer.timeout(0.5), 0.5)
        debouncer.add({"a.goose"})
        self.assertAlmostEqual(debouncer.timeout(0.5), 0.15)
        clock.now = 0.1
        debouncer.add({"b.goose"})
        self.assertEqual(debouncer.due(), set())
        clock.now = 0.2
        self.assertEqual(debouncer.due(), set())
        clock.now = 0.25
        self.assertEqual(debouncer.due(), {"a.goose", "b.goose"})
        self.assertEqual(debouncer.paths, set())

    def test_continuous_changes_flush_at_max_wait(self):
        clock = FakeClock()
        debouncer = dev.Debouncer(quiet=0.15, max_wait=1.0, clock=clock)
        for step in range(10):
            clock.now = step * 0.1
            debouncer.add({f"f{step}.goose"})
            self.assertEqual(debouncer.due(), set(), f"not due at {clock.now:.1f}")
        clock.now = 0.9
        debouncer.add({"last.goose"})
        clock.now = 1.0
        batch = debouncer.due()
        self.assertEqual(len(batch), 11)

    def test_empty_adds_are_ignored(self):
        clock = FakeClock()
        debouncer = dev.Debouncer(clock=clock)
        debouncer.add(set())
        self.assertEqual(debouncer.paths, set())
        self.assertEqual(debouncer.timeout(0.5), 0.5)


class WatcherTest(unittest.TestCase):
    """Each implementation gets its own directory, so one test's files cannot leak into the other's."""

    IMPLEMENTATIONS = ["PollingWatcher", "InotifyWatcher"]

    def make_watcher(self, kind, root):
        if kind == "PollingWatcher":
            return dev.PollingWatcher([str(root)], interval=0.05)
        if not sys.platform.startswith("linux"):
            self.skipTest("inotify is Linux only")
        try:
            return dev.InotifyWatcher([str(root)])
        except (OSError, AttributeError) as error:
            self.skipTest(f"inotify unavailable: {error}")

    def check_each(self, check):
        for kind in self.IMPLEMENTATIONS:
            with self.subTest(watcher=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "server.goose").write_text("one\n")
                watcher = self.make_watcher(kind, root)
                try:
                    check(root, watcher)
                finally:
                    watcher.close()

    def test_reports_watched_file_change(self):
        def check(root, watcher):
            (root / "server.goose").write_text("two\n")
            self.assertIn(str(root / "server.goose"), watcher.wait(2.0))

        self.check_each(check)

    def test_ignores_build_output_and_other_suffixes(self):
        def check(root, watcher):
            (root / "build").mkdir()
            (root / "build" / "server").write_text("binary")
            (root / "notes.md").write_text("docs")
            self.assertEqual(watcher.wait(0.5), set())

        self.check_each(check)

    def test_new_directories_are_watched(self):
        def check(root, watcher):
            (root / "views").mkdir()
            (root / "views" / "home.html").write_text("<p>hi</p>")
            self.assertIn(str(root / "views" / "home.html"), watcher.wait(2.0))
            (root / "views" / "home.html").write_text("<p>again</p>")
            self.assertIn(str(root / "views" / "home.html"), watcher.wait(2.0))

        self.check_each(check)


class BuildFailureTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.source = self.root / "server.goose"
        self.source.write_text("first\n")
        self.port = dev.find_free_port()
        self.server = dev.DevServer(self.source, port=self.port, reload_port=dev.find_free_port(),
                                    build_command=[sys.executable, str(FAKE_BUILD), "{source}", "{output}"])

    def tearDown(self):
        self.server.stop_server()
        self.directory.cleanup()

    def body(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/", timeout=5) as response:
            return response.read().decode().strip()

    def test_failed_build_keeps_running_server_and_reports_output(self):
        self.assertTrue(self.server.rebuild())
        self.assertIsNone(self.server.hub.last_error)
        self.assertEqual(self.body(), "first")
        child = self.server.child
        events = self.server.hub.subscribe()

        self.source.write_text("BROKEN\n")
        self.assertFalse(self.server.rebuild())
        self.assertIn("fake compile failure", self.server.hub.last_error)
        self.assertIs(self.server.child, child)
        self.assertIsNone(child.poll(), "the running server must survive a failed build")
        self.assertEqual(self.body(), "first")

        message = events.get(timeout=5)
        self.assertTrue(message.startswith(b"event: error\n"))
        self.assertIn(b"fake compile failure", message)

        self.source.write_text("second\n")
        self.assertTrue(self.server.rebuild())
        self.assertIsNone(self.server.hub.last_error)
        self.assertEqual(self.body(), "second")
        self.assertIsNot(self.server.child, child)
        self.assertIsNotNone(child.poll(), "the replaced server must have stopped")

    def test_late_clients_receive_the_last_error(self):
        self.source.write_text("BROKEN\n")
        self.assertFalse(self.server.rebuild())
        client = self.server.hub.subscribe()
        self.assertIn(b"fake compile failure", client.get(timeout=5))
        self.server.hub.unsubscribe(client)

    def test_missing_output_is_a_build_failure(self):
        self.server.build_template = [sys.executable, "-c", "print('nothing written')"]
        ok, message = self.server.build()
        self.assertFalse(ok)
        self.assertIn("nothing written", message)

    def test_hub_publishes_to_every_client(self):
        hub = dev.LiveReloadHub()
        clients = [hub.subscribe() for _ in range(2)]
        hub.reload()
        for client in clients:
            self.assertEqual(client.get(timeout=1), dev.format_event("reload", {}))
        self.assertEqual(dev.format_event("error", {"message": "x"}), b'event: error\ndata: {"message": "x"}\n\n')
        with self.assertRaises(queue.Empty):
            clients[0].get_nowait()


class ArgumentTest(unittest.TestCase):
    def test_arguments_after_double_dash_go_to_the_program(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "server.goose"
            source.write_text("import std;\n")
            args, server_args = dev.parse_arguments([str(source), "--port", "9000", "--", "--workers", "2"])
            self.assertEqual(args.port, 9000)
            self.assertEqual(server_args, ["--workers", "2"])

    def test_package_root_comes_from_the_import_line(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "pkg").mkdir()
            source = base / "app" / "server.goose"
            source.parent.mkdir()
            source.write_text('import goose_web from "../pkg";\nimport std;\n')
            self.assertEqual(dev.imported_package_roots(source), [str((base / "pkg").resolve())])


if __name__ == "__main__":
    unittest.main(verbosity=1)
