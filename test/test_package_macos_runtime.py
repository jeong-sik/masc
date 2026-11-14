"""Adversarial upstream archive tests for the regular-only macOS payload."""
import argparse
import importlib.util
import io
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
import tarfile
import tempfile
import unittest
import ssl
import urllib.error
import urllib.request
import zipfile
from email.message import Message
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/package-macos-runtime.py'
spec = importlib.util.spec_from_file_location('runtime_package', SCRIPT)
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PythonHttpsProbe(unittest.TestCase):
    def run_probe(self):
        shipped = os.path.join(sys.base_prefix, 'ssl', 'cacert.pem')
        with patch.dict(os.environ, {'SSL_CERT_FILE': shipped}):
            exec(package.MACOS_PYTHON_HTTPS_PROBE, {})

    def test_macos_probe_requires_the_shipped_bundle(self):
        for cafile in (None, '/private/etc/ssl/cert.pem'):
            environ = {name: value for name, value in os.environ.items() if name != 'SSL_CERT_FILE'}
            if cafile is not None:
                environ['SSL_CERT_FILE'] = cafile
            with self.subTest(cafile=cafile), patch.dict(os.environ, environ, clear=True), \
                    patch.object(urllib.request, 'urlopen') as request:
                with self.assertRaisesRegex(ValueError, 'shipped CA bundle'):
                    exec(package.MACOS_PYTHON_HTTPS_PROBE, {})
                request.assert_not_called()

    def test_https_rejection_is_a_validated_response(self):
        body = io.BytesIO(b'forbidden')
        response = urllib.error.HTTPError('https://example.com', 403, 'Forbidden', Message(), body)
        with patch.object(urllib.request, 'urlopen', side_effect=response) as request:
            self.run_probe()
        request.assert_called_once_with('https://example.com', timeout=30)
        self.assertTrue(body.closed)

    def test_network_and_certificate_errors_propagate(self):
        for cause in (ssl.SSLCertVerificationError('untrusted certificate'),
                      OSError('DNS lookup failed'), OSError('Tunnel connection failed: 403 Forbidden')):
            error = urllib.error.URLError(cause)
            with self.subTest(cause=cause), patch.object(urllib.request, 'urlopen', side_effect=error):
                with self.assertRaises(urllib.error.URLError) as raised:
                    self.run_probe()
                self.assertIs(raised.exception, error)

    def test_http_downgrade_is_rejected_even_on_http_error(self):
        for code in (200, 403):
            body = io.BytesIO(b'response')
            response = urllib.error.HTTPError('http://example.com', code, 'response', Message(), body)
            effect = response if code == 403 else None
            with self.subTest(code=code), patch.object(
                    urllib.request, 'urlopen', return_value=response, side_effect=effect):
                with self.assertRaisesRegex(ValueError, 'non-HTTPS'):
                    self.run_probe()
            self.assertTrue(body.closed)

    def test_https_success_is_retained(self):
        body = io.BytesIO(b'ok')
        response = urllib.error.HTTPError('https://example.com', 200, 'OK', Message(), body)
        with patch.object(urllib.request, 'urlopen', return_value=response):
            self.run_probe()
        self.assertTrue(body.closed)


