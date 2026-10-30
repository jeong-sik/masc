"""Execute the actual standalone manifest/identifier/vocabulary interfaces.
Only inline test declarations are removed; no Dune or Core/project linking.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

MODULES = ['model_identifiers', 'capability_vocab', 'reasoning_effort', 'capability_manifest']


def main():
    args = argparse.ArgumentParser()
    args.add_argument('--source-ref')
    args.add_argument('--before', action='store_true')
    args = args.parse_args()
    here = Path(__file__).resolve().parent
    root = here.parents[2]
    lib = Path('packages/agent_core/lib/llm_provider')
    hashes = {}
    with tempfile.TemporaryDirectory(prefix='masc-exact-manifest-') as folder:
        folder = Path(folder)
        files = []
        for module in MODULES:
            for extension in ['mli', 'ml']:
                name = f'{module}.{extension}'
                path = lib / name
                source = (subprocess.check_output(['git', 'show', f'{args.source_ref}:{path}'], cwd=root, text=True)
                          if args.source_ref else root.joinpath(path).read_text())
                compiled, count = re.subn(r'^let%test\b.*?^;;\n', '', source, flags=re.M | re.S)
                hashes[name] = {'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
                                'compiled_sha256': hashlib.sha256(compiled.encode()).hexdigest(),
                                'inline_tests_excluded': count}
                folder.joinpath(name).write_text(compiled)
                files.append(name)
        folder.joinpath('fixture.ml').write_bytes(here.joinpath('fixture.ml').read_bytes())
        subprocess.run(['ocamlfind', 'ocamlc', '-package', 'yojson', '-linkpkg', *files,
                        'fixture.ml', '-o', 'fixture'], cwd=folder, check=True)
        checks = json.loads(subprocess.check_output([str(folder / 'fixture'),
                            'before' if args.before else 'after'], text=True))
    print(json.dumps({'scope': 'actual standalone production modules and interfaces with inline-test declarations excluded',
                      'source_ref': args.source_ref, 'before': args.before,
                      'sources': hashes, 'checks': checks, 'project_linked': False,
                      'request_resolver_executed': False, 'provider_called': False}, indent=2))
    if not all(checks.values()):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
