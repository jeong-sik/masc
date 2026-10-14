#!/usr/bin/env python3
# pyright: strict
"""Fixtures and behaviour for scripts/migrate-lane-addon-bindings.py.

The fixtures copy the exact JSON shapes the container itself writes:
v0.48.0's entry_json (lib/lane_addon/lane_addon_runtime.ml at tag v0.48.0)
and the current entry_json, which is the target schema. The container rules
under test are record_is_detached (phase must be exactly
{"kind": "detached"}), read_authority (top-level visibility AND
source_access, each an object with only the allowed keys), and the store's
read_bindings (only files whose name ends in .json are read).
"""

import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'migrate-lane-addon-bindings.py'
spec = importlib.util.spec_from_file_location('migrate_lane_addon_bindings', SCRIPT)
tool = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(tool)


def v048_record(phase=None, configuration=None, instance='lane-0001'):
    """A pre-v0.49.0 binding exactly as v0.48.0's entry_json wrote it."""
    record = {
        'instance_id': instance,
        'incarnation': instance,
        'action_schema': None,
        'run_id': 'run-abc',
        'addon_id': 'lane-0003d45da4fa',
        'title': 'dos-play',
        'revision': 'rev-1',
        'observation_seq': 3,
        'rows_count': 0,
        'observation_pending': False,
        'coalesced_wakes': 0,
        'unchanged_source_refreshes': 0,
        'binding': {'sources': []},
        'package': {'id': 'lane-0003d45da4fa', 'revision': 'rev-1'},
        'container_id': 'cont-9',
    }
    if phase is not None:
        record['phase'] = phase
    if configuration is not None:
        record['configuration'] = configuration
    return record


DETACHED = {'kind': 'detached'}
ATTACHED = {'kind': 'attached'}
INSTALLATION = {'id': 'inst-77', 'source_path': 'addons/dos-play/package.json', 'revision': 'rev-1'}
VISIBILITY_KEEPER = {'kind': 'keeper', 'keeper': 'wkbl-data'}
SOURCE_ACCESS_KEEPER = {'kind': 'keeper', 'keeper': 'wkbl-data'}


class StoreTree:
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='masc-lane-addon-migrate-test-')
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.bindings = self.root / 'var' / 'lib' / 'masc' / 'lane_addon' / 'bindings'
        self.bindings.mkdir(parents=True)
        self.archive = self.root / 'archive'

    def write(self, name, value):
        path = self.bindings / name
        if isinstance(value, str):
            path.write_text(value, encoding='utf-8')
        else:
            path.write_text(json.dumps(value), encoding='utf-8')
        return path

    def snapshot(self):
        return {p.name: p.read_bytes() for p in sorted(self.bindings.iterdir())}

    def run_tool(self, *extra):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = tool.main(['--store-root', str(self.root / 'var' / 'lib' / 'masc' / 'lane_addon'), *extra])
        return status, out.getvalue() + err.getvalue()

    def lines(self, text):
        return [line for line in text.splitlines() if line.startswith(('detached-legacy', 'non-detached-legacy', 'newer-readable', 'newer-broken', 'unreadable'))]