class LinuxRuntimeProbe(unittest.TestCase):
    """The Linux runtime ships no CA bundle, so its probe must not ask for one."""
    PLATFORM = 'linux-x64'

    def load_linux_packager(self):
        script = SCRIPT.with_name('package-linux-runtime.py')
        spec = importlib.util.spec_from_file_location('linux_runtime_package', script)
        if spec is None or spec.loader is None:
            raise ImportError('cannot load ' + str(script))
        linux = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(linux)
        return linux

    def packaged_probe(self):
        linux = self.load_linux_packager()
        commit, archive = 'a' * 40, b'reviewed Linux Python archive'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dist = root / 'dist'
            dist.mkdir()
            for name in linux.portable.NAMES:
                (dist / (name + '-' + self.PLATFORM)).write_bytes(b'staged executable')
            lock = root / 'lock.json'
            lock.write_text(json.dumps({'release': 'pinned', 'upstream': 'pinned', 'platforms': {self.PLATFORM: {
                'browser_download_url': 'https://github.com/astral-sh/python-build-standalone/pinned.tar.gz',
                'size': len(archive), 'digest': 'sha256:' + hashlib.sha256(archive).hexdigest()}}}))
            with patch.object(linux.portable, 'fetch', return_value=archive), \
                    patch.object(linux.portable, 'unpack_python'), \
                    patch.object(linux.portable, 'run', return_value=commit + '\n'), \
                    patch.object(linux.subprocess, 'run') as interpreter, \
                    patch.object(linux.portable, 'freeze_python_bytecode',
                                 side_effect=RuntimeError('probe ran')):
                with self.assertRaisesRegex(RuntimeError, 'probe ran'):
                    linux.package(dist, root / 'stage', self.PLATFORM, commit, lock, None)
        interpreter.assert_called_once()
        (argv,), _ = interpreter.call_args
        self.assertEqual(argv[1:3], ['-I', '-c'])
        return argv[3]

    def test_linux_package_stages_every_smoke_executable(self):
        smoke = SCRIPT.with_name('install-smoke.sh').read_text()
        loops = [line for line in smoke.splitlines()
                 if line.startswith('for a in ') and '$' not in line]
        self.assertEqual(1, len(loops), 'expected one literal smoke executable loop')
        words = shlex.split(loops[0])
        self.assertEqual(['for', 'a', 'in'], words[:3])
        self.assertEqual('do', words[-1])
        self.assertTrue(words[-2].endswith(';'))
        required = set(words[3:-2] + [words[-2][:-1]])
        self.assertIn('masc', required)
        original_copy = shutil.copy2
        with patch.object(shutil, 'copy2', wraps=original_copy) as copy:
            self.packaged_probe()
        staged = {Path(call.args[1]).name for call in copy.call_args_list}
        self.assertFalse(required - staged, f'Linux package did not stage: {sorted(required - staged)}')

    def test_linux_probe_validates_https_without_a_shipped_bundle(self):
        probe = self.packaged_probe()
        environ = {name: value for name, value in os.environ.items()
                   if name not in ('SSL_CERT_FILE', 'SSL_CERT_DIR')}
        body = io.BytesIO(b'ok')
        response = urllib.error.HTTPError('https://example.com', 200, 'OK', Message(), body)
        with patch.dict(os.environ, environ, clear=True), \
                patch.object(urllib.request, 'urlopen', return_value=response) as request:
            exec(probe, {})
        request.assert_called_once_with('https://example.com', timeout=30)
        self.assertTrue(body.closed)

    def test_linux_probe_still_fails_on_certificate_errors(self):
        probe = self.packaged_probe()
        error = urllib.error.URLError(ssl.SSLCertVerificationError('untrusted certificate'))
        with patch.object(urllib.request, 'urlopen', side_effect=error):
            with self.assertRaises(urllib.error.URLError) as raised:
                exec(probe, {})
        self.assertIs(raised.exception, error)


