"""Real private outbox durability with fabricated credential/Browser edges.

No host publication ACK, Keeper wake, Chrome or real 1Password account runs.
"""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "onepassword"))
from login import Extension, Journal, LoginError, Logins
import oauth
from onepassword_store_fixture import MemoryRecords, active_raw, replace_active_raw
from oauth import ConnectionError
from test_onepassword_login import APP_LINK, BROWSER, CALLER, REFERENCE, Bridge, Connector


class PublicationTests(unittest.TestCase):
    def setUp(self):
        backend = mock.patch.object(oauth, "ProtectedRecords", MemoryRecords)
        backend.start()
        self.addCleanup(backend.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "journal"
        self.path = self.directory / "operations.reference.json"
        self.journal = Journal(self.directory, provision=True)
        self.connector, self.bridges = Connector(), []
        self.extension = Extension(Path(self.temp.name) / "extension", "a" * 32)
        self.now = 1000.
        self.uncertain = set()
        self.engine = self.make_engine()

    def make_engine(self):
        def create(_descriptor):
            bridge = Bridge()
            bridge.journal_store = self.journal
            self.bridges.append(bridge)
            return bridge
        engine = Logins(self.connector, self.journal, self.extension,
                        bridge=create, clock=lambda: self.now)

        def close():
            if engine in self.uncertain:
                with self.assertRaisesRegex(LoginError, "^outcome_unknown$"):
                    engine.close()
            else:
                engine.close()
        self.addCleanup(close)
        return engine

    def start(self, *, tab_id=7):
        result, admitted = self.engine.reserve(descriptor={"private": "PRIVATE_CAPABILITY_MARKER"},
            caller=CALLER, browser_instance_id=BROWSER, tab_id=tab_id,
            website="https://example.test/login", goal="Sign in", reason="Continue")
        self.assertTrue(admitted)
        operation = result["operation_id"]
        self.engine.request(operation, CALLER, goal="Sign in", reason="Continue")
        return operation

    def ready(self):
        operation = self.start()
        self.engine.opened(operation)
        self.now += 5.
        self.bridges[-1].responses.append({"state": "resolved", "granted": True, "reference": REFERENCE})
        return operation, self.bridges[-1]

    def pending(self, operation):
        return self.engine.pending_publications(operation, CALLER)

    def record(self):
        return json.loads(active_raw(self.journal))["operations"][0]

    def test_attention_and_state_commit_together_without_poll_wakes_or_private_data(self):
        operation = self.start()
        notices = self.pending(operation)
        self.assertEqual(len(notices), 1)
        self.assertEqual(notices[0]["kind"], "attention_required")
        self.assertEqual(notices[0]["output"], self.engine.status(operation, CALLER))
        stored = self.record()["publications"][0]
        self.assertEqual(stored["publication_id"], notices[0]["publication_id"])
        self.assertEqual(stored["phase"], self.record()["phase"])
        self.assertFalse(stored["host_accepted"])
        self.assertEqual(self.engine.approval(operation), {"open_url": APP_LINK})
        self.engine.opened(operation)
        self.now += 5.
        self.engine.advance(operation, CALLER)
        self.assertEqual(self.pending(operation), notices)
        self.now += 121.
        self.engine.advance(operation, CALLER)
        waiting = self.pending(operation)
        self.assertEqual([n["output"]["phase"] for n in waiting], ["approval_ready", "waiting_user"])
        self.engine.advance(operation, CALLER)
        self.assertEqual(self.pending(operation), waiting)
        self.assertNotIn("PRIVATE_", json.dumps(waiting))
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)

    def test_each_explicit_fill_keeps_its_own_notice_and_terminal_is_not_website_auth(self):
        operation, bridge = self.ready()
        self.engine.advance(operation, CALLER)
        first = self.pending(operation)
        self.engine.reserve_fill(operation, CALLER)
        self.engine.fill(operation, CALLER)
        both = self.pending(operation)
        self.assertEqual(both[:len(first)], first)
        self.assertEqual(both[-2]["output"], both[-1]["output"])
        self.assertNotEqual(both[-2]["publication_id"], both[-1]["publication_id"])
        self.engine.reserve_finish(operation, CALLER)
        self.engine.finish(operation, CALLER)
        notices = self.pending(operation)
        self.assertEqual([n["kind"] for n in notices],
                         ["attention_required", "effect_submitted", "effect_submitted", "terminal"])
        self.assertEqual(notices[-1]["output"]["phase"], "released")
        self.assertTrue(all(n["output"]["website_login_verified"] is False for n in notices))
        self.assertNotIn("PRIVATE_", json.dumps(notices))
        self.assertEqual([name for name, _ in bridge.calls].count("fill"), 2)

    def test_exact_ack_is_idempotent_and_never_changes_snapshot_or_grants_caller_authority(self):
        operation = self.start()
        envelope = self.pending(operation)[0]
        before = active_raw(self.journal).encode()
        for caller in [{"kind": "operator"}, {"kind": "keeper", "name": "other"}]:
            with self.assertRaises(LoginError):
                self.engine.acknowledge_publication(operation, caller, envelope)
        variants = []
        for key in ["fill_submitted", "website_login_verified"]:
            changed = copy.deepcopy(envelope)
            changed["output"][key] = 0
            variants.append(changed)
        changed = copy.deepcopy(envelope)
        changed["output"]["phase"] = "released"
        variants += [changed, {**envelope, "extra": True}]
        for changed in variants:
            with self.assertRaises(LoginError):
                self.engine.acknowledge_publication(operation, CALLER, changed)
        self.assertEqual(active_raw(self.journal).encode(), before)
        self.engine.acknowledge_publication(operation, CALLER, envelope)
        acknowledged = active_raw(self.journal).encode()
        self.assertEqual(self.pending(operation), [])
        self.assertEqual(self.engine.status(operation, CALLER), envelope["output"])
        self.engine.acknowledge_publication(operation, CALLER, envelope)
        self.assertEqual(active_raw(self.journal).encode(), acknowledged)
        self.assertTrue(self.record()["publications"][0]["host_accepted"])

    def test_restart_retains_original_envelopes_and_records_owner_loss_without_rebind(self):
        operation = self.start()
        original = self.pending(operation)
        self.engine.close()
        self.engine = self.make_engine()
        lost = self.pending(operation)
        self.assertEqual(lost[:-1], original)
        self.assertEqual(lost[-1]["kind"], "terminal")
        self.assertEqual(lost[-1]["output"]["phase"], "outcome_unknown")
        self.assertEqual(len(self.bridges), 1)
        self.engine.close()
        self.engine = self.make_engine()
        self.assertEqual(self.pending(operation), lost)
        self.assertEqual(len(self.bridges), 1)

    def _failed_fill_commit(self, *, committed):
        operation, bridge = self.ready()
        write, attempted = self.journal.write, []

        def fail(root, value):
            phase = value["operations"][0]["phase"]
            attempted.append(phase)
            if phase == "fill_submitted":
                if committed:
                    write(root, value)
                raise OSError("PRIVATE_STORAGE_FAILURE")
            write(root, value)

        self.uncertain.add(self.engine)
        with mock.patch.object(self.journal, "write", side_effect=fail):
            with self.assertRaisesRegex(LoginError, "^outcome_unknown$"):
                self.engine.advance(operation, CALLER)
            preserved = active_raw(self.journal).encode()
            for call in [lambda: self.pending(operation), lambda: self.engine.status(operation, CALLER),
                         lambda: self.engine.cancel(operation, CALLER)]:
                with self.assertRaisesRegex(LoginError, "^outcome_unknown$"):
                    call()
            self.assertEqual(active_raw(self.journal).encode(), preserved)
        self.assertEqual(attempted[-1], "fill_submitted")
        self.assertEqual(attempted.count("fill_submitted"), 1)
        snapshot = self.record()
        self.assertEqual(snapshot["phase"], "fill_submitted" if committed else "filling")
        expected = copy.deepcopy(snapshot["publications"])
        self.assertTrue(bridge.cancelled)
        self.assertEqual([name for name, _ in bridge.calls].count("fill"), 1)
        with self.assertRaisesRegex(LoginError, "^outcome_unknown$"):
            self.engine.close()
        self.engine = self.make_engine()
        recovered = self.record()
        self.assertEqual(recovered["publications"][:-1], expected)
        self.assertEqual(recovered["phase"], "outcome_unknown")
        self.assertIs(recovered["fill_submitted"], committed)
        self.assertEqual([name for name, _ in bridge.calls].count("fill"), 1)
        self.assertEqual(len(self.bridges), 1)

    def test_failure_before_fill_record_commit_never_synthesizes_submitted_notice(self):
        self._failed_fill_commit(committed=False)

    def test_failure_after_fill_record_commit_never_overwrites_persisted_notice(self):
        self._failed_fill_commit(committed=True)

    def test_uncertain_ack_commit_preserves_original_id_and_delivery_evidence(self):
        operation = self.start()
        envelope = self.pending(operation)[0]
        write = self.journal.write

        def fail(root, value):
            write(root, value)
            raise OSError("PRIVATE_ACK_FSYNC_FAILURE")

        self.uncertain.add(self.engine)
        with mock.patch.object(self.journal, "write", side_effect=fail):
            with self.assertRaisesRegex(LoginError, "^outcome_unknown$"):
                self.engine.acknowledge_publication(operation, CALLER, envelope)
        stored = self.record()["publications"][0]
        self.assertEqual(stored["publication_id"], envelope["publication_id"])
        self.assertTrue(stored["host_accepted"])
        with self.assertRaisesRegex(LoginError, "^outcome_unknown$"):
            self.engine.close()
        self.engine = self.make_engine()
        self.assertNotIn(envelope["publication_id"], [p["publication_id"] for p in self.pending(operation)])
        self.assertEqual(self.record()["publications"][0], stored)

    def test_corrupt_or_duplicate_publication_evidence_is_rejected_without_repair(self):
        self.start()
        self.engine.close()
        original = json.loads(active_raw(self.journal))
        variants = []
        for key, value in [("kind", "unknown"), ("phase", "requesting"), ("host_accepted", 1),
                           ("publication_id", "not-an-id"), ("extra", True)]:
            changed = copy.deepcopy(original)
            changed["operations"][0]["publications"][0][key] = value
            variants.append(changed)
        changed = copy.deepcopy(original)
        changed["operations"][0]["publications"] *= 2
        variants.append(changed)
        changed = copy.deepcopy(original)
        changed["operations"][0]["publications"] = []
        variants.append(changed)
        for value in variants:
            replace_active_raw(self.journal, json.dumps(value))
            before = active_raw(self.journal).encode()
            with self.journal.locked() as root:
                with self.assertRaises(ConnectionError):
                    self.journal.read(root)
            self.assertEqual(active_raw(self.journal).encode(), before)

    def test_publication_identity_cannot_be_reused_across_operations(self):
        self.start()
        self.start(tab_id=8)
        self.engine.close()
        value = json.loads(active_raw(self.journal))
        value["operations"][1]["publications"][0]["publication_id"] = value["operations"][0]["publications"][0]["publication_id"]
        replace_active_raw(self.journal, json.dumps(value))
        with self.journal.locked() as root:
            with self.assertRaisesRegex(ConnectionError, "^duplicate_login_publication$"):
                self.journal.read(root)


if __name__ == "__main__":
    unittest.main()
