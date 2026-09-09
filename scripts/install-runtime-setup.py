#!/usr/bin/env python3
"""Select runtime connections and validate them before publishing together.

Python 3.8 stdlib only. --spec names a JSON file, never a credential value.
The wizard requires real response/tool verification; --spec stays offline unless
--verify is supplied. Offline configuration validation is not inference proof.
"""
import argparse
import fcntl
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
    allowed |= {'endpoint', 'api_key_env'} if default_command is None else {'command'}
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
        base_capabilities = 'ollama' if choice == 'ollama' else 'openai_chat'
        caps = {'id_prefix': model, 'provider_name': provider, 'base': base_capabilities,
                'max_context_tokens': context, 'supports_tools': spec['tools'],
                'supports_native_streaming': spec['streaming']}
        caps.update({key: False for key in UNVERIFIED_CAPABILITIES})
        caps.update(thinking_control_format='none', reasoning_streaming_format='none')
        overlay = table(('models',), caps, array=True)
        # Exact-output lanes resolve through this same provider/model pair.
        # A runtime binding alone is not an Agent Core target declaration.
        overlay += table(('providers',), {
            'id': provider, 'kind': 'ollama' if choice == 'ollama' else 'openai_compat', 'base_url': endpoint,
            'request_path': '/api/chat' if choice == 'ollama' else '/chat/completions', 'api_key_env': spec.get('api_key_env', ''),
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
    result = subprocess.run([str(binary), 'runtime-wizard-catalog', '--base-path', str(base_path), '--json'],
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


def discover_models(choice, endpoint='', api_key_env='', timeout=10):
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
        path = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'models_cache.json'
        try:
            cache = json.loads(path.read_text())
            rows = cache['models']
            if not isinstance(rows, list):
                raise ValueError('invalid model cache')
        except (OSError, ValueError, KeyError, TypeError):
            return [], 'No readable Codex model list. Sign in with Codex and open its /model picker to find an exact model ID.'
        origin = 'Codex local model list (cached; availability is checked after selection)'
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
        return [dict(id=row['id'], label=row.get('label', row['id']), context=row['max_context'])
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
    if context is None and choice in ('codex', 'claude_code'):
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


PROTOCOL_CHOICES = {'ollama-http': 'ollama', 'openai-compatible-http': 'openai_compatible',
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
                          credential_kind=row.get('credential_kind', 'unknown'), rows=[])
            sources.append(source)
        source['rows'].append(row)
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
    if command:
        status = 'CLI found' if shutil.which(command) else 'CLI not found'
    elif key:
        status = key + (' is set' if os.environ.get(key) else ' is not set')
    else:
        status = endpoint or 'configured connection'
    return source['label'] + ' — ' + status


def source_models(binary, source, timeout):
    choice = source['choice']
    can_discover = choice and source.get('credential_kind', 'none') in ('none', 'env')
    observed, origin = discover_models(choice, source['endpoint'], source['api_key_env'], timeout) if can_discover else ([], 'Configured models')
    rows = []
    for model in observed:
        existing_rows = [row for row in source['rows'] if row['model'] == model['id']]
        # A workspace declaration is relevant only in this exact connection.
        if existing_rows:
            for existing in existing_rows:
                context = model['context'] or existing['max_context']
                label = model['label'] + (' — ' + existing['id'] if len(existing_rows) > 1 else '')
                rows.append(dict(model, label=label, context=context, existing=existing))
        else:
            rows.append(dict(model, existing=None))
    for row in source['rows']:
        if not any(item.get('existing', {}).get('id') == row['id'] for item in rows if item.get('existing')):
            duplicates = sum(other['model'] == row['model'] for other in source['rows']) > 1
            label = row['model'] + (' — ' + row['id'] if duplicates else '')
            rows.append(dict(id=row['model'], label=label, context=row['max_context'], existing=row))
    if choice in ('codex', 'claude_code'):
        for model in catalog_models(binary, choice):
            if not any(item['id'] == model['id'] for item in rows):
                rows.append(dict(model, existing=None))
    return rows, origin


def resolve_model_spec(source, model, timeout):
    existing = model.get('existing')
    choice = source['choice']
    # Preserve every setting on an operator's existing connection. Its actual
    # model/tool capability is verified before it can become imp's default.
    if existing and existing.get('tools') is True and choice != 'ollama':
        return existing['id'], None
    if source.get('credential_kind', 'none') not in ('none', 'env'):
        raise SetupError('this connection uses a protected credential reference; select an existing tool-enabled model or add an environment-authenticated connection')
    if choice is None or choice == 'antigravity':
        raise SetupError('this connection needs runtime-specific configuration; choose an existing tool-enabled runtime')
    context = model.get('context')
    if choice == 'ollama':
        details = ollama_model_details(source['endpoint'], model['id'], source['api_key_env'], timeout, load=True)
        if details['tools'] is False:
            raise SetupError('this Ollama model reports no tool support; select a tool-capable model for imp')
        context = details['context']
    elif choice in ('llama_cpp', 'openai_compatible') and context is None:
        endpoint = source['endpoint'].rstrip('/')
        root = endpoint[:-3] if endpoint.endswith('/v1') else endpoint
        try:
            props = http_json(root, '/props', source['api_key_env'], timeout)
        except (OSError, ValueError, URLError):
            props = None
        served, _ = discover_models(choice, endpoint, source['api_key_env'], timeout)
        # Router metadata must not become another model's context declaration.
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
        spec.update(endpoint=source['endpoint'], api_key_env=source['api_key_env'])
    elif source['command']:
        spec['command'] = source['command']
    return render(spec)[0], spec


def select_connections(binary, inventory, timeout):
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
            key_index = pick('Server authentication', ['No API key'] + keys + ['Another environment variable name'])[0]
            key = '' if key_index == 0 else keys[key_index - 1] if key_index <= len(keys) else ask_text('API key environment variable name (not its value)')
            source = dict(choice=choice, endpoint=endpoint, api_key_env=key, command='', rows=[], label=endpoint)
        else:
            source = sources[index]
        while True:
            models, origin = source_models(binary, source, timeout)
            print(terminal_text(origin) + '\nListed models are checked with a real response and tool call before saving.', file=sys.stderr)
            options = [item['label'] + (' — existing connection' if item.get('existing') else '') for item in models]
            actions = ['Refresh model list', 'Back to connection selection', 'Advanced: enter an exact model ID']
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
                model_id = ask_text('Exact model ID from your runtime')
                if not model_text(model_id):
                    raise SetupError('model ID must be a nonempty single line')
                models.append(dict(id=model_id, label=model_id, context=None, existing=None))
                indexes = [len(models) - 1]
            for model_index in indexes:
                model = models[model_index]
                runtime_id, spec = resolve_model_spec(source, model, timeout)
                if runtime_id not in selected:
                    selected.append(runtime_id)
                    names[runtime_id] = source['label'] + ' / ' + model['id']
                    if spec:
                        specs.append(spec)
            break
    return selected, specs, names


def wizard(binary, base_path, timeout):
    while True:
        try:
            inventory = configured_inventory(binary, base_path)
            selected, specs, names = select_connections(binary, inventory, timeout)
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
                    result['base_path'] = str(base_path)
                    return result
                except VerificationError as error:
                    print('Verification failed: ' + terminal_text(names[error.runtime_id]), file=sys.stderr)
                    # Native verification owns safe fixed diagnostics; never
                    # display provider stderr or HTTP bodies here.
                    if model_text(error.failure.get('code')) and model_text(error.failure.get('message')):
                        print(terminal_text(error.failure['code']) + ': ' + terminal_text(error.failure['message']), file=sys.stderr)
                    action = pick('Keep your choices and decide how to continue',
                                  ['Retry the selected connections', 'Exclude this connection', 'Choose connections again', 'Configure later'])[0]
                    if action == 1:
                        ordered.remove(error.runtime_id)
                    elif action == 2:
                        break
                    elif action == 3:
                        return dict(configured=False, readiness='deferred', base_path=str(base_path))
        except (SetupError, OSError, ValueError, URLError) as error:
            if not isinstance(error, SetupError):
                error = SetupError('the selected server did not return usable model details; check its connection and try again')
            print(terminal_text(error), file=sys.stderr)
            action = pick('Connection setup', ['Choose connections again', 'Configure later'])[0]
            if action == 1:
                return dict(configured=False, readiness='deferred', base_path=str(base_path))


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
        suggestion = base.parent / (base.name + '-new')
        suffix = 2
        while suggestion.exists():
            suggestion = base.parent / (base.name + '-new-' + str(suffix))
            suffix += 1
        action = pick('Choose a workspace', ['Use new workspace: ' + str(suggestion),
                                             'Choose another directory', 'Return without changing existing data'])[0]
        if action == 2:
            raise SetupError('installation cancelled; existing workspace data was preserved')
        candidate = suggestion if action == 0 else Path(ask_text('New unused workspace directory')).expanduser().resolve()
        if candidate.exists():
            print('Choose an unused directory. Existing directories will not be cleared.', file=sys.stderr)
            continue
        base = candidate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--base-path', required=True)
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
        if sum(map(bool, (args.spec, args.select_model, args.wizard, args.batch_spec, args.workspace_check))) != 1:
            raise SetupError('choose exactly one of --spec, --batch-spec, --wizard or --select-model')
        if not math.isfinite(args.discovery_timeout) or args.discovery_timeout <= 0:
            raise SetupError('discovery timeout must be positive')
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
