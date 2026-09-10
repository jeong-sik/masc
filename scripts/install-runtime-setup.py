#!/usr/bin/env python3
"""Select runtime connections and validate them before publishing together.

Python 3.8 stdlib only. --spec names a JSON file, never a credential value.
The wizard requires real response/tool verification; --spec stays offline unless
--verify is supplied. Offline configuration validation is not inference proof.
"""
import argparse
import fcntl
import getpass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import select
import shutil
import stat
import sys
import subprocess
import tempfile
import termios
import tty
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler
from urllib.error import HTTPError, URLError

CHOICES = {
    'ollama': ('ollama-http', None),
    'llama_cpp': ('openai-compatible-http', None),
    'vllm': ('openai-compatible-http', None),
    'openai_compatible': ('openai-compatible-http', None),
    'messages': ('messages-http', None),
    'claude_code': ('claude-code', 'claude'),
    'codex': ('codex-app-server', 'codex'),
    'antigravity': ('antigravity-cli', 'agy'),
}
UNVERIFIED_CAPABILITIES = (
    'supports_tool_choice', 'supports_required_tool_choice', 'supports_named_tool_choice',
    'supports_parallel_tool_calls', 'supports_reasoning',
    'supports_response_format_json', 'supports_structured_output',
    'supports_multimodal_inputs', 'supports_image_input', 'supports_audio_input',
    'supports_video_input', 'supports_document_input',
    'supports_prompt_caching', 'supports_top_k', 'supports_min_p',
    'supports_seed',
)


class SetupError(Exception):
    pass


class VerificationError(SetupError):
    def __init__(self, runtime_id, failure=None):
        self.runtime_id = runtime_id
        self.failure = failure if isinstance(failure, dict) else {}
        super().__init__('The selected model did not pass response and tool verification. Configuration was preserved.')


def text(spec, key):
    value = spec.get(key)
    if not isinstance(value, str) or not value or value != value.strip() or any(ord(c) < 32 for c in value):
        raise SetupError(key + ' must be a nonempty single-line string without surrounding whitespace')
    return value


def toml(value):
    # JSON string escaping is also valid for the single-line TOML values used
    # here; ensure_ascii=False avoids JSON surrogate-pair escapes in TOML.
    return json.dumps(value, ensure_ascii=False)


def table(path, fields, array=False):
    header = '.'.join(toml(part) for part in path)
    return '\n' + ('[[' + header + ']]' if array else '[' + header + ']') + '\n' + ''.join(
        toml(key) + ' = ' + toml(value) + '\n' for key, value in fields.items())


def render(spec):
    if not isinstance(spec, dict):
        raise SetupError('spec must be a JSON object')
    choice = text(spec, 'choice')
    if choice not in CHOICES:
        raise SetupError('unsupported runtime choice')
    protocol, default_command = CHOICES[choice]
    allowed = {'choice', 'model', 'max_context', 'tools', 'streaming'}
    allowed |= {'endpoint', 'api_key_env', 'credential_file', 'provider_kind', 'request_path'} if default_command is None else {'command'}
    if choice == 'antigravity':
        allowed |= {'credential_file', 'timeout_s'}
    if set(spec) - allowed:
        raise SetupError('unexpected setup fields: ' + ', '.join(sorted(set(spec) - allowed)))
    model = text(spec, 'model')
    context = spec.get('max_context')
    if type(context) is not int or context <= 0:
        raise SetupError('max_context must be a positive integer supplied by the operator')
    for key in ('tools', 'streaming'):
        if type(spec.get(key)) is not bool:
            raise SetupError(key + ' must be an explicitly declared boolean')
    # A connection/model is an identity, not a singleton slot per CLI kind.
    # Include explicit capabilities and limits so changed operator settings do
    # not silently mutate a runtime another Keeper may already use.
    identity = hashlib.sha256(json.dumps(spec, sort_keys=True, ensure_ascii=False,
                                        separators=(',', ':')).encode()).hexdigest()
    provider = 'setup_' + choice + '_' + identity
    model_key = provider + '_model'
    fields = {'display-name': choice + ' / ' + model, 'protocol': protocol}
    if default_command is None:
        endpoint = text(spec, 'endpoint')
        try:
            url = urlsplit(endpoint)
            valid = url.scheme in ('http', 'https') and url.hostname and not (url.username or url.password or url.query or url.fragment)
            _ = url.port
        except ValueError:
            valid = False
        if not valid:
            raise SetupError('endpoint must be an HTTP(S) URL without embedded credentials, query or fragment')
        fields['endpoint'] = endpoint
    else:
        fields.update(command=text(spec, 'command') if 'command' in spec else default_command,
                      **{'is-non-interactive': True})
    if choice == 'antigravity':
        timeout = spec.get('timeout_s')
        if type(timeout) not in (int, float) or not math.isfinite(timeout) or timeout <= 0:
            raise SetupError('Antigravity timeout_s must be an explicit positive number')
        fields['timeout-s'] = float(timeout)
    runtime = table(('providers', provider), fields)
    if default_command is None:
        runtime += table(('providers', provider, 'healthcheck'), {'path': '/api/tags' if choice == 'ollama' else '/models'})
        if spec.get('credential_file') and spec.get('api_key_env'):
            raise SetupError('choose one credential reference for the connection')
        if 'credential_file' in spec:
            credential = Path(text(spec, 'credential_file'))
            if not credential.is_absolute():
                raise SetupError('credential_file must be an absolute private file reference')
            runtime += table(('providers', provider, 'credentials'), {'type': 'file', 'path': str(credential)})
        if 'api_key_env' in spec and spec['api_key_env'] != '':
            key = text(spec, 'api_key_env')
            if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key):
                raise SetupError('api_key_env must name an environment variable, not a credential value')
            runtime += table(('providers', provider, 'credentials'), {'type': 'env', 'key': key})
    elif choice == 'antigravity':
        credential = Path(text(spec, 'credential_file')).expanduser()
        if not credential.is_absolute():
            raise SetupError('Antigravity credential_file must be an absolute path')
        runtime += table(('providers', provider, 'credentials'), {'type': 'file', 'path': str(credential)})
    runtime += table(('models', model_key), {'api-name': model, 'max-context': context,
                                           'tools-support': spec['tools'], 'streaming': spec['streaming']})
    binding = {'wizard-default': True}
    if choice == 'ollama':
        # Discovery reads the configured/loaded window, not the architectural
        # maximum. Keep request-side context and MASC's window in agreement.
        binding['num-ctx'] = context
    runtime += table((provider, model_key), binding)
    overlay = ''
    if default_command is None:
        kind = spec.get('provider_kind') or ('ollama' if choice == 'ollama' else 'openai_compat')
        accepted = ('anthropic', 'kimi') if choice == 'messages' else ('ollama',) if choice == 'ollama' else ('openai_compat', 'glm')
        if kind not in accepted:
            raise SetupError('the provider kind does not match the selected HTTP protocol')
        base_capabilities = {'anthropic':'anthropic', 'kimi':'kimi', 'ollama':'ollama', 'glm':'glm', 'openai_compat':'openai_chat'}[kind]
        request_path = spec.get('request_path') or ('/api/chat' if choice == 'ollama' else '/v1/messages' if choice == 'messages' else '/chat/completions')
        parsed_path = urlsplit(request_path)
        if not request_path.startswith('/') or parsed_path.scheme or parsed_path.netloc or parsed_path.query or parsed_path.fragment or not model_text(request_path):
            raise SetupError('request_path must be an API path without credentials or a server address')
        caps = {'id_prefix': model, 'provider_name': provider, 'base': base_capabilities,
                'max_context_tokens': context, 'supports_tools': spec['tools'],
                'supports_native_streaming': spec['streaming']}
        caps.update({key: False for key in UNVERIFIED_CAPABILITIES})
        caps.update(thinking_control_format='none', reasoning_streaming_format='none')
        overlay = table(('models',), caps, array=True)
        # Exact-output lanes resolve through this same provider/model pair.
        # A runtime binding alone is not an Agent Core target declaration.
        overlay += table(('providers',), {
            'id': provider, 'kind': kind, 'base_url': endpoint,
            'request_path': request_path, 'api_key_env': spec.get('api_key_env', ''),
            'capabilities_base': base_capabilities}, array=True)
        overlay += table(('targets',), {
            'id': provider + '.' + model_key, 'provider_ref': provider,
            'model_id': model}, array=True)
    return provider + '.' + model_key, runtime.encode(), overlay.encode()


