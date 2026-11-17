"""Focused complete-module replay against compatible prebuilt dependencies."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', type=Path, required=True)
parser.add_argument('--build-repo', type=Path, required=True)
parser.add_argument('--opam-prefix', type=Path, required=True)
parser.add_argument('--bundle', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
repo, build, opam, bundle, out = [p.resolve() for p in
    (args.repo, args.build_repo, args.opam_prefix, args.bundle, args.out)]
if 'artifacts' not in out.parts:
    parser.error('--out must be a new directory under artifacts/')
out.mkdir(parents=True, exist_ok=False)
environment = dict(os.environ, PATH=str(opam / 'bin') + os.pathsep + os.environ['PATH'])
manifest = json.loads((bundle / 'native-inputs.json').read_text())
receipts = []

def sha(data):
    return hashlib.sha256(data).hexdigest()

def run(label, argv, expected=0):
    started = time.monotonic()
    process = subprocess.run(list(map(str, argv)), cwd=out, env=environment,
                             capture_output=True, text=True)
    (out / (label + '.stdout')).write_text(process.stdout)
    (out / (label + '.stderr')).write_text(process.stderr)
    receipts.append(dict(label=label, argv=list(map(str, argv)),
                         exit_code=process.returncode,
                         elapsed_seconds=time.monotonic() - started,
                         stdout_sha256=sha(process.stdout.encode()),
                         stderr_sha256=sha(process.stderr.encode())))
    (out / 'commands.json').write_text(json.dumps(receipts, indent=2) + '\n')
    print(label, process.returncode, flush=True)
    if process.returncode != expected:
        raise RuntimeError(process.stderr)
    return process

def source(path, *, base=False):
    if base:
        data = subprocess.check_output(['git', 'show', manifest['base'] + ':' + path], cwd=repo)
    else:
        data = (repo / path).read_bytes()
    key = ('base:' if base else '') + path
    if sha(data) != manifest['source_sha256'][key]:
        raise ValueError('Frozen source mismatch: ' + key)
    return data

for ext in ('mli', 'ml'):
    name = 'packages/agent_core/lib/llm_provider/http_request_stream.' + ext
    (out / ('stream_under_test.' + ext)).write_bytes(b'open Llm_provider\n' + source(name))
    name = 'packages/agent_core/lib/llm_provider/complete_common.' + ext
    before, after = source(name, base=True), source(name)
    if ext == 'mli' and before != after:
        raise ValueError('This replay assumes an unchanged Complete_common interface')
    (out / ('common_before.' + ext)).write_bytes(b'open Llm_provider\n' + before)
    prefix = b'open Llm_provider\n'
    if ext == 'ml':
        prefix += b'module Http_request_stream = Stream_under_test\n'
    (out / ('common_after.' + ext)).write_bytes(prefix + after)

test = source('packages/agent_core/test/test_http_request_stream.ml').decode()
assert test.count('module Stream = Http_request_stream') == 1
(out / 'test_core.ml').write_text(test.replace('module Stream = Http_request_stream',
                                             'module Stream = Stream_under_test', 1))
(out / 'test_core.mli').write_text('')
receipt = source('packages/agent_core/test/test_output_token_receipt.ml')
(out / 'test_receipt_suite.ml').write_bytes(receipt.replace(b'open Llm_provider\n',
    b'open Llm_provider\nmodule Complete_common = Common_after\n', 1))
helper = source('packages/agent_core/test/agent_core_test_deps.ml')
(out / 'agent_core_test_deps.ml').write_bytes(helper)
source('packages/agent_core/test/dune')
fixture = (bundle / 'probe_actual.ml').read_bytes()
if sha(fixture) != manifest['fixture_sha256']:
    raise ValueError('Fixture mismatch')
(out / 'probe_actual.ml').write_bytes(fixture)

packages = manifest['opam_packages']
find = str(opam / 'bin/ocamlfind')
compiler = [find, 'ocamlopt', '-thread', '-package', ','.join(packages)]
provider = build / '_build/default/packages/agent_core/lib/llm_provider'
local = [build / '_build/default/packages/agent_core/lib/strings',
         build / '_build/default/packages/agent_core/lib/digest', provider]
includes = ['-I', str(out)]
for directory, library in zip(local, ('agent_core_strings', 'agent_core_digest', 'llm_provider')):
    for visibility in ('public_cmi', 'byte'):
        includes += ['-I', str(directory / ('.' + library + '.objs') / visibility)]
flags = ['-no-alias-deps', '-w', '+4+8+32+69', '-warn-error', '+4+8+32+69', '-opaque', '-g']
prefix = compiler + includes + flags
for ext in ('mli', 'ml'):
    run('core-' + ext, prefix + ['-c', 'stream_under_test.' + ext])

public = [str(out), str(opam / 'lib/yojson'), str(opam / 'lib/alcotest'),
          str(provider / '.llm_provider.objs/public_cmi')]
queries = run('query-transitive-dirs', [find, 'query', '-recursive', '-format', '%d'] + packages)
hidden = sorted(set(queries.stdout.splitlines()) | set(includes[1::2]))

def test_prefix(visible):
    result = [str(opam / 'bin/ocamlopt.opt'), '-thread']
    for directory in visible:
        result += ['-I', directory]
    for directory in hidden:
        result += ['-H', directory]
    return result + flags

run('empty-test-interface', test_prefix(public) + ['-c', 'test_core.mli'])
negative = run('hidden-yojson-refused',
              test_prefix([p for p in public if p != str(opam / 'lib/yojson')])
              + ['-c', 'test_core.ml'], expected=2)
assert 'Unbound module Yojson' in negative.stderr
run('declared-test-compiles', test_prefix(public) + ['-c', 'test_core.ml'])

libraries = [local[0] / 'agent_core_strings.cmxa', local[1] / 'agent_core_digest.cmxa',
             provider / 'llm_provider.cmxa']

def link(label, modules):
    run(label + '-link', compiler + ['-linkpkg', '-I', str(out)] + libraries +
        [out / (module + '.cmx') for module in modules] + ['-o', out / (label + '.exe')])
    return run(label + '-native', [out / (label + '.exe')])

core = link('core-test', ['stream_under_test', 'test_core'])
assert '4 tests run' in core.stdout
binding = {}
ppx = build / manifest['ppx_relative_path']
for unit in ('common_before', 'common_after'):
    run(unit + '-mli', prefix + ['-c', unit + '.mli'])
    before = sha((out / (unit + '.cmi')).read_bytes())
    ppx_command = shlex.join([str(ppx), '-as-ppx', '-inline-test-lib', unit,
                             '-inline-test-drop-with-deadcode'])
    run(unit + '-ml', prefix + ['-ppx', ppx_command, '-c', unit + '.ml'])
    after = sha((out / (unit + '.cmi')).read_bytes())
    assert before == after, 'Implementation did not preserve the explicit MLI'
    binding[unit] = {'after_mli_sha256': before, 'after_ml_sha256': after}
for unit in ('agent_core_test_deps', 'probe_actual', 'test_receipt_suite'):
    run(unit + '-compile', prefix + ['-c', unit + '.ml'])
probe = link('actual', ['stream_under_test', 'common_before', 'common_after', 'probe_actual'])
observed = json.loads(probe.stdout)
assert observed['assertions'] == 104
(out / 'observed.json').write_text(json.dumps(observed, indent=2) + '\n')
receipt = link('receipt', ['stream_under_test', 'agent_core_test_deps', 'common_after',
                           'test_receipt_suite'])
assert '15 tests run' in receipt.stdout
result = {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'manifest_sha256': sha((bundle / 'native-inputs.json').read_bytes()),
          'replay_sha256': sha(Path(__file__).read_bytes()), 'interface_binding': binding,
          'declared_test_public_dirs': public, 'expected_hidden_yojson_failure': True,
          'core_tests': 4, 'consumer_assertions': 104, 'receipt_tests': 15,
          'scope': 'Complete fresh source modules, explicit unchanged MLI binding, compatible prebuilt dependencies; no Dune, HTTP/provider, pool or installed-runtime execution.'}
(out / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result), flush=True)
