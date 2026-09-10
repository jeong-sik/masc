import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('archive_verifier', Path(__file__).parents[1] / 'verify-sandbox-image-archive.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class ArchiveTest(unittest.TestCase):
    def fixture(self, path, *, corrupt=False, wrong_size=False):
        blobs = {}
        def blob(value, media):
            raw = value if isinstance(value, bytes) else json.dumps(value).encode()
            digest = 'sha256:' + hashlib.sha256(raw).hexdigest()
            blobs[verifier.blob_path(digest)] = raw
            return {'digest': digest, 'size': len(raw), 'mediaType': media}
        layer = blob(b'fixture layer bytes', 'application/vnd.oci.image.layer.v1.tar')
        config = blob({'architecture': 'arm64', 'os': 'linux', 'rootfs': {'type': 'layers', 'diff_ids': [layer['digest']]},
                       'config': {'Labels': {'org.opencontainers.image.revision': 'source'}}}, 'application/vnd.oci.image.config.v1+json')
        manifest = blob({'schemaVersion': 2, 'mediaType': 'application/vnd.oci.image.manifest.v1+json', 'config': config, 'layers': [layer]}, 'application/vnd.oci.image.manifest.v1+json')
        if corrupt:
            blobs[verifier.blob_path(layer['digest'])] = b'x' * layer['size']
        if wrong_size:
            manifest['size'] += 1
        blobs['index.json'] = json.dumps({'schemaVersion': 2, 'manifests': [manifest]}).encode()
        blobs['oci-layout'] = b'{"imageLayoutVersion":"1.0.0"}'
        blobs['manifest.json'] = json.dumps([{'Config': verifier.blob_path(config['digest']), 'Layers': [verifier.blob_path(layer['digest'])], 'RepoTags': ['fixture:v1']}]).encode()
        with tarfile.open(path, 'w:gz') as archive:
            for name, data in blobs.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        return config['digest'], manifest['digest']

    def test_cross_engine_ids_resolve_to_different_verified_objects(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'image.tar.gz'
            config, manifest = self.fixture(path)
            result = verifier.verify_archive(path)
            self.assertNotEqual(config, manifest)
            self.assertEqual(len(result['verified_blobs']), 3)
            for identity, kind in [(config, 'config_digest'), (manifest, 'manifest_digest')]:
                inspected = [{'Id': identity, 'Architecture': 'arm64', 'Os': 'linux', 'RepoTags': ['fixture:v1'],
                              'RootFS': {'Type': 'layers', 'Layers': result['rootfs_diff_ids']},
                              'Config': {'Labels': {'org.opencontainers.image.revision': 'source'}}}]
                self.assertEqual(verifier.verify_inspect(inspected, result, 'fixture:v1')['identity_kind'], kind)
                inspected[0]['Id'] = 'sha256:' + 'f' * 64
                with self.assertRaisesRegex(ValueError, 'not linked'):
                    verifier.verify_inspect(inspected, result, 'fixture:v1')

    def test_matching_id_does_not_hide_changed_destination_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'image.tar.gz'
            config, manifest = self.fixture(path)
            result = verifier.verify_archive(path)
            image = {'Id': manifest, 'Architecture': 'arm64', 'Os': 'linux', 'RepoTags': ['fixture:v1'],
                     'RootFS': {'Type': 'layers', 'Layers': result['rootfs_diff_ids']},
                     'Config': {'Labels': {'org.opencontainers.image.revision': 'source'}}}
            for key, replacement in [('RootFS', {'Type': 'layers', 'Layers': []}),
                                     ('Config', {'Labels': {'org.opencontainers.image.revision': 'other'}}),
                                     ('Config', {**image['Config'], 'User': '0'}),
                                     ('Config', {**image['Config'], 'Entrypoint': ['/unexpected']}),
                                     ('Descriptor', {'digest': config, 'mediaType': result['manifest_media_type'], 'size': result['manifest_bytes']})]:
                with self.subTest(field=key), self.assertRaises(ValueError):
                    verifier.verify_inspect([{**image, key: replacement}], result, 'fixture:v1')

    def test_execution_configuration_is_not_ignored(self):
        baseline = {"User": "65532", "Entrypoint": ["/bin/sh"], "WorkingDir": "/work"}
        fingerprint = verifier.configuration_fingerprint(baseline)
        self.assertEqual(fingerprint, verifier.configuration_fingerprint({**baseline, "AttachStdin": False}))
        for key, value in [("User", "0"), ("Entrypoint", ["/other"]),
                           ("WorkingDir", "/other"), ("Healthcheck", {"Test": ["CMD", "false"]})]:
            with self.subTest(key=key):
                self.assertNotEqual(fingerprint, verifier.configuration_fingerprint({**baseline, key: value}))
        self.assertNotEqual(fingerprint, verifier.configuration_fingerprint({**baseline, "Tty": True}))

    def test_modified_layer_bytes_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'image.tar.gz'
            self.fixture(path, corrupt=True)
            with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                verifier.verify_archive(path)

    def test_descriptor_size_is_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'image.tar.gz'
            self.fixture(path, wrong_size=True)
            with self.assertRaisesRegex(ValueError, 'size or file type'):
                verifier.verify_archive(path)


if __name__ == '__main__':
    unittest.main()
