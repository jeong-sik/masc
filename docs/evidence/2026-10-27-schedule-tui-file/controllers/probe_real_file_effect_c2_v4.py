#!/usr/bin/env python3
"""Prepared single scheduled DeepSeek MicroVM file-effect probe; v4 owned guest-shim setup derivative.

Executing this file starts an owned server and real model work. Preparation and
AST checks do not execute it. No production installation is performed.
"""
import argparse
import zipfile
from urllib.parse import quote
import hashlib
import json
import math
import os
from pathlib import Path
import socket
import stat
import struct
import subprocess
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--image-reference', required=True)
parser.add_argument('--guest-shim', type=Path, required=True, help='Explicit read-only pinned guest ELF input; never searched or executed by preflight.')
parser.add_argument('--guest-shim-sidecar', type=Path, required=True, help='Explicit matching pinned SHA256 sidecar; no primary config is copied.')
parser.add_argument('--native-binding', type=Path, required=True, help='Explicit root-verified identity and original receipt/archive/verification file bindings.')
parser.add_argument('--preflight-only', action='store_true', help='Validate only local input files and CLI; never initialize a workspace, inspect credentials or start a process.')
parser.add_argument('--provider', choices=['ollama_cloud'], required=True)
parser.add_argument('--observation-deadline-unix', type=float, required=True, help='Caller-owned observation limit, never a producer terminal verdict.')
args = parser.parse_args()
REPO = Path(__file__).resolve().parents[2]
output = args.output.resolve()
if not output.is_relative_to(REPO/'artifacts') or output == REPO/'artifacts':
    raise RuntimeError('output must be a fresh owned directory under this repository artifacts/')
# A new output directory is mandatory; no adoption of an old workspace.
if output.exists():
    raise RuntimeError('output already exists; original runs must remain immutable')
if not math.isfinite(args.observation_deadline_unix) or args.observation_deadline_unix <= time.time():
    raise RuntimeError('observation deadline must be in the future')
# No unfrozen C2 source, run or binary value is invented here. The operator's
# explicit binding is checked against all three original inputs before setup.


def file_digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def checked_hex(value, length):
    if not isinstance(value, str) or len(value) != length or any(c not in '0123456789abcdef' for c in value):
        raise RuntimeError('invalid canonical digest in native binding')
    return value


# Explicit local asset pins. The original release/source provenance is unknown;
# matching these bytes/ELF/sidecar does not prove C2 guest protocol compatibility.
EXPECTED_GUEST_SHIM_SHA256 = '04b6db55669ade5bd0a1cb6a05bacbc0950b9442d1028554278a9f3ad8bc78fe'
EXPECTED_GUEST_SHIM_BYTES = 5471544
EXPECTED_GUEST_SIDECAR_SHA256 = 'af27b84f3b740b268ad53a92562bcbb2e0e3118dabdd8041237fe6d752763a51'
EXPECTED_GUEST_SIDECAR_BYTES = 93


def read_pinned_guest_file(path, expected_sha256, expected_bytes, expected_mode):
    path = path.expanduser().absolute()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or stat.S_IMODE(before.st_mode) != expected_mode:
            raise RuntimeError('guest asset must be a regular file with its pinned mode')
        raw = stream.read()
        after = os.fstat(stream.fileno())
    named = path.lstat()
    stamp = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    if stamp(before) != stamp(after) or stamp(after) != stamp(named):
        raise RuntimeError('guest asset identity changed during read')
    digest = hashlib.sha256(raw).hexdigest()
    if len(raw) != expected_bytes or digest != expected_sha256:
        raise RuntimeError('explicit guest asset hash/bytes mismatch')
    return raw, {'path':str(path),'sha256':digest,'bytes':len(raw),
                 'mode':oct(stat.S_IMODE(after.st_mode)), 'regular_file':True,
                 'device':after.st_dev,'inode':after.st_ino}


def verify_guest_shim_pair(shim_path, sidecar_path):
    binary_bytes, binary_identity = read_pinned_guest_file(shim_path,
        EXPECTED_GUEST_SHIM_SHA256, EXPECTED_GUEST_SHIM_BYTES, 0o755)
    sidecar_bytes, sidecar_identity = read_pinned_guest_file(sidecar_path,
        EXPECTED_GUEST_SIDECAR_SHA256, EXPECTED_GUEST_SIDECAR_BYTES, 0o644)
    if not os.access(binary_identity['path'], os.X_OK):
        raise RuntimeError('explicit guest shim is not executable')
    if (len(binary_bytes) < 64 or binary_bytes[:4] != b'\x7fELF'
            or binary_bytes[4] != 2 or binary_bytes[5] != 1
            or binary_bytes[6] != 1 or struct.unpack_from('<H', binary_bytes, 18)[0] != 183):
        raise RuntimeError('guest shim must be ELF64 little-endian AArch64')
    # Canonical verify_shim_sidecar trims and checks the first space-separated
    # lowercase SHA256, not the trailing asset name or release authenticity.
    first = sidecar_bytes.decode('ascii').strip().split(' ', 1)[0].strip()
    if (len(first) != 64 or any(char not in '0123456789abcdef' for char in first)
            or first != binary_identity['sha256']):
        raise RuntimeError('canonical guest sidecar digest does not match binary')
    receipt = {'binary':binary_identity,'sidecar':sidecar_identity,
        'elf':{'class':64,'byte_order':'little','e_machine':183,
               'e_type':struct.unpack_from('<H',binary_bytes,16)[0]},
        'sidecar_first_digest_matches_binary':True,'executable_access':True,
        'scope':'Local exact-byte input integrity only. No release authenticity, source-commit provenance or actual protocol compatibility established.'}
    return receipt, binary_bytes, sidecar_bytes


def stage_owned_guest_shim():
    # Re-read the explicit assets after canonical init, before any server start.
    # Only this binary and sidecar are copied; .conf/.env and .bin are never read.
    source, binary_bytes, sidecar_bytes = verify_guest_shim_pair(args.guest_shim, args.guest_shim_sidecar)
    for relative in ['.masc', '.masc/microvm', '.masc/microvm/shim']:
        directory = base/relative
        directory.mkdir(exist_ok=True)
        if not stat.S_ISDIR(directory.lstat().st_mode) or directory.is_symlink():
            raise RuntimeError('owned guest shim parent must be a real directory')
    directory = base/'.masc/microvm/shim'
    target = directory/'masc-exec-shim'
    sidecar = directory/'masc-exec-shim.sha256'
    write_json('guest-shim-copy-start.json', {'source':source,'destination_paths':[str(target),str(sidecar)],
        'publication':'exclusive fresh owned files; partial failure is preserved, never replaced or rolled back'})
    for path, raw, mode in [(target,binary_bytes,0o755),(sidecar,sidecar_bytes,0o644)]:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, mode)
        with os.fdopen(fd,'wb') as stream:
            os.fchmod(stream.fileno(),mode)
            stream.write(raw);stream.flush();os.fsync(stream.fileno())
    destination, _, _ = verify_guest_shim_pair(target,sidecar)
    receipt = {'source':source,'destination':destination,
        'binary_bytes_equal':source['binary']['sha256']==destination['binary']['sha256'],
        'sidecar_bytes_equal':source['sidecar']['sha256']==destination['sidecar']['sha256'],
        'copied_before_server_start':True,'configuration_copied':False,
        'limit':'Runtime generates the owned shim config. Actual guest protocol compatibility is not established by copying or local verification.'}
    write_json('guest-shim-copy-verified.json',receipt)
    return receipt