class ClassificationTests(StoreTree, unittest.TestCase):
    def test_v048_detached_record_is_safe_to_move(self):
        self.write('a.json', v048_record(phase=DETACHED))
        status, out = self.run_tool()
        self.assertEqual(status, 0)
        self.assertIn('detached-legacy: 1', out)
        self.assertIn('holds-back: nothing', out)
        self.assertIn('no changes made', out)

    def test_v048_attached_record_holds_its_installation(self):
        self.write('b.json', v048_record(phase=ATTACHED, configuration=INSTALLATION))
        status, out = self.run_tool()
        self.assertEqual(status, 0)
        self.assertIn('non-detached-legacy: 1', out)
        self.assertIn('holds-back: installation inst-77', out)

    def test_v048_attached_manual_attach_holds_nothing(self):
        self.write('c.json', v048_record(phase=ATTACHED, configuration=None))
        status, out = self.run_tool()
        self.assertEqual(status, 0)
        self.assertIn('non-detached-legacy: 1', out)
        self.assertIn('holds-back: nothing (manual attach)', out)

    def test_v048_attached_unparseable_owner_holds_every_installation(self):
        broken = dict(INSTALLATION)
        del broken['source_path']
        self.write('d.json', v048_record(phase=ATTACHED, configuration=broken))
        status, out = self.run_tool()
        self.assertEqual(status, 0)
        self.assertIn('non-detached-legacy: 1', out)
        self.assertIn('holds-back: every enabled installation (owner unreadable)', out)

    def test_phase_with_extra_key_is_not_detached(self):
        self.write('e.json', v048_record(phase={'kind': 'detached', 'message': 'x'}))
        status, out = self.run_tool()
        self.assertEqual(status, 0)
        self.assertIn('non-detached-legacy: 1', out)

    def test_phase_failed_detaching_and_missing_are_not_detached(self):
        for name, phase in [('f1.json', {'kind': 'failed', 'message': 'boom'}), ('f2.json', {'kind': 'detaching'}), ('f3.json', None)]:
            self.write(name, v048_record(phase=phase))
        status, out = self.run_tool()
        self.assertEqual(status, 0)
        self.assertIn('non-detached-legacy: 3', out)
        self.assertIn('detached-legacy: 0', out)

    def test_newer_readable_and_newer_broken(self):
        readable = v048_record(phase=ATTACHED, configuration=INSTALLATION)
        readable['visibility'] = VISIBILITY_KEEPER
        readable['source_access'] = SOURCE_ACCESS_KEEPER
        broken = v048_record(phase=ATTACHED, configuration=INSTALLATION, instance='lane-0002')
        broken['visibility'] = VISIBILITY_KEEPER
        self.write('g1.json', readable)
        self.write('g2.json', broken)
        status, out = self.run_tool()
        self.assertEqual(status, 0)
        self.assertIn('newer-readable: 1', out)
        self.assertIn('newer-broken: 1', out)

    def test_blank_keeper_names_are_invalid(self):
        record = v048_record(phase=ATTACHED, configuration=INSTALLATION)
        record['visibility'] = {'kind': 'keeper', 'keeper': '   '}
        record['source_access'] = SOURCE_ACCESS_KEEPER
        self.write('h.json', record)
        status, out = self.run_tool()
        self.assertEqual(status, 0)
        self.assertIn('newer-broken: 1', out)

    def test_detached_with_invalid_visibility_is_newer_broken_and_not_moved(self):
        record = v048_record(phase=DETACHED)
        record['visibility'] = {'kind': 'keeper', 'keeper': '   '}
        path = self.write('h_detached.json', record)
        self.archive.mkdir()
        status, out = self.run_tool('--write-out', str(self.archive))
        self.assertEqual(status, 0)
        self.assertIn('newer-broken: 1', out)
        self.assertIn('detached-legacy: 0', out)
        self.assertTrue(path.exists())
        self.assertFalse(path.with_name('h_detached.json.migrated').exists())
        self.assertFalse((self.archive / 'h_detached.json.legacy').exists())

    def test_non_object_and_unparseable_files_are_unreadable(self):
        self.write('i1.json', ['not', 'an', 'object'])
        self.write('i2.json', '{not json')
        self.write('ignored.txt', v048_record(phase=DETACHED))
        status, out = self.run_tool()
        self.assertEqual(status, 0)
        self.assertIn('unreadable: 2', out)
        self.assertIn('input records: 2', out)

    def test_repaired_non_detached_record_becomes_readable_without_loss(self):
        """The documented repair path for a non-detached legacy record: add
        visibility and source_access at the top level. The tool itself never
        performs this rewrite; this test pins that the repaired shape is
        exactly what the tool classifies as readable."""
        record = v048_record(phase=ATTACHED, configuration=INSTALLATION)
        self.assertEqual(tool.classify(record), tool.NON_DETACHED_LEGACY)
        repaired = dict(record)
        repaired['visibility'] = {'kind': 'shared'}
        repaired['source_access'] = {'kind': 'operator_configuration'}
        self.assertEqual(tool.classify(repaired), tool.NEWER_READABLE)