class OcamlNoticeShipping(unittest.TestCase):
    """The statically linked OCaml libraries' notices travel in the runtime archive (#39934)."""
    PLATFORM = 'linux-x64'

    def runtime_members(self, make_notices):
        script = SCRIPT.with_name('package-linux-runtime.py')
        spec = importlib.util.spec_from_file_location('linux_runtime_notices', script)
        linux = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(linux)
        commit, archive = 'a' * 40, b'reviewed Linux Python archive'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dist = root / 'dist'
            dist.mkdir()
            for name in linux.portable.NAMES:
                (dist / (name + '-' + self.PLATFORM)).write_bytes(b'staged executable')
            lock = root / 'lock.json'
            lock.write_text(json.dumps({'release': 'pinned', 'upstream': 'pinned', 'platforms': {self.PLATFORM: {
                'browser_download_url': 'https://github.com/astral-sh/python-build-standalone/pinned.tar.gz',
                'size': len(archive), 'digest': 'sha256:' + hashlib.sha256(archive).hexdigest()}}}))
            with patch.object(linux.portable, 'fetch', return_value=archive), \
                    patch.object(linux.portable, 'unpack_python'), \
                    patch.object(linux.portable, 'run', return_value=commit + '\n'), \
                    patch.object(linux.subprocess, 'run'), \
                    patch.object(linux.portable, 'freeze_python_bytecode'):
                linux.package(dist, root / 'stage', self.PLATFORM, commit, lock, make_notices(root))
            with tarfile.open(dist / ('masc-runtime-' + self.PLATFORM + '.tar.gz')) as output:
                return {member.name: (member.mode, output.extractfile(member).read())
                        for member in output.getmembers()}

    FILES = {'tls/LICENSE.md': b'Copyright (c) 2014, David Kaloper and Hannes Mehnert\n',
             'yaml/vendor/License': b'Copyright (c) 2006-2016 Kirill Simonov\n'}

    @classmethod
    def collected(cls, root):
        notices = root / 'notices'
        for name, data in cls.FILES.items():
            (notices / name).parent.mkdir(parents=True, exist_ok=True)
            (notices / name).write_bytes(data)
            (notices / name).chmod(0o600)
        (notices / 'packages.json').write_text(json.dumps({'schema': 'masc.ocaml-notices.v1', 'packages': [
            {'name': name.split('/')[0], 'notices': [{'file': name, 'sha256': hashlib.sha256(data).hexdigest()}]}
            for name, data in cls.FILES.items()] + [{'name': 'zstd', 'notices': []}]}))
        return notices

    def test_release_runtime_ships_the_collected_notices_under_licenses_ocaml(self):
        members = self.runtime_members(self.collected)
        for name, data in self.FILES.items():
            self.assertEqual((0o644, data), members['licenses/ocaml/' + name])
        self.assertEqual(0o644, members['licenses/ocaml/packages.json'][0])

    def test_a_file_the_manifest_does_not_name_is_refused(self):
        def extra(root):
            notices = self.collected(root)
            (notices / 'tls/COPYING').write_bytes(b'added after the collector ran\n')
            return notices
        with self.assertRaisesRegex(ValueError, 'OCaml notices differ from .*: tls/COPYING$'):
            self.runtime_members(extra)

    def test_a_notice_whose_bytes_differ_from_the_manifest_is_refused(self):
        def changed(root):
            notices = self.collected(root)
            (notices / 'yaml/vendor/License').write_bytes(b'another text\n')
            return notices
        with self.assertRaisesRegex(ValueError, 'OCaml notices differ from .*: yaml/vendor/License$'):
            self.runtime_members(changed)

    def test_a_named_notice_that_is_missing_is_refused(self):
        def missing(root):
            notices = self.collected(root)
            (notices / 'tls/LICENSE.md').unlink()
            return notices
        with self.assertRaisesRegex(ValueError, 'OCaml notices differ from .*: tls/LICENSE.md$'):
            self.runtime_members(missing)

    def test_a_notice_directory_the_collector_did_not_finish_is_refused(self):
        def unfinished(root):
            notices = self.collected(root)
            (notices / 'packages.json').unlink()
            return notices
        with self.assertRaisesRegex(ValueError, 'OCaml notice manifest missing'):
            self.runtime_members(unfinished)

    def test_a_probe_runtime_carries_no_ocaml_notices(self):
        members = self.runtime_members(lambda root: None)
        self.assertFalse([name for name in members if name.startswith('licenses/ocaml/')])

    def test_every_packager_caller_chooses_whether_notices_ship(self):
        parser = argparse.ArgumentParser()
        package.add_ocaml_notice_arguments(parser)
        with patch('sys.stderr', io.StringIO()), self.assertRaises(SystemExit):
            parser.parse_args([])
        self.assertEqual(Path('n'), parser.parse_args(['--ocaml-notices', 'n']).ocaml_notices)
        self.assertIsNone(parser.parse_args(['--without-ocaml-notices']).ocaml_notices)


class PythonArchive(unittest.TestCase):
    def exercise(self, entries):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        archive = root / 'upstream.tar.gz'
        with tarfile.open(archive, 'w:gz') as output:
            for name, content, link in entries:
                info = tarfile.TarInfo(name)
                info.mode = 0o755
                if link is not None:
                    info.type, info.linkname = tarfile.SYMTYPE, link
                else:
                    info.size = len(content)
                output.addfile(info, io.BytesIO(content) if link is None else None)
        package.unpack_python(archive, root / 'payload')
        return root / 'payload'

    def test_internal_interpreter_alias_is_materialized(self):
        root = self.exercise([('python/bin/python3.13', b'python bytes', None),
                              ('python/bin/python3', b'', 'python3.13')])
        alias = root / 'python/bin/python3'
        self.assertFalse(alias.is_symlink())
        self.assertEqual(alias.read_bytes(), b'python bytes')
        self.assertEqual(alias.stat().st_mode & 0o777, 0o755)

    def test_absolute_traversal_and_escaping_links_are_rejected(self):
        for entries in ([('/outside', b'bad', None)],
                        [('python/../../outside', b'bad', None)],
                        [('python/bin/python3', b'', '/usr/bin/python3')],
                        [('python/bin/python3', b'', '../../../outside')],
                        [('python/bin/python3', b'', 'python3')]):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                self.exercise(entries)

    def test_duplicate_members_are_rejected(self):
        with self.assertRaises(ValueError):
            self.exercise([('python/bin/python3', b'one', None), ('python/bin/python3', b'two', None)])


