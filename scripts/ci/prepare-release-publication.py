#!/usr/bin/env python3
"""Stage the exact distribution from a successful RC, without rebuilding it."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
import zipfile

from release_behavior import load_profile

PLATFORMS = ('macos-arm64', 'macos-x64', 'linux-x64', 'linux-arm64')


def api(repo, endpoint, *, pages=False):
    command = ['gh', 'api', f'repos/{repo}/{endpoint}']
    if pages:
        command += ['--paginate', '--slurp']
    return json.loads(subprocess.check_output(command, text=True))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_run(run, repo, commit, run_id):
    require(run['id'] == run_id, 'RC run identity changed')
    require(run['repository']['full_name'] == repo, 'RC belongs to another repository')
    require(run['head_repository']['id'] == run['repository']['id'], 'Fork RC is not publishable')
    require(run['path'] == '.github/workflows/release-candidate.yml', 'Not a release-candidate workflow')
    require(run['event'] == 'workflow_dispatch', 'RC was not explicitly dispatched')
    require(run['head_sha'] == commit, 'RC commit differs from the version tag')
    require(run['status'] == 'completed' and run['conclusion'] == 'success', 'Release candidate verification has not succeeded')


def check_tag(repo, tag, commit):
    require(tag.startswith('v') and '/' not in tag, 'Expected a version tag')
    obj = api(repo, f'git/ref/tags/{tag}')['object']
    seen = set()
    while obj['type'] == 'tag':
        require(obj['sha'] not in seen, 'Cyclic annotated tag')
        seen.add(obj['sha'])
        obj = api(repo, f"git/tags/{obj['sha']}")['object']
    require(obj['type'] == 'commit' and obj['sha'] == commit, 'Version tag target changed')


def checked_run(repo, commit, run_id, tag):
    check_tag(repo, tag, commit)
    run = api(repo, f'actions/runs/{run_id}')
    validate_run(run, repo, commit, run_id)
    pages = api(repo, f'actions/workflows/release-candidate.yml/runs?head_sha={commit}&per_page=100', pages=True)
    runs = [row for page in pages for row in page['workflow_runs'] if row['head_sha'] == commit]
    require(runs and max(row['id'] for row in runs) == run_id, 'A newer RC exists for this commit')
    return run


def select_artifact(artifacts, name, run):
    matches = [a for a in artifacts if a['name'] == name]
    require(len(matches) == 1, f'Expected one artifact: {name}')
    artifact = matches[0]
    require(artifact['expired'] is False, f'Artifact expired: {name}')
    require(artifact['workflow_run']['id'] == run['id']
            and artifact['workflow_run']['head_sha'] == run['head_sha'], 'Artifact provenance mismatch')
    require(re.fullmatch(r'sha256:[0-9a-f]{64}', artifact.get('digest') or '') is not None,
            'Artifact has no SHA-256 digest')
    return artifact


def extract_archive(archive, artifact, destination):
    with archive.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    require('sha256:' + digest == artifact['digest'], 'Downloaded artifact digest mismatch')
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as bundle:
        names = set()
        for entry in bundle.infolist():
            # Both RC artifacts have a flat root. Do not accept paths or links.
            path = PurePosixPath(entry.filename)
            mode = (entry.external_attr >> 16) & 0o170000
            require(len(path.parts) == 1 and path.name not in ('.', '..')
                    and entry.filename == path.name and not entry.is_dir() and mode in (0, 0o100000),
                    f'Unexpected artifact entry: {entry.filename}')
            require(entry.filename not in names, 'Duplicate artifact entry')
            names.add(entry.filename)
            with bundle.open(entry) as source, (destination / path.name).open('wb') as target:
                shutil.copyfileobj(source, target)


def download(repo, artifact, destination):
    with tempfile.TemporaryDirectory() as temporary:
        archive = Path(temporary) / 'artifact.zip'
        with archive.open('wb') as output:
            subprocess.run(['gh', 'api', f"repos/{repo}/actions/artifacts/{artifact['id']}/zip"],
                           stdout=output, check=True)
        extract_archive(archive, artifact, destination)


def validate_receipt(receipt, run, repo):
    require(receipt['schema_version'] == 2 and receipt['commit'] == run['head_sha'], 'RC receipt commit/schema mismatch')
    require(receipt['run_attempt'] == run['run_attempt'], 'RC receipt is from another attempt')
    require(receipt['run_url'] == f"https://github.com/{repo}/actions/runs/{run['id']}", 'RC receipt run mismatch')
    require(receipt['checks_passed'] is True and receipt['published'] is False,
            'RC receipt is not successful verification')
    require(receipt['results'] == dict(compile='success', behavior='success', installation='success'),
            'RC receipt omits required release verification')
    require(receipt.get('behavior_scope') == load_profile(),
            'RC behavior selection differs from the reviewed release profile')


def validate_distribution(directory, checkout):
    expected = {'install.sh', 'install-runtime-setup.py', 'SHA256SUMS',
                'masc-exec-shim-linux-amd64', 'masc-exec-shim-linux-arm64'}
    for arch in PLATFORMS:
        expected.update({f'masc-{arch}', f'masc-tui-{arch}', f'masc-browser-host-{arch}',
                         f'masc-deployment-preflight-helper-{arch}',
                         f'masc-check-runtime-deployment-preflight-{arch}',
                         f'masc-dashboard-{arch}.tar.gz', f'masc-release-dashboard-bundle-{arch}.py',
                         f'masc-runtime-{arch}.tar.gz'})
    actual = {p.name for p in directory.iterdir()}
    require(actual == expected, 'Distribution assets are missing or unexpected')
    hashes = {}
    for line in (directory / 'SHA256SUMS').read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64}) [ *](.+)', line)
        require(match is not None, 'Malformed distribution checksum')
        digest, name = match.groups()
        path = PurePosixPath(name)
        require(not path.is_absolute() and '..' not in path.parts and name not in hashes,
                'Unsafe or duplicate checksum path')
        if name in actual and name != 'SHA256SUMS':
            file = directory / name
        elif name == 'runtime.toml':
            file = checkout / 'config/runtime.toml'
        else:
            require(path.parts[0] == 'presets', 'Unknown checksum source')
            file = checkout / path
        with file.open('rb') as source:
            require(hashlib.file_digest(source, 'sha256').hexdigest() == digest,
                    f'Distribution checksum mismatch: {name}')
        hashes[name] = digest
    require(expected - {'SHA256SUMS'} <= hashes.keys(), 'Distribution asset lacks a checksum')


def prepare(repo, commit, run_id, tag, output, checkout):
    require(not output.exists(), 'Publication staging directory already exists')
    run = checked_run(repo, commit, run_id, tag)
    pages = api(repo, f'actions/runs/{run_id}/artifacts?per_page=100', pages=True)
    artifacts = [a for page in pages for a in page['artifacts']]
    receipt_artifact = select_artifact(artifacts, f"candidate-verification-{commit}-attempt-{run['run_attempt']}", run)
    distribution = select_artifact(artifacts, f"release-distribution-{run_id}", run)
    download(repo, receipt_artifact, output / 'receipt')
    receipt = json.loads((output / 'receipt/candidate-verification.json').read_text())
    validate_receipt(receipt, run, repo)
    download(repo, distribution, output / 'assets')
    validate_distribution(output / 'assets', checkout)
    # RC checked this exact body, including its compare link and run URL.
    shutil.copyfile(output / 'receipt/release-body.md', output / 'release-body.md')
    plan = dict(repo=repo, commit=commit, run_id=run_id, tag=tag, attempt=run['run_attempt'])
    (output / 'publication.json').write_text(json.dumps(plan, indent=2) + '\n')
    recheck(output)
    print(f"Staged verified RC {run_id} attempt {run['run_attempt']} for {tag}; no rebuild")


def recheck(output):
    plan = json.loads((output / 'publication.json').read_text())
    run = checked_run(plan['repo'], plan['commit'], plan['run_id'], plan['tag'])
    require(run['run_attempt'] == plan['attempt'], 'RC was rerun after artifacts were selected')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo')
    parser.add_argument('--commit')
    parser.add_argument('--run', type=int)
    parser.add_argument('--tag')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--recheck', action='store_true')
    args = parser.parse_args()
    if args.recheck:
        recheck(args.output)
    else:
        require(all((args.repo, args.commit, args.run, args.tag)), 'repo, commit, run and tag are required')
        prepare(args.repo, args.commit, args.run, args.tag, args.output, Path.cwd())


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, StopIteration, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Release publication refused: {error}') from error
