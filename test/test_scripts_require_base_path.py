#!/usr/bin/env python3
"""A script works on the base path its caller names, and stops when none is named."""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
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

    def test_surrounding_spaces_are_not_part_of_the_path(self):
        self.assertEqual(self.resolve("  /srv/masc  ", None), Path("/srv/masc"))
        self.assertEqual(self.resolve(None, " /srv/masc\n"), Path("/srv/masc"))

    def test_a_relative_value_is_read_against_the_callers_directory(self):
        self.assertEqual(self.resolve("work/base", None), Path.cwd() / "work" / "base")
        self.assertEqual(self.resolve(None, "./base/../other"), Path.cwd() / "other")

    def test_a_tilde_is_reported_and_not_expanded(self):
        for value in ("~", "~/base", "~someone/base"):
            self.assertEqual(self.resolve(value, None), masc_base_path.Unexpanded(value))
            self.assertEqual(self.resolve(None, value), masc_base_path.Unexpanded(value))


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

    def test_a_named_config_wins_over_the_environment(self):
        base = self.root / "base"
        self.config_under(base)
        named = self.root / "named.toml"
        result = self.run_python(self.SCRIPT, "--config", str(named), base=base)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(named), result.stderr)

    def test_a_tilde_base_is_reported(self):
        result = self.run_python(self.SCRIPT, base="~/base")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("starts with a tilde the shell did not expand", result.stderr)

    def test_a_tilde_or_blank_config_flag_is_refused(self):
        result = self.run_python(self.SCRIPT, "--config", "~/runtime.toml", base=self.root / "base")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("starts with a tilde the shell did not expand", result.stderr)
        for empty in ("", "  "):
            self.assert_stops_unnamed(
                self.run_python(self.SCRIPT, "--config", empty, base=self.root / "base"),
                "--config",
            )


