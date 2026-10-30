"""Record byte-level restart evidence for an explicitly selected MASC workspace.

Required domain files cannot silently fall out of the scope. This records hashes,
not file contents. Comparison distinguishes changed content from retained JSONL
prefixes; it does not establish semantic memory continuity or stop the runtime.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import stat


SCHEMA = 'masc.collaboration_state_capture.v1'
EXCLUDED = {'.git', 'node_modules', '.venv', '_build', '__pycache__'}


def read_identity(path, prefix_bytes=None):
    if path.resolve(strict=True) != path:
        raise ValueError(f'symlinked file or parent is outside the capture scope: {path}')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f'not a regular file: {path}')
        full, prefix, read_bytes = hashlib.sha256(), hashlib.sha256(), 0
        while block := source.read(1024 * 1024):
            full.update(block)
            if prefix_bytes is not None and read_bytes < prefix_bytes:
                prefix.update(block[:prefix_bytes - read_bytes])
            read_bytes += len(block)
        after = os.fstat(source.fileno())
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError(f'file changed during observation; capture again: {path}')
        result = {'sha256': full.hexdigest(), 'bytes': read_bytes}
        if prefix_bytes is not None and read_bytes >= prefix_bytes:
            result['previous_size_prefix_sha256'] = prefix.hexdigest()
        return result


def collect_paths(state, keepers):
    if state.resolve(strict=True) != state:
        raise ValueError(f'state root must not be a symlink: {state}')
    required = {'tasks/backlog.json', 'goals.json', 'config/runtime.toml'}
    required.update(f'config/keepers/{keeper}.toml' for keeper in keepers)
    for name in required:
        path = state / name
        if path.is_symlink() or not path.is_file() or path.resolve(strict=True) != path:
            raise ValueError(f'required canonical state file absent or symlinked: {name}')
    selected, skipped = set(required), []
    for name in ['tasks-archive.json', 'goal_verifications.json', 'goal_events.jsonl']:
        if (state / name).exists():
            selected.add(name)
    trees = [state / 'tasks', state / 'config']
    trees.extend(state / 'playground/docker' / keeper for keeper in keepers)
    for tree in trees:
        if tree.is_symlink():
            raise ValueError(f'scope root must not be a symlink: {tree}')
        for directory, directories, files in os.walk(tree, followlinks=False):
            parent = Path(directory)
            ignored = [name for name in directories
                       if name in EXCLUDED or (parent / name).is_symlink()]
            skipped.extend(str((parent / name).relative_to(state)) for name in ignored)
            directories[:] = [name for name in directories if name not in ignored]
            for name in files:
                path = parent / name
                relative = str(path.relative_to(state))
                if name in EXCLUDED or path.is_symlink():
                    skipped.append(relative)
                elif path.is_file():
                    selected.add(relative)
    return required, selected, sorted(skipped)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--keeper', action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compare', type=Path)
    args = parser.parse_args()
    for keeper in args.keeper:
        if not keeper or keeper in {'.', '..'} or Path(keeper).name != keeper:
            raise ValueError('keeper names must be single path components')
    base = args.base.resolve(strict=True)
    state = base / '.masc'
    previous = json.loads(args.compare.read_text()) if args.compare else None
    if previous is not None:
        if (previous['schema'], previous['base_path'], previous['keepers']) != (
                SCHEMA, str(base), sorted(args.keeper)):
            raise ValueError('previous capture does not identify the same workspace and keepers')
    required, selected, skipped = collect_paths(state, args.keeper)
    before_files = previous['files'] if previous else {}
    files = {name: read_identity(state / name, before_files.get(name, {}).get('bytes'))
             for name in sorted(selected)}
    result = {'schema': SCHEMA, 'base_path': str(base), 'keepers': sorted(args.keeper),
              'observed_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'scope': 'Required Task backlog, Goals, runtime and selected Keeper configuration; '
                       'regular tasks/config files and selected Docker playground artifacts; '
                       'listed symlinks, VCS metadata, build and dependency trees excluded.',
              'required_paths': sorted(required), 'excluded_paths': skipped, 'files': files}
    if previous is not None:
        unchanged, appended, changed = [], [], []
        for name in sorted(before_files.keys() & files.keys()):
            old, current = before_files[name], files[name]
            if current['sha256'] == old['sha256']:
                unchanged.append(name)
            elif name.endswith('.jsonl') and current.get('previous_size_prefix_sha256') == old['sha256']:
                appended.append(name)
            else:
                changed.append(name)
        result['comparison'] = {'previous_capture': str(args.compare.resolve()),
            'unchanged': unchanged, 'append_only_jsonl': appended, 'changed': changed,
            'missing': sorted(before_files.keys() - files.keys()),
            'created': sorted(files.keys() - before_files.keys())}
    with args.output.open('x') as output:
        args.output.chmod(0o600)
        json.dump(result, output, ensure_ascii=False, indent=2)
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())
    print(json.dumps({'receipt': str(args.output), 'files': len(files),
                      'required_paths': sorted(required),
                      'comparison_counts': {name: len(paths) for name, paths in
                          result.get('comparison', {}).items() if isinstance(paths, list)}}))


if __name__ == '__main__':
    main()
