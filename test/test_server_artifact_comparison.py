"""Reject misleading artifact and HTTP receipts without running a MASC binary."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/harness/perf"))
from linux_probe_artifact import BINARIES, digest, verify
from compare_server_artifacts import validate_session


def put(path, value):
    path.write_text(json.dumps(value))


class ArtifactTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = "a" * 40
        self.options = dict(source=self.source, run_id=11, artifact_id=22, repository_id=33)
        self.run = dict(id=11, head_sha=self.source, status="completed", conclusion="success",
                        repository={"id": 33}, path=".github/workflows/linux-x64-probe.yml",
                        event="workflow_dispatch", run_attempt=1)
        self.meta = dict(id=22, expired=False, name=f"linux-x64-probe-{self.source}-attempt-1",
                         workflow_run=dict(id=11, head_sha=self.source, repository_id=33, head_repository_id=33))
        header = b"\x7fELF\x02\x01" + bytes(12) + b"\x3e\x00" + bytes(12)
        self.binaries = {name: header + name.encode() for name in BINARIES}
        self.archive()

    def archive(self, *, sums=None, extra=None):
        sums = sums if sums is not None else "".join(
            f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in self.binaries.items())
        with zipfile.ZipFile(self.root / "artifact.zip", "w") as archive:
            for name, data in self.binaries.items():
                archive.writestr(name, data)
            archive.writestr("SHA256SUMS", sums)
            if extra is not None:
                archive.writestr(extra, b"unexpected")
        self.meta.update(size_in_bytes=(self.root / "artifact.zip").stat().st_size,
                         digest="sha256:" + digest(self.root / "artifact.zip"))
        put(self.root / "artifact.json", self.meta)
        put(self.root / "run.json", self.run)

    def test_valid_exact_artifact(self):
        result = verify(self.root, **self.options)
        self.assertEqual(set(result["sha256"]), BINARIES)
        for name, data in self.binaries.items():
            self.assertEqual((self.root / name).read_bytes(), data)

    def test_wrong_source_repository_or_unfinished_build(self):
        for field, value in [("head_sha", "b" * 40), ("repository", {"id": 34}),
                             ("status", "in_progress"), ("path", ".github/workflows/release.yml")]:
            with self.subTest(field=field):
                changed = {**self.run, field: value}
                put(self.root / "run.json", changed)
                with self.assertRaises(ValueError):
                    verify(self.root, **self.options)

    def test_outer_and_inner_hashes_are_independent(self):
        (self.root / "artifact.zip").write_bytes((self.root / "artifact.zip").read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "ZIP digest/size"):
            verify(self.root, **self.options)
        sums = "".join(f"{'0' * 64}  {name}\n" for name in self.binaries)
        self.archive(sums=sums)
        with self.assertRaisesRegex(ValueError, "binary digest"):
            verify(self.root, **self.options)

    def test_archive_scope_checksum_duplicates_and_architecture(self):
        self.archive(extra="../escaped")
        with self.assertRaises(ValueError):
            verify(self.root, **self.options)
        line = f"{'0' * 64}  main_eio.exe\n"
        self.archive(sums=line * 4)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            verify(self.root, **self.options)
        self.binaries["main_eio.exe"] = b"not an ELF64 executable"
        self.archive()
        with self.assertRaisesRegex(ValueError, "ELF64"):
            verify(self.root, **self.options)

    def test_output_symlink_is_not_followed(self):
        outside = self.root / "outside"
        outside.write_text("preserve")
        (self.root / "main_eio.exe").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            verify(self.root, **self.options)
        self.assertEqual(outside.read_text(), "preserve")


class ReceiptTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.expected = dict(source="a" * 40, artifact={}, run_id=11, sha256={"main_eio.exe": "b" * 64})
        self.entry = dict(encoding="identity", text_kind="ascii")
        self.options = dict(tasks=1, cycles=1, workers=1, runner_hash="runner", fixture_hash="fixture")
        identity = dict(self.expected, tasks=1, cycles=1, workers=1, encoding="identity", text_kind="ascii",
                        runner_sha256="runner", fixture_sha256="fixture", base=str(self.root / "owned"))
        put(self.root / "identity.json", identity)
        self.workers = [dict(id=None, name="fixture-worker-0000", agent_type="fixture", status="active",
                             capabilities=[], current_task=None, session_bound_at="2001-09-09T01:46:40Z",
                             last_seen="2001-09-09T01:46:40Z", meta=None)]
        for name in ("worker-fixture.json", "workers-after.json"):
            put(self.root / name, self.workers)
        put(self.root / "cleanup.json", dict(reaped=True, server_returncode=0, stub_stopped=True, model_requests=[]))
        health = dict(keeper_fibers=0, paths={"effective_masc_root": identity["base"] + "/.masc"},
                      build=dict(binary_commit=self.expected["source"], executable_sha256="b" * 64,
                                 runtime_instance_id="one-instance"))
        put(self.root / "health-before.json", health)
        put(self.root / "health-after.json", health)
        tasks = [dict(id=f"task-{n:03d}", title=f"task {n}", status="todo",
                      created_at="now", updated_at="now") for n in range(1, 4)]
        put(self.root / "success.json", dict(initial_revision=1, final_revision=4, final_tasks=3))
        for name in ("backlog.json", "backlog.json.last-good"):
            put(self.root / name, dict(tasks=tasks, version=4))
        self.rows = []
        for phase, rpc_id, method in [("initialize", 1, "initialize"), ("registry", 2, "tools/list"),
                                      ("seed", 3, "tools/call")]:
            result = {"structuredContent": {"ok": True}} if phase == "seed" else {}
            self.add(phase, {"id": rpc_id, "result": result}, rpc_id=rpc_id, rpc_method=method,
                     tool="masc_batch_add_tasks" if phase == "seed" else None)
        self.add("prime", dict(tasks=tasks[:1], execution_publication_generation=1))
        self.add("mutation", {"id": 4, "result": {"structuredContent": {"ok": True, "task_id": "task-002"}}},
                 rpc_id=4, rpc_method="tools/call", tool="masc_add_task")
        body = dict(tasks=tasks[:2], execution_publication_generation=2, execution_invalidated=False,
                    query={"actor": None, "default_light_request": True})
        self.add("cold", body, server_timing="cache_compute;dur=1")
        self.add("warm", body, server_timing="cache_hit;dur=0")
        self.add("concurrent_mutation", {"id": 5, "result": {"structuredContent": {"ok": True, "task_id": "task-003"}}},
                 rpc_id=5, rpc_method="tools/call", tool="masc_add_task")
        self.add("concurrent_liveness", {"live": True})

    def add(self, phase, body, **extra):
        is_rpc = phase in ("initialize", "registry", "seed", "mutation", "concurrent_mutation")
        if phase in ("prime", "cold", "warm"):
            body = {**body, "agents": self.workers, "offline_worker_briefs": [],
                    "worker_support_briefs": [dict(name="fixture-worker-0000", status="active",
                        active_task_count=0, state="quiet", last_signal_at="2001-09-09T01:46:40Z",
                        last_signal_age_sec=100)]}
        raw = json.dumps(body)
        self.rows.append(dict(phase=phase, cycle=1 if phase in (
            "mutation", "cold", "warm", "concurrent_mutation", "concurrent_liveness") else None,
            status=200, start_ns=0, end_ns=1000000, wire_ms=1., body_utf8=raw,
            body_sha256=hashlib.sha256(raw.encode()).hexdigest(), json_bytes=len(raw.encode()), encoding=None,
            requested_encoding="identity",
            method="POST" if is_rpc else "GET",
            path="/mcp" if is_rpc else ("/health/live" if phase == "concurrent_liveness" else "/api/v1/dashboard/execution"),
            arguments_sha256="inputs", **extra))

    def check(self):
        (self.root / "requests.jsonl").write_text("".join(json.dumps(row) + "\n" for row in self.rows))
        return validate_session(self.root, self.entry, self.expected, **self.options)

    def test_complete_receipts_and_overlap(self):
        rows, summary, semantics = self.check()
        self.assertEqual(len(rows), 5)
        self.assertEqual(summary["client_overlap_pairs"], 1)
        self.assertEqual(len(semantics["persisted_tasks"]), 3)
        self.assertEqual(len(semantics["worker_snapshots"]), 2)

    def test_worker_disappearance_or_reclassification_is_rejected(self):
        original = copy.deepcopy(self.rows)
        for change in (dict(agents=[]), dict(worker_support_briefs=[]),
                       dict(offline_worker_briefs=[{"name": "fixture-worker-0000"}])):
            with self.subTest(change=change):
                self.rows = copy.deepcopy(original)
                row = next(r for r in self.rows if r["phase"] == "prime")
                raw = json.dumps(json.loads(row["body_utf8"]) | change)
                row.update(body_utf8=raw, body_sha256=hashlib.sha256(raw.encode()).hexdigest(),
                           json_bytes=len(raw.encode()))
                with self.assertRaisesRegex(ValueError, "worker projection"):
                    self.check()

    def test_worker_count_ownership_and_persisted_records_are_checked(self):
        row = next(r for r in self.rows if r["phase"] == "prime")
        body = json.loads(row["body_utf8"])
        body["worker_support_briefs"][0]["active_task_count"] = 1
        raw = json.dumps(body)
        row.update(body_utf8=raw, body_sha256=hashlib.sha256(raw.encode()).hexdigest(), json_bytes=len(raw.encode()))
        with self.assertRaisesRegex(ValueError, "worker support state/count"):
            self.check()
        put(self.root / "workers-after.json", [])
        with self.assertRaisesRegex(ValueError, "worker records changed"):
            self.check()

    def test_empty_fleet_is_an_explicit_workload(self):
        self.options["workers"] = 0
        identity = json.loads((self.root / "identity.json").read_text())
        identity["workers"] = 0
        put(self.root / "identity.json", identity)
        for name in ("worker-fixture.json", "workers-after.json"):
            put(self.root / name, [])
        for row in self.rows:
            if row["phase"] in ("prime", "cold", "warm"):
                body = json.loads(row["body_utf8"])
                body.update(agents=[], worker_support_briefs=[])
                raw = json.dumps(body)
                row.update(body_utf8=raw, body_sha256=hashlib.sha256(raw.encode()).hexdigest(),
                           json_bytes=len(raw.encode()))
        _, _, semantics = self.check()
        self.assertEqual(semantics["worker_fixture"], [])

    def test_missing_receipt_never_yields_a_full_summary(self):
        self.rows.pop()
        with self.assertRaisesRegex(ValueError, "incomplete request"):
            self.check()

    def test_requested_and_actual_encoding_remain_distinct(self):
        self.entry["encoding"] = "gzip"
        identity = json.loads((self.root / "identity.json").read_text())
        identity["encoding"] = "gzip"
        put(self.root / "identity.json", identity)
        for row in self.rows:
            if row["phase"] in ("prime", "cold", "warm"):
                row["requested_encoding"] = "gzip"
        rows, _, _ = self.check()
        self.assertTrue(all(row["encoding"] is None for row in rows))
        self.entry["encoding"] = "identity"
        identity["encoding"] = "identity"
        put(self.root / "identity.json", identity)
        for row in self.rows:
            row["requested_encoding"] = "identity"
        next(row for row in self.rows if row["phase"] == "cold")["encoding"] = "gzip"
        with self.assertRaisesRegex(ValueError, "response encoding"):
            self.check()

    def test_every_identity_request_rejects_gzip(self):
        for phase in ("initialize", "registry", "seed", "prime", "mutation",
                      "concurrent_mutation", "concurrent_liveness"):
            with self.subTest(phase=phase):
                row = next(r for r in self.rows if r["phase"] == phase)
                row["encoding"] = "gzip"
                with self.assertRaisesRegex(ValueError, "response encoding"):
                    self.check()
                row["encoding"] = None

    def test_http_success_does_not_hide_tool_failure(self):
        row = next(r for r in self.rows if r["phase"] == "mutation")
        body = json.loads(row["body_utf8"])
        body["result"]["isError"] = True
        raw = json.dumps(body)
        row.update(body_utf8=raw, body_sha256=hashlib.sha256(raw.encode()).hexdigest(), json_bytes=len(raw))
        with self.assertRaisesRegex(ValueError, "tool failure"):
            self.check()

    def test_wrong_endpoint_and_runtime_change_are_rejected(self):
        saved = copy.deepcopy(self.rows)
        next(r for r in self.rows if r["phase"] == "cold")["path"] = "/health"
        with self.assertRaisesRegex(ValueError, "endpoint"):
            self.check()
        self.rows = saved
        after = json.loads((self.root / "health-after.json").read_text())
        after["build"]["runtime_instance_id"] = "another-instance"
        put(self.root / "health-after.json", after)
        with self.assertRaisesRegex(ValueError, "instance changed"):
            self.check()

    def test_failure_cleanup_or_model_post_prevents_acceptance(self):
        for change in [dict(reaped=False), dict(server_returncode=1),
                       dict(model_requests=[{"method": "POST", "path": "/v1/chat/completions"}])]:
            with self.subTest(change=change):
                put(self.root / "cleanup.json", dict(reaped=True, server_returncode=0,
                                                      stub_stopped=True, model_requests=[]) | change)
                with self.assertRaisesRegex(ValueError, "unclean shutdown"):
                    self.check()


if __name__ == "__main__":
    unittest.main()
