"""Publication must reuse successful, matching, untampered RC bytes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('publication', ROOT / 'scripts/ci/prepare-release-publication.py')
pub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pub)
REPO = 'owner/repo'
SHA = 'a' * 40
RUN = dict(id=42, repository=dict(id=7, full_name=REPO), head_repository=dict(id=7),
           head_sha=SHA, path='.github/workflows/release-candidate.yml',
           event='workflow_dispatch', status='completed', conclusion='success', run_attempt=2)
RECEIPT = dict(schema_version=1, commit=SHA, run_attempt=2,
               run_url=f'https://github.com/{REPO}/actions/runs/42',
               checks_passed=True, published=False,
               results=dict(compile='success', behavior='success', installation='success'))


class PublicationTests(unittest.TestCase):
    def test_only_successful_exact_repository_full_rc_can_be_published(self):
        pub.validate_run(RUN, REPO, SHA, 42)
        for changes in [dict(head_sha='b' * 40), dict(status='in_progress'),
                        dict(conclusion='failure'), dict(path='.github/workflows/release.yml'),
                        dict(event='pull_request'), dict(head_repository=dict(id=8)),
                        dict(repository=dict(id=7, full_name='other/repo'))]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                pub.validate_run(RUN | changes, REPO, SHA, 42)

    def test_receipt_must_cover_the_same_attempt_and_all_required_scopes(self):
        pub.validate_receipt(RECEIPT, RUN, REPO)
        for changes in [dict(commit='b' * 40), dict(run_attempt=1), dict(checks_passed=False),
                        dict(run_url='https://github.com/other/repo/actions/runs/42'),
                        dict(results=dict(compile='success', behavior='skipped', installation='success'))]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                pub.validate_receipt(RECEIPT | changes, RUN, REPO)

    def test_artifact_expiry_provenance_and_digest_are_required(self):
        artifact = dict(id=9, name='distribution', expired=False, digest='sha256:' + 'b' * 64,
                        workflow_run=dict(id=42, head_sha=SHA))
        self.assertEqual(pub.select_artifact([artifact], 'distribution', RUN), artifact)
        for changes in [dict(expired=True), dict(digest=None),
                        dict(workflow_run=dict(id=43, head_sha=SHA)),
                        dict(workflow_run=dict(id=42, head_sha='b' * 40))]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                pub.select_artifact([artifact | changes], 'distribution', RUN)
        with self.assertRaises(ValueError):
            pub.select_artifact([], 'distribution', RUN)
        with self.assertRaises(ValueError):
            pub.select_artifact([artifact, artifact], 'distribution', RUN)

    def test_archive_bytes_are_checked_before_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'a.zip'
            with zipfile.ZipFile(archive, 'w') as bundle:
                bundle.writestr('asset', b'actual compiled artifact')
            digest = 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest()
            pub.extract_archive(archive, dict(digest=digest), root / 'good')
            self.assertEqual((root / 'good/asset').read_bytes(), b'actual compiled artifact')
            with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                pub.extract_archive(archive, dict(digest='sha256:' + '0' * 64), root / 'bad')
            self.assertFalse((root / 'bad').exists())

    def test_zip_paths_and_links_do_not_escape_staging(self):
        for name, mode in [('../outside', 0), ('/outside', 0), ('asset/.', 0), ('link', 0o120777)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = root / 'a.zip'
                with zipfile.ZipFile(archive, 'w') as bundle:
                    info = zipfile.ZipInfo(name)
                    info.external_attr = mode << 16
                    bundle.writestr(info, b'target')
                digest = 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest()
                with self.assertRaises(ValueError):
                    pub.extract_archive(archive, dict(digest=digest), root / 'out')

    def make_distribution(self, root):
        directory = root / 'assets'
        directory.mkdir()
        names = ['install.sh', 'install-runtime-setup.py', 'masc-exec-shim-linux-amd64', 'masc-exec-shim-linux-arm64']
        for arch in ('macos-arm64', 'macos-x64', 'linux-x64', 'linux-arm64'):
            names += [f'masc-{arch}', f'masc-tui-{arch}', f'masc-browser-host-{arch}',
                      f'masc-deployment-preflight-helper-{arch}', f'masc-check-runtime-deployment-preflight-{arch}',
                      f'masc-dashboard-{arch}.tar.gz', f'masc-release-dashboard-bundle-{arch}.py',
                      f'masc-runtime-{arch}.tar.gz']
        lines = []
        for name in names:
            body = f'verified bytes for {name}'.encode()
            (directory / name).write_bytes(body)
            lines.append(f'{hashlib.sha256(body).hexdigest()}  {name}\n')
        (root / 'config').mkdir()
        (root / 'config/runtime.toml').write_bytes(b'runtime = []\n')
        lines.append(f'{hashlib.sha256(b"runtime = []" + bytes([10])).hexdigest()}  runtime.toml\n')
        (directory / 'SHA256SUMS').write_text(''.join(lines))
        return directory

    def test_distribution_requires_all_platform_assets_and_matching_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = self.make_distribution(root)
            pub.validate_distribution(directory, root)
            target = directory / 'masc-linux-x64'
            original = target.read_bytes()
            target.write_bytes(b'different executable')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                pub.validate_distribution(directory, root)
            target.write_bytes(original)
            target.unlink()
            with self.assertRaisesRegex(ValueError, 'missing or unexpected'):
                pub.validate_distribution(directory, root)

    def test_newer_failed_rc_cannot_be_ignored(self):
        def request(repo, endpoint, **kwargs):
            if endpoint.startswith('git/ref/'):
                return dict(object=dict(type='commit', sha=SHA))
            if endpoint == 'actions/runs/42':
                return RUN
            return [dict(workflow_runs=[RUN, RUN | dict(id=43, conclusion='failure')])]
        with patch.object(pub, 'api', side_effect=request), self.assertRaisesRegex(ValueError, 'newer RC'):
            pub.checked_run(REPO, SHA, 42, 'v0.49.0')

    def test_annotated_tag_is_resolved_and_movement_is_rejected(self):
        with patch.object(pub, 'api', side_effect=[dict(object=dict(type='tag', sha='tag-object')),
                                                  dict(object=dict(type='commit', sha=SHA))]):
            pub.check_tag(REPO, 'v0.49.0', SHA)
        with patch.object(pub, 'api', return_value=dict(object=dict(type='commit', sha='b' * 40))):
            with self.assertRaisesRegex(ValueError, 'target changed'):
                pub.check_tag(REPO, 'v0.49.0', SHA)

    def test_successful_retry_reuses_prior_installation_bytes_and_checked_body(self):
        # Run attempt2 can reuse installation completed in attempt1. The
        # distribution is scoped to run42, while the receipt names attempt2.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            distribution = self.make_distribution(root)
            archives, artifacts = {}, []
            for identifier, name, files in [
                (8, f'candidate-verification-{SHA}-attempt-2',
                 {'candidate-verification.json': json.dumps(RECEIPT).encode(),
                  'release-body.md': b'Verified release.\nhttps://github.com/owner/repo/actions/runs/42\n'}),
                (9, 'release-distribution-42',
                 {p.name: p.read_bytes() for p in distribution.iterdir()}),
            ]:
                archive = root / f'{identifier}.zip'
                with zipfile.ZipFile(archive, 'w') as bundle:
                    for filename, contents in files.items():
                        bundle.writestr(filename, contents)
                artifacts.append(dict(id=identifier, name=name, expired=False,
                                      digest='sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest(),
                                      workflow_run=dict(id=42, head_sha=SHA)))
                archives[identifier] = archive

            def request(repo, endpoint, **kwargs):
                self.assertEqual(repo, REPO)
                if endpoint.startswith('git/ref/'):
                    return dict(object=dict(type='commit', sha=SHA))
                if endpoint == 'actions/runs/42':
                    return RUN
                if endpoint.startswith('actions/workflows/'):
                    return [dict(workflow_runs=[RUN])]
                if endpoint.startswith('actions/runs/42/artifacts'):
                    return [dict(artifacts=artifacts)]
                self.fail(endpoint)

            def download(repo, artifact, destination):
                pub.extract_archive(archives[artifact['id']], artifact, destination)

            output = root / 'publication'
            with patch.object(pub, 'api', side_effect=request), patch.object(pub, 'download', side_effect=download):
                pub.prepare(REPO, SHA, 42, 'v0.49.0', output, root)
            for original in distribution.iterdir():
                self.assertEqual((output / 'assets' / original.name).read_bytes(), original.read_bytes())
            self.assertEqual((output / 'release-body.md').read_bytes(),
                             (output / 'receipt/release-body.md').read_bytes())
            self.assertIn('Verified release.', (output / 'release-body.md').read_text())
            self.assertIn('/actions/runs/42', (output / 'release-body.md').read_text())

    def test_rerun_after_download_refuses_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / 'publication.json').write_text(json.dumps(dict(repo=REPO, commit=SHA, run_id=42,
                                                                    tag='v0.49.0', attempt=1)))
            with patch.object(pub, 'checked_run', return_value=RUN):
                with self.assertRaisesRegex(ValueError, 'rerun'):
                    pub.recheck(output)


if __name__ == '__main__':
    unittest.main()
