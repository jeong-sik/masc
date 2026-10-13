#!/usr/bin/env python3
"""A script works on the base path its caller names, and stops when none is named."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / "scripts"

sys.path.insert(0, str(SCRIPTS / "lib"))

import masc_base_path  # noqa: E402


# What the two capture scripts import before they read their arguments.
PLAYWRIGHT_STUB = "Browser = Page = object\n\n\ndef sync_playwright():\n    raise RuntimeError('not a browser')\n"


class Workdir(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        stub = self.root / "stubs" / "playwright"
        stub.mkdir(parents=True)
        (stub / "__init__.py").write_text("")
        (stub / "sync_api.py").write_text(PLAYWRIGHT_STUB)
        self.bin = self.root / "bin"
        self.bin.mkdir()

    # The caller's environment with no base path in it. [base] names one.
    def env(self, base=None, **extra):
        env = {
            key: value
            for key, value in os.environ.items()
            if key not in ("MASC_BASE_PATH", "MASC_MCP_TOKEN", "MASC_SEARXNG_CONFIG_DIR")
        }
        env["HOME"] = str(self.home)
        env["PYTHONPATH"] = str(self.root / "stubs")
        env["PATH"] = f"{self.bin}{os.pathsep}{env['PATH']}"
        if base is not None:
            env["MASC_BASE_PATH"] = str(base)
        env.update(extra)
        return env

    def run_python(self, script, *args, base=None):
        return subprocess.run(
            [sys.executable, str(SCRIPTS / script), *args],
            env=self.env(base),
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def run_shell(self, script, *args, base=None, **extra):
        return subprocess.run(
            ["bash", str(SCRIPTS / script), *args],
            env=self.env(base, **extra),
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def assert_stops_unnamed(self, result, flag):
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(f"{flag} or MASC_BASE_PATH is required", result.stderr)
        self.assertEqual(list(self.home.iterdir()), [])


class Resolve(unittest.TestCase):
    def resolve(self, flag, env_value):
        saved = os.environ.get("MASC_BASE_PATH")
        try:
            if env_value is None:
                os.environ.pop("MASC_BASE_PATH", None)
            else:
                os.environ["MASC_BASE_PATH"] = env_value
            return masc_base_path.resolve(flag)
        finally:
            if saved is None:
                os.environ.pop("MASC_BASE_PATH", None)
            else:
                os.environ["MASC_BASE_PATH"] = saved

    def test_nothing_named_is_none(self):
        self.assertIsNone(self.resolve(None, None))

    def test_environment_names_the_base(self):
        self.assertEqual(self.resolve(None, "/srv/masc"), Path("/srv/masc"))

    def test_flag_wins_over_the_environment(self):
        self.assertEqual(self.resolve("/srv/flagged", "/srv/masc"), Path("/srv/flagged"))

    def test_blank_values_name_nothing(self):
        self.assertIsNone(self.resolve(None, "  "))
        self.assertIsNone(self.resolve("", None))

    def test_a_blank_flag_does_not_fall_back_to_the_environment(self):
        self.assertIsNone(self.resolve("", "/srv/masc"))


class DenialStreaks(Workdir):
    SCRIPT = "measure-keeper-denial-streaks.py"

    def test_stops_when_no_base_is_named(self):
        self.assert_stops_unnamed(self.run_python(self.SCRIPT), "--base")

    def test_reads_the_base_the_environment_names(self):
        base = self.root / "base"
        result = self.run_python(self.SCRIPT, base=base)
        self.assertIn(f"no trajectories under {base}/.masc/trajectories", result.stderr)

    def test_reads_the_base_the_flag_names(self):
        flagged = self.root / "flagged"
        result = self.run_python(self.SCRIPT, "--base", str(flagged), base=self.root / "base")
        self.assertIn(f"no trajectories under {flagged}/.masc/trajectories", result.stderr)


class ToolRoundtrips(Workdir):
    SCRIPT = "measure-tool-roundtrips.py"

    def test_stops_when_no_base_is_named(self):
        self.assert_stops_unnamed(self.run_python(self.SCRIPT, "--date", "2026-09-01"), "--base-path")

    def test_reads_the_base_the_environment_names(self):
        base = self.root / "base"
        result = self.run_python(self.SCRIPT, "--date", "2026-09-01", base=base)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(f"no such log file: {base}/.masc/tool_calls/2026-09/01.jsonl", result.stderr)

    def test_reads_the_base_the_flag_names(self):
        flagged = self.root / "flagged"
        result = self.run_python(
            self.SCRIPT, "--base-path", str(flagged), "--date", "2026-09-01", base=self.root / "base"
        )
        self.assertIn(f"no such log file: {flagged}/.masc/tool_calls/2026-09/01.jsonl", result.stderr)


class StructuredOutputProbe(Workdir):
    SCRIPT = "probe-structured-output-enforcement.py"

    def config_under(self, base):
        config = base / ".masc" / "config" / "runtime.toml"
        config.parent.mkdir(parents=True)
        config.write_text("")
        return config

    def test_stops_when_no_config_is_named(self):
        self.assert_stops_unnamed(self.run_python(self.SCRIPT), "--config")

    def test_reads_the_config_under_the_base_the_environment_names(self):
        base = self.root / "base"
        self.config_under(base)
        result = self.run_python(self.SCRIPT, base=base)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("no targets to probe", result.stderr)

    def test_a_named_config_needs_no_base(self):
        config = self.config_under(self.root / "elsewhere")
        result = self.run_python(self.SCRIPT, "--config", str(config))
        self.assertIn("no targets to probe", result.stderr)


class JudgeEval(Workdir):
    SCRIPT = "memory_os_judge_eval.py"

    def test_stops_when_no_base_is_named(self):
        self.assert_stops_unnamed(self.run_python(self.SCRIPT), "--store-dir with --runtime-config")

    def test_one_named_path_still_needs_the_base_for_the_other(self):
        result = self.run_python(self.SCRIPT, "--store-dir", str(self.root / "store"))
        self.assert_stops_unnamed(result, "--store-dir with --runtime-config")

    def test_reads_the_config_under_the_base_the_environment_names(self):
        base = self.root / "base"
        result = self.run_python(self.SCRIPT, base=base)
        self.assertIn(f"cannot read runtime config '{base}/.masc/config/runtime.toml'", result.stderr)

    def test_both_named_paths_need_no_base(self):
        config = self.root / "named.toml"
        result = self.run_python(
            self.SCRIPT, "--store-dir", str(self.root / "store"), "--runtime-config", str(config)
        )
        self.assertIn(f"cannot read runtime config '{config}'", result.stderr)


class JudgeEvalPaths(unittest.TestCase):
    def paths(self, store_dir, runtime_config, base):
        sys.path.insert(0, str(SCRIPTS))
        saved = os.environ.get("MASC_BASE_PATH")
        try:
            import memory_os_judge_eval

            if base is None:
                os.environ.pop("MASC_BASE_PATH", None)
            else:
                os.environ["MASC_BASE_PATH"] = base
            return memory_os_judge_eval.store_and_config(store_dir, runtime_config)
        finally:
            sys.path.remove(str(SCRIPTS))
            if saved is None:
                os.environ.pop("MASC_BASE_PATH", None)
            else:
                os.environ["MASC_BASE_PATH"] = saved

    def test_the_base_fills_both_unnamed_paths(self):
        self.assertEqual(
            self.paths(None, None, "/srv/masc"),
            ("/srv/masc/.masc/config/keepers", "/srv/masc/.masc/config/runtime.toml"),
        )

    def test_a_named_store_is_kept(self):
        self.assertEqual(
            self.paths("/named/store", None, "/srv/masc"),
            ("/named/store", "/srv/masc/.masc/config/runtime.toml"),
        )

    def test_a_named_config_is_kept(self):
        self.assertEqual(
            self.paths(None, "/named/runtime.toml", "/srv/masc"),
            ("/srv/masc/.masc/config/keepers", "/named/runtime.toml"),
        )

    def test_two_named_paths_need_no_base(self):
        self.assertEqual(
            self.paths("/named/store", "/named/runtime.toml", None),
            ("/named/store", "/named/runtime.toml"),
        )

    def test_an_unnamed_path_without_a_base_is_none(self):
        self.assertIsNone(self.paths("/named/store", None, None))
        self.assertIsNone(self.paths(None, "/named/runtime.toml", None))


class TuiCaptures(Workdir):
    def test_surface_capture_stops_when_no_base_is_named(self):
        result = self.run_python("capture-tui-screenshots.py", "--out", str(self.root / "out"))
        self.assert_stops_unnamed(result, "--base-path")

    def test_lane_run_capture_stops_when_no_base_is_named(self):
        result = self.run_python("capture-tui-lane-runs.py", "--out", str(self.root / "out"))
        self.assert_stops_unnamed(result, "--base-path")


class WebBenchTokens(Workdir):
    def bench(self):
        spec = importlib.util.spec_from_file_location("bench_web_tools", SCRIPTS / "bench-web-tools.py")
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def candidates(self, base=None, token=None):
        saved = dict(os.environ)
        scoped = self.env(base)
        if token is not None:
            scoped["MASC_MCP_TOKEN"] = token
        try:
            os.environ.clear()
            os.environ.update(scoped)
            return self.bench().token_candidates()
        finally:
            os.environ.clear()
            os.environ.update(saved)

    def test_no_base_searches_no_token_file_and_says_so(self):
        self.assertEqual(
            self.candidates(),
            ([], ["token files not searched: MASC_BASE_PATH is unset"]),
        )

    def test_the_environment_token_is_a_candidate_without_a_base(self):
        pairs, unsearched = self.candidates(token="from-env")
        self.assertEqual(pairs, [("env:MASC_MCP_TOKEN", "from-env")])
        self.assertEqual(len(unsearched), 1)

    def test_token_files_come_from_the_named_base(self):
        base = self.root / "base"
        auth = base / ".masc" / "auth"
        auth.mkdir(parents=True)
        (auth / "operator.token").write_text("from-file\n")
        self.assertEqual(self.candidates(base=base), ([("operator.token", "from-file")], []))

    def test_a_refused_run_names_the_unsearched_token_files(self):
        saved = dict(os.environ)
        scoped = self.env()
        try:
            os.environ.clear()
            os.environ.update(scoped)
            bench = self.bench()

            def refused(_client, _method, _params):
                raise RuntimeError("HTTP 401")

            bench.McpClient.rpc = refused
            with self.assertRaises(RuntimeError) as raised:
                bench.authenticated_client("http://unused.invalid/mcp")
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.assertEqual(
            str(raised.exception),
            "no token candidate accepted: no-token: HTTP 401"
            " | token files not searched: MASC_BASE_PATH is unset",
        )


class SearxngLocal(Workdir):
    SCRIPT = "searxng-local.sh"

    def setUp(self):
        super().setUp()
        # A docker whose container exists and is stopped.
        docker = self.bin / "docker"
        docker.write_text('#!/bin/sh\nif [ "$1" = inspect ] && [ "$2" = -f ]; then echo false; fi\n')
        docker.chmod(0o755)

    def test_start_stops_when_no_config_folder_is_named(self):
        result = self.run_shell(self.SCRIPT, "start")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("MASC_SEARXNG_CONFIG_DIR or MASC_BASE_PATH is required", result.stderr)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_start_writes_settings_under_the_named_base(self):
        base = self.root / "base"
        result = self.run_shell(self.SCRIPT, "start", base=base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((base / ".local/share/masc-searxng/settings.yml").is_file())

    def test_a_named_config_folder_needs_no_base(self):
        config = self.root / "searxng"
        result = self.run_shell(self.SCRIPT, "start", MASC_SEARXNG_CONFIG_DIR=str(config))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((config / "settings.yml").is_file())

    def test_status_needs_no_base(self):
        result = self.run_shell(self.SCRIPT, "status")
        self.assertEqual(result.returncode, 0, result.stderr)


class BoardSlo(Workdir):
    SCRIPT = "board-slo-extractor.sh"

    def test_stops_when_no_base_is_named(self):
        result = self.run_shell(self.SCRIPT, "--offline", "--json")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_help_needs_no_base(self):
        result = self.run_shell(self.SCRIPT, "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("board-slo-extractor.sh", result.stdout)
        self.assertNotIn("set -euo pipefail", result.stdout)

    def test_reports_the_named_base(self):
        base = self.root / "base"
        result = self.run_shell(self.SCRIPT, "--offline", "--json", base=base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'"basepath": "{base}"', result.stdout)


if __name__ == "__main__":
    unittest.main()