class JudgeEval(Workdir):
    SCRIPT = "memory_os_judge_eval.py"

    def test_stops_when_no_runtime_config_is_named(self):
        self.assert_stops_unnamed(self.run_python(self.SCRIPT), "--runtime-config")

    def test_reads_the_config_under_the_base_the_environment_names(self):
        base = self.root / "base"
        result = self.run_python(self.SCRIPT, base=base)
        self.assertIn(f"cannot read runtime config '{base}/.masc/config/runtime.toml'", result.stderr)

    # A calibrate run reads no fact store.
    def test_calibrate_needs_only_the_runtime_config(self):
        config = self.root / "named.toml"
        result = self.run_python(self.SCRIPT, "--mode", "calibrate", "--runtime-config", str(config))
        self.assertIn(f"cannot read runtime config '{config}'", result.stderr)

    def test_measure_and_relabel_stop_without_a_fact_store(self):
        config = self.root / "named.toml"
        for mode in ("measure", "relabel"):
            result = self.run_python(self.SCRIPT, "--mode", mode, "--runtime-config", str(config))
            self.assert_stops_unnamed(result, "--store-dir")

    def test_a_named_store_does_not_stand_in_for_the_runtime_config(self):
        result = self.run_python(self.SCRIPT, "--mode", "measure", "--store-dir", str(self.root / "store"))
        self.assert_stops_unnamed(result, "--runtime-config")

    def test_two_named_paths_need_no_base(self):
        config = self.root / "named.toml"
        result = self.run_python(
            self.SCRIPT, "--mode", "measure", "--store-dir", str(self.root / "store"), "--runtime-config", str(config)
        )
        self.assertIn(f"cannot read runtime config '{config}'", result.stderr)

    def test_tilde_and_blank_flags_are_refused(self):
        base = self.root / "base"
        result = self.run_python(self.SCRIPT, "--runtime-config", "~/runtime.toml", base=base)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("starts with a tilde the shell did not expand", result.stderr)
        result = self.run_python(
            self.SCRIPT,
            "--mode",
            "measure",
            "--runtime-config",
            str(self.root / "named.toml"),
            "--store-dir",
            "~/store",
            base=base,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("starts with a tilde the shell did not expand", result.stderr)
        for empty in ("", "  "):
            self.assert_stops_unnamed(
                self.run_python(self.SCRIPT, "--runtime-config", empty, base=base),
                "--runtime-config",
            )

    def test_runs_through_a_symlink(self):
        link = self.root / "judge.py"
        link.symlink_to(SCRIPTS / self.SCRIPT)
        result = subprocess.run(
            [sys.executable, str(link)], env=self.env(), cwd=self.root, capture_output=True, text=True, timeout=60
        )
        self.assert_stops_unnamed(result, "--runtime-config")


class JudgeEvalPaths(unittest.TestCase):
    def path(self, named, base):
        import argparse

        sys.path.insert(0, str(SCRIPTS))
        saved = os.environ.get("MASC_BASE_PATH")
        try:
            import memory_os_judge_eval

            if base is None:
                os.environ.pop("MASC_BASE_PATH", None)
            else:
                os.environ["MASC_BASE_PATH"] = base
            return memory_os_judge_eval.config_path(argparse.ArgumentParser(), named, "keepers", "--store-dir")
        finally:
            sys.path.remove(str(SCRIPTS))
            if saved is None:
                os.environ.pop("MASC_BASE_PATH", None)
            else:
                os.environ["MASC_BASE_PATH"] = saved

    def test_the_base_fills_an_unnamed_path(self):
        self.assertEqual(self.path(None, "/srv/masc"), "/srv/masc/.masc/config/keepers")

    def test_a_named_path_is_kept(self):
        self.assertEqual(self.path("/named/store", "/srv/masc"), "/named/store")
        self.assertEqual(self.path("/named/store", None), "/named/store")


class TuiCaptures(Workdir):
    SCRIPTS = ("capture-tui-screenshots.py", "capture-tui-lane-runs.py")

    def capture(self, script, *args, base=None):
        return self.run_python(script, "--out", str(self.root / "out"), *args, base=base)

    def test_stop_when_no_base_is_named(self):
        for script in self.SCRIPTS:
            self.assert_stops_unnamed(self.capture(script), "--base-path")

    # Neither folder below is a workspace, so the script stops at the base
    # path it chose and names it; nothing is launched.
    def test_read_the_base_the_environment_names(self):
        base = self.root / "base"
        base.mkdir()
        for script in self.SCRIPTS:
            result = self.capture(script, base=base)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(f"not a MASC base path (no .masc directory): {base}", result.stderr)

    def test_read_the_base_the_flag_names(self):
        base, flagged = self.root / "base", self.root / "flagged"
        base.mkdir()
        flagged.mkdir()
        for script in self.SCRIPTS:
            result = self.capture(script, "--base-path", str(flagged), base=base)
            self.assertIn(f"not a MASC base path (no .masc directory): {flagged}", result.stderr)


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

    def test_a_tilde_base_searches_no_token_file_and_says_so(self):
        pairs, unsearched = self.candidates(base="~/base")
        self.assertEqual(pairs, [])
        self.assertEqual(len(unsearched), 1)
        self.assertIn("starts with a tilde the shell did not expand", unsearched[0])

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
        result = self.run_shell(self.SCRIPT, "start", XDG_DATA_HOME="", HOME="")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("MASC_SEARXNG_CONFIG_DIR is required", result.stderr)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_start_defaults_to_the_host_global_data_home(self):
        xdg = self.root / "xdg"
        result = self.run_shell(self.SCRIPT, "start", XDG_DATA_HOME=str(xdg))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((xdg / "masc-searxng/settings.yml").is_file())

    def test_start_falls_back_to_home_local_share(self):
        result = self.run_shell(self.SCRIPT, "start", XDG_DATA_HOME="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / ".local/share/masc-searxng/settings.yml").is_file())

    def test_a_named_config_folder_needs_no_base(self):
        config = self.root / "searxng"
        result = self.run_shell(self.SCRIPT, "start", MASC_SEARXNG_CONFIG_DIR=str(config))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((config / "settings.yml").is_file())

    def test_a_named_config_folder_wins_over_the_defaults(self):
        xdg, config = self.root / "xdg", self.root / "searxng"
        result = self.run_shell(
            self.SCRIPT, "start", XDG_DATA_HOME=str(xdg), MASC_SEARXNG_CONFIG_DIR=str(config))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((config / "settings.yml").is_file())
        self.assertFalse(xdg.exists())
        self.assertEqual(list(self.home.iterdir()), [])

    def test_a_default_of_only_spaces_names_nothing(self):
        result = self.run_shell(self.SCRIPT, "start", XDG_DATA_HOME="  ", HOME="")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("MASC_SEARXNG_CONFIG_DIR is required", result.stderr)
        self.assertEqual([p.name for p in self.root.iterdir() if p.name not in ("home", "stubs", "bin")], [])

    def test_the_other_commands_need_no_base(self):
        for command in ("status", "logs", "stop"):
            result = self.run_shell(self.SCRIPT, command)
            self.assertEqual(result.returncode, 0, f"{command}: {result.stderr}")


class BoardSlo(Workdir):
    SCRIPT = "board-slo-extractor.sh"

    def test_stops_when_no_base_is_named(self):
        result = self.run_shell(self.SCRIPT, "--offline", "--json")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_a_base_of_only_spaces_names_nothing(self):
        result = self.run_shell(self.SCRIPT, "--offline", "--json", base="  ")
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


class SkillUsage(Workdir):
    SCRIPT = "skill-usage-stats.py"

    def base_reported(self, *args, base=None):
        result = self.run_python(self.SCRIPT, "--json", *args, base=base)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)["base_path"]

    def test_stops_when_no_base_is_named(self):
        self.assert_stops_unnamed(self.run_python(self.SCRIPT, "--json"), "--base-path")

    def test_reads_the_base_the_environment_names(self):
        base = self.root / "base"
        self.assertEqual(self.base_reported(base=base), str(base))

    def test_reads_the_base_the_flag_names(self):
        flagged = self.root / "flagged"
        self.assertEqual(self.base_reported("--base-path", str(flagged), base=self.root / "base"), str(flagged))


class ExecuteFailures(Workdir):
    SCRIPT = "analyze-keeper-execute-failures.sh"

    def test_stops_when_no_base_is_named(self):
        for extra in ({}, {"MASC_BASE_PATH": "  "}):
            result = self.run_shell(self.SCRIPT, **extra)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("a base_path argument or MASC_BASE_PATH is required", result.stderr)

    def test_reads_the_base_the_environment_names(self):
        base = self.root / "base"
        result = self.run_shell(self.SCRIPT, base=base)
        self.assertIn(f"no tool call data at {base}/.masc/tool_calls", result.stderr)

    def test_reads_the_base_the_argument_names(self):
        named = self.root / "named"
        result = self.run_shell(self.SCRIPT, str(named), base=self.root / "base")
        self.assertIn(f"no tool call data at {named}/.masc/tool_calls", result.stderr)


class MsxCarts(Workdir):
    SCRIPT = "msx-fetch-homebrew-carts.sh"

    def created(self):
        return [p.name for p in self.root.iterdir() if p.name not in ("home", "stubs", "bin")]

    def test_stops_when_no_base_is_named(self):
        for extra in ({}, {"MASC_BASE_PATH": "  "}):
            result = self.run_shell(self.SCRIPT, **extra)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("--base-path or MASC_BASE_PATH is required", result.stderr)
            self.assertEqual(self.created(), [])

    def test_the_pinned_table_needs_no_base(self):
        result = self.run_shell(self.SCRIPT, "--list")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_dry_run_names_the_base_the_environment_names(self):
        base = self.root / "base"
        result = self.run_shell(self.SCRIPT, "--dry-run", base=base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"would get {base}/.masc/msx/carts/", result.stdout)
        self.assertEqual(self.created(), [])

    def test_a_dry_run_names_the_base_the_flag_names(self):
        flagged = self.root / "flagged"
        result = self.run_shell(self.SCRIPT, "--dry-run", "--base-path", str(flagged), base=self.root / "base")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"would get {flagged}/.masc/msx/carts/", result.stdout)
        self.assertEqual(self.created(), [])