class PinnedDownload(unittest.TestCase):
    def exercise(self, payload, reaches_extraction):
        expected = b'reviewed Python archive'
        url = 'https://github.com/astral-sh/python-build-standalone/releases/download/pinned/python.tar.gz'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = root / 'lock.json'
            lock.write_text(json.dumps({'platforms': {'macos-arm64': {
                'browser_download_url': url, 'size': len(expected),
                'digest': 'sha256:' + hashlib.sha256(expected).hexdigest()}}}))
            with patch.object(package, 'fetch', return_value=payload) as fetch, patch.object(
                    package, 'unpack_python', side_effect=RuntimeError('verified bytes reached extraction')) as unpack:
                if reaches_extraction:
                    with self.assertRaisesRegex(RuntimeError, 'verified bytes reached extraction'):
                        package.package(root / 'dist', root / 'stage', 'macos-arm64', 'a' * 40, lock, None)
                    unpack.assert_called_once()
                else:
                    with self.assertRaisesRegex(ValueError, 'checksum differs from pin'):
                        package.package(root / 'dist', root / 'stage', 'macos-arm64', 'a' * 40, lock, None)
                    unpack.assert_not_called()
                fetch.assert_called_once_with(url)

    def test_verified_payload_uses_only_pinned_download(self):
        self.exercise(b'reviewed Python archive', True)

    def test_equal_size_tampering_is_rejected_before_extraction(self):
        self.exercise(b'altered! Python archive', False)

    def test_truncated_payload_is_rejected_before_extraction(self):
        self.exercise(b'reviewed Python', False)