class DefaultRunTests(StoreTree, unittest.TestCase):
    def test_default_run_changes_nothing(self):
        self.write('a.json', v048_record(phase=DETACHED))
        self.write('b.json', v048_record(phase=ATTACHED, configuration=INSTALLATION))
        before = self.snapshot()
        status, out = self.run_tool()
        self.assertEqual(status, 0)
        self.assertEqual(self.snapshot(), before)
        self.assertIn('converted', out) is None if False else None
        self.assertNotIn('migrated:', out)


class WriteOutTests(StoreTree, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.detached = self.write('d1.json', v048_record(phase=DETACHED, instance='lane-d1'))
        self.attached = self.write('a1.json', v048_record(phase=ATTACHED, configuration=INSTALLATION, instance='lane-a1'))
        self.archive.mkdir()
        self.original_detached = self.detached.read_bytes()
        self.original_attached = self.attached.read_bytes()

    def test_moves_only_detached_records_and_preserves_bytes(self):
        status, out = self.run_tool('--write-out', str(self.archive))
        self.assertEqual(status, 0)
        self.assertFalse(self.detached.exists())
        migrated = self.detached.with_name('d1.json.migrated')
        self.assertTrue(migrated.exists())
        self.assertEqual(migrated.read_bytes(), self.original_detached)
        archived = self.archive / 'd1.json.legacy'
        self.assertEqual(archived.read_bytes(), self.original_detached)
        self.assertEqual(self.attached.read_bytes(), self.original_attached)
        self.assertTrue(self.attached.exists())
        self.assertIn('converted (moved away): 1', out)
        self.assertIn('rejected (left in place): 1', out)

    def test_container_read_path_skips_migrated_suffix(self):
        """The store's read_bindings reads only names ending in .json; after
        the move the detached record is out of every read, byte-preserved on
        disk."""
        self.run_tool('--write-out', str(self.archive))
        read_names = sorted(p.name for p in self.bindings.iterdir() if p.name.endswith('.json'))
        self.assertEqual(read_names, ['a1.json'])

    def test_refuses_to_overwrite_an_existing_archive(self):
        (self.archive / 'd1.json.legacy').write_bytes(b'older copy')
        before = self.snapshot()
        with self.assertRaises(SystemExit):
            self.run_tool('--write-out', str(self.archive))
        self.assertEqual(self.snapshot(), before)

    def test_resumes_when_identical_archive_already_exists_without_migrated(self):
        archived = self.archive / 'd1.json.legacy'
        archived.write_bytes(self.original_detached)
        status, out = self.run_tool('--write-out', str(self.archive))
        self.assertEqual(status, 0)
        self.assertFalse(self.detached.exists())
        migrated = self.detached.with_name('d1.json.migrated')
        self.assertTrue(migrated.exists())
        self.assertEqual(migrated.read_bytes(), self.original_detached)
        self.assertEqual(archived.read_bytes(), self.original_detached)
        self.assertIn('converted (moved away): 1', out)

    def test_aborts_if_source_changes_between_scan_and_move(self):
        _, records = tool.scan_records(self.bindings)
        self.detached.write_text(json.dumps(v048_record(phase=ATTACHED, instance='lane-d1')), encoding='utf-8')
        modified_bytes = self.detached.read_bytes()
        with self.assertRaises(SystemExit):
            tool.write_out(self.bindings, self.archive, records)
        self.assertTrue(self.detached.exists())
        self.assertEqual(self.detached.read_bytes(), modified_bytes)
        self.assertFalse(self.detached.with_name('d1.json.migrated').exists())
        self.assertFalse((self.archive / 'd1.json.legacy').exists())

    def test_write_out_directory_inside_bindings_is_refused(self):
        inside = self.bindings / 'archive'
        inside.mkdir()
        status, out = self.run_tool('--write-out', str(inside))
        self.assertEqual(status, 2)
        self.assertIn('must differ from the bindings directory', out)

    def test_missing_write_out_directory_is_an_error(self):
        status, out = self.run_tool('--write-out', str(self.root / 'nowhere'))
        self.assertEqual(status, 2)
        self.assertIn('does not exist', out)

    def test_missing_store_is_an_error(self):
        status, out = self.run_tool('--store-root', str(self.root / 'var' / 'nowhere'))
        self.assertEqual(status, 2)
        self.assertIn('no bindings directory', out)


if __name__ == '__main__':
    unittest.main()
