"""Execute actual standalone production manifest boundary modules/interfaces.
Only inline-test declarations are excluded. No Dune or MASC/Core linking.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

MODULES = ['model_identifiers', 'capability_vocab', 'reasoning_effort', 'capability_manifest']


def main():
    here = Path(__file__).resolve().parent
    lib = here.parents[2] / 'packages/agent_core/lib/llm_provider'
    hashes = {}
    with tempfile.TemporaryDirectory(prefix='masc-manifest-admission-') as folder:
        folder = Path(folder)
        files = []
        for module in MODULES:
            for extension in ['mli', 'ml']:
                name = f'{module}.{extension}'
                source = (lib / name).read_text()
                compiled, count = re.subn(r'^let%test\b.*?^;;\n', '', source, flags=re.M | re.S)
                hashes[name] = {'source_sha256':hashlib.sha256(source.encode()).hexdigest(),
                    'compiled_sha256':hashlib.sha256(compiled.encode()).hexdigest(),
                    'inline_tests_excluded':count}
                (folder / name).write_text(compiled)
                files.append(name)
        (folder / 'fixture.ml').write_bytes((here / 'fixture.ml').read_bytes())
        subprocess.run(['ocamlfind','ocamlc','-package','yojson','-linkpkg',*files,'fixture.ml','-o','fixture'],cwd=folder,check=True)
        checks = json.loads(subprocess.check_output([str(folder / 'fixture')],text=True))
        failures = {}
        for name, source in {
            'raw_list_install': 'let () = Capability_manifest.set_global []\n',
            'entry_view_reinstall': 'let () = Capability_manifest.set_global (Capability_manifest.entries Capability_manifest.empty)\n'
        }.items():
            (folder / f'{name}.ml').write_text(source)
            result = subprocess.run(['ocamlfind','ocamlc','-package','yojson','-c',f'{name}.ml'],cwd=folder,capture_output=True,text=True)
            checks[f'{name}_is_type_rejected'] = result.returncode != 0 and 'Capability_manifest.t' in result.stderr
            failures[name] = result.stderr
    print(json.dumps({'scope':'actual manifest/identifier/vocabulary/effort modules and interfaces with inline-test declarations excluded',
        'sources':hashes, 'checks':checks, 'expected_compile_rejections':failures,
        'fixture_dependencies':False,'project_linked':False,'capability_request_resolver_executed':False,
        'provider_called':False},indent=2))
    if not all(checks.values()):raise SystemExit(1)


if __name__ == '__main__':main()
