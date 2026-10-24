#!/usr/bin/env python3
"""Project commands must preserve arguments, failures and generated source compatibility."""
from pathlib import Path
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_docs", ROOT / "scripts/check_docs.py")
docs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(docs)


class DocumentationTest(unittest.TestCase):
    def test_links_fragments_and_fences(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "other page.md").write_text("# One `Thing`\n# One Thing\n")
            (root / "page.md").write_text(
                "# Top\n[good](other%20page.md#one-thing-1)\n[bad](missing.md)\n"
                "[fragment](#absent)\n[web](https://example.com/no-network)\n"
                "```md\n[ignored](also-missing.md)\n```\n")
            count, errors = docs.check(root)
            self.assertEqual(count, 3)
            self.assertEqual(len(errors), 2)
            self.assertIn("missing.md", errors[0])
            self.assertIn("fragment does not exist", errors[1])


class ProjectCommandsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="goose-cli-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copy2(ROOT / "manage.py", self.root / "manage.py")
        (self.root / "server.goose").write_text("fn main() {}\n")
        fake = self.root / "fake compiler"
        fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ['COMMAND_LOG']).write_text(json.dumps(sys.argv[1:]))
if '-o' in sys.argv:
    p = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
    p.write_text("#!/usr/bin/env python3\\nimport json,os,pathlib,sys\\n"
                 "pathlib.Path(os.environ['PROGRAM_LOG']).write_text(json.dumps(sys.argv[1:]))\\n")
    p.chmod(0o755)
sys.exit(int(os.environ.get('COMPILER_EXIT', '0')))
''')
        fake.chmod(0o755)
        self.env = dict(os.environ, GOOSE=str(fake), COMMAND_LOG=str(self.root / "command.json"),
                        PROGRAM_LOG=str(self.root / "program.json"))

    def command(self, *args, **extra):
        return subprocess.run([sys.executable, str(self.root / "manage.py"), *args],
                              env=dict(self.env, **extra), capture_output=True, text=True, timeout=10)

    def test_build_and_forward_arguments(self):
        result = self.command("run", "--output", "build/my app", "--", "--port", "9000", "a b")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.root / "program.json").read_text()), ["--port", "9000", "a b"])
        command = json.loads((self.root / "command.json").read_text())
        self.assertIn("--debug", command)
        self.assertEqual(command[1], str(self.root / "server.goose"))

    def test_compiler_failure_stops_ci(self):
        (self.root / "test.py").write_text("raise SystemExit('must not run after failed check')\n")
        result = self.command("ci", COMPILER_EXIT="7")
        self.assertEqual(result.returncode, 7)
        self.assertNotIn("must not run", result.stderr)

    def test_suite_exit_code_propagates(self):
        (self.root / "test.py").write_text("raise SystemExit(9)\n")
        self.assertEqual(self.command("test").returncode, 9)

    def test_generator_uses_matching_checkout_and_copies_commands(self):
        project = self.root / "generated"
        result = subprocess.run([sys.executable, str(ROOT / "scripts/new_project.py"), "demo", str(project)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        relative = Path(os.path.relpath(ROOT, project)).as_posix()
        self.assertIn(f'import goose_web from "{relative}";', (project / "server.goose").read_text())
        self.assertTrue((project / "manage.py").is_file())
        self.assertTrue((project / "Makefile").is_file())


if __name__ == "__main__":
    unittest.main()