def snapshot(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        raise SetupError('configuration must be a regular file: ' + str(path))
    return (info.st_dev, info.st_ino, info.st_mtime_ns, stat.S_IMODE(info.st_mode), path.read_bytes())


def atomic_write(path, content, mode):
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, str(path))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def configured_inventory(binary, base_path):
    result = subprocess.run([str(binary), 'runtime-wizard-catalog', '--base-path', str(base_path), '--json', '--private-credentials'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise SetupError('cannot read the workspace runtime inventory; configuration was not changed')
    inventory = json.loads(result.stdout)
    if not isinstance(inventory, dict) or not isinstance(inventory.get('runtimes'), list):
        raise SetupError('invalid workspace runtime inventory')
    ids = [row.get('id') for row in inventory['runtimes'] if isinstance(row, dict)]
    if len(ids) != len(inventory['runtimes']) or not all(model_text(value) for value in ids) or len(set(ids)) != len(ids):
        raise SetupError('invalid or duplicate workspace runtime identities')
    return inventory


def configure(binary, base_path, spec):
    return configure_many(binary, base_path, [spec])


def configure_many(binary, base_path, specs, selected_ids=None, verify=False, default_id=None):
    if not isinstance(specs, list):
        raise SetupError('connections must be a list')
    if selected_ids is not None and (not isinstance(selected_ids, list) or not all(model_text(value) for value in selected_ids)):
        raise SetupError('runtime_ids must be a list of runtime identifiers')
    if default_id is not None and not model_text(default_id):
        raise SetupError('default_runtime_id must be a runtime identifier')
    rendered = [render(spec) for spec in specs]
    selected = list(dict.fromkeys(selected_ids if selected_ids is not None else [row[0] for row in rendered]))
    if not selected:
        raise SetupError('select at least one runtime')
    if default_id is None:
        default_id = selected[0]
    if default_id not in selected:
        raise SetupError('the default must be one of the selected runtimes')
    selected = [default_id] + [value for value in selected if value != default_id]
    base = Path(base_path).expanduser().resolve()
    config = base / '.masc/config'
    paths = [config / 'runtime.toml', config / 'agent-core-models-overlay.toml']
    if not config.is_dir():
        raise SetupError('initialize the selected workspace before runtime setup')
    # The existing OCaml config writer uses POSIX lockf on this same path.
    with open(str(paths[0]) + '.lock', 'a+b') as lock:
        fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        originals = [snapshot(path) for path in paths]
        if originals[0] is None:
            raise SetupError('runtime.toml is missing; initialize the workspace first')
        inventory = configured_inventory(binary, base)
        existing_ids = {row['id'] for row in inventory['runtimes']}
        additions = {}
        for runtime_id, runtime_text, overlay_text in rendered:
            if runtime_id not in existing_ids:
                additions[runtime_id] = (runtime_text, overlay_text)
        if not set(selected) <= existing_ids | set(additions):
            raise SetupError('a selected runtime disappeared; refresh the list and choose again')
        addition = b''.join(row[0] for row in additions.values())
        overlay_addition = b''.join(row[1] for row in additions.values())
        contents = [originals[0][-1] + (b'\n' + addition if addition else b''),
                    (originals[1][-1] if originals[1] else b'') + overlay_addition]
        with tempfile.TemporaryDirectory(prefix='masc-runtime-setup-') as stage:
            stage_config = Path(stage) / '.masc/config'
            stage_config.mkdir(parents=True)
            for path, content in zip(paths, contents):
                (stage_config / path.name).write_bytes(content)
            env = dict(os.environ, MASC_BASE_PATH=stage, MASC_CONFIG_DIR=str(stage_config))
            command = [str(Path(binary).resolve()), 'runtime-default-set', '--base-path', stage, default_id, '--setup-lanes', '--setup-imp']
            for runtime_id in selected[1:]:
                command += ['--fallback-runtime', runtime_id]
            result = subprocess.run(command, env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                diagnostic = result.stderr.decode(errors='replace').strip() or 'validator produced no stderr'
                raise SetupError('runtime validation failed; original configuration preserved:\n' + diagnostic)
            contents[0] = (stage_config / paths[0].name).read_bytes()
            verifications = []
            if verify:
                for runtime_id in selected:
                    probe = subprocess.run([str(Path(binary).resolve()), 'runtime-verify', '--base-path', stage, runtime_id],
                                           env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    try:
                        receipt = json.loads(probe.stdout)
                    except ValueError:
                        raise SetupError('runtime verification did not return a result; configuration was preserved')
                    checks = receipt.get('checks') if isinstance(receipt, dict) else None
                    if (not isinstance(receipt, dict) or not isinstance(checks, dict) or probe.returncode or receipt.get('schema') != 'masc.runtime_verification.v1'
                            or receipt.get('runtime_id') != runtime_id or receipt.get('status') != 'verified'
                            or checks.get('response') is not True
                            or checks.get('tool_roundtrip') is not True):
                        raise VerificationError(runtime_id, receipt.get('failure') if isinstance(receipt, dict) else None)
                    verifications.append(receipt)
        if [snapshot(path) for path in paths] != originals:
            raise SetupError('configuration changed during validation; rerun setup against the new snapshot')
        written = []
        try:
            # Publish the dependency first and its default-runtime reference
            # last. Each replace is atomic; the pair is protected by the lock
            # and rolled back on a reported error, not a filesystem-wide swap.
            for index in (1, 0):
                if index == 1 and not overlay_addition:
                    continue
                atomic_write(paths[index], contents[index], originals[index][3] if originals[index] else 0o600)
                written.append(index)
        except BaseException:
            for index in reversed(written):
                if originals[index] is None:
                    paths[index].unlink()
                else:
                    atomic_write(paths[index], originals[index][-1], originals[index][3])
            raise
    return {'runtime_id': default_id, 'runtime_ids': selected, 'configured': True, 'validation': 'passed',
            'readiness': 'verified' if verify else 'not_probed', 'verifications': verifications,
            'models': [spec['model'] for spec in specs]}


def positive_integer(value):
    return type(value) is int and value > 0


def model_text(value):
    return isinstance(value, str) and bool(value) and value == value.strip() and all(ord(c) >= 32 and ord(c) != 127 for c in value)


def http_json(endpoint, path, api_key_env='', timeout=10, body=None):
    url = urlsplit(endpoint)
    if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise SetupError('Use an HTTP(S) API URL without embedded credentials, query or fragment')
    headers = {'Accept': 'application/json'}
    if api_key_env:
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', api_key_env):
            raise SetupError('Choose an API key environment variable, not a credential value')
        if os.environ.get(api_key_env):
            headers['Authorization'] = 'Bearer ' + os.environ[api_key_env]
    data = None if body is None else json.dumps(body).encode()
    if data is not None:
        headers['Content-Type'] = 'application/json'
    class NoRedirect(HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    with build_opener(NoRedirect()).open(Request(endpoint.rstrip('/') + path, data=data, headers=headers), timeout=timeout) as response:
        return json.load(response)


def ollama_model_details(endpoint, model, api_key_env='', timeout=10, load=False):
    details = http_json(endpoint, '/api/show', api_key_env, timeout, {'model': model})
    if not isinstance(details, dict):
        raise SetupError('Ollama returned invalid model details')
    capabilities = details.get('capabilities')
    tools = 'tools' in capabilities if isinstance(capabilities, list) else None
    configured = []
    parameters = details.get('parameters', '')
    if not isinstance(parameters, str):
        raise SetupError('Ollama returned invalid model parameters')
    for line in parameters.splitlines():
        parts = line.split()
        if parts and parts[0] == 'num_ctx':
            if len(parts) != 2 or not parts[1].isascii() or not parts[1].isdigit() or int(parts[1]) <= 0:
                raise SetupError('Ollama returned an invalid num_ctx parameter')
            configured.append(int(parts[1]))
    if len(set(configured)) > 1:
        raise SetupError('Ollama returned conflicting num_ctx parameters')
    if configured:
        return dict(context=configured[0], context_source='Ollama configured num_ctx', tools=tools)
    if load:
        # Official preload API; only the models the operator selected are
        # loaded. Let the server choose its window instead of allocating the
        # model's potentially enormous architectural maximum.
        http_json(endpoint, '/api/generate', api_key_env, timeout, {'model': model, 'stream': False})
    running_payload = http_json(endpoint, '/api/ps', api_key_env, timeout)
    if not isinstance(running_payload, dict) or not isinstance(running_payload.get('models'), list):
        raise SetupError('Ollama returned an invalid running model list')
    running = running_payload['models']
    matches = [row['context_length'] for row in running if isinstance(row, dict)
               and row.get('name', row.get('model')) == model and positive_integer(row.get('context_length'))]
    if len(set(matches)) > 1:
        raise SetupError('Ollama returned conflicting running context windows')
    return dict(context=matches[0] if matches else None, context_source='Ollama running context window' if matches else None, tools=tools)


def codex_model_rows(command, timeout):
    path = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'models_cache.json'
    try:
        rows = json.loads(path.read_text())['models']
        if isinstance(rows, list) and rows:
            return rows, 'Codex local model list (cached; availability is checked after selection)'
    except (OSError, ValueError, KeyError, TypeError):
        pass
    # A fresh user has no cache. Ask the installed client for its own bundled
    # catalog, without logging in, starting a turn, or inheriting credentials.
    # Its context_window is distinct from an API model's maximum capacity.
    with tempfile.TemporaryDirectory(prefix='masc-codex-models-') as home:
        env = {key: value for key, value in os.environ.items() if key in ('PATH', 'LANG', 'LC_ALL')}
        env.update(HOME=home, CODEX_HOME=str(Path(home) / '.codex'))
        try:
            result = subprocess.run([command, 'debug', 'models', '--bundled'],
                                    cwd=home, env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True, timeout=timeout)
            rows = json.loads(result.stdout)['models'] if result.returncode == 0 else None
            if isinstance(rows, list):
                return rows, 'Installed Codex CLI bundled model catalog (availability is checked after selection)'
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
            pass
    return [], 'Codex model details unavailable. Refresh after updating/signing in to your CLI, or choose another connection.'


def discover_models(choice, endpoint='', api_key_env='', timeout=10, command='codex'):
    """Return observed IDs, not guessed names or inferred context capacities."""
    if choice == 'ollama':
        try:
            rows = http_json(endpoint, '/api/tags', api_key_env, timeout)['models']
            if not isinstance(rows, list):
                raise ValueError('invalid model list')
            models = [dict(id=row['name'], label=row['name'], context=None)
                      for row in rows if isinstance(row, dict) and model_text(row.get('name'))]
            origin = 'Installed Ollama models'
        except (OSError, ValueError, KeyError, TypeError, URLError):
            return [], 'Ollama model list unavailable. Start Ollama, then choose Refresh.'
    elif choice == 'codex':
        rows, origin = codex_model_rows(command, timeout)
        models = []
        for row in rows:
            if not isinstance(row, dict) or row.get('visibility') != 'list' or not model_text(row.get('slug')):
                continue
            models.append(dict(id=row['slug'], label=row.get('display_name'), context=row.get('context_window')))
    elif choice in ('llama_cpp', 'vllm', 'openai_compatible'):
        url = urlsplit(endpoint)
        if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password or url.query or url.fragment:
            raise SetupError('Use the server HTTP(S) API base URL without embedded credentials, query or fragment')
        headers = {'Accept': 'application/json'}
        if api_key_env:
            if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', api_key_env):
                raise SetupError('Enter the API key environment variable name, not the key itself')
            credential = os.environ.get(api_key_env)
            if credential:
                headers['Authorization'] = 'Bearer ' + credential
        class NoRedirect(HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None
        try:
            with build_opener(NoRedirect()).open(Request(endpoint.rstrip('/') + '/models', headers=headers), timeout=timeout) as response:
                rows = json.load(response)['data']
            if not isinstance(rows, list):
                raise ValueError('invalid model list')
        except (OSError, ValueError, KeyError, TypeError, URLError) as error:
            detail = 'HTTP ' + str(error.code) if isinstance(error, HTTPError) else 'unavailable or invalid response'
            return [], 'Server /models: ' + detail + '. Start the server/check authentication, or copy its exact served model ID.'
        origin = 'Your server /models response'
        models = [dict(id=row['id'], label=row.get('name'), context=row.get('max_model_len'))
                  for row in rows if isinstance(row, dict) and model_text(row.get('id'))]
    else:
        return [], ('Open Claude Code and use /model to find your model ID.' if choice == 'claude_code'
                    else 'Copy the exact model ID shown by your runtime.')
    seen, result = set(), []
    for model in models:
        if model['id'] in seen:
            continue
        seen.add(model['id'])
        model['label'] = model['label'] if model_text(model['label']) else model['id']
        model['context'] = model['context'] if positive_integer(model['context']) else None
        result.append(model)
    return result, origin


def catalog_models(binary, choice):
    client = {'claude_code': 'claude-code', 'codex': 'codex'}.get(choice)
    if client is None:
        return []
    result = subprocess.run([binary, 'runtime-model-list', client], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        return []
    try:
        rows = json.loads(result.stdout)['models']
        if not isinstance(rows, list):
            return []
        # API catalog capacities do not establish a Codex client window. Keep
        # names as suggestions, but require client metadata or advanced input.
        return [dict(id=row['id'], label=row.get('label', row['id']),
                     context=None if choice == 'codex' else row['max_context'])
                for row in rows if isinstance(row, dict) and model_text(row.get('id'))
                and positive_integer(row.get('max_context'))]
    except (ValueError, KeyError, TypeError):
        return []


def select_model(binary, choice, endpoint='', api_key_env='', timeout=10):
    def ask(label):
        print('? ' + label + ': ', end='', file=sys.stderr, flush=True)
        answer = sys.stdin.readline()
        if not answer or answer.strip().lower() == 'q':
            raise SetupError('model setup cancelled; run the installer again when you have the model settings')
        return answer.strip()
    models, origin = discover_models(choice, endpoint, api_key_env, timeout)
    if not models and choice in ('codex', 'claude_code'):
        models = catalog_models(binary, choice)
        if models:
            origin = 'Installed MASC model catalog (suggestions; model response is not yet verified)'
    print('\n' + origin, file=sys.stderr)
    for index, item in enumerate(models, 1):
        print('  {}) {} — ID: {}'.format(index, item['label'] if model_text(item['label']) else item['id'], item['id']), file=sys.stderr)
    print('Choose a listed number or paste an exact model ID. Enter q to cancel; do not guess a model name.', file=sys.stderr)
    selected = None
    while True:
        answer = ask('Model number or exact ID' if models else 'Exact model ID from your runtime')
        if answer.isascii() and answer.isdigit() and models:
            index = int(answer)
            if 1 <= index <= len(models):
                selected = models[index - 1]
                model = selected['id']
                break
            print('Choose one of the displayed numbers, or paste a model ID.', file=sys.stderr)
        elif model_text(answer):
            model = answer
            selected = next((item for item in models if item['id'] == model), None)
            break
        else:
            print('Enter a model ID or a listed number; blank input cannot choose a model.', file=sys.stderr)
    context = selected['context'] if selected else None
    context_source = origin if context else None
    if context is None and choice == 'claude_code':
        result = subprocess.run([binary, 'runtime-model-info', model, '--client', {'codex':'codex','claude_code':'claude-code'}[choice]], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if result.returncode == 0:
            try:
                info = json.loads(result.stdout)
                if info.get('model') == model and positive_integer(info.get('max_context')):
                    context, context_source = info['max_context'], 'installed MASC model catalog'
            except (ValueError, AttributeError):
                pass
    if context is not None:
        print('Context window: {:,} tokens — from {}. No number to enter.'.format(context, context_source), file=sys.stderr)
    else:
        print('Context window means the amount of text the model can keep in one request, measured in tokens.', file=sys.stderr)
        print('Use the configured server limit (llama.cpp --ctx-size, vLLM --max-model-len), or the model limit documented by your CLI/provider.', file=sys.stderr)
        print('Do not guess. For input format only: a documented 8,192-token limit is entered as 8192. Enter q if you do not know the limit.', file=sys.stderr)
        while context is None:
            answer = ask('Documented/configured context limit in tokens (digits only; q to cancel)')
            if answer.isascii() and answer.isdigit() and int(answer) > 0:
                context = int(answer)
            else:
                print('Enter the documented token count using digits greater than zero, without commas or units; or q to cancel.', file=sys.stderr)
    return dict(model=model, max_context=context)


def terminal_text(value):
    # API/catalog labels are untrusted terminal input, not ANSI instructions.
    return ''.join(c if c.isprintable() else ' ' for c in str(value))


def ask_text(label):
    print('? ' + label + ': ', end='', file=sys.stderr, flush=True)
    answer = sys.stdin.readline()
    if not answer or answer.strip() == 'q':
        raise SetupError('setup cancelled; existing connections were preserved')
    return answer.strip()


def pick(title, labels, multiple=False, defaults=()):
    """TTY arrows/Space picker; numbered input for accessible/scripted terminals."""
    if not labels:
        raise SetupError('there are no options to select')
    selected = set(defaults)
    current = min(selected) if selected else 0
    interactive = sys.stdin.isatty() and sys.stderr.isatty() and os.environ.get('TERM') != 'dumb'
    if not interactive:
        print('\n' + terminal_text(title), file=sys.stderr)
        for index, label in enumerate(labels, 1):
            print('  {}) {}'.format(index, terminal_text(label)), file=sys.stderr)
        while True:
            answer = ask_text('Numbers separated by commas; Enter keeps marked choices; q cancels' if multiple else 'Number; Enter selects {}'.format(current + 1))
            if not answer:
                if not multiple:
                    return [current]
                if selected:
                    return sorted(selected)
            else:
                parts = answer.split(',')
                if all(part.strip().isascii() and part.strip().isdigit() for part in parts):
                    indexes = list(dict.fromkeys(int(part.strip()) - 1 for part in parts))
                    if all(0 <= index < len(labels) for index in indexes) and (multiple or len(indexes) == 1):
                        return indexes
            print('Choose displayed numbers' + (' separated by commas.' if multiple else '.'), file=sys.stderr)
    fd = sys.stdin.fileno()
    original = termios.tcgetattr(fd)
    drawn = 0
    try:
        tty.setcbreak(fd)
        while True:
            width, height = shutil.get_terminal_size()
            count = max(1, height - 5)
            start = min(max(0, current - count + 1), max(0, len(labels) - count))
            if drawn:
                print('\x1b[{}A'.format(drawn), end='', file=sys.stderr)
            lines = [terminal_text(title), '↑/↓ move · Space select · Enter continue · q cancel' if multiple else '↑/↓ move · Enter select · q cancel']
            for index in range(start, min(len(labels), start + count)):
                marker = '[x]' if index in selected else '[ ]'
                lines.append(('› ' if index == current else '  ') + (marker + ' ' if multiple else '') + terminal_text(labels[index]))
            lines.append('{} selected'.format(len(selected)) if multiple else '{}/{}'.format(current + 1, len(labels)))
            for line in lines:
                print('\r\x1b[2K' + line[:max(1, width - 1)], file=sys.stderr)
            sys.stderr.flush()
            drawn = len(lines)
            key = os.read(fd, 1)
            if not key:
                raise SetupError('terminal closed; existing connections were preserved')
            if key == b'\x1b':
                # Escape sequences arrive separately on some terminals. Bound
                # only key decoding, never model execution or Keeper behavior.
                if select.select([fd], [], [], 0.1)[0]:
                    prefix = os.read(fd, 1)
                    if prefix == b'[' and select.select([fd], [], [], 0.1)[0]:
                        direction = os.read(fd, 1)
                        key = b'k' if direction == b'A' else b'j' if direction == b'B' else b''
                else:
                    key = b'q'
            if key in (b'q', b'\x03', b'\x04'):
                raise SetupError('setup cancelled; existing connections were preserved')
            elif key == b'k':
                current = (current - 1) % len(labels)
            elif key == b'j':
                current = (current + 1) % len(labels)
            elif multiple and key == b' ':
                selected.symmetric_difference_update([current])
            elif key in (b'\r', b'\n'):
                if not multiple:
                    return [current]
                if selected:
                    return sorted(selected)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, original)


PROTOCOL_CHOICES = {'ollama-http': 'ollama', 'openai-compatible-http': 'openai_compatible', 'messages-http': 'messages',
                    'claude-code': 'claude_code', 'codex-app-server': 'codex',
                    'antigravity-cli': 'antigravity'}


def connection_sources(inventory):
    sources = []
    for row in inventory['runtimes']:
        source = next((item for item in sources if item['provider_id'] == row['provider_id']), None)
        if source is None:
            source = dict(provider_id=row['provider_id'], label=row['display_name'],
                          choice=PROTOCOL_CHOICES.get(row['protocol']), endpoint=row.get('endpoint') or '',
                          command=row.get('command') or '', api_key_env=row.get('api_key_env') or '',
                          credential_kind=row.get('credential_kind', 'unknown'),
                          credential_file=row.get('credential_file'), provider_kind=row.get('provider_kind'),
                          request_path=row.get('request_path'), rows=[])
            sources.append(source)
        source['rows'].append(row)
    for integration in inventory.get('integrations', []):
        existing = next((source for source in sources if source['provider_id'] == integration['id']), None)
        if existing:
            existing['origin'] = integration['origin']
            continue
        sources.append(dict(provider_id=integration['id'], label=integration['display_name'],
                            choice=PROTOCOL_CHOICES.get(integration.get('protocol')),
                            endpoint=integration.get('endpoint') or '', command=integration.get('command') or '',
                            api_key_env=integration.get('api_key_env') or '',
                            credential_kind=integration.get('credential_kind', 'env' if integration.get('api_key_env') else 'none'),
                            credential_file=integration.get('credential_file'),
                            provider_kind=integration.get('provider_kind'), request_path=integration.get('request_path'),
                            origin=integration['origin'], setup_support=integration['setup_support'], rows=[]))
    # These are local server connection suggestions, never guessed model IDs.
    for choice, label, endpoint in [('ollama', 'Ollama on this computer', 'http://localhost:11434'),
                                     ('llama_cpp', 'llama.cpp on this computer', 'http://localhost:8080/v1')]:
        if not any(item['endpoint'].rstrip('/') == endpoint for item in sources):
            sources.append(dict(provider_id=None, label=label, choice=choice, endpoint=endpoint,
                                command='', api_key_env='', rows=[]))
    for choice, command, label in [('codex', 'codex', 'Codex'), ('claude_code', 'claude', 'Claude Code')]:
        if not any(item['choice'] == choice for item in sources) and shutil.which(command):
            sources.append(dict(provider_id=None, label=label, choice=choice, endpoint='',
                                command=command, api_key_env='', rows=[]))
    return sources


def source_label(source):
    command, endpoint, key = source['command'], source['endpoint'], source['api_key_env']
    if source.get('setup_support') == 'unsupported':
        status = 'connection support not available yet'
    elif source.get('credential_file'):
        status = 'saved private API key; access will be checked'
    elif command:
        status = 'CLI found' if shutil.which(command) else 'CLI not found'
    elif key:
        status = key + (' is set' if os.environ.get(key) else ' is not set')
    else:
        status = endpoint or 'configured connection'
    return source['label'] + ' — ' + status


class PendingCredentials:
    """Own only files created by this wizard, until a config commit retains them."""
    def __init__(self, binary, base_path=None):
        self.binary = binary
        self.base_path = base_path
        self.pending = {}

    def __enter__(self):
        return self

    def __exit__(self, *exception):
        for path, identity in self.pending.items():
            try:
                info = os.lstat(path)
                if (info.st_dev, info.st_ino) == identity and stat.S_ISREG(info.st_mode):
                    os.unlink(path)
            except FileNotFoundError:
                pass

    def retain(self, specs):
        for spec in specs:
            self.pending.pop(spec.get('credential_file'), None)

    def save(self):
        if not sys.stdin.isatty():
            raise SetupError('API keys require the hidden input in an interactive terminal')
        secret = getpass.getpass('API key (hidden; saved privately): ', stream=sys.stderr)
        result = subprocess.run([str(self.binary), 'runtime-store-credential'], input=secret,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        del secret
        if result.returncode != 0:
            raise SetupError('The API key could not be stored. Enter one raw key and check your user configuration permissions.')
        try:
            receipt = json.loads(result.stdout)
            path = receipt['credential_file']
            if receipt.get('schema') != 'masc.private_credential_reference.v1' or not os.path.isabs(path):
                raise ValueError('invalid reference')
            info = os.lstat(path)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
                raise ValueError('invalid private file')
        except (KeyError, TypeError, ValueError, OSError):
            raise SetupError('MASC did not return a valid private credential reference')
        self.pending[path] = (info.st_dev, info.st_ino)
        return path

    def register_account_reference(self, path):
        info = os.lstat(path)
        if not os.path.isabs(path) or not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise SetupError('Antigravity did not return a private account reference')
        self.pending[path] = (info.st_dev, info.st_ino)


def antigravity_catalog_rows(catalog):
    if (catalog.get('source') != 'antigravity_cli_models'
            or catalog.get('account_availability_verified') is not False
            or not isinstance(catalog.get('models'), list)):
        raise SetupError('Antigravity returned an unsupported model list')
    result = []
    for row in catalog['models']:
        if not isinstance(row, dict) or not model_text(row.get('id')) or not model_text(row.get('label')):
            raise SetupError('Antigravity returned an invalid model entry')
        result.append(dict(id=row['id'], label=row['label'], context=None))
    return result


def prepare_antigravity_account(source, credentials):
    if credentials is None or credentials.base_path is None:
        raise SetupError('Open masc setup to select an Antigravity account')
    actions = [('current', 'Use the account signed in to Antigravity on this computer'),
               ('signin', 'Sign in with the official Antigravity client'), ('back', 'Back to connections')]
    if source.get('credential_file'):
        actions.insert(0, ('saved', 'Use this workspace’s saved Antigravity account'))
    selected = actions[pick('Antigravity account', [label for _, label in actions])[0]][0]
    if selected == 'back':
        raise SetupError('returned to connection selection')
    arguments = [str(credentials.binary), 'runtime-antigravity-account', '--base-path', str(credentials.base_path),
                 '--cli-path', source['command']]
    if selected == 'signin':
        arguments.append('--sign-in')
    elif selected == 'saved':
        arguments += ['--credential-file', source['credential_file']]
    response = subprocess.run(arguments, stdout=subprocess.PIPE, text=True)
    try:
        receipt = json.loads(response.stdout)
        if response.returncode:
            if receipt.get('schema') == 'masc.antigravity_setup_error.v1':
                raise SetupError(terminal_text(receipt['error']))
            raise ValueError('invalid failure')
        if (receipt.get('schema') != 'masc.antigravity_account.v1' or receipt.get('invocation_verified') is not False
                or not isinstance(receipt.get('provider_timeout_s'), (int, float))
                or not math.isfinite(receipt['provider_timeout_s']) or receipt['provider_timeout_s'] <= 0):
            raise ValueError('invalid account receipt')
        credential = receipt['credential_file']
        models = antigravity_catalog_rows(receipt['catalog'])
        credentials.register_account_reference(credential)
    except (KeyError, TypeError, ValueError):
        raise SetupError('Antigravity account selection did not return a readable result')
    source.update(credential_file=credential, credential_kind='file', credential_replaced=True,
                  account_catalog=models, provider_timeout_s=receipt['provider_timeout_s'])
    if receipt.get('catalog_error'):
        print(terminal_text(receipt['catalog_error']) + ' Choose Refresh model list to try again.', file=sys.stderr)
    return source


def antigravity_models(binary, source):
    if 'account_catalog' in source:
        return source.pop('account_catalog')
    response = subprocess.run([str(binary), 'runtime-antigravity-models', '--cli-path', source['command'],
                               '--credential-file', source['credential_file']],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if response.returncode:
        raise SetupError('Antigravity could not refresh models. Check sign-in and retry account selection.')
    try:
        return antigravity_catalog_rows(json.loads(response.stdout))
    except (TypeError, ValueError):
        raise SetupError('Antigravity did not return a readable model list')


def prerequisite_menu(binary, dependency):
    result = subprocess.run([str(binary), 'prerequisite-actions', dependency],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        catalog = json.loads(result.stdout)
        if result.returncode or catalog.get('schema') != 'masc.prerequisite_actions.v1' or not isinstance(catalog.get('actions'), list):
            raise ValueError('invalid actions')
    except (TypeError, ValueError):
        raise SetupError('MASC could not inspect installation actions for this computer')
    actions = catalog['actions']
    labels = [row['label'] + (' · administrator permission' if row['requires_admin'] else '') for row in actions]
    choice = pick('Install or start the selected prerequisite', labels + ['Refresh detection', 'Back to setup choices'])[0]
    if choice == len(actions) + 1:
        return False
    if choice == len(actions):
        return True
    selected = actions[choice]
    print(terminal_text(selected['detail']), file=sys.stderr)
    print('Source: ' + terminal_text(selected['source_url']), file=sys.stderr)
    # The selected native action owns commands and privilege boundaries. Child
    # password prompts and vendor output keep the terminal, not a hidden pipe.
    result = subprocess.run([str(binary), 'prerequisite-actions', dependency, '--execute', selected['id']],
                            stdout=subprocess.PIPE, text=True)
    try:
        receipt = json.loads(result.stdout)
        if receipt.get('schema') != 'masc.prerequisite_action_result.v1' or receipt.get('readiness') != 'not_checked':
            raise ValueError('invalid result')
        state = receipt['status']
    except (KeyError, TypeError, ValueError):
        raise SetupError('Installation action did not return a readable result; recheck the prerequisite')
    if state == 'failed' or result.returncode:
        reason = receipt.get('reason')
        if isinstance(reason, str) and reason.strip():
            print(terminal_text(reason), file=sys.stderr)
        else:
            print('The selected step did not finish. Check its terminal output and retry when ready.', file=sys.stderr)
    elif state == 'external_step_pending':
        print('Complete the vendor installation window, then choose Refresh detection.', file=sys.stderr)
    elif state == 'commands_completed_recheck_required':
        print('The installation step finished. Checking the service and account access next.', file=sys.stderr)
    else:
        raise SetupError('MASC returned an unknown installation state')
    return True


def prepare_connection(source, credentials):
    source = dict(source)
    if source.get('setup_support') == 'unsupported' or source['choice'] is None:
        raise SetupError(source['label'] + ' is listed for visibility but its setup integration is not available yet')
    if CHOICES[source['choice']][1] is not None:
        command = source.get('command') or CHOICES[source['choice']][1]
        while not shutil.which(command):
            client = {'claude_code': 'claude-code', 'codex': 'codex'}.get(source['choice'])
            if credentials is None or client is None or not prerequisite_menu(credentials.binary, client):
                raise SetupError('Install the selected client, then return to connection setup')
        if source['choice'] == 'antigravity':
            source['command'] = shutil.which(command)
            return prepare_antigravity_account(source, credentials)
        return source
    if not source['endpoint']:
        urls = ['http://127.0.0.1:8000/v1', 'http://127.0.0.1:8080/v1']
        selected = pick('Choose the running local server address', urls + ['Another API URL'])[0]
        source['endpoint'] = urls[selected] if selected < len(urls) else ask_text('API base URL')
    has_credential = bool(source.get('credential_file') or (source['api_key_env'] and os.environ.get(source['api_key_env'])))
    if source['api_key_env'] and not has_credential and credentials is not None:
        action = pick(source['label'] + ': account access', [
            'Enter an API key now (hidden, saved for future terminals)',
            'Return to connection selection'])[0]
        if action:
            raise SetupError('returned to connection selection')
        source.update(credential_file=credentials.save(), credential_kind='file', api_key_env='', credential_replaced=True)
    return source


def native_connection_command(binary, command, source, timeout, arguments=()):
    spec = {key: source[key] for key in ('choice', 'provider_kind', 'endpoint', 'provider_id', 'api_key_env', 'credential_file')
            if source.get(key)}
    with tempfile.TemporaryDirectory(prefix='masc-model-discovery-') as directory:
        path = Path(directory) / 'connection.json'
        atomic_write(path, json.dumps(spec).encode(), 0o600)
        return subprocess.run([str(binary), command, '--spec', str(path)] + list(arguments),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)


def native_discover_models(binary, source, timeout):
    try:
        result = native_connection_command(binary, 'runtime-discover-models', source, timeout)
    except subprocess.TimeoutExpired:
        return [], 'Model list did not answer in time; check the connection and refresh.'
    if result.returncode:
        # Native errors are fixed diagnostics; never forward provider bodies.
        return [], 'Model list unavailable. Check account access, API credit or the running server, then refresh.'
    try:
        result = json.loads(result.stdout)
        if result.get('source') != 'account_or_server_model_list' or result.get('account_availability_verified') is not False:
            raise ValueError('unsupported observation')
        models = result['models']
        if not isinstance(models, list) or not all(isinstance(row, dict) and model_text(row.get('id')) for row in models):
            raise ValueError('invalid models')
    except (KeyError, TypeError, ValueError):
        raise SetupError('MASC returned an invalid model-list observation')
    return models, 'Current account/server model list; invocation is checked after selection'


def native_serving_context(binary, source, model, timeout, load=False):
    arguments = ['--model', model] + (['--load'] if load else [])
    if load:
        print('Loading the selected model and reading its running context… Ctrl-C cancels setup.', file=sys.stderr)
    try:
        # A cold model load may legitimately outlast an inventory request.
        # The operator can cancel it; the discovery timeout must not keep
        # aborting and restarting a large model before it becomes available.
        result = native_connection_command(binary, 'runtime-serving-context', source, None if load else timeout, arguments)
    except subprocess.TimeoutExpired:
        raise SetupError('The selected model is not ready yet. Wait for its server to load it, then refresh.')
    if result.returncode:
        raise SetupError('The selected server did not return its serving context. Check its account or server configuration.')
    try:
        observation = json.loads(result.stdout)
        if (observation.get('model') != model
                or observation.get('context_source') not in ('running_model', 'configured_model', 'serving_endpoint', 'not_reported')
                or (observation.get('context') is not None and not positive_integer(observation['context']))
                or (observation.get('tools') is not None and type(observation['tools']) is not bool)):
            raise ValueError('invalid observation')
    except (TypeError, ValueError):
        raise SetupError('The native serving-context observation was invalid')
    return observation


def source_models(binary, source, timeout):
    choice = source['choice']
    can_discover = choice and (source.get('credential_kind', 'none') in ('none', 'env') or source.get('credential_file'))
    if choice == 'antigravity' and source.get('credential_file'):
        observed, origin = antigravity_models(binary, source), 'Models from the selected Antigravity account'
    elif can_discover and CHOICES[choice][1] is None:
        observed, origin = native_discover_models(binary, source, timeout)
    else:
        observed, origin = discover_models(choice, source['endpoint'], source['api_key_env'], timeout,
                                          command=source.get('command') or 'codex') if can_discover else ([], 'Configured models')
    rows = []
    for model in observed:
        existing_rows = [row for row in source['rows'] if row['model'] == model['id']]
        # A workspace declaration is relevant only in this exact connection.
        if existing_rows:
            for existing in existing_rows:
                context = model['context'] or existing['max_context']
                label = model['label'] + (' — ' + existing['id'] if len(existing_rows) > 1 else '')
                rows.append(dict(model, label=label, context=context,
                                 existing=None if source.get('credential_replaced') else existing))
        else:
            rows.append(dict(model, existing=None))
    for row in source['rows']:
        if source.get('credential_replaced') and any(item['id'] == row['model'] for item in rows):
            continue
        if not any(item.get('existing', {}).get('id') == row['id'] for item in rows if item.get('existing')):
            duplicates = sum(other['model'] == row['model'] for other in source['rows']) > 1
            label = row['model'] + (' — ' + row['id'] if duplicates else '')
            rows.append(dict(id=row['model'], label=label, context=row['max_context'],
                             existing=None if source.get('credential_replaced') else row))
    if choice in ('codex', 'claude_code'):
        for model in catalog_models(binary, choice):
            if not any(item['id'] == model['id'] for item in rows):
                rows.append(dict(model, existing=None))
    return rows, origin


def resolve_model_spec(source, model, timeout, binary=None):
    existing = model.get('existing')
    choice = source['choice']
    # Preserve every setting on an operator's existing connection. Its actual
    # model/tool capability is verified before it can become imp's default.
    if existing and existing.get('tools') is True and choice != 'ollama':
        return existing['id'], None
    if source.get('credential_kind', 'none') not in ('none', 'env') and not source.get('credential_file'):
        raise SetupError('this connection uses a protected credential reference; select an existing tool-enabled model or add an environment-authenticated connection')
    if choice is None:
        raise SetupError('this connection needs runtime-specific configuration; choose an existing tool-enabled runtime')
    context = model.get('context')
    if not positive_integer(context) and binary and source.get('provider_id') and choice != 'ollama':
        result = subprocess.run([str(binary), 'runtime-model-info', model['id'], '--provider', source['provider_id']],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if result.returncode == 0:
            try:
                catalog_model = json.loads(result.stdout)
                if catalog_model.get('model') == model['id'] and positive_integer(catalog_model.get('max_context')):
                    context = catalog_model['max_context']
            except ValueError:
                pass
    if choice == 'ollama':
        details = (native_serving_context(binary, source, model['id'], timeout, load=True) if binary
                   else ollama_model_details(source['endpoint'], model['id'], source['api_key_env'], timeout, load=True))
        if details['tools'] is False:
            raise SetupError('this Ollama model reports no tool support; select a tool-capable model for imp')
        context = details['context']
    elif choice in ('llama_cpp', 'openai_compatible') and context is None:
        if binary:
            try:
                context = native_serving_context(binary, source, model['id'], timeout)['context']
            except SetupError:
                context = None
        else:
            endpoint = source['endpoint'].rstrip('/')
            root = endpoint[:-3] if endpoint.endswith('/v1') else endpoint
            try:
                props = http_json(root, '/props', source['api_key_env'], timeout)
            except (OSError, ValueError, URLError):
                props = None
            served, _ = discover_models(choice, endpoint, source['api_key_env'], timeout)
            if len(served) == 1 and served[0]['id'] == model['id'] and isinstance(props, dict):
                settings = props.get('default_generation_settings')
                if isinstance(settings, dict) and positive_integer(settings.get('n_ctx')):
                    context = settings['n_ctx']
    if not positive_integer(context):
        action = pick('The server did not report its configured context window.',
                      ['Return to model selection', 'Advanced: enter the documented server limit'])[0]
        if action == 0:
            raise SetupError('select another model or refresh after configuring its server context window')
        while not positive_integer(context):
            answer = ask_text('Configured context tokens (for example, 8192 only if your server declares that limit)')
            context = int(answer) if answer.isascii() and answer.isdigit() else None
    spec = dict(choice=choice, model=model['id'], max_context=context, tools=True,
                streaming=choice in ('claude_code', 'codex'))
    if CHOICES[choice][1] is None:
        spec.update(endpoint=source['endpoint'])
        spec.update({key: source[key] for key in ('api_key_env', 'credential_file', 'provider_kind', 'request_path') if source.get(key)})
    elif source['command']:
        spec['command'] = source['command']
    if choice == 'antigravity':
        spec.update(credential_file=source['credential_file'], timeout_s=source['provider_timeout_s'])
    return render(spec)[0], spec


def select_connections(binary, inventory, timeout, credentials=None):
    sources = connection_sources(inventory)
    labels = [source_label(source) for source in sources] + ['Add another server URL', 'Configure later']
    chosen = pick('Select model connections (you can choose several)', labels, multiple=True)
    if len(sources) + 1 in chosen:
        if len(chosen) != 1:
            raise SetupError('choose Configure later alone, or select connections')
        return [], [], {}
    selected, specs, names = [], [], {}
    for index in chosen:
        if index == len(sources):
            kind = pick('Server type', ['OpenAI-compatible / vLLM', 'llama.cpp', 'Ollama'])[0]
            choice = ['openai_compatible', 'llama_cpp', 'ollama'][kind]
            endpoint = ask_text('API base URL' + (' (including /v1)' if choice != 'ollama' else ''))
            # Validate before issuing any request; values never go into menus.
            parsed = urlsplit(endpoint)
            if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
                raise SetupError('use an HTTP(S) API URL without embedded credentials')
            keys = sorted({source['api_key_env'] for source in sources if source['api_key_env']}
                          | {key for key in os.environ if key.endswith('_API_KEY')})
            key_index = pick('Server authentication', ['No API key', 'Enter an API key now (hidden)'] + keys + ['Advanced: environment variable name'])[0]
            key = keys[key_index - 2] if 2 <= key_index < len(keys) + 2 else ask_text('API key environment variable name (not its value)') if key_index == len(keys) + 2 else ''
            source = dict(choice=choice, endpoint=endpoint, api_key_env=key, command='', rows=[], label=endpoint)
            if key_index == 1:
                if credentials is None:
                    raise SetupError('Open masc setup to save an API key privately')
                source.update(credential_file=credentials.save(), credential_kind='file')
        else:
            source = sources[index]
        source = prepare_connection(source, credentials)
        while True:
            models, origin = source_models(binary, source, timeout)
            print(terminal_text(origin) + '\nListed models are checked with a real response and tool call before saving.', file=sys.stderr)
            options = [item['label'] + (' — existing connection' if item.get('existing') else '') for item in models]
            actions = ['Refresh model list', 'Back to connection selection', 'Advanced: enter an exact model ID']
            can_replace_key = credentials is not None and CHOICES[source['choice']][1] is None
            if can_replace_key:
                actions.append('Save or replace API key (hidden)')
            indexes = pick(source['label'] + ': select models', options + actions, multiple=True)
            commands = [value for value in indexes if value >= len(models)]
            if commands:
                if len(indexes) != 1:
                    print('Select a menu action on its own, or select several models.', file=sys.stderr)
                    continue
                action = commands[0] - len(models)
                if action == 0:
                    continue
                if action == 1:
                    raise SetupError('returned to connection selection')
                if action == 3 and can_replace_key:
                    source.update(credential_file=credentials.save(), credential_kind='file', api_key_env='', credential_replaced=True)
                    continue
                model_id = ask_text('Exact model ID from your runtime')
                if not model_text(model_id):
                    raise SetupError('model ID must be a nonempty single line')
                models.append(dict(id=model_id, label=model_id, context=None, existing=None))
                indexes = [len(models) - 1]
            for model_index in indexes:
                model = models[model_index]
                runtime_id, spec = resolve_model_spec(source, model, timeout, binary=binary)
                if runtime_id not in selected:
                    selected.append(runtime_id)
                    names[runtime_id] = source['label'] + ' / ' + model['id']
                    if spec:
                        specs.append(spec)
            break
    return selected, specs, names


def login_command(runtime_id, specs, inventory):
    spec = next((spec for spec in specs if render(spec)[0] == runtime_id), None)
    if spec:
        choice, command = spec['choice'], spec.get('command') or CHOICES[spec['choice']][1]
    else:
        row = next((row for row in inventory['runtimes'] if row['id'] == runtime_id), None)
        if row is None:
            return None
        choice, command = PROTOCOL_CHOICES.get(row['protocol']), row.get('command')
    arguments = {'claude_code': ['auth', 'login'], 'codex': ['login', '--device-auth']}.get(choice)
    return [command] + arguments if command and arguments else None


def wizard(binary, base_path, timeout):
    with PendingCredentials(binary, base_path) as credentials:
        return wizard_with_credentials(binary, base_path, timeout, credentials)


def wizard_with_credentials(binary, base_path, timeout, credentials):
    while True:
        try:
            inventory = configured_inventory(binary, base_path)
            selected, specs, names = select_connections(binary, inventory, timeout, credentials)
            if not selected:
                return dict(configured=False, readiness='deferred', base_path=str(base_path))
            primary = pick('Which connection should imp use first?', [names[value] for value in selected])[0]
            ordered = [selected.pop(primary)]
            if len(selected) > 1:
                print('Fallback order:\n' + '\n'.join('  {}. {}'.format(index, terminal_text(names[value]))
                                                       for index, value in enumerate(selected, 1)), file=sys.stderr)
                customize = pick('Fallback order', ['Keep this order', 'Choose a different order'])[0]
                if customize:
                    while len(selected) > 1:
                        index = pick('Choose the next fallback connection', [names[value] for value in selected])[0]
                        ordered.append(selected.pop(index))
            ordered += selected
            print('Checking a real response and a harmless tool call for each selected connection…', file=sys.stderr)
            while ordered:
                try:
                    # Excluding a failed connection must also exclude its new
                    # declaration from the transaction, not just from the lane.
                    active_specs = [spec for spec in specs if render(spec)[0] in ordered]
                    result = configure_many(binary, base_path, active_specs, ordered, verify=True)
                    credentials.retain(active_specs)
                    result['base_path'] = str(base_path)
                    return result
                except VerificationError as error:
                    print('Verification failed: ' + terminal_text(names[error.runtime_id]), file=sys.stderr)
                    # Native verification owns safe fixed diagnostics; never
                    # display provider stderr or HTTP bodies here. The detail
                    # line is the official client's own account of what it
                    # looked for (a missing sign-in, a binary that would not
                    # launch), written by the adapter, not by the provider.
                    if model_text(error.failure.get('code')) and model_text(error.failure.get('message')):
                        print(terminal_text(error.failure['code']) + ': ' + terminal_text(error.failure['message']), file=sys.stderr)
                    if model_text(error.failure.get('detail')):
                        print('  ' + terminal_text(error.failure['detail']), file=sys.stderr)
                    login = login_command(error.runtime_id, specs, inventory)
                    actions = ['Retry the selected connections', 'Exclude this connection', 'Choose connections again', 'Configure later']
                    if login:
                        actions.append('Sign in with the official CLI, then retry these choices')
                    action = pick('Keep your choices and decide how to continue', actions)[0]
                    if action == 1:
                        ordered.remove(error.runtime_id)
                    elif action == 2:
                        break
                    elif action == 3:
                        return dict(configured=False, readiness='deferred', base_path=str(base_path))
                    elif action == 4 and login:
                        print('The official client will handle sign-in. MASC does not ask for your password.', file=sys.stderr)
                        if subprocess.run(login, stdout=sys.stderr).returncode != 0:
                            print('Sign-in did not finish. Your model choices are still selected.', file=sys.stderr)
        except (SetupError, OSError, ValueError, URLError) as error:
            if not isinstance(error, SetupError):
                error = SetupError('the selected server did not return usable model details; check its connection and try again')
            print(terminal_text(error), file=sys.stderr)
            action = pick('Connection setup', ['Choose connections again', 'Configure later'])[0]
            if action == 1:
                return dict(configured=False, readiness='deferred', base_path=str(base_path))


def workspace_upgrade_catalog(binary, base_path):
    result = subprocess.run([str(binary), 'workspace-upgrade', '--base-path', str(base_path)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        catalog = json.loads(result.stdout)
        if (result.returncode or catalog.get('schema') != 'masc.workspace_upgrades.v1'
                or catalog.get('read_only') is not True
                or not isinstance(catalog.get('keepers'), list) or not isinstance(catalog.get('backups'), list)):
            raise ValueError('invalid catalog')
    except (TypeError, ValueError):
        raise SetupError('Workspace upgrades could not be inspected. Existing files were preserved.')
    return catalog


def workspace_upgrade_action(binary, base_path, arguments, schema):
    result = subprocess.run([str(binary), 'workspace-upgrade', '--base-path', str(base_path)] + arguments,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        receipt = json.loads(result.stdout)
        if result.returncode:
            if receipt.get('schema') == 'masc.workspace_upgrade_error.v1' and isinstance(receipt.get('error'), str):
                print(terminal_text(receipt['error']), file=sys.stderr)
                return False
            raise ValueError('invalid error')
        if receipt.get('schema') != schema:
            raise ValueError('invalid receipt')
    except (TypeError, ValueError):
        raise SetupError('The upgrade result could not be read. Inspect the workspace backups before retrying.')
    if receipt.get('backup_path'):
        print('Original configuration saved at ' + terminal_text(receipt['backup_path']), file=sys.stderr)
    if not receipt.get('durability_confirmed') or not receipt.get('lock_release_confirmed'):
        print('The file was changed, but final disk or lock confirmation was incomplete. The original backup remains available.', file=sys.stderr)
    return True


def select_workspace_upgrades(binary, base_path, plans):
    labels = [row['keeper_name'] + ' — preserve activation mode: ' + row['plan']['activation_mode'] for row in plans]
    selected = pick('Back up and upgrade the selected Keeper configurations', labels, multiple=True)
    print('Each selected file gets a separate private backup. Other workspace data stays in place.', file=sys.stderr)
    for index in selected:
        row = plans[index]
        if not workspace_upgrade_action(binary, base_path,
                ['--apply', row['keeper_name'], '--source-sha256', row['plan']['source_sha256']],
                'masc.keeper_upgrade_receipt.v1'):
            break  # preserve successful receipts and re-inspect before another attempt


def select_workspace_restore(binary, base_path, backups):
    labels = [Path(row['receipt']['plan']['path']).stem + ' — backup ' + row['backup_id'] for row in backups]
    selected = pick('Restore an original configuration (later edits are protected)', labels + ['Back'])[0]
    if selected < len(backups):
        print('Restoring the original may require using the previous MASC version for this workspace.', file=sys.stderr)
        workspace_upgrade_action(binary, base_path, ['--restore', backups[selected]['backup_id']],
                                 'masc.workspace_restore.v1')


def workspace_check(binary, base_path):
    base = Path(base_path).expanduser().resolve()
    while True:
        result = subprocess.run([str(binary), 'setup-preflight', '--base-path', str(base)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            receipt = json.loads(result.stdout)
        except ValueError:
            raise SetupError('workspace preflight did not return a readable result; existing data was preserved')
        if (result.returncode == 0 and receipt.get('status') == 'ready'
                and receipt.get('read_only') is True and receipt.get('scope') == 'keeper_goal_state_schema'):
            return dict(base_path=str(base), status='ready')
        if receipt.get('status') != 'needs_attention' or not isinstance(receipt.get('issues'), list):
            raise SetupError('workspace preflight failed; existing data was preserved')
        print('This workspace contains state that this version cannot open. Its files have not been changed.', file=sys.stderr)
        for issue in receipt['issues']:
            print('  ' + terminal_text(issue['path']) + ': ' + terminal_text(issue['detail']), file=sys.stderr)
        if not sys.stdin.isatty():
            raise SetupError('choose a new unused workspace with --base-path, or keep the previous version for this workspace')
        upgrades = workspace_upgrade_catalog(binary, base)
        plans = [row for row in upgrades['keepers'] if row['status'] == 'upgrade_available']
        suggestion = base.parent / (base.name + '-new')
        suffix = 2
        while suggestion.exists():
            suggestion = base.parent / (base.name + '-new-' + str(suffix))
            suffix += 1
        actions = ['Use new workspace: ' + str(suggestion),
                   'Choose another directory', 'Return without changing existing data']
        optional = []
        if plans:
            optional.append(('upgrade', 'Keep this workspace: back up and upgrade known Keeper settings'))
        if upgrades['backups']:
            optional.append(('restore', 'Restore a previous configuration backup'))
        action = pick('Choose a workspace', actions + [label for _, label in optional])[0]
        if action >= len(actions):
            if optional[action - len(actions)][0] == 'upgrade':
                select_workspace_upgrades(binary, base, plans)
            else:
                select_workspace_restore(binary, base, upgrades['backups'])
            continue
        if action == 2:
            raise SetupError('installation cancelled; existing workspace data was preserved')
        candidate = suggestion if action == 0 else Path(ask_text('New unused workspace directory')).expanduser().resolve()
        if candidate.exists():
            print('Choose an unused directory. Existing directories will not be cleared.', file=sys.stderr)
            continue
        base = candidate


def onboarding_status(binary, base_path=None):
    argv = [str(binary), 'doctor', '--json']
    if base_path is not None:
        argv += ['--base-path', str(base_path)]
    response = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        state = json.loads(response.stdout)
    except ValueError:
        raise SetupError('MASC could not inspect this workspace. Run masc doctor for recovery details.')
    if (response.returncode != 0 or not isinstance(state, dict)
            or state.get('schema') != 'masc.onboarding_status.v1'
            or state.get('scope') != 'configuration_observation'
            or not isinstance(state.get('checks'), list)):
        raise SetupError('MASC returned an unsupported setup observation; reinstall the complete release.')
    return state


def open_workspace(binary, base_path, port):
    sibling = Path(binary).resolve().parent / 'masc-tui'
    tui = str(sibling) if os.access(str(sibling), os.X_OK) else shutil.which('masc-tui')
    if not tui:
        raise SetupError('The terminal UI is missing. Reinstall the complete MASC release, then run masc again.')
    return subprocess.run([tui, '--base-path', str(base_path), '--port', str(port)]).returncode


def select_sandbox(binary, base_path):
    advanced = False
    names = {'docker': 'Docker', 'apple_container': 'Apple Container', 'nerdctl_kata': 'Kata (nerdctl)',
             'microsandbox': 'microsandbox', 'remote_ssh': 'Remote SSH'}
    while True:
        response = subprocess.run([str(binary), 'sandbox-catalog', '--base-path', str(base_path)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            catalog = json.loads(response.stdout)
        except ValueError:
            raise SetupError('Sandbox inspection failed. Run masc sandbox-catalog for details.')
        if response.returncode != 0 or catalog.get('schema') != 'masc.sandbox_readiness.v1':
            raise SetupError('MASC could not inspect sandbox prerequisites.')
        if catalog.get('configuration_error'):
            print(terminal_text(catalog['configuration_error']), file=sys.stderr)
        rows = [row for row in catalog['candidates'] if advanced or not row['advanced']]
        rows.sort(key=lambda row: not row['recommended'])
        labels = [names.get(row['id'], row['id']) + (' · recommended' if row['recommended'] else '')
                  + ' — ' + ('service found; guest still needs preparation' if row['state'] == 'service_ready' else row['reason'])
                  for row in rows]
        action = pick('3 · Choose imp’s sandbox', labels + [
            'Refresh after installing or starting a service',
            'Show common choices' if advanced else 'Advanced sandbox choices', 'Finish later'])[0]
        if action == len(rows):
            continue
        if action == len(rows) + 1:
            advanced = not advanced
            continue
        if action == len(rows) + 2:
            return None
        row = rows[action]
        if row['state'] != 'service_ready':
            print(terminal_text(row['reason']), file=sys.stderr)
            prerequisite_menu(binary, row['id'])
            continue
        arguments = list(row['setup_args'])
        configured = catalog.get('configured_selection')
        same_backend = isinstance(configured, dict) and configured.get('backend') == row['id']
        modes = row['capabilities']['network_modes']
        if same_backend and not advanced:
            print('Keeping the configured guest network policy. MASC model connections and WebFetch have separate server-side controls.', file=sys.stderr)
            return arguments
        if advanced:
            # A declared policy can be kept; creating a new one also needs its
            # destination configuration, so it is not synthesized here.
            modes = [mode for mode in modes if mode in ('inherit', 'none')]
            modes.sort(key=lambda mode: mode != 'inherit')
            labels = [('Allow internet access for guest commands' if mode == 'inherit'
                       else 'Disable networking for guest commands') for mode in modes]
            if same_backend:
                labels.insert(0, 'Keep configured guest network policy (' + terminal_text(configured['network_mode']) + ')')
            print('Guest networking controls sandbox commands. MASC model connections and WebFetch run through separate server-side controls.', file=sys.stderr)
            choice = pick('Sandbox guest network access', labels)[0]
            if same_backend:
                if choice == 0:
                    return arguments
                choice -= 1
            mode = modes[choice]
        else:
            if 'inherit' not in modes:
                raise SetupError('This sandbox needs advanced network configuration for the first conversation.')
            mode = 'inherit'
            print('The new sandbox allows internet access for guest commands. MASC model connections and WebFetch have separate server-side controls; Advanced choices can disable guest networking.', file=sys.stderr)
        return arguments + ['--network-mode', mode]



def journey(binary, base_path, port, timeout, resume=False):
    state = onboarding_status(binary, base_path)
    conditions = {check['id']: check['condition'] for check in state['checks']}
    # Persistence permits opening existing history, never a readiness badge.
    # The TUI observes/reconnects the server and reports current execution.
    if (resume and state.get('base_path') and conditions.get('workspace') == 'satisfied'
            and conditions.get('keeper_persistence') == 'satisfied'
            and 'invalid' not in conditions.values()):
        return open_workspace(binary, state['base_path'], port)
    print('\nWelcome. Let’s make a home for you and imp.\n'
          'Choose with arrows and Enter; Space selects several connections.', file=sys.stderr)
    proposed = state.get('base_path') or str(Path.home() / 'MASC')
    selection = pick('1 · Your workspace', ['Use ' + proposed, 'Choose another directory', 'Finish later'])[0]
    if selection == 2:
        return 0
    base = proposed if selection == 0 else ask_text('Workspace directory')
    base = workspace_check(binary, base)['base_path']
    if subprocess.run([str(binary), 'init', '--base-path', base], stdout=sys.stderr).returncode != 0:
        raise SetupError('Workspace initialization stopped. Existing files were preserved; run masc setup to resume.')
    print('\n2 · Connect a model\nA subscription or API credit may be required by your provider.', file=sys.stderr)
    configured = wizard(binary, base, timeout)
    if configured.get('readiness') != 'verified':
        print('Your workspace is saved. Run masc to continue from here.', file=sys.stderr)
        return 0
    sandbox_args = select_sandbox(binary, base)
    if sandbox_args is None:
        print('Your model connection is saved. Run masc setup to prepare the sandbox later.', file=sys.stderr)
        return 0
    print('\n4 · Open your first conversation', file=sys.stderr)
    while True:
        # Native setup owns staging, image preparation, server/operator login,
        # and imp boot. --no-tui avoids re-entering this interactive journey.
        code = subprocess.run([str(binary), 'setup', '--base-path', base, '--port', str(port),
                               '--no-tui'] + sandbox_args, stdout=sys.stderr).returncode
        if code == 0:
            return open_workspace(binary, base, port)
        action = pick('imp is not running yet. Keep your workspace and continue when ready.',
                      ['Retry preparation', 'Finish later'])[0]
        if action == 1:
            return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--base-path')
    parser.add_argument('--journey', action='store_true')
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--port', type=int, default=8945)
    parser.add_argument('--spec')
    parser.add_argument('--wizard', action='store_true')
    parser.add_argument('--workspace-check', action='store_true')
    parser.add_argument('--batch-spec', help='JSON with connections, runtime_ids and optional default_runtime_id')
    parser.add_argument('--verify', action='store_true', help='require real response and tool verification before saving')
    parser.add_argument('--select-model', choices=CHOICES)
    parser.add_argument('--endpoint', default='')
    parser.add_argument('--credential-env', dest='api_key_env', default='')
    parser.add_argument('--discovery-timeout', type=float, default=10)
    args = parser.parse_args()
    try:
        if sum(map(bool, (args.spec, args.select_model, args.wizard, args.batch_spec, args.workspace_check, args.journey))) != 1:
            raise SetupError('choose exactly one setup operation')
        if not args.journey and not args.base_path:
            raise SetupError('--base-path is required for this setup operation')
        if not math.isfinite(args.discovery_timeout) or args.discovery_timeout <= 0:
            raise SetupError('discovery timeout must be positive')
        if args.journey:
            raise SystemExit(journey(args.binary, args.base_path, args.port, args.discovery_timeout, args.resume))
        if args.workspace_check:
            result = workspace_check(args.binary, args.base_path)
        elif args.wizard:
            result = wizard(args.binary, args.base_path, args.discovery_timeout)
        elif args.batch_spec:
            spec = json.loads(Path(args.batch_spec).read_text())
            result = configure_many(args.binary, args.base_path, spec['connections'], spec.get('runtime_ids'),
                                    args.verify, spec.get('default_runtime_id'))
        elif args.select_model:
            result = select_model(args.binary, args.select_model, args.endpoint, args.api_key_env, args.discovery_timeout)
        else:
            result = configure_many(args.binary, args.base_path, [json.loads(Path(args.spec).read_text())], verify=args.verify)
        print(json.dumps(result, ensure_ascii=False))
    except (SetupError, OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit('runtime setup failed: ' + str(error))


if __name__ == '__main__':
    main()
