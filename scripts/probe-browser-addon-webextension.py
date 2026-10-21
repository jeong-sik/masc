#!/usr/bin/env python3
"""Real external Firefox extension through Addon HTTP ingress.

geckodriver owns only isolated browser setup/cleanup. Production extension,
native host, HTTP routes and Addon public tools perform all content operations.
Native manifests are isolated in Firefox's process-local directory service,
following Mozilla's own native messaging test fixture; HOME is unchanged.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
import urllib.error
import urllib.request


DIRECTORIES = '''
const {NativeManifests}=ChromeUtils.importESModule('resource://gre/modules/NativeManifests.sys.mjs');
if (NativeManifests._initializePromise !== null) throw new Error('native manifest lookup already initialized');
const directory=Cc['@mozilla.org/file/local;1'].createInstance(Ci.nsIFile);
directory.initWithPath(arguments[0]);
const paths=[];
for (const key of ['XREUserNativeManifests','XRESysNativeManifests']) {
 const before=Services.dirsvc.get(key,Ci.nsIFile).path;
 Services.dirsvc.undefine(key);
 Services.dirsvc.set(key,directory);
 const after=Services.dirsvc.get(key,Ci.nsIFile).path;
 if (after!==directory.path) throw new Error('native manifest directory override refused');
 paths.push({key,before,after});
}
return {lookup_was_uninitialized:true,paths};
'''


def publish(path, value):
    temporary = path.with_suffix('.pending')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def request(base, method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    query = urllib.request.Request(base + path, data=data, method=method,
                                   headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(query, timeout=30) as reply:
            value = json.load(reply)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f'fixture WebDriver {path}: {error.read().decode()}') from error
    result = value['value']
    if isinstance(result, dict) and 'error' in result:
        raise RuntimeError(f'fixture WebDriver {path}: {result}')
    return result


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def wait_file(path, process, deadline):
    while not path.exists():
        if process.poll() is not None:
            raise RuntimeError('native probe ended before ' + path.name)
        if time.monotonic() >= deadline:
            raise TimeoutError('fixture did not publish ' + path.name)
        time.sleep(.01)
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('firefox', 'driver', 'probe', 'launcher', 'guardian', 'worker', 'native-host', 'out'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for name in ('setup.json', 'detached.json', 'browser-still-alive.json',
                 'webextension-addon-proof.json', 'webextension.png', 'workspace.txt',
                 'harness-result.json', 'extension-installation.json', 'browser-setup.json'):
        (output / name).unlink(missing_ok=True)
    repo = Path(__file__).resolve().parents[1]
    deadline = time.monotonic() + 600  # Fixture resource bound, not a product deadline.
    result = {'returncode': None, 'timed_out': False, 'error': None,
              'browser_alive_after_cleanup': None, 'session_delete_confirmed': False}
    probe = driver = None
    session = browser_pid = None
    base = None
    # These existing endpoint overrides outrank Workspace_connection. Removing
    # them from this child environment leaves the real production launcher.
    browser_env = {key: value for key, value in os.environ.items()
                   if key not in ('MASC_HTTP_BASE_URL', 'MASC_HTTP_PORT')}
    with (output / 'probe.log').open('w') as probe_log, (output / 'geckodriver.log').open('w') as driver_log:
        try:
            probe = subprocess.Popen([
                str(args.probe.resolve()), '--manifest', str(repo / 'addons/browser/lane.toml'),
                '--launcher', str(args.launcher.resolve()), '--guardian', str(args.guardian.resolve()),
                '--worker', str(args.worker.resolve()), '--native-host', str(args.native_host.resolve()),
                '--out', str(output),
            ], stdout=probe_log, stderr=subprocess.STDOUT)
            setup = wait_file(output / 'setup.json', probe, deadline)
            installed = []
            for name in ('host', 'launcher', 'native_manifest'):
                path = Path(setup[name])
                installed.append({'name': name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
            for path in sorted(Path(setup['extension']).rglob('*')):
                if path.is_file():
                    installed.append({'name': 'extension/' + str(path.relative_to(setup['extension'])),
                                      'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
            if installed[0]['sha256'] != hashlib.sha256(args.native_host.read_bytes()).hexdigest():
                raise RuntimeError('installed native host differs from the actual proof input')
            publish(output / 'extension-installation.json', installed)
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                port = listener.getsockname()[1]
            base = f'http://127.0.0.1:{port}'
            driver = subprocess.Popen([str(args.driver.resolve()), '--port', str(port), '--allow-system-access'],
                                      env=browser_env, stdout=driver_log, stderr=subprocess.STDOUT)
            while True:
                if driver.poll() is not None:
                    raise RuntimeError('fixture geckodriver exited before readiness')
                try:
                    if request(base, 'GET', '/status')['ready']:
                        break
                except urllib.error.URLError:
                    pass
                if time.monotonic() >= deadline:
                    raise TimeoutError('fixture geckodriver did not become ready')
                time.sleep(.05)
            opened = request(base, 'POST', '/session', {'capabilities': {'alwaysMatch': {
                'browserName': 'firefox', 'moz:firefoxOptions': {
                    'binary': str(args.firefox.resolve()),
                    'args': ['-headless', setup['fixture_url']],
                }}}})
            session = opened['sessionId']
            browser_pid = opened['capabilities']['moz:processID']
            route = '/session/' + session
            request(base, 'POST', route + '/moz/context', {'context': 'chrome'})
            directory_receipt = request(base, 'POST', route + '/execute/sync', {
                'script': DIRECTORIES, 'args': [setup['native_root']]})
            request(base, 'POST', route + '/moz/context', {'context': 'content'})
            extension_id = request(base, 'POST', route + '/moz/addon/install', {
                'path': setup['extension'], 'temporary': True})
            if extension_id != 'browser-lane@masc.local':
                raise RuntimeError('Firefox installed an unexpected extension identity')
            publish(output / 'browser-setup.json', {'capabilities': opened['capabilities'],
                    'native_directories': directory_receipt, 'extension_id': extension_id,
                    'scope': 'fixture driver setup only; content commands use public Addon tools'})
            wait_file(output / 'detached.json', probe, deadline)
            publish(output / 'browser-still-alive.json', {'alive': driver.poll() is None and alive(browser_pid),
                                                        'original_browser_pid': browser_pid})
            while probe.poll() is None:
                if time.monotonic() >= deadline:
                    raise TimeoutError('external extension fixture exceeded its resource bound')
                time.sleep(.05)
            result['returncode'] = probe.returncode
        except TimeoutError as error:
            result.update(timed_out=True, error=str(error))
        except (OSError, RuntimeError, ValueError, KeyError) as error:
            result['error'] = str(error)
        finally:
            if session is not None:
                try:
                    request(base, 'DELETE', '/session/' + session)
                    result['session_delete_confirmed'] = True
                except (OSError, RuntimeError, ValueError, KeyError) as error:
                    result['cleanup_error'] = str(error)
            stop(probe)
            stop(driver)
            if browser_pid is not None:
                result['browser_alive_after_cleanup'] = alive(browser_pid)
    workspace = output / 'workspace.txt'
    if workspace.exists():
        logs = output / 'worker-logs'
        if logs.is_symlink():
            raise ValueError('worker log directory must not be a symlink')
        logs.mkdir(exist_ok=True)
        for index, path in enumerate(Path(workspace.read_text()).rglob('*.log')):
            if path.is_file() and not path.is_symlink():
                shutil.copyfile(path, logs / f'{index}-{path.name}')
    publish(output / 'harness-result.json', result)
    print((output / 'probe.log').read_text())
    print(json.dumps(result))
    return 0 if (result['returncode'] == 0 and result['error'] is None
                 and result['session_delete_confirmed'] and result['browser_alive_after_cleanup'] is False) else 1


if __name__ == '__main__':
    raise SystemExit(main())