binding_path = args.native_binding.resolve(strict=True)
binding_bytes = binding_path.read_bytes()
binding = json.loads(binding_bytes)
if binding.get('schema') != 'masc.schedule-c2-native-binding.v1':
    raise RuntimeError('unsupported native binding schema')
EXPECTED_SOURCE = 'a3950a189b9cc5a7ce82cb725699455d79923f42'
if checked_hex(binding['source_sha'], 40) != EXPECTED_SOURCE:
    raise RuntimeError('binding is not the frozen C2 product source')
EXPECTED_WORKFLOW = checked_hex(binding['workflow_sha'], 40)
EXPECTED_BINARY = checked_hex(binding['server_sha256'], 64)
EXPECTED_ARCHIVE = checked_hex(binding['archive_sha256'], 64)
WORKFLOW_RUN = binding['workflow_run']
ARTIFACT_ID = binding['artifact_id']
WORKFLOW_REF = binding['workflow_ref']
if any(type(value) is not int or value <= 0 for value in [WORKFLOW_RUN, ARTIFACT_ID]) or not isinstance(WORKFLOW_REF, str) or not WORKFLOW_REF:
    raise RuntimeError('invalid run, artifact or ref binding')


def bound_input(name):
    entry = binding[name]
    path = Path(entry['path'])
    if not path.is_absolute():
        path = binding_path.parent / path
    path = path.resolve(strict=True)
    if type(entry['bytes']) is not int or path.stat().st_size != entry['bytes'] or file_digest(path) != checked_hex(entry['sha256'], 64):
        raise RuntimeError('original native input hash/bytes mismatch: '+name)
    return path


artifact_binary = args.binary.resolve(strict=True)
artifact_receipt_path = bound_input('artifact_receipt')
archive_path = bound_input('archive')
verification_path = bound_input('download_verification')
artifact_receipt_bytes = artifact_receipt_path.read_bytes()
artifact_receipt = json.loads(artifact_receipt_bytes)
verification = json.loads(verification_path.read_bytes())
if (file_digest(artifact_binary) != EXPECTED_BINARY
        or binding['archive']['sha256'] != EXPECTED_ARCHIVE
        or artifact_receipt.get('source_sha') != EXPECTED_SOURCE
        or artifact_receipt.get('workflow_sha') != EXPECTED_WORKFLOW
        or artifact_receipt.get('server_sha256') != EXPECTED_BINARY
        or verification.get('workflow') != binding['workflow_name']
        or verification.get('run_id') != WORKFLOW_RUN
        or verification.get('workflow_ref') != WORKFLOW_REF
        or verification.get('workflow_execution_head') != EXPECTED_WORKFLOW
        or verification.get('source_input') != EXPECTED_SOURCE
        or verification.get('artifact_id') != ARTIFACT_ID
        or verification.get('archive_sha256') != EXPECTED_ARCHIVE):
    raise RuntimeError('exact native source/run/execution/artifact identity mismatch')
observations = [row for row in verification.get('observations', []) if row.get('executable') == 'masc']
if len(observations) != 1 or not all([
        observations[0].get('sha256') == EXPECTED_BINARY,
        observations[0].get('args') == ['build-commit'],
        observations[0].get('exit_code') == 0,
        observations[0].get('stdout_utf8') == EXPECTED_SOURCE+'\n',
        observations[0].get('stdout_sha256') == hashlib.sha256((EXPECTED_SOURCE+'\n').encode()).hexdigest()]):
    raise RuntimeError('root build-commit observation does not bind this exact executable')
with zipfile.ZipFile(archive_path) as archive:
    for name, expected in [('masc', EXPECTED_BINARY), ('receipt.json', hashlib.sha256(artifact_receipt_bytes).hexdigest())]:
        members = [member for member in archive.infolist() if not member.is_dir() and Path(member.filename).name == name]
        if len(members) != 1:
            raise RuntimeError('archive member missing or ambiguous: '+name)
        with archive.open(members[0]) as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != expected:
                raise RuntimeError('extracted input differs from original archive: '+name)