class DashboardCapture(Workdir):
    SCRIPT = "capture-dashboard-screenshots.py"

    # A server whose health answer carries [paths].
    def health_server(self, paths):
        body = json.dumps({"paths": paths}).encode()

        class Health(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Health)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_address[1]}"

    def capture(self, paths, *args):
        url = self.health_server(paths)
        return self.run_python(self.SCRIPT, "--base-url", url, "--out", str(self.root / "out"), *args)

    def test_stops_when_neither_the_server_nor_a_flag_names_a_base(self):
        result = self.capture({})
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("reports no base path; pass --base-path", result.stderr)
        self.assertFalse((self.root / "out").exists())

    def test_reads_the_base_the_server_names(self):
        base = self.root / "base"
        result = self.capture({"effective_base_path": str(base)})
        self.assertIn(f"no keepers found below {base}/.masc/keepers", result.stderr)

    def test_reads_the_base_the_flag_names(self):
        flagged = self.root / "flagged"
        result = self.capture({"effective_base_path": str(self.root / "base")}, "--base-path", str(flagged))
        self.assertIn(f"no keepers found below {flagged}/.masc/keepers", result.stderr)


# The two readiness scripts ask the build for the keeper store layout as they
# load; a manifest with one store is enough to reach their base path.
class ReadinessScripts(Workdir):
    AUDIT = "audit-keeper-fleet-readiness.py"
    GATE = "keeper-production-readiness-gate.py"

    def setUp(self):
        super().setUp()
        manifest = self.bin / "store-layout-manifest"
        layout = {
            "schema": "masc.keeper_runtime_store_layout.v1",
            "stores": [{"dirname": "placeholder", "placement": "keeper_scoped_dated"}],
        }
        manifest.write_text(f"#!/bin/sh\ncat <<'JSON'\n{json.dumps(layout)}\nJSON\n")
        manifest.chmod(0o755)
        self.manifest = str(manifest)

    def run_readiness(self, script, *args, base=None):
        return subprocess.run(
            [sys.executable, str(SCRIPTS / script), *args],
            env=self.env(base, KEEPER_STORE_LAYOUT_MANIFEST_EXE=self.manifest),
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def test_stop_when_no_base_is_named(self):
        for script in (self.AUDIT, self.GATE):
            for args in ((), ("--base-path", "")):
                self.assert_stops_unnamed(self.run_readiness(script, *args), "--base-path")

    def test_a_tilde_base_is_reported(self):
        for script in (self.AUDIT, self.GATE):
            result = self.run_readiness(script, "--base-path", "~/base")
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("starts with a tilde the shell did not expand", result.stderr)
            self.assertEqual(list(self.home.iterdir()), [])

    def test_the_audit_reads_the_base_the_environment_names(self):
        base = self.root / "base"
        result = self.run_readiness(self.AUDIT, base=base)
        self.assertIn(f"keeper config dir not found: {base}/.masc/config/keepers", result.stderr)

    def test_the_audit_reads_the_base_the_flag_names(self):
        flagged = self.root / "flagged"
        result = self.run_readiness(self.AUDIT, "--base-path", str(flagged), base=self.root / "base")
        self.assertIn(f"keeper config dir not found: {flagged}/.masc/config/keepers", result.stderr)

    def test_the_gate_reads_the_base_the_environment_names(self):
        base = self.root / "base"
        result = self.run_readiness(self.GATE, base=base)
        self.assertIn(f"base_path: {base}", result.stdout)

    def test_the_gate_reads_the_base_the_flag_names(self):
        flagged = self.root / "flagged"
        result = self.run_readiness(self.GATE, "--base-path", str(flagged), base=self.root / "base")
        self.assertIn(f"base_path: {flagged}", result.stdout)


class FrameLatency(Workdir):
    def test_stops_when_no_base_is_named(self):
        self.assert_stops_unnamed(self.run_python("tui-frame-latency.py"), "--base-path")


class ProgressExtract(Workdir):
    SCRIPT = "progress/extract_progress.py"

    # The repository folder is empty, so a run that has its masc root goes on
    # to miss the feature matrix; one that lacks it stops before that.
    def extract(self, *args, base=None):
        repo = self.root / "repo"
        repo.mkdir(exist_ok=True)
        return self.run_python(self.SCRIPT, "--repo-root", str(repo), *args, base=base)

    def assert_went_on(self, result):
        self.assertNotIn("is required", result.stderr)
        self.assertIn("keeper-feature-state-matrix", result.stderr)

    def test_stops_when_no_masc_root_is_named(self):
        self.assert_stops_unnamed(self.extract(), "--masc-root")

    def test_the_environment_names_the_masc_root(self):
        self.assert_went_on(self.extract(base=self.root / "base"))

    def test_a_named_masc_root_needs_no_base(self):
        self.assert_went_on(self.extract("--masc-root", str(self.root / "named")))

    def test_an_empty_masc_root_does_not_fall_back_to_the_environment(self):
        for empty in ("", "  "):
            result = self.extract("--masc-root", empty, base=self.root / "base")
            self.assert_stops_unnamed(result, "--masc-root")

    def test_a_tilde_masc_root_is_refused(self):
        for tilde in ("~", "~/nowhere/.masc", "~someone/.masc"):
            result = self.extract("--masc-root", tilde, base=self.root / "base")
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("starts with a tilde the shell did not expand", result.stderr)


if __name__ == "__main__":
    unittest.main()