class CaBundle(unittest.TestCase):
    URL = 'https://files.pythonhosted.org/packages/pinned/certifi.whl'

    def wheel(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive:
            archive.writestr('certifi/cacert.pem', b'pinned certificates')
            archive.writestr('certifi-0.dist-info/licenses/LICENSE', b'MPL-2.0 notice')
        return buffer.getvalue()

    def pin(self, data):
        return {'browser_download_url': self.URL, 'size': len(data),
                'digest': 'sha256:' + hashlib.sha256(data).hexdigest(),
                'member': 'certifi/cacert.pem',
                'license_member': 'certifi-0.dist-info/licenses/LICENSE'}

    def stage(self, root, sites=('python3.13',)):
        stage = root / 'stage'
        stage.mkdir()
        for site in sites:
            (stage / 'python/lib' / site / 'site-packages').mkdir(parents=True)
        return stage

    def test_verified_bundle_becomes_the_runtime_default(self):
        data = self.wheel()
        with tempfile.TemporaryDirectory() as directory:
            stage = self.stage(Path(directory))
            with patch.object(package, 'fetch', return_value=data) as fetch:
                package.stage_ca_bundle(stage, self.pin(data))
            fetch.assert_called_once_with(self.URL)
            bundle = stage / 'python/ssl/cacert.pem'
            self.assertEqual(bundle.read_bytes(), b'pinned certificates')
            self.assertEqual(bundle.stat().st_mode & 0o777, 0o644)
            self.assertEqual((stage / 'licenses/certifi/LICENSE').read_bytes(), b'MPL-2.0 notice')
            hook = stage / 'python/lib/python3.13/site-packages/sitecustomize.py'
            self.assertEqual(hook.read_text(), package.SITECUSTOMIZE)

    def test_tampered_or_truncated_wheel_is_rejected_before_staging(self):
        data = self.wheel()
        for payload in (data[:-1], bytes([data[0] ^ 1]) + data[1:]):
            with self.subTest(size=len(payload)), tempfile.TemporaryDirectory() as directory:
                stage = self.stage(Path(directory))
                with patch.object(package, 'fetch', return_value=payload):
                    with self.assertRaisesRegex(ValueError, 'checksum differs from pin'):
                        package.stage_ca_bundle(stage, self.pin(data))
                self.assertFalse((stage / 'python/ssl').exists())

    def test_staging_needs_exactly_one_site_packages(self):
        data = self.wheel()
        for sites in ((), ('python3.12', 'python3.13')):
            with self.subTest(sites=sites), tempfile.TemporaryDirectory() as directory:
                stage = self.stage(Path(directory), sites)
                with patch.object(package, 'fetch', return_value=data):
                    with self.assertRaisesRegex(ValueError, 'exactly one site-packages'):
                        package.stage_ca_bundle(stage, self.pin(data))
                self.assertFalse((stage / 'python/ssl').exists())

    def run_hook(self, environ):
        with patch.dict(os.environ, environ, clear=True):
            exec(package.SITECUSTOMIZE, {})
            return dict(os.environ)

    def test_hook_defaults_to_the_shipped_bundle(self):
        self.assertEqual(self.run_hook({}),
                         {'SSL_CERT_FILE': os.path.join(sys.base_prefix, 'ssl', 'cacert.pem')})

    def test_hook_keeps_user_certificate_settings(self):
        for environ in ({'SSL_CERT_FILE': '/custom/roots.pem'}, {'SSL_CERT_DIR': '/custom/roots'}):
            with self.subTest(environ=environ):
                self.assertEqual(self.run_hook(environ), environ)


class BinaryPublication(unittest.TestCase):
    def test_readonly_destination_is_replaced_with_staged_bytes_and_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, destination = root / 'staged', root / 'masc-macos-arm64'
            source.write_bytes(b'verified staged executable')
            source.chmod(0o555)
            destination.write_bytes(b'old executable')
            destination.chmod(0o555)
            old_inode = destination.stat().st_ino
            package.publish_binary(source, destination)
            self.assertEqual(destination.read_bytes(), source.read_bytes())
            self.assertEqual(destination.stat().st_mode & 0o777, 0o555)
            self.assertNotEqual(destination.stat().st_ino, old_inode)
            self.assertEqual({p.name for p in root.iterdir()}, {'staged', 'masc-macos-arm64'})

    def test_destination_symlink_target_is_never_modified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, target, destination = root / 'staged', root / 'untouched', root / 'masc-macos-arm64'
            source.write_bytes(b'verified staged executable')
            source.chmod(0o755)
            target.write_bytes(b'external old executable')
            target.chmod(0o444)
            destination.symlink_to(target)
            package.publish_binary(source, destination)
            self.assertFalse(destination.is_symlink())
            self.assertEqual(destination.read_bytes(), source.read_bytes())
            self.assertEqual(destination.stat().st_mode & 0o777, 0o755)
            self.assertEqual(target.read_bytes(), b'external old executable')
            self.assertEqual(target.stat().st_mode & 0o777, 0o444)


class StableBytecode(unittest.TestCase):
    def test_relocated_sources_keep_bytecode_bytes_for_all_optimizations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / 'stage'
            binary = stage / 'python/bin/python3'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' "$@"\n')
            binary.chmod(0o755)
            library = stage / 'python/lib'
            library.mkdir()
            (library / 'probe.py').write_text('value = 42\n')
            package.freeze_python_bytecode(stage)
            relocated = root / 'installed'
            shutil.copytree(stage, relocated)
            for source in relocated.rglob('*.py'):
                os.utime(source, (1, 1))
            def snapshot():
                return {p.relative_to(relocated).as_posix(): p.read_bytes()
                        for p in relocated.rglob('*.pyc')}
            before = snapshot()
            self.assertEqual(len(before), 3)
            self.assertTrue(all(int.from_bytes(data[4:8], 'little') == 3 for data in before.values()))
            command = 'import sys; sys.path.insert(0,sys.argv[1]); import probe; assert probe.value == 42'
            for optimization in ([], ['-O'], ['-OO']):
                for _ in range(2):
                    subprocess.run([str(relocated / 'python/bin/python3'), '-I', *optimization,
                                    '-c', command, str(relocated / 'python/lib')], check=True)
                    self.assertEqual(snapshot(), before)


if __name__ == '__main__':
    unittest.main()