SOURCE_BINDINGS = {'config/runtime.toml': {'bytes': 104331, 'sha256': 'e26f3faa9e1715c487d52e31f3bd767e0d4431ea5d11ff78693eaccf65c946cf'}, 'scripts/fixtures/release-evidence/runtime.toml': {'bytes': 3058, 'sha256': 'ccbe65e399f47a3abddbf4299e15dd0fd55001dd785b2e0d75948ad86acf7cfd'}, 'config/tools/Write.toml': {'bytes': 722, 'sha256': 'c5e3d87bbe0180343f5208cdc465ef52f5b454f4c561a06878301bb53da655a7'}, 'config/tools/Read.toml': {'bytes': 2270, 'sha256': '007ea215e6473c9b7daf9228abd213deb8473f49c32dac51ad158e58e5c0c06f'}, 'lib/keeper/keeper_tool_descriptor.ml': {'bytes': 144103, 'sha256': '35a944e04b94472ee3c84fd75fc7d486a592222913858d38ec90506bb248add8'}, 'lib/keeper/keeper_tool_filesystem_runtime.ml': {'bytes': 129930, 'sha256': '694a9c14cf252a62effae1d599bd5ce43aacddb986e489ae4b9fdb3f1fa8bf96'}, 'lib/keeper/keeper_tool_filesystem_remote_write.ml': {'bytes': 23780, 'sha256': '0db849d8ddb3bde497a412b47a946b62ff610c4ca569cbf58c21e2a66ae8811c'}, 'lib/keeper/keeper_sandbox_read_runner.ml': {'bytes': 4199, 'sha256': '95488911943bde29c0b9020d3c6a02083a4b8c26f6b89286eef8e907ad0e5730'}, 'lib/keeper/keeper_sandbox_read_backend.ml': {'bytes': 30262, 'sha256': '94e8c5f1682d4ffca9ca6423f260e66f5f15306164f7f24c22e73aac4c1eb3b6'}, 'lib/keeper/keeper_remote_path.ml': {'bytes': 10254, 'sha256': '7bfdc3f52e90cdb144de4e9179a1d7f06a53f1e571303685a49f136c03dbeb1a'}, 'lib/keeper/keeper_workspace_namespace.ml': {'bytes': 1649, 'sha256': '7dcc9ffbe5360e967ab0f0d233931d53e4d9769edf5e50bf0f1a6ac6ba1e8855'}, 'lib/keeper/keeper_sandbox.ml': {'bytes': 10490, 'sha256': 'a21f0137feb338f1683324622412030a389073230f49c6faec9a9416a6b528f1'}, 'lib/config/keeper_sandbox_config.ml': {'bytes': 4601, 'sha256': '80633b393b62415299c3afb8f0d3a043c036205de173c37909a8230bbc5bf25c'}, 'lib/config/playground_paths.ml': {'bytes': 5279, 'sha256': '13d5927af8bb69b6e29899bfd3d165e26c0c76c201ac6375e33bfecdaa67a1a6'}, 'lib/keeper_tool_call_log.ml': {'bytes': 58598, 'sha256': 'e823ecc9c36e7fb2226a02544929bd6e0f27ad41177509d98681579cd90018dd'}, 'lib/keeper_tool_call_log_route_evidence.ml': {'bytes': 5279, 'sha256': '99948d0fb56f7db3fc3a4f61fcf9b8bdea487512344c0b920a3b5330ad4086b6'}, 'lib/keeper/keeper_reaction_ledger.ml': {'bytes': 77170, 'sha256': '86cf1d1e79061d30f9f303705944d7cf57578b804ebfb1fe93130c0772b6d740'}, 'lib/keeper_runtime/keeper_event_queue_state_wire.ml': {'bytes': 30684, 'sha256': '53d7c4d57b17a376c8428320a1cf3f89025efbd5a0cedcb570bb03878c2df17b'}, 'lib/keeper/keeper_unified_prompt.ml': {'bytes': 96880, 'sha256': '55f607445980c9f6471410abce9f9572f4ba806e336d9f3cb402d98247985126'}, 'lib/keeper/keeper_run_prompt.ml': {'bytes': 9267, 'sha256': '54229d2bce98cbe1406952f4f6655524e5366e0b9ad1a6c8426071894a8334a0'}, 'lib/config_dir_resolver/config_dir_resolver.ml': {'bytes': 17936, 'sha256': '20d184fd58a59131799096479fb3235f7f4efc568ab58abca6d9a568b87b5ffd'}}
SOURCE_BINDINGS['lib/keeper/keeper_hooks_agent_core.ml'] = {'bytes': 54717, 'sha256': '26e2b488d0308ed0d8f8a4a65d80f79af1cb08eefd30d04764177d1dc9eb9a41'}
SOURCE_BINDINGS['lib/keeper/keeper_sandbox_microvm.ml'] = {'bytes':137028,'sha256':'7ac31a2ea288f7685de5a76434339c607a2101238ba6d40f9b7cf819573339c1'}
SOURCE_BINDINGS['lib/keeper/keeper_microvm_shim_readiness.ml'] = {'bytes':7550,'sha256':'7bbcdfd20218fb903a56abd4c6e435a42a23033df9cabc73e2b7a9b22c5b558e'}
for relative, bound in SOURCE_BINDINGS.items():
    path = REPO / relative
    if path.stat().st_size != bound['bytes'] or file_digest(path) != bound['sha256']:
        raise RuntimeError('frozen source file mismatch: '+relative)
if (WORKFLOW_RUN, ARTIFACT_ID, EXPECTED_WORKFLOW, WORKFLOW_REF, EXPECTED_BINARY, EXPECTED_ARCHIVE) != (
        40396800146, 12687003191, '9377c7f3025d68e3856d2afd3762468dabc77813', 'main',
        '1622a35d1082da4fe24d9effb05aec11918d9444288441049c8d6d30cedb415c',
        'a9e1eff4b3ddc6b43c14fa2fc48b7f468634d902ff487d9337b57bc4f5cb5927'):
    raise RuntimeError('unexpected producer binding')

guest_shim_input, _, _ = verify_guest_shim_pair(args.guest_shim, args.guest_shim_sidecar)

if args.preflight_only:
    print(json.dumps({'scope': 'local native and explicit guest-shim inputs only; no workspace copy, binary execution, server/model/credential access',
        'source_sha': EXPECTED_SOURCE, 'workflow_run': WORKFLOW_RUN,
        'workflow_sha': EXPECTED_WORKFLOW, 'workflow_ref': WORKFLOW_REF,
        'server_sha256': EXPECTED_BINARY, 'binding_sha256': hashlib.sha256(binding_bytes).hexdigest(),
        'controller_sha256':file_digest(Path(__file__)), 'source_file_count':len(SOURCE_BINDINGS),
        'guest_shim_input':guest_shim_input}))
    raise SystemExit(0)
output.mkdir(parents=True, exist_ok=False)
repo = REPO
binary = args.binary.resolve(strict=True)
records = []
checks = []


class Incomplete(RuntimeError):
    pass


class BehaviorFailure(RuntimeError):
    pass


def sanitize(value):
    # Never retain control or authentication tokens from live observation APIs.
    if isinstance(value, dict):
        return {k: sanitize(v) for k, v in value.items() if k not in
                {'chat_control_token', 'interrupt_token', 'authorization', 'token',
                 'access_token', 'refresh_token', 'bearer_token', 'mcp_session_id'}}
    if isinstance(value, list):
        return [sanitize(v) for v in value]
    if isinstance(value, str):
        # MCP may wrap the same structured response in a JSON text block.
        try:
            decoded = json.loads(value)
        except (json.JSONDecodeError, ValueError):
            return value
        if isinstance(decoded, (dict, list)):
            return json.dumps(sanitize(decoded), ensure_ascii=False)
    return value


