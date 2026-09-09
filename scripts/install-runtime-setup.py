#!/usr/bin/env python3
"""Configure one operator-selected runtime; validate offline before publishing.

Python 3.8 stdlib only. --spec names a JSON file, never a credential value.
Configuration validation is not installation, authentication or inference proof.
"""
import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import subprocess
import tempfile
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler
from urllib.error import HTTPError, URLError

CHOICES = {
    'llama_cpp': ('openai-compatible-http', None),
    'vllm': ('openai-compatible-http', None),
    'openai_compatible': ('openai-compatible-http', None),
    'claude_code': ('claude-code', 'claude'),
    'codex': ('codex-app-server', 'codex'),
    'antigravity': ('antigravity-cli', 'agy'),
}
UNVERIFIED_CAPABILITIES = (
    'supports_tool_choice', 'supports_required_tool_choice', 'supports_named_tool_choice',
    'supports_parallel_tool_calls', 'supports_reasoning', 'supports_extended_thinking',
    'supports_response_format_json', 'supports_structured_output',
    'supports_multimodal_inputs', 'supports_image_input', 'supports_audio_input',
    'supports_video_input', 'supports_document_input',
    'supports_caching', 'supports_prompt_caching', 'supports_top_k', 'supports_min_p',
    'supports_seed', 'supports_computer_use', 'supports_code_execution',
)


class SetupError(Exception):
    pass


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
    provider = 'setup_' + choice
    model_key = provider + '_model'
    fields = {'display-name': choice, 'protocol': protocol}
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
        runtime += table(('providers', provider, 'healthcheck'), {'path': '/models'})
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
    runtime += table((provider, model_key), {'wizard-default': True})
    overlay = ''
    if default_command is None:
        caps = {'id_prefix': model, 'provider_name': provider, 'base': 'openai_chat',
                'max_context_tokens': context, 'supports_tools': spec['tools'],
                'supports_native_streaming': spec['streaming']}
        caps.update({key: False for key in UNVERIFIED_CAPABILITIES})
        caps.update(thinking_control_format='none', reasoning_streaming_format='none')
        overlay = table(('models',), caps, array=True)
        # Exact-output lanes resolve through this same provider/model pair.
        # A runtime binding alone is not an Agent Core target declaration.
        overlay += table(('providers',), {
            'id': provider, 'kind': 'openai_compat', 'base_url': endpoint,
            'request_path': '/chat/completions', 'api_key_env': spec.get('api_key_env', ''),
            'capabilities_base': 'openai_chat'}, array=True)
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


def configure(binary, base_path, spec):
    runtime_id, addition, overlay_addition = render(spec)
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
        contents = [originals[0][-1] + b'\n' + addition,
                    (originals[1][-1] if originals[1] else b'') + overlay_addition]
        with tempfile.TemporaryDirectory(prefix='masc-runtime-setup-') as stage:
            stage_config = Path(stage) / '.masc/config'
            stage_config.mkdir(parents=True)
            for path, content in zip(paths, contents):
                (stage_config / path.name).write_bytes(content)
            env = dict(os.environ, MASC_BASE_PATH=stage, MASC_CONFIG_DIR=str(stage_config))
            result = subprocess.run([str(Path(binary).resolve()), 'runtime-default-set',
                                     '--base-path', stage, runtime_id, '--setup-lanes'], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                diagnostic = result.stderr.decode(errors='replace').strip() or 'validator produced no stderr'
                raise SetupError('runtime validation failed; original configuration preserved:\n' + diagnostic)
            contents[0] = (stage_config / paths[0].name).read_bytes()
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
    return {'runtime_id': runtime_id, 'configured': True, 'validation': 'passed',
            'readiness': 'not_probed', 'model': spec['model'], 'choice': spec['choice']}


def positive_integer(value):
    return type(value) is int and value > 0


def model_text(value):
    return isinstance(value, str) and bool(value) and value == value.strip() and all(ord(c) >= 32 and ord(c) != 127 for c in value)


def discover_models(choice, endpoint='', api_key_env='', timeout=10):
    """Return observed IDs, not guessed names or inferred context capacities."""
    if choice == 'codex':
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
            origin = 'Installed MASC model catalog (account availability is checked after selection)'
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--base-path', required=True)
    parser.add_argument('--spec')
    parser.add_argument('--select-model', choices=CHOICES)
    parser.add_argument('--endpoint', default='')
    parser.add_argument('--credential-env', dest='api_key_env', default='')
    parser.add_argument('--discovery-timeout', type=float, default=10)
    args = parser.parse_args()
    try:
        if bool(args.spec) == bool(args.select_model):
            raise SetupError('choose exactly one of --spec or --select-model')
        if args.select_model:
            if not math.isfinite(args.discovery_timeout) or args.discovery_timeout <= 0:
                raise SetupError('discovery timeout must be positive')
            result = select_model(args.binary, args.select_model, args.endpoint, args.api_key_env, args.discovery_timeout)
        else:
            result = configure(args.binary, args.base_path, json.loads(Path(args.spec).read_text()))
        print(json.dumps(result, ensure_ascii=False))
    except (SetupError, OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit('runtime setup failed: ' + str(error))


if __name__ == '__main__':
    main()
