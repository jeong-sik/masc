"""Exercise the CI-built CLI with original media fixtures and real tools."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE_MODULES = (
    "bin/masc_cli_inspect_file.ml",
    "lib/verification_media_inspection.ml",
    "lib/verification_pdf_inspection.ml",
    "lib/verification_presentation_inspection.ml",
    "lib/verification_video_inspection.ml",
)
BINARY = None
PRESENTATION_BASE = None
if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    parser.add_argument('--presentation-base')
    arguments = parser.parse_args()
    BINARY = str(Path(arguments.binary).resolve())
    PRESENTATION_BASE = arguments.presentation_base


def digest(data):
    return hashlib.sha256(data).hexdigest()


@unittest.skipUnless(BINARY, 'requires CI-built native CLI')
class OperatorInspection(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = self.root / 'workspace'
        self.base.mkdir()
        # This is the actual Task store location (Workspace_utils.backlog_path).
        backlog = self.base / '.masc/tasks/backlog.json'
        backlog.parent.mkdir(parents=True)
        backlog.write_text('{"tasks":[],"last_updated":"inspection-sentinel"}\n')

    def invoke(self, path, *, base=None, env=None, expected=0, identity=True):
        assert BINARY is not None
        base = base or self.base
        original = path.read_bytes() if identity and path.is_file() else None
        state = base / '.masc'
        watched = ['tasks/backlog.json', 'tasks', 'tasks-archive.json', 'goals.json',
                   'verification-runs.jsonl', 'goal-verification-runs.jsonl', 'config']
        def snapshot():
            files = []
            for name in watched:
                entry = state / name
                files.extend(entry.rglob('*') if entry.is_dir() else [entry])
            return {str(p): digest(p.read_bytes()) for p in files if p.is_file()}
        before = snapshot()
        result = subprocess.run([BINARY, 'inspect-file', '--base-path', str(base), str(path)],
                                capture_output=True, text=True, env=env, cwd=self.root,
                                timeout=240)
        self.assertEqual(result.returncode, expected, result.stderr + '\n' + result.stdout[:2000])
        payload = json.loads(result.stdout)
        self.assertEqual(payload['schema'], 'masc.operator_file_inspection.v1')
        self.assertEqual(payload['llm_verdict'], 'not_run')
        self.assertEqual(payload['result']['disposition'], 'completed' if expected == 0 else 'failed')
        self.assertEqual(snapshot(), before, 'inspection changed domain state or configuration')
        capture = state / 'execute_output'
        self.assertFalse(capture.exists() and any(p.is_file() for p in capture.rglob('*')), 'temporary capture leaked')
        if original is not None:
            self.assertEqual(path.read_bytes(), original, 'input changed')
            self.assertEqual(payload['source']['sha256'], digest(original))
            self.assertEqual(payload['source']['bytes'], len(original))
        return payload

    def copy(self, relative, name):
        path = self.root / name
        path.write_bytes((ROOT / relative).read_bytes())
        return path

    def assert_images(self, payload, pages):
        images = [item for item in payload['content'] if item['type'] == 'image']
        self.assertEqual(len(images), len(pages))
        for image, page in zip(images, pages):
            data = base64.b64decode(image['data'], validate=True)
            self.assertEqual(image['mimeType'], 'image/png')
            self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
            self.assertEqual(digest(data), page['rendered_sha256'])
            self.assertEqual(len(data), page['rendered_bytes'])

    def test_pdf_returns_original_identity_and_every_actual_render(self):
        path = self.copy('docs/evidence/2026-09-10-collaboration-baseline/goal-publication/booklet.pdf', 'original.pdf')
        payload = self.invoke(path)
        data = payload['result']['data']
        self.assertEqual(data['sha256'], payload['source']['sha256'])
        self.assertGreater(data['page_count'], 1)
        self.assertEqual(data['page_count'], len(data['pages']))
        self.assert_images(payload, data['pages'])

    def test_mp4_decodes_all_actual_audio_video_streams(self):
        path = self.copy('test/fixtures/verifier-video.mp4', 'original.mp4')
        payload = self.invoke(path)
        data = payload['result']['data']['inspection']
        self.assertEqual(data['sha256'], payload['source']['sha256'])
        self.assertTrue(data['audio_present'] and data['video_present'])
        self.assertEqual(data['full_decode']['exit_code'], 0)
        self.assertEqual(data['decoded_stream_indices'],
                         [s['index'] for s in data['streams'] if s['kind'] in ('audio', 'video')])
        self.assertFalse(data['visual_input'])

    def test_pptx_uses_managed_parser_and_returns_every_slide(self):
        # RUNNER_TEMP is the existing CI preparation contract and remains
        # stable when Dune changes TMPDIR. Manual artifact checks can supply
        # --presentation-base explicitly.
        if PRESENTATION_BASE:
            base = Path(PRESENTATION_BASE).resolve()
        else:
            self.assertIn('RUNNER_TEMP', os.environ,
                          'prepare presentation fixtures and pass --presentation-base')
            base = Path(os.environ['RUNNER_TEMP']) / 'masc-presentation-verifier'
        self.assertTrue((base / 'inputs/presentation.pptx').is_file(),
                        'run scripts/ci/prepare-presentation-verifier.py first')
        path = self.root / 'original.pptx'
        path.write_bytes((base / 'inputs/presentation.pptx').read_bytes())
        expected = json.loads((base / 'inputs/expected.json').read_text())
        payload = self.invoke(path, base=base)
        data = payload['result']['data']
        self.assertEqual(data['sha256'], expected['sha256'])
        self.assertEqual(data['slide_count'], 2)
        self.assertEqual([s['speaker_notes'] for s in data['slides']], ['Speaker note one', 'Speaker note two'])
        self.assert_images(payload, data['rendered_slides'])
        self.assertEqual([s['visible'] for s in data['slides']], [True, False])
        self.assertEqual(data['slides'][0]['hyperlinks'], ['https://example.invalid/reference'])

    def test_missing_dependency_preserves_source_identity_and_typed_failure(self):
        path = self.copy('test/fixtures/verifier-video.mp4', 'original.mp4')
        empty = self.root / 'empty-path'
        empty.mkdir()
        payload = self.invoke(path, env=dict(os.environ, PATH=str(empty)), expected=1)
        self.assertEqual(payload['result']['failure_class'], 'dependency_unavailable')
        self.assertIn('video_dependency_unavailable', payload['result']['message'])
        self.assertEqual(payload['content'], [])

    def test_truncated_original_is_not_success(self):
        path = self.copy('test/fixtures/verifier-video.mp4', 'truncated.mp4')
        path.write_bytes(path.read_bytes()[:len(path.read_bytes()) // 2])
        payload = self.invoke(path, expected=1)
        self.assertEqual(payload['result']['failure_class'], 'runtime_failure')

    def test_unknown_and_missing_files_are_explicit_failures(self):
        unknown = self.root / 'unsupported.txt'
        unknown.write_text('This is not a media inspection.')
        for path in [unknown, self.root / 'missing.pdf']:
            payload = self.invoke(path, expected=1)
            self.assertEqual(payload['result']['failure_class'], 'workflow_rejection')

    def test_extensionless_mp4_uses_the_same_signature_detection(self):
        path = self.copy('test/fixtures/verifier-video.mp4', 'capture')
        payload = self.invoke(path)
        self.assertEqual(payload['result']['data']['inspection']['sha256'],
                         payload['source']['sha256'])

    def test_symlink_is_refused_before_reading_the_target(self):
        original = self.copy('test/fixtures/verifier-video.mp4', 'target.mp4')
        link = self.root / 'link.mp4'
        link.symlink_to(original)
        payload = self.invoke(link, expected=1, identity=False)
        self.assertEqual(payload['result']['failure_class'], 'policy_rejection')
        self.assertIsNone(payload['source'])

    def test_oversized_source_is_refused_without_hashing_a_prefix(self):
        path = self.root / 'oversized.pdf'
        with path.open('wb') as output:
            output.truncate(128 * 1024 * 1024)
        payload = self.invoke(path, expected=1, identity=False)
        self.assertEqual(payload['result']['failure_class'], 'policy_rejection')
        self.assertIn('media_source_too_large', payload['result']['message'])
        self.assertIsNone(payload['source'])


if __name__ == '__main__':
    unittest.main(argv=[__file__])