def save():
    (output / 'api-records.json').write_text(json.dumps(records, indent=2) + '\n')
    (output / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')


def check(name, condition, detail=None):
    try:
        checks.append({'name': name, 'passed': bool(condition), 'detail': sanitize(detail)})
        save()
        print(('PASS ' if condition else 'FAIL ') + name, flush=True)
    finally:
        # An observed behavior failure outranks failure to save/print its receipt.
        # A positive check still requires its evidence writes to succeed.
        if not condition:
            raise BehaviorFailure(name)


setup_processes = []


def command(argv, env):
    observation_open()
    # No subprocess.run(timeout): it would kill an owned CLI on expiry.
    # These CLI outputs are never retained (login can contain credentials).
    child = subprocess.Popen(argv, env=env, cwd=base, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
    row = {'pid':child.pid,'command_verb':argv[1], 'started_at_unix':time.time()}
    setup_processes.append(row)
    write_json('setup-processes.json',setup_processes)
    try:
        child.wait(timeout=max(.001,args.observation_deadline_unix-time.time()))
    except subprocess.TimeoutExpired:
        row.update(observation_ended_at_unix=time.time(),returncode=child.poll(),
                   left_running=True,forced_kill=False)
        write_json('setup-processes.json',setup_processes)
        raise Incomplete('setup CLI observation deadline; child left independently observable')
    row.update(returncode=child.returncode,ended_at_unix=time.time(),forced_kill=False)
    write_json('setup-processes.json',setup_processes)
    if child.returncode:
        raise Incomplete('owned setup CLI failed: '+argv[1]+' exit='+str(child.returncode))
    return ''


def request(path, token=None, body=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(url + path, headers=headers,
          data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            status, data = response.status, json.load(response)
    except urllib.error.HTTPError as error:
        status = error.code
        raw = error.read().decode()
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            data = {'body': raw}
    if (path == '/api/v1/dashboard/scheduled-automation?schedule_id='+quote(schedule_id)
            and isinstance(data,dict)
            and ((data.get('request') or {}).get('keeper_queue_evidence') or {}).get('terminal_outcome') in ['failed','cancelled']):
        check('original scheduled source avoids terminal failure or cancellation',False,
              (data['request']['keeper_queue_evidence']))
    retained = ({k: data.get(k) for k in ['build', 'paths', 'startup']} if path == '/health?full=1' and isinstance(data, dict) else data)
    records.append({'stage': stage, 'path': path, 'body': body, 'status': status, 'response': sanitize(retained)})
    save()
    return status, data


sessions = {}
request_id = 0


def mcp_roundtrip(token, payload, session=None):
    headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream',
               'Authorization': 'Bearer ' + token, 'Mcp-Protocol-Version': '2025-11-25'}
    if session:
        headers['Mcp-Session-Id'] = session
    req = urllib.request.Request(url + '/mcp', headers=headers, data=json.dumps(payload).encode())
    try:
        response = urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        raw = response.read().decode()
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            events = [json.loads(line[5:].strip()) for line in raw.splitlines() if line.startswith('data:')]
            data = next((event for event in events if event.get('id') == payload.get('id')), {'raw': raw})
        records.append({'stage': stage, 'path': '/mcp', 'body': payload, 'status': response.status, 'response': sanitize(data)})
        save()
        return response.status, data, response.headers.get('Mcp-Session-Id')


def tool(name, body, token=None):
    global request_id
    selected = admin_token if token is None else token
    if selected not in sessions:
        request_id += 1
        status, result, session = mcp_roundtrip(selected, {'jsonrpc': '2.0', 'id': request_id,
            'method': 'initialize', 'params': {'protocolVersion': '2025-11-25',
            'capabilities': {}, 'clientInfo': {'name': 'schedule-api-audit', 'version': '1'}}})
        if status != 200 or not session or 'error' in result:
            raise RuntimeError('MCP initialize failed: ' + json.dumps(result))
        sessions[selected] = session
    request_id += 1
    status, result, _ = mcp_roundtrip(selected, {'jsonrpc': '2.0', 'id': request_id,
        'method': 'tools/call', 'params': {'name': name, 'arguments': body}}, sessions[selected])
    if 'error' in result:
        data = {'isError': True, 'data': result['error']}
    else:
        reply = result.get('result', {})
        payload = reply.get('structuredContent')
        if payload is None:
            blocks = reply.get('content', [])
            text = next((block['text'] for block in blocks if block.get('type') == 'text'), '')
            try:
                payload = json.loads(text)
            except json.JSONDecodeError:
                payload = {'text': text}
        data = {'isError': reply.get('isError', False), 'data': payload}
    print(name, status, 'isError=' + str(data['isError']), flush=True)
    return status, data


def unwrap(result):
    if isinstance(result, dict) and isinstance(result.get('data'), dict):
        return result['data']
    if isinstance(result, dict) and isinstance(result.get('message'), str):
        try:
            decoded = json.loads(result['message'])
            return decoded if isinstance(decoded, dict) else result
        except json.JSONDecodeError:
            return result
    return result


import tomllib
import uuid

stage = 'setup'
server = None
process = {'producer_started': False, 'forced_kills': [], 'restart_count': 0}
keeper = 'audit-file-' + uuid.uuid4().hex
schedule_id = 'audit-file-job-' + uuid.uuid4().hex
marker = 'FILE_EFFECT_VERIFIED_' + uuid.uuid4().hex
relative_file = 'schedule-file-' + uuid.uuid4().hex + '.txt'
expected_content = 'nonce=' + uuid.uuid4().hex + '\n예약 파일 결과 확인 🐙'
expected_bytes = expected_content.encode('utf-8')
base = (output/'workspace').resolve()
base.mkdir()
# This is a source-defined bookkeeping spelling, never a host-file claim.
logical_root = str(base/'.masc/playground'/keeper)
logical_target = logical_root + '/' + relative_file
message = (
    f'Perform this single authorized scheduled job for schedule_id {json.dumps(schedule_id)}. '
    f'Using the public Write tool exactly once, write the new sandbox-relative file_path '
    f'{json.dumps(relative_file)} with exact UTF-8 content represented by this JSON string: '
    f'{json.dumps(expected_content, ensure_ascii=False)}. Decode JSON escapes: the content has '
    f'exactly one LF, Korean and emoji, exactly {len(expected_bytes)} UTF-8 bytes and NO final newline. '
    'Use Write file_path and content only (the public tool overwrites); do not append or patch. '
    'Only after Write succeeds, use the public Read schema on the same file to read its full content '
    '(offset defaults to 1; explicit cwd/offset/limit are allowed when they read that same complete file). Compare the complete actual Read content and byte count with this request; '
    'do not infer success from your intended content or a final narrative. '
    f'Only after the complete Read returns exactly those bytes without truncation, call '
    f'masc_schedule_note_add exactly once on schedule_id {json.dumps(schedule_id)} '
    f'with exact body {json.dumps(marker)}. Then finish this job. '
    'Do not write any other file or note, retry Write, use Edit/Patch/Execute/shell, create another '
    'schedule/chat/task/Board/external message, or ask for confirmation. Tool discovery is allowed. '
    'If the effect cannot be verified, report the failure without adding the marker note.')
meta = {'schema': 'masc.schedule-real-file-effect-preparation.v1',
    'source_sha': EXPECTED_SOURCE, 'source_bindings': SOURCE_BINDINGS,
    'controller_sha256': file_digest(Path(__file__)),
    'native_binding_sha256': hashlib.sha256(binding_bytes).hexdigest(), 'native_binding': binding,
    'native_scope': 'Staged producer artifact; no install, merge, rebuild or primary replacement.',
    'binary': str(binary), 'binary_sha256': EXPECTED_BINARY, 'archive_sha256': EXPECTED_ARCHIVE,
    'image_reference': args.image_reference, 'image_identity_limit': 'Existing image reference promoted into owned config; guest image not independently hashed. Explicit shim/sidecar local bytes are pinned, original release/source provenance unknown and protocol compatibility unproven.',
    'guest_shim_input':guest_shim_input, 'parent_controller_sha256':'bc450f6d8201956d18026d6aa2e3533534aaed198e6a16a201c54299c1f657d1',
    'keeper': keeper, 'schedule_id': schedule_id, 'marker': marker,
    'relative_file': relative_file, 'logical_target': logical_target,
    'expected_utf8_content': expected_content, 'expected_bytes': len(expected_bytes),
    'expected_sha256': hashlib.sha256(expected_bytes).hexdigest(), 'scheduled_message': message,
    'base_path': str(base), 'observation_deadline_unix': args.observation_deadline_unix,
    'authority': 'Owned fixture explicitly sets Gate always_allow and Keeper approval yolo; scheduled wake grants no authority. This is not default Gate/Ask behavior proof.',
    'scope': 'One scheduled job, actual MicroVM Write then full backend Read and marker note; no host-file/export/delivery claim.',
    'not_proven': ['full provider wire bodies or first request body', 'external delivery',
        'host-file export', 'two-job DeepSeek scope correctness', 'restart', 'provider failover',
        'installation', 'multi-account or complete feature correctness']}


def write_json(name, value):
    (output/name).write_text(json.dumps(sanitize(value), ensure_ascii=False, indent=2)+'\n')


def observation_open():
    if server is not None and server.poll() is not None:
        raise Incomplete('owned producer exited before required observations')
    if time.time() >= args.observation_deadline_unix:
        raise Incomplete('observation deadline; producer completion is not inferred')


def exact_read(path):
    status, data = request(path, admin_token)
    if status != 200:
        raise Incomplete('authoritative API unavailable: '+path)
    return data


def successful_tool(name, arguments):
    status, result = tool(name, arguments)
    if status != 200 or result.get('isError') is not False:
        raise Incomplete('setup tool refused: '+name)
    data = unwrap(result)
    return data.get('schedule', data)


def read_jsonl(root, destination, retain=True):
    rows, sources = [], []
    for path in sorted(root.rglob('*.jsonl')):
        raw = path.read_bytes()
        if raw and not raw.endswith(b'\n'):
            raise Incomplete('concurrent incomplete JSONL row; no row invented')
        parsed = [json.loads(line) for line in raw.splitlines() if line.strip()]
        copied = output/'raw'/destination/path.relative_to(root)
        if retain:
            copied.parent.mkdir(parents=True, exist_ok=True)
            copied.write_bytes(raw)
        rows.extend(parsed)
        sources.append({'original_path':str(path),'retained_path':str(copied),
            'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw),'rows':len(parsed)})
    return rows, sources


def decode(value):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except (ValueError, TypeError):
            return None
    return value if isinstance(value, dict) else None


def call_output(call):
    value = decode(call.get('output'))
    if isinstance(value, dict) and '_blob' in value:
        raise Incomplete('small expected file output was artifact-wrapped; full canonical read not retained by this controller')
    return value


def all_calls():
    rows, _ = read_jsonl(base/'.masc/tool_calls', 'tool_calls', retain=False)
    # Read/parse only: a verdict must precede optional retention IO.
    return [row for row in rows if row.get('keeper') == keeper and row.get('record_kind') == 'tool_call']


def retain_calls():
    rows, sources = read_jsonl(base/'.masc/tool_calls', 'tool_calls')
    calls = [row for row in rows if row.get('keeper') == keeper and row.get('record_kind') == 'tool_call']
    write_json('all-owned-tool-calls.json', {'entries':calls,'sources':sources,
        'scope':'All durable files and all owned tool_call rows, including errors/extra effects. Raw ignored evidence requires privacy review before publication.'})
    return calls


queue_captures = []


def queue_capture():
    path = base/'.masc/keepers'/keeper/'event-queue-v19.json'
    if not path.exists():
        return
    raw = path.read_bytes(); state = json.loads(raw)
    if state.get('schema') != 'keeper.event_queue.state.v19':
        raise Incomplete('unsupported queue schema')
    ordinal = len(queue_captures)
    name = 'queue-'+str(ordinal)+'.json'
    (output/name).write_bytes(raw)
    queue_captures.append({'file':name,'sha256':hashlib.sha256(raw).hexdigest(),
        'bytes':len(raw),'observed_at_unix':time.time(),'state':state})


def history(created):
    data = exact_read('/api/v1/dashboard/scheduled-automation?schedule_id='+quote(schedule_id))
    row = data.get('request') or {}
    if (row.get('schedule_id'),row.get('schedule_instance_id')) != (schedule_id,created['schedule_instance_id']):
        raise Incomplete('original schedule instance identity unavailable')
    q = row.get('keeper_queue_evidence') or {}
    if q and (q.get('schedule_id'),q.get('schedule_instance_id'),q.get('keeper_name')) != (schedule_id,created['schedule_instance_id'],keeper):
        raise Incomplete('queue projection identity mismatch')
    return data,q


def live():
    data = exact_read('/api/v1/keepers/turns')
    rows = [row for row in data.get('keepers',[]) if row.get('keeper_name') == keeper]
    if len(rows) != 1 or rows[0].get('status') != 'ok':
        raise Incomplete('owned Keeper missing/unreadable; not idle')
    return rows[0].get('turn')


def notes_primary(created):
    # Pure read/selection: no capture IO before the caller's negative verdict.
    raw = (base/'.masc/schedules.json').read_bytes(); state = json.loads(raw)
    rows = [row for row in state['schedules'] if row['schedule_id'] == schedule_id]
    if len(rows) != 1 or rows[0]['schedule_instance_id'] != created['schedule_instance_id']:
        raise Incomplete('original primary schedule identity mismatch')
    notes = [row for row in state['notes'] if row['schedule_id'] == schedule_id]
    return notes, {'raw':raw,'sha256':hashlib.sha256(raw).hexdigest(),
                   'bytes':len(raw),'observed_at_unix':time.time()}


def retain_primary(capture):
    (output/'primary-schedules.json').write_bytes(capture['raw'])
    write_json('primary-source.json',{k:v for k,v in capture.items() if k!='raw'})


READONLY = {'Read','masc_schedule_get','masc_schedule_list','masc_schedule_notes_list'}
ALLOWED = READONLY | {'keeper_tool_search','Write','masc_schedule_note_add','keeper_artifact_read'}


def successful_call(call):
    return call.get('wire_outcome')=='ok' and call.get('disposition')=='completed'


def complete_read(data):
    # Completeness comes from the canonical returned window, not absence of
    # valid optional input arguments or a model narrative.
    return (isinstance(data,dict) and data.get('ok') is True
            and data.get('path')==logical_target and data.get('via')=='microvm'
            and data.get('truncated') is False and type(data.get('offset')) is int
            and data['offset']==1 and 'next_offset' not in data
            and data.get('last_line_partial',False) is False)


def validate_effects(calls, notes, terminal):
    # No optional capture writes until all currently decidable failures have
    # been assessed. Complete failed readonly rows remain in the raw ledger.
    check('owned call ledger contains only scoped effect/inspection/discovery tools',
          all(c.get('tool') in ALLOWED for c in calls),{'tools':[c.get('tool') for c in calls]})
    writes=[c for c in calls if c.get('tool')=='Write']
    reads=[c for c in calls if c.get('tool')=='Read']
    adds=[c for c in calls if c.get('tool')=='masc_schedule_note_add']
    check('no extra Write or marker note attempt',len(writes)<=1 and len(adds)<=1,
          {'write_calls':len(writes),'note_add_calls':len(adds)})
    check('no extra primary note',len(notes)<=1 and all(n.get('body')==marker and n.get('author_id')==keeper for n in notes),notes)
    if terminal:
        check('Completed original source has required Write and marker calls and primary effect',
              len(writes)==1 and len(adds)==1 and len(notes)==1,
              {'writes':len(writes),'note_adds':len(adds),'primary_notes':len(notes)})
    successful_reads=[];failed_readonly=[];nonqualifying_reads=[];unsupported=[];unknown_reads=[]
    for c in calls:
        name=c.get('tool');args_=c.get('input');ok=successful_call(c)
        if name in READONLY and not ok:
            # An unsuccessful incidental inspection is retained, never counted
            # as the required actual successful complete Read.
            failed_readonly.append(c)
            continue
        if name=='Write':
            check('sole Write carries exact requested content',isinstance(args_,dict)
                and isinstance(args_.get('file_path'),str) and bool(args_['file_path'])
                and args_.get('content')==expected_content,args_)
            check('sole Write attempt completed successfully',ok,
                  {'execution_id':c.get('execution_id'),'wire_outcome':c.get('wire_outcome'),'disposition':c.get('disposition')})
            check('Write execution has no logged output truncation','truncated_to' not in c,{'execution_id':c.get('execution_id')})
            data=decode(c.get('output'))
            if isinstance(data,dict) and '_blob' in data:
                unsupported.append({'execution_id':c.get('execution_id'),'kind':'canonical_write_result_blob'})
                continue
            if data is None:
                unsupported.append({'execution_id':c.get('execution_id'),'kind':'write_result_unavailable'})
                continue
            check('actual Write confirms exact MicroVM logical target',data.get('ok') is True
                and data.get('path')==logical_target and data.get('via')=='microvm',data)
            check('Write confirms overwrite and exact UTF-8 byte count',data.get('mode')=='overwrite'
                and type(data.get('bytes_written')) is int and data['bytes_written']==len(expected_bytes),data)
        elif name=='Read':
            data=decode(c.get('output'))
            if isinstance(data,dict) and '_blob' in data:
                unsupported.append({'execution_id':c.get('execution_id'),'kind':'canonical_read_result_blob'})
                unknown_reads.append(c)
                continue
            if not isinstance(data,dict) or 'truncated_to' in c:
                unsupported.append({'execution_id':c.get('execution_id'),'kind':'read_result_unavailable_or_logged_truncated'})
                unknown_reads.append(c)
                continue
            check('successful filesystem Read stays on the exact requested MicroVM target',
                data.get('ok') is True and data.get('path')==logical_target and data.get('via')=='microvm',data)
            if complete_read(data):
                check('complete Read returns exact UTF-8 content and byte count',isinstance(data.get('content'),str)
                    and data['content'].encode('utf-8')==expected_bytes and type(data.get('bytes')) is int
                    and data['bytes']==len(expected_bytes) and type(data.get('returned_lines')) is int
                    and data['returned_lines']==2,data)
                successful_reads.append(c)
            else:
                nonqualifying_reads.append(c)
        elif name in {'masc_schedule_get','masc_schedule_notes_list'}:
            check('successful schedule inspection remains on original job',
                  isinstance(args_,dict) and args_.get('schedule_id')==schedule_id,args_)
        elif name=='masc_schedule_list':
            # 'all' is confined to this new one-job isolated workspace; it is
            # not a query against the user's operational primary workspace.
            check('successful schedule list is scoped to the owned fixture',isinstance(args_,dict)
                and (args_.get('owner') in ['self','all'] or
                     (args_.get('owner') in ['wake_target','scheduled_by']
                      and args_.get('owner_name') in [keeper,'schedule-file-observer'])),args_)
        elif name=='masc_schedule_note_add':
            check('only requested original-job marker is added successfully',isinstance(args_,dict)
                and args_.get('schedule_id')==schedule_id and args_.get('body')==marker and ok,c)
        elif name=='keeper_artifact_read':
            unsupported.append({'execution_id':c.get('execution_id'),'kind':'canonical_artifact_read_requires_blob_correlation'})
    chosen=None
    if terminal:
        w,n=writes[0],adds[0]
        ordered=[r for r in successful_reads if w['ts']<r['ts']<notes[0]['created_at']<=n['ts']]
        # Only unavailable output of an actual successful Read in the required
        # causal interval can defer the missing-full-Read decision. An unrelated
        # Write/note/artifact observation cannot mask Read absence or bad order.
        ordered_unknown=[r for r in unknown_reads if w['ts']<r['ts']<notes[0]['created_at']<=n['ts']]
        if not ordered and not ordered_unknown:
            check('Completed source has an actual full successful exact Read after Write before marker',False,
                  {'write_ts':w['ts'],'successful_complete_reads':[r['execution_id'] for r in successful_reads],
                   'failed_readonly_count':len(failed_readonly),'nonqualifying_read_count':len(nonqualifying_reads),
                   'unknown_read_execution_ids':[r['execution_id'] for r in unknown_reads],
                   'ordered_unknown_read_execution_ids':[r['execution_id'] for r in ordered_unknown],'note':notes[0]})
        if ordered:
            chosen=(w,ordered[-1],n)
            check('actual full successful exact Read occurs after Write and before marker',True,
                  {'write_execution_id':w['execution_id'],'read_execution_id':chosen[1]['execution_id'],'note':notes[0]})
        note_output=decode(n.get('output'))
        if isinstance(note_output,dict) and '_blob' in note_output:
            unsupported.append({'execution_id':n.get('execution_id'),'kind':'canonical_note_result_blob'})
        elif note_output is None:
            unsupported.append({'execution_id':n.get('execution_id'),'kind':'note_result_unavailable'})
        else:
            check('actual marker result equals primary stored note',note_output.get('note')==notes[0],note_output)
    if unsupported:
        raise Incomplete('canonical result observation unsupported or incomplete; no preview-based PASS: '+json.dumps(unsupported))
    write_json('readonly-observations.json',{'failed_readonly_attempts':failed_readonly,
        'nonqualifying_same_target_reads':nonqualifying_reads,
        'successful_complete_exact_read_execution_ids':[c['execution_id'] for c in successful_reads],
        'scope':'All rows also retained in the complete ledger. Failed/partial inspections are not required file effects. No row is dropped or counted as a successful complete Read.'})
    return chosen


def final_proof(created,q,calls,notes):
    effects=validate_effects(calls,notes,True)
    reaction_rows,reaction_files=read_jsonl(base/'.masc/keepers'/keeper/'reaction-ledger','reaction-ledger')
    turn_rows,turn_files=read_jsonl(base/'.masc/keepers'/keeper/'turn-records','turn-records')
    post=q['post_id']
    events=[r for r in reaction_rows if r.get('stimulus_id')==post]
    def matching(kind,disposition=None):
        return [r for r in events if (r.get('reaction') or {}).get('kind')==kind and (disposition is None or r['reaction'].get('disposition')==disposition)]
    starts=sorted(matching('turn_started'),key=lambda r:r['recorded_at_unix'])
    ends=sorted(matching('turn_finished'),key=lambda r:r['recorded_at_unix'])
    acks=matching('event_queue_ack')
    if not starts or len(starts)!=len(ends) or len(acks)!=1:
        raise Incomplete('source-attempt start/finish/final ACK witnesses absent or ambiguous')
    intervals=[]
    for index,(start,end) in enumerate(zip(starts,ends)):
        lo,hi=start['recorded_at_unix'],end['recorded_at_unix']
        final=index==len(starts)-1
        if not (lo<hi and (index==0 or ends[index-1]['recorded_at_unix']<lo)
                and end['reaction'].get('disposition')==('completed' if final else 'checkpointed')):
            raise Incomplete('original source attempt intervals are not a closed checkpoint/readmission chain')
        intervals.append({'start':lo,'end':hi,'disposition':end['reaction']['disposition']})
    if not intervals[-1]['end']<=acks[0]['recorded_at_unix']:
        raise Incomplete('final source ACK ordering unavailable')
    transition=acks[0]['reaction']['transition_receipt']['transition'];source=transition.get('source',{});payload=source.get('payload',{})
    check('ACK source is exact original scheduled request',transition.get('kind')=='ack_source_terminal' and transition.get('source_receipt_kind')=='turn_completed'
        and source.get('post_id')==post==payload.get('occurrence_id')
        and payload.get('kind')=='schedule_due' and payload.get('schedule_id')==schedule_id
        and payload.get('schedule_instance_id')==created['schedule_instance_id'] and payload.get('message')==message
        and payload.get('due_at_unix')==q.get('wake_due_at') and payload.get('payload_digest')==q.get('wake_payload_digest'),transition)
    pending=[entry for cap in queue_captures for entry in cap['state']['pending'] if entry['source']['post_id']==post]
    if not pending: raise Incomplete('original admitted queue incarnation not sampled; ACK alone is not this stronger proof')
    check('queue admission and ACK bind same exact source and incarnation',type(transition.get('source_incarnation')) is int and all(e['source']==source and type(e['admitted_revision']) is int and e['admitted_revision']==transition.get('source_incarnation') for e in pending),pending)
    # Single work source can legitimately checkpoint/readmit across several
    # physical Keeper turns. Each actual call and every turn must be covered.
    if (len({c.get('execution_id') for c in calls})!=len(calls)
            or not all(isinstance(c.get('execution_id'),str) and c['execution_id']
                       and isinstance(c.get('tool_use_id'),str) and c['tool_use_id']
                       and isinstance(c.get('trace_id'),str) and c['trace_id']
                       and type(c.get('keeper_turn_id')) is int for c in calls)):
        raise Incomplete('owned calls lack unique complete execution/tool-use/turn identities')
    joined=[];covered=set()
    if len(turn_rows)!=len(intervals):
        raise Incomplete('complete per-attempt turn-record coverage is unavailable')
    for interval in intervals:
        records_=[r for r in turn_rows if r.get('keeper')==keeper and interval['start']<r.get('ts',-1)<=interval['end']]
        if len(records_)!=1:
            raise Incomplete('source attempt has no unique exact turn record')
        record=records_[0];trace=record.get('trace_id');turn=record.get('absolute_turn')
        if record.get('turn_ref')!=str(trace)+'#'+str(turn):
            raise Incomplete('turn reference does not bind trace and absolute turn')
        owned=[c for c in calls if (c.get('trace_id'),c.get('keeper_turn_id'))==(trace,turn)]
        executions={c.get('execution_id') for c in owned}
        if (None in executions or set(record.get('execution_ids',[]))!=executions
                or not all(interval['start']<c['ts']<=record['ts']<=interval['end'] for c in owned)
                or (interval['disposition']=='completed' and record.get('finish_reason')!='completed')):
            raise Incomplete('exact source-attempt/turn/execution membership is not fully established')
        covered.update(executions);joined.append({'source_interval':interval,'turn':record})
    if covered!={c.get('execution_id') for c in calls}:
        raise Incomplete('one or more owned calls have no exact original-source turn membership')
    for c in effects:
        contract=c.get('runtime_contract') or {}
        check('effect execution has selected runtime and sandbox contract',contract.get('keeper_name')==keeper and contract.get('sandbox_profile')=='microvm'
            and str(contract.get('sandbox_root','')).rstrip('/')==logical_root and contract.get('runtime_profile')==runtime_id,contract)
    exact=[]
    for c in calls:
        execution=c.get('execution_id')
        if not isinstance(execution,str) or not execution: raise Incomplete('call lacks execution ID')
        data=exact_read('/api/v1/keepers/'+quote(keeper)+'/tool-calls?execution_id='+quote(execution));row=data.get('entry') or {}
        check('exact execution API confirms '+execution,all(row.get(k)==c.get(k) for k in ['keeper','tool','input','execution_id','tool_use_id','trace_id','keeper_turn_id','wire_outcome','disposition'])
            and decode(row.get('output'))==decode(c.get('output')) and (decode(c.get('output')) is not None or row.get('output')==c.get('output')))
        exact.append(data)
    write_json('exact-executions.json',exact)
    write_json('source-execution-proof.json',{'events':events,'reaction_files':reaction_files,'turn_files':turn_files,'attempt_turn_bindings':joined,
        'source':source,'source_incarnation':transition['source_incarnation'],'queue_captures':[{k:v for k,v in c.items() if k!='state'} for c in queue_captures],
        'scope':'Actual MicroVM backend Write/Read; returned path is a logical bookkeeping spelling, not independently inspected host/guest file.'})


try:
    source_config=tomllib.loads((repo/'config/runtime.toml').read_text())
    model='ollama-cloud-deepseek-v4-1-flash';runtime_id='ollama_cloud.'+model
    provider=source_config['providers']['ollama_cloud'];credential_name=provider['credentials']['key']
    if provider['credentials']['type']!='env' or not os.environ.get(credential_name):
        raise Incomplete('required configured provider credential unavailable')
    env={k:v for k,v in os.environ.items() if k in ['PATH','HOME','LANG','LC_ALL','TMPDIR',credential_name]}
    env.update(MASC_BASE_PATH=str(base),MASC_CONFIG_DIR=str(base/'.masc/config'),
        XDG_CONFIG_HOME=str(base/'xdg-config'),MASC_KEEPER_AUTONOMOUS_ENABLED='false',MASC_SCHEDULE_RUNNER_INTERVAL_SEC='1')
    meta.update(runtime_id=runtime_id,provider_endpoint=provider['endpoint'],credential_name=credential_name,
        environment_names=sorted(env),home_unchanged=env.get('HOME')==os.environ.get('HOME'),
        masc_config_dir=env['MASC_CONFIG_DIR'],xdg_config_home=env['XDG_CONFIG_HOME'])
    write_json('provenance.json',meta)
    command([str(binary),'init','--base-path',str(base)],env)
    meta['guest_shim_copy'] = stage_owned_guest_shim()
    write_json('provenance.json',meta)
    def table(name,values):
        rows=['['+name+']']
        for key,value in values.items():
            if not isinstance(value,dict):rows.append(key+' = '+json.dumps(value))
        for key,value in values.items():
            if isinstance(value,dict):rows.append(table(name+'.'+key,value))
        return '\n'.join(rows)+'\n'
    fixture=tomllib.loads((repo/'scripts/fixtures/release-evidence/runtime.toml').read_text())
    text=table('runtime',{'default':runtime_id})
    for lane in fixture['runtime']['exact_output_lanes']:
        text+=table('runtime.exact_output_lanes.'+lane,{'slots':[runtime_id]})
    text+=table('providers.ollama_cloud',{k:provider[k] for k in ['display-name','protocol','endpoint','connect-timeout-s','exact-body-timeout-s','credentials'] if k in provider})
    text+=table('models.'+model,source_config['models'][model]);text+=table(runtime_id,source_config['ollama_cloud'][model])
    (base/'.masc/config/runtime.toml').write_text(text);(output/'runtime-config.toml').write_text(text)
    command([str(binary),'sandbox-image','promote','--base-path',str(base),'--runtime','apple_container','base',args.image_reference],env)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    if port==8935: raise Incomplete('reserved primary port selected; refusing setup')
    url='http://127.0.0.1:'+str(port);meta['url']=url
    command([str(binary),'login','--base-path',str(base),'--host','127.0.0.1','--port',str(port),
        '--agent','schedule-file-observer','--role','admin','--client-env','MASC_SCHEDULE_FILE_TOKEN','--no-expiry','--json'],env)
    admin_token=(base/'.masc/auth/schedule-file-observer.token').read_text().strip()
    write_json('provenance.json',meta)
    log=(output/'server.log').open('w')
    observation_open()
    server=subprocess.Popen([str(binary),'start','--base-path',str(base),'--host','127.0.0.1','--port',str(port)],
        env=env,stdout=log,stderr=log,cwd=base,start_new_session=True)
    process.update(producer_started=True,pid=server.pid,started_at_unix=time.time(),url=url,base_path=str(base));write_json('process.json',process)
    while True:
        observation_open()
        try:
            status,health=request('/health?full=1')
            if status==200 and health.get('startup',{}).get('state_ready'):break
        except (urllib.error.URLError,TimeoutError):pass
        time.sleep(.3)
    check('owned workspace and frozen native source actually served',health['paths']['effective_base_path']==str(base)
        and health['paths']['effective_masc_root']==str(base/'.masc')
        and health['build'].get('executable_sha256')==EXPECTED_BINARY and health['build'].get('binary_commit')==EXPECTED_SOURCE,
        {k:health[k] for k in ['build','paths']})
    status,gate=request('/api/v1/dashboard/gate/mode',admin_token,{'mode':'always_allow'})
    check('explicit owned permissive Gate fixture accepted',status==200,gate)
    successful_tool('masc_keeper_up',{'name':keeper,'create_only':True,'sandbox_profile':'microvm','sandbox_image':'base',
        'microvm_backend':'apple_container','network_mode':'none','activation_mode':'manual','runtime_id':runtime_id,'skills':{'names':[]},
        'instructions':'Perform only the exact authorized scheduled request. Use Write then Read and its original schedule note. No shell, unrelated writes, contacts, or extra work.'})
    status,approval=request('/api/v1/keepers/tool-approval-mode',admin_token,{'name':keeper,'mode':'yolo'})
    check('explicit owned permissive Keeper approval fixture accepted',status==200,approval)
    check('new owned Keeper is idle before sole schedule',live() is None)
    stage='single-scheduled-file-effect'
    created=successful_tool('masc_schedule_create',{'schedule_id':schedule_id,'keeper_name':keeper,'due_in_sec':1,'message':message})
    write_json('created.json',created)
    previous_call_digest = None
    while True:
        observation_open();queue_capture()
        data,q=history(created)
        write_json('last-observation.json',{'data':data,'observed_at_unix':time.time()})
        terminal=q.get('terminal_outcome')
        if terminal in ['failed','cancelled']:
            check('original scheduled source avoids terminal failure or cancellation',False,q)
        # After Completed, authoritative missing effects are assessed before any
        # optional queue/checkpoint/provider/forensic enrichment.
        notes,primary_capture=notes_primary(created)
        if len(notes)>1 or any(n.get('body')!=marker or n.get('author_id')!=keeper for n in notes):
            check('original primary has no extra or wrong marker',False,notes)
        if terminal=='completed':
            check('Completed original source has exactly its required primary marker',len(notes)==1 and notes[0].get('body')==marker and notes[0].get('author_id')==keeper,notes)
        calls=all_calls()
        call_digest=hashlib.sha256(json.dumps([calls,notes],sort_keys=True).encode()).hexdigest()
        if terminal=='completed' or call_digest!=previous_call_digest:
            validate_effects(calls,notes,terminal=='completed')
            previous_call_digest=call_digest
        retain_primary(primary_capture)
        if terminal=='completed' and live() is None:
            final_proof(created,q,calls,notes)
            fresh,fq=history(created)
            check('fresh original source remains Completed and owned Keeper idle',fq.get('terminal_outcome')=='completed' and live() is None,fq)
            # Freeze all calls again after exact API observations, before stop.
            check('no additional owned call appeared after final proof',all_calls()==calls)
            check('retained complete call ledger matches final verified calls',retain_calls()==calls)
            break
        time.sleep(.2)
    process['stop_reason']='full mandatory file/source/execution proof and fresh terminal idle observed'
    server.terminate()
    try:server.wait(timeout=15)
    except subprocess.TimeoutExpired:raise Incomplete('normal stop pending; no forced kill or restart')
    process.update(returncode=server.returncode,stopped_at_unix=time.time(),forced_kill=False)
    try:
        write_json('process-ended.json',process)
    finally:
        if server.returncode!=0:
            check('owned producer exits normally without forced kill',False,{'returncode':server.returncode})
    check('owned producer exits normally without forced kill',server.returncode==0)
    write_json('result.json',{'verdict':'PASS','source_sha':EXPECTED_SOURCE,'binary_sha256':EXPECTED_BINARY,'checks':len(checks),
        'scope':meta['scope'],'not_proven':meta['not_proven']})
except BaseException as error:
    verdict='FAIL' if isinstance(error,BehaviorFailure) else 'INCOMPLETE'
    returncode=None if server is None else server.poll()
    result={'verdict':verdict,'error_type':type(error).__name__,'detail':str(error),
        'producer_started':server is not None,'producer_terminal':server is not None and returncode is not None,
        'producer_returncode':returncode,'owned_pid':None if server is None else server.pid,
        'observation_ended_at_unix':time.time(),'forced_kills':[],'restart_count':0,
        'setup_processes':setup_processes,
        'scope':'No automatic retry, cancellation, provider switch, restart or forced kill. Running owned producer remains observable; operator must inspect fresh terminal/idle before normal cleanup.'}
    failures=[]
    try:
        for name,value in [('result.json',result),('observation-ended-process.json',{**process,**result})]:
            try:write_json(name,value)
            except Exception as ioe:failures.append({'file':name,'error_type':type(ioe).__name__})
        if server is not None:
            try:
                captured_calls=retain_calls()
                write_json('failed-readonly-attempts.json',{'entries':[c for c in captured_calls if c.get('tool') in READONLY and not successful_call(c)],
                    'scope':'Forensic selection after original non-PASS verdict frozen; complete rows also retained in all-owned-tool-calls/raw files.'})
            except Exception as ioe:failures.append({'file':'raw/all-owned-tool-calls/failed-readonly-attempts','error_type':type(ioe).__name__})
        try:save()
        except Exception as ioe:failures.append({'file':'api-records/checks','error_type':type(ioe).__name__})
        print(json.dumps({'verdict':verdict,'receipt_write_errors':failures}),flush=True)
    finally:raise SystemExit(1 if verdict=='FAIL' else 2)
