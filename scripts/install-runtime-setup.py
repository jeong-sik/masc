#!/usr/bin/env python3
"""Select runtime connections and validate them before publishing together.

Python 3.8 stdlib only. --spec names a JSON file, never a credential value.
The wizard requires real response/tool verification; --spec stays offline unless
--verify is supplied. Offline configuration validation is not inference proof.
"""
import argparse
import getpass
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


class SetupError(Exception):
    pass


class VerificationError(SetupError):
    def __init__(self, runtime_id, failure=None):
        self.runtime_id = runtime_id
        self.failure = failure if isinstance(failure, dict) else {}
        super().__init__('The selected model did not pass response and tool verification. Configuration was preserved.')


def native_setup_command(binary, command, payload=None, arguments=()):
    # The compiled renderer is the only identity authority. This helper handles
    # terminal interaction and private IPC; it never renders or edits TOML.
    if not binary:
        raise SetupError('Runtime setup requires the installed MASC executable')
    with tempfile.TemporaryDirectory(prefix='masc-setup-request-') as directory:
        argv = [str(binary), command] + list(arguments)
        if payload is not None:
            path = Path(directory) / 'request.json'
            atomic_write(path, json.dumps(payload, ensure_ascii=False, allow_nan=False).encode(), 0o600)
            argv += ['--spec' if command == 'runtime-setup-render' else '--request', str(path)]
        result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        receipt = json.loads(result.stdout)
    except (TypeError, ValueError):
        raise SetupError('MASC did not return a setup result. Inspect the workspace before retrying.')
    if not isinstance(receipt, dict):
        raise SetupError('MASC returned an invalid setup result')
    if result.returncode:
        if receipt.get('schema') == 'masc.runtime_setup_error.v1':
            if receipt.get('kind') == 'verification_failed' and model_text(receipt.get('runtime_id')):
                raise VerificationError(receipt['runtime_id'])
            if model_text(receipt.get('error')):
                raise SetupError(receipt['error'])
        raise SetupError('Runtime setup did not finish. Inspect the workspace before retrying.')
    return receipt


def text(spec, key):
    value = spec.get(key)
    if not isinstance(value, str) or not value or value != value.strip() or any(ord(c) < 32 for c in value):
        raise SetupError(key + ' must be a nonempty single-line string without surrounding whitespace')
    return value


def toml(value):
    return json.dumps(value, ensure_ascii=False)


def table(path, fields, array=False):
    header = '.'.join(toml(part) for part in path)
    return '\n' + ('[[' + header + ']]' if array else '[' + header + ']') + '\n' + ''.join(
        toml(key) + ' = ' + toml(value) + '\n' for key, value in fields.items())


def render(spec, binary=None):
    if not isinstance(spec, dict):
        raise SetupError('spec must be a JSON object')
    named = 'provider_id' in spec
    if named:
        choice = text(spec, 'choice')
        if choice not in CHOICES:
            raise SetupError('unsupported runtime choice')
        protocol, default_command = CHOICES[choice]
        if default_command is not None:
            raise SetupError('a named catalog provider is an HTTP connection')
        allowed = {'choice', 'model', 'max_context', 'tools', 'streaming',
                   'endpoint', 'api_key_env', 'credential_file', 'provider_kind', 'request_path',
                   'provider_id', 'provider_display_name', 'model_key', 'provider_declared',
                   'reasoning_effort', 'thinking_disable_encodable', 'wizard_default'}
        if set(spec) - allowed:
            raise SetupError('unexpected setup fields: ' + ', '.join(sorted(set(spec) - allowed)))
        model = text(spec, 'model')
        context = spec.get('max_context')
        if type(context) is not int or context <= 0:
            raise SetupError('max_context must be a positive integer supplied by the operator')
        for key in ('tools', 'streaming'):
            if type(spec.get(key)) is not bool:
                raise SetupError(key + ' must be an explicitly declared boolean')
        endpoint = text(spec, 'endpoint')
        try:
            url = urlsplit(endpoint)
            valid = url.scheme in ('http', 'https') and url.hostname and not (url.username or url.password or url.query or url.fragment)
            _ = url.port
        except ValueError:
            valid = False
        if not valid:
            raise SetupError('endpoint must be an HTTP(S) URL without embedded credentials, query or fragment')
        key = text(spec, 'api_key_env')
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key):
            raise SetupError('api_key_env must name an environment variable, not a credential value')
        provider = text(spec, 'provider_id')
        model_key = provider + '-' + text(spec, 'model_key')
        runtime = ''
        if spec.get('provider_declared') is not True:
            runtime += table(('providers', provider), {'display-name': text(spec, 'provider_display_name'),
                                                       'protocol': protocol, 'endpoint': endpoint})
            runtime += table(('providers', provider, 'healthcheck'),
                             {'path': '/api/tags' if choice == 'ollama' else '/models'})
            runtime += table(('providers', provider, 'credentials'), {'type': 'env', 'key': key})
        model_fields = {'api-name': model, 'tools-support': spec['tools'], 'streaming': spec['streaming']}
        if spec.get('reasoning_effort'):
            model_fields.update(**{'thinking-support': True, 'reasoning-effort': text(spec, 'reasoning_effort')})
        runtime += table(('models', model_key), model_fields)
        binding = {'wizard-default': True} if spec.get('wizard_default') is True else {}
        runtime += table((provider, model_key), binding)
        target = {'id': provider + '.' + model_key, 'provider_ref': provider, 'model_id': model}
        if spec.get('thinking_disable_encodable') is True:
            target['enable_thinking'] = False
        overlay = table(('targets',), target, array=True)
        return provider + '.' + model_key, runtime.encode(), overlay.encode()

    if not binary:
        raise SetupError('Runtime setup requires the installed MASC executable')
    rendered = native_setup_command(binary, 'runtime-setup-render', spec)
    if (not model_text(rendered.get('runtime_id'))
            or not isinstance(rendered.get('runtime_toml'), str)
            or not isinstance(rendered.get('model_overlay_toml'), str)):
        raise SetupError('MASC returned an invalid runtime specification')
    return rendered['runtime_id'], rendered['runtime_toml'].encode(), rendered['model_overlay_toml'].encode()


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
    inventory = native_setup_command(binary, 'runtime-setup-inventory',
                                     arguments=['--base-path', str(base_path)])
    if not isinstance(inventory.get('runtimes'), list) or not setup_revision(inventory.get('setup_revision')):
        raise SetupError('invalid workspace runtime inventory')
    ids = [row.get('id') for row in inventory['runtimes'] if isinstance(row, dict)]
    if len(ids) != len(inventory['runtimes']) or not all(model_text(value) for value in ids) or len(set(ids)) != len(ids):
        raise SetupError('invalid or duplicate workspace runtime identities')
    return inventory


def setup_revision(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def configure(binary, base_path, spec):
    return configure_many(binary, base_path, [spec])


def configure_many(binary, base_path, specs, selected_ids=None, verify=False, default_id=None,
                   expected_revision=None):
    if not isinstance(specs, list):
        raise SetupError('connections must be a list')
    if selected_ids is not None and (not isinstance(selected_ids, list) or not all(model_text(value) for value in selected_ids)):
        raise SetupError('runtime_ids must be a list of runtime identifiers')
    if default_id is not None and not model_text(default_id):
        raise SetupError('default_runtime_id must be a runtime identifier')
    if expected_revision is None:
        expected_revision = configured_inventory(binary, base_path)['setup_revision']
    if not setup_revision(expected_revision):
        raise SetupError('Refresh the connection list before saving')
    rendered = [render(spec, binary) for spec in specs]
    selected = list(dict.fromkeys(selected_ids if selected_ids is not None else [row[0] for row in rendered]))
    if not selected:
        raise SetupError('select at least one runtime')
    default_id = selected[0] if default_id is None else default_id
    if default_id not in selected:
        raise SetupError('the default must be one of the selected runtimes')
    selected = [default_id] + [value for value in selected if value != default_id]
    result = native_setup_command(binary, 'runtime-setup-batch', dict(
        connections=specs, runtime_ids=selected, default_runtime_id=default_id,
        expected_revision=expected_revision, verify=verify), arguments=['--base-path', str(base_path)])
    if (result.get('runtime_id') != default_id or result.get('runtime_ids') != selected
            or result.get('configured') is not True or result.get('validation') != 'passed'
            or result.get('readiness') != ('verified' if verify else 'not_probed')):
        raise SetupError('MASC did not confirm the selected configuration. Inspect the workspace before retrying.')
    return result


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
        # The binary's client catalog owns the window: its rows are verified
        # client metadata, so the wizard trusts the stated context as-is.
        return [dict(id=row['id'], label=row.get('label', row['id']), context=row['max_context'],
                     release=row.get('release'))
                for row in rows if isinstance(row, dict) and model_text(row.get('id'))
                and positive_integer(row.get('max_context'))]
    except (ValueError, KeyError, TypeError):
        return []


def model_slug(model_id):
    return re.sub(r'[^A-Za-z0-9-]+', '-', model_id).strip('-').lower()


def provider_catalog_models(binary, provider_id):
    """Curated rows for a named catalog provider, from the installed binary."""
    result = subprocess.run([binary, 'runtime-model-list', '--provider', provider_id],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        # A failed catalog read must not masquerade as "no curated models":
        # every later pick would be refused with a message about the catalog
        # instead of the actual failure.
        raise SetupError('runtime-model-list --provider ' + provider_id + ' failed: '
                         + (result.stderr.strip() or 'no diagnostics'))
    try:
        rows = json.loads(result.stdout)['models']
    except (ValueError, KeyError, TypeError):
        raise SetupError('runtime-model-list --provider ' + provider_id + ' returned an unreadable catalog')
    if not isinstance(rows, list):
        raise SetupError('runtime-model-list --provider ' + provider_id + ' returned an unreadable catalog')
    return [row for row in rows if isinstance(row, dict) and model_text(row.get('id'))]


def positive_integer(value):
    return type(value) is int and value > 0


def model_text(value):
    return isinstance(value, str) and bool(value) and value == value.strip() and all(ord(c) >= 32 and ord(c) != 127 for c in value)


def select_model(binary, choice, endpoint='', api_key_env='', timeout=10):
    def ask(label):
        print('? ' + label + ': ', end='', file=sys.stderr, flush=True)
        answer = sys.stdin.readline()
        if not answer or answer.strip().lower() == 'q':
            raise SetupError('model setup cancelled; run the installer again when you have the model settings')
        return answer.strip()
    # CLI clients answer only through the binary's client catalog; an empty
    # catalog offers nothing to guess from. HTTP connections use the native
    # discovery command, which owns the wire formats.
    if choice in ('codex', 'claude_code'):
        models = catalog_models(binary, choice)
        origin = ('Installed MASC model catalog (suggestions; model response is not yet verified)' if models
                  else 'Model list unavailable. Check account access, API credit or the running server, then refresh.')
    else:
        source = dict(choice=choice)
        if endpoint:
            source['endpoint'] = endpoint
        if api_key_env:
            source['api_key_env'] = api_key_env
        models, origin = native_discover_models(binary, source, timeout)
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
    """TTY arrows/Space picker with type-to-filter; numbered input for accessible/scripted terminals."""
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
            answer = ask_text('Numbers separated by commas; Enter selects marked choices or option 1; q cancels' if multiple else 'Number; Enter selects {}'.format(current + 1))
            if not answer:
                if not multiple:
                    return [current]
                if selected:
                    return sorted(selected)
                return [current]
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
    # The filter changes what is displayed, never the index space: selected
    # and current keep real indexes into labels, so a choice made under a
    # filter still names the same row after the filter is cleared.
    query = bytearray()
    try:
        tty.setcbreak(fd)
        while True:
            width, height = shutil.get_terminal_size()
            text_query = bytes(query).decode('utf-8', 'ignore')
            needle = text_query.strip().casefold()
            visible = [index for index, label in enumerate(labels)
                       if not needle or needle in terminal_text(label).casefold()]
            if visible and current not in visible:
                current = visible[0]
            position = visible.index(current) if current in visible else 0
            count = max(1, height - 6)
            start = min(max(0, position - count + 1), max(0, len(visible) - count))
            if drawn:
                print('\x1b[{}A'.format(drawn), end='', file=sys.stderr)
            hint = ('↑/↓ move · Space mark several · Enter choose · type to filter · Esc clears · Ctrl-C cancels' if multiple
                    else '↑/↓ move · Enter select · type to filter · Esc clears · Ctrl-C cancels')
            lines = [terminal_text(title), hint, 'Filter: ' + text_query]
            for slot in range(start, min(len(visible), start + count)):
                index = visible[slot]
                marker = '[x]' if index in selected else '[ ]'
                lines.append(('› ' if index == current else '  ') + (marker + ' ' if multiple else '') + terminal_text(labels[index]))
            if not visible:
                footer = 'no matches'
            elif multiple:
                footer = '{} selected · {}/{} shown'.format(len(selected), len(visible), len(labels))
            else:
                footer = '{}/{} shown'.format(len(visible), len(labels))
            lines.append(footer)
            # A narrower frame has fewer lines than the one before it. Pad
            # with cleared empties so exactly the previous frame's line count
            # is rewritten, or the rows that vanished stay on screen as ghost
            # rows (old markers, old footer and all).
            emitted = lines + [''] * max(0, drawn - len(lines))
            for line in emitted:
                print('\r\x1b[2K' + line[:max(1, width - 1)], file=sys.stderr)
            sys.stderr.flush()
            drawn = len(emitted)
            key = os.read(fd, 1)
            if not key:
                raise SetupError('terminal closed; existing connections were preserved')
            move = 0
            cancel = False
            if key == b'\x1b':
                # Escape sequences arrive separately on some terminals. Bound
                # only key decoding, never model execution or Keeper behavior.
                if select.select([fd], [], [], 0.1)[0]:
                    prefix = os.read(fd, 1)
                    if prefix == b'[' and select.select([fd], [], [], 0.1)[0]:
                        direction = os.read(fd, 1)
                        move = -1 if direction == b'A' else 1 if direction == b'B' else 0
                        key = b''
                    elif prefix:
                        # A byte arriving right after Esc is a keystroke of
                        # its own, not half of a sequence: clear the filter
                        # and process it instead of eating it.
                        del query[:]
                        key = prefix
                    else:
                        key = b''
                elif query:
                    del query[:]
                    key = b''
                else:
                    cancel = True
            # Every printable byte types into the query, q/j/k included: a
            # filter is ordinary text, and a model id can start with any
            # letter (qwen, kimi, janus). Movement is arrows only and cancel
            # is Ctrl-C/Ctrl-D, or Esc when nothing is typed.
            if cancel or key in (b'\x03', b'\x04'):
                raise SetupError('setup cancelled; existing connections were preserved')
            elif move:
                if len(visible) > 1:
                    current = visible[(position + move) % len(visible)]
            elif multiple and key == b' ':
                if current in visible:
                    selected.symmetric_difference_update([current])
            elif key in (b'\r', b'\n'):
                # An empty filter must not hand back a row the operator cannot
                # see; Enter waits for a match instead.
                if not visible:
                    continue
                if not multiple:
                    return [current]
                if selected:
                    return sorted(selected)
                return [current]
            elif key == b'\x7f':
                if query:
                    query.pop()
            elif len(key) == 1 and key >= b' ':
                # Space toggles in multiple mode, so a filter cannot contain a
                # space there; single mode types it. Bytes at 0x80 and above
                # are UTF-8 continuation bytes on their way into the query.
                query.extend(key)
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
        source = dict(provider_id=integration['id'], label=integration['display_name'],
                      choice=PROTOCOL_CHOICES.get(integration.get('protocol')),
                      endpoint=integration.get('endpoint') or '', command=integration.get('command') or '',
                      api_key_env=integration.get('api_key_env') or '',
                      credential_kind=integration.get('credential_kind', 'env' if integration.get('api_key_env') else 'none'),
                      credential_file=integration.get('credential_file'),
                      provider_kind=integration.get('provider_kind'), request_path=integration.get('request_path'),
                      origin=integration['origin'], setup_support=integration['setup_support'], rows=[])
        # A catalog-advertised new connection carries the provider's own name,
        # so the wizard renders a named provider instead of an anonymous one.
        # verification_support absent means an older binary that predates the
        # field; those rows were always response-tool verified.
        if (integration.get('setup_support') == 'new_connection'
                and integration.get('protocol') in PROTOCOL_CHOICES
                and integration.get('api_key_env') and integration.get('endpoint')
                and integration.get('verification_support', 'response_tool') == 'response_tool'):
            source['catalog_provider'] = dict(declared=integration.get('origin') == 'runtime_config')
        sources.append(source)
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
    for source in sources:
        source['model_release_catalog'] = inventory.get('model_release_catalog')
    return sources


def source_label(source):
    command, endpoint, key = source['command'], source['endpoint'], source['api_key_env']
    if source.get('setup_support') == 'unsupported':
        status = 'connection support not available yet'
    elif source.get('credential_file'):
        status = 'saved private API key; access will be checked'
    elif command:
        status = 'CLI found; sign-in checked after selection' if shutil.which(command) else 'CLI needs installation'
    elif key:
        status = 'API key found; account access will be checked' if os.environ.get(key) else 'API key needed; enter it privately after selection'
    else:
        status = endpoint or 'configured connection'
    return source['label'] + ' — ' + status


class PendingCredentials:
    """Own new private references until their selected configuration may be committed."""
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


def antigravity_context(binary, source, model_id):
    print('Reading the selected Antigravity model’s context window…', file=sys.stderr)
    response = subprocess.run([str(binary), 'runtime-antigravity-context', '--cli-path', source['command'],
                               '--credential-file', source['credential_file'], '--model', model_id],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        observed = json.loads(response.stdout)
        if response.returncode:
            if observed.get('schema') == 'masc.antigravity_setup_error.v1' and isinstance(observed.get('error'), str):
                raise SetupError(terminal_text(observed['error']))
            raise ValueError('invalid error')
        context = observed['context']
        if (observed.get('source') != 'antigravity_statusline' or observed.get('model') != model_id
                or observed.get('invocation_verified') is not False
                or context is not None and not positive_integer(context)):
            raise ValueError('invalid context')
        return context
    except (KeyError, TypeError, ValueError):
        raise SetupError('Antigravity did not return a valid context for the selected model')


class SetupSessionFinished(Exception):
    """The selected group session finished; the old-group parent must exit."""


def docker_account_actions(binary):
    result = subprocess.run([str(binary), 'docker-account-access'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        catalog = json.loads(result.stdout)
        if (result.returncode or catalog.get('schema') != 'masc.docker_account_actions.v1'
                or not isinstance(catalog.get('actions'), list)):
            raise ValueError('invalid actions')
        return [dict(row, account_action=True) for row in catalog['actions']]
    except (TypeError, ValueError):
        raise SetupError('MASC could not inspect this account’s Docker access')


def docker_account_action(binary, base_path, port, action):
    # Native handoff redirects the child journey to the terminal; stdout remains
    # its own typed outcome, never mixed with the child's interactive output.
    result = subprocess.run([str(binary), 'docker-account-access', '--execute', action,
                             '--base-path', str(base_path), '--port', str(port)],
                            stdout=subprocess.PIPE, text=True)
    try:
        receipt = json.loads(result.stdout)
        if (receipt.get('schema') != 'masc.docker_account_action_result.v1'
                or receipt.get('readiness') != 'not_checked'):
            raise ValueError('invalid result')
        state = receipt['status']
        if state not in ('failed', 'recheck_required', 'session_finished', 'reauthentication_required'):
            raise ValueError('unknown result')
        if state == 'session_finished' and result.returncode == 0:
            raise SetupSessionFinished()
        if state == 'failed' or state == 'reauthentication_required' or result.returncode:
            reason = receipt.get('reason')
            print(terminal_text(reason) if isinstance(reason, str) and reason.strip()
                  else 'Docker account setup did not complete. Saved model choices are kept; retry when ready.', file=sys.stderr)
        else:
            print('Account access updated. Choose Continue saved setup to enter the new group session.', file=sys.stderr)
    except (KeyError, TypeError, ValueError):
        raise SetupError('Docker account setup did not return a valid result; recheck account access')
    return True


def decode_pdf_tools_readiness(value):
    if (not isinstance(value, dict) or value.get('schema') != 'masc.pdf_tools_readiness.v1'
            or value.get('status') not in ('tools_available', 'unavailable')
            or value.get('pdf_inspection') != 'not_run'
            or value.get('scope') != 'current_process_environment'):
        raise SetupError('MASC returned unreadable PDF tool readiness')
    checks = value.get('checks')
    if (not isinstance(checks, list) or len(checks) != 2
            or any(not isinstance(row, dict) or row.get('status') not in ('missing', 'started', 'failed')
                   or row.get('command') not in ('pdftotext', 'pdftoppm') for row in checks)
            or {row.get('command') for row in checks} != {'pdftotext', 'pdftoppm'}):
        raise SetupError('MASC did not check both PDF inspection tools')
    started = all(row['status'] == 'started' for row in checks)
    if started != (value['status'] == 'tools_available'):
        raise SetupError('MASC returned inconsistent PDF tool readiness')
    return value


def pdf_tools_status(binary):
    result = subprocess.run([str(binary), 'prerequisite-actions', 'pdf-tools'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        catalog = json.loads(result.stdout)
        if result.returncode or not isinstance(catalog, dict) or catalog.get('schema') != 'masc.prerequisite_actions.v1':
            raise ValueError('invalid catalog')
        return decode_pdf_tools_readiness(catalog.get('dependency_readiness'))
    except (ValueError, TypeError):
        raise SetupError('MASC could not inspect PDF tool availability')


def decode_presentation_tools_readiness(value, base_path=None):
    if (not isinstance(value, dict) or value.get('schema') != 'masc.presentation_tools_readiness.v1'
            or value.get('status') not in ('tools_available', 'unavailable')
            or value.get('presentation_inspection') != 'not_run'
            or value.get('scope') != 'workspace_host_runtime'
            or not isinstance(value.get('base_path'), str) or not value['base_path']):
        raise SetupError('MASC returned unreadable presentation tool readiness')
    if base_path is not None and Path(value['base_path']).resolve() != Path(base_path).resolve():
        raise SetupError('MASC checked presentation tools for another workspace')
    checks = value.get('checks')
    if (not isinstance(checks, list) or len(checks) != 2
            or any(not isinstance(row, dict) or row.get('status') not in ('missing', 'started', 'failed')
                   or not isinstance(row.get('command'), str) for row in checks)
            or {row.get('component') for row in checks} != {'python_pptx', 'libreoffice'}):
        raise SetupError('MASC did not check both presentation dependencies')
    if all(row['status'] == 'started' for row in checks) != (value['status'] == 'tools_available'):
        raise SetupError('MASC returned inconsistent presentation readiness')
    return value


def presentation_tools_status(binary, base_path):
    result = subprocess.run([str(binary), 'prerequisite-actions', 'presentation-tools',
                             '--base-path', str(base_path)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        catalog = json.loads(result.stdout)
        if result.returncode or not isinstance(catalog, dict) or catalog.get('schema') != 'masc.prerequisite_actions.v1':
            raise ValueError('invalid catalog')
        return decode_presentation_tools_readiness(catalog.get('dependency_readiness'), base_path)
    except (ValueError, TypeError):
        raise SetupError('MASC could not inspect presentation tool availability')


def show_presentation_readiness(readiness):
    print('Presentation tools are available on this workspace host; document inspection has not run.'
          if readiness['status'] == 'tools_available' else
          'Presentation tools are not ready on this workspace host. Install the missing dependencies and refresh detection.',
          file=sys.stderr)
    for row in readiness['checks']:
        print(terminal_text(row['component']) + ': ' + terminal_text(row['status'])
              + ' (' + terminal_text(row['command']) + ')', file=sys.stderr)
        detail = row.get('detail') or row.get('output')
        if detail:
            print(terminal_text(detail), file=sys.stderr)


def prerequisite_menu(binary, dependency, base_path=None, port=8945):
    if dependency == 'presentation-tools' and base_path is None:
        raise SetupError('Presentation setup requires the selected workspace')
    workspace_args = ['--base-path', str(base_path)] if dependency == 'presentation-tools' else []
    result = subprocess.run([str(binary), 'prerequisite-actions', dependency] + workspace_args,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        catalog = json.loads(result.stdout)
        if result.returncode or catalog.get('schema') != 'masc.prerequisite_actions.v1' or not isinstance(catalog.get('actions'), list):
            raise ValueError('invalid actions')
    except (TypeError, ValueError):
        raise SetupError('MASC could not inspect installation actions for this computer')
    actions = catalog['actions']
    if dependency == 'pdf-tools':
        pdf = decode_pdf_tools_readiness(catalog.get('dependency_readiness'))
        if pdf['status'] == 'tools_available':
            print('PDF inspection tools are available. Original PDF inspection runs when a document is read.', file=sys.stderr)
        else:
            print('PDF inspection is unavailable. Install the tools below, then refresh detection.', file=sys.stderr)
        for row in pdf['checks']:
            print(terminal_text(row['command']) + ': ' + terminal_text(row['status']), file=sys.stderr)
        if pdf['status'] == 'tools_available':
            return True
        if not actions:
            print('No automatic installation action is available on this host. Install Poppler through your operating system, then refresh detection.', file=sys.stderr)
    if dependency == 'presentation-tools':
        presentation = decode_presentation_tools_readiness(catalog.get('dependency_readiness'), base_path)
        show_presentation_readiness(presentation)
        if presentation['status'] == 'tools_available':
            return True
        if not actions:
            print('No automatic presentation installation action is available on this host.', file=sys.stderr)
    if dependency == 'docker' and base_path is not None:
        account_actions = docker_account_actions(binary)
        for row in account_actions:
            print(terminal_text(row['detail']), file=sys.stderr)
        actions = account_actions + actions
    labels = [row['label'] + (' · administrator permission' if row['requires_admin'] else '') for row in actions]
    choice = pick('Install or start the selected prerequisite', labels + ['Refresh detection', 'Back to setup choices'])[0]
    if choice == len(actions) + 1:
        return False
    if choice == len(actions):
        return True
    selected = actions[choice]
    print(terminal_text(selected['detail']), file=sys.stderr)
    print('Source: ' + terminal_text(selected['source_url']), file=sys.stderr)
    if selected.get('account_action'):
        return docker_account_action(binary, base_path, port, selected['id'])
    # The selected native action owns commands and privilege boundaries. Child
    # password prompts and vendor output keep the terminal, not a hidden pipe.
    result = subprocess.run([str(binary), 'prerequisite-actions', dependency, '--execute', selected['id']] + workspace_args,
                            stdout=subprocess.PIPE, text=True)
    try:
        receipt = json.loads(result.stdout)
        if receipt.get('schema') != 'masc.prerequisite_action_result.v1':
            raise ValueError('invalid result')
        state = receipt['status']
        if dependency == 'pdf-tools' and receipt.get('readiness') in ('tools_available', 'unavailable'):
            pdf = decode_pdf_tools_readiness(receipt.get('dependency_readiness'))
            if receipt['readiness'] != pdf['status']:
                raise ValueError('inconsistent PDF recheck')
            if state == 'commands_completed' and pdf['status'] != 'tools_available':
                raise ValueError('PDF tools were not available after installation')
        elif dependency == 'presentation-tools':
            presentation = decode_presentation_tools_readiness(receipt.get('dependency_readiness'), base_path)
            if receipt.get('readiness') != presentation['status']:
                raise ValueError('inconsistent presentation recheck')
            if state == 'commands_completed' and presentation['status'] != 'tools_available':
                raise ValueError('presentation installation was not ready')
        elif receipt.get('readiness') != 'not_checked':
            raise ValueError('invalid readiness')
        if dependency == 'pdf-tools' and state == 'commands_completed' and receipt.get('readiness') != 'tools_available':
            raise ValueError('PDF installation was not rechecked')
    except (KeyError, TypeError, ValueError):
        raise SetupError('Installation action did not return a readable result; recheck the prerequisite')
    if dependency == 'presentation-tools':
        show_presentation_readiness(presentation)
    if state == 'failed' or result.returncode:
        reason = receipt.get('reason')
        if isinstance(reason, str) and reason.strip():
            print(terminal_text(reason), file=sys.stderr)
        else:
            print('The selected step did not finish. Check its terminal output and retry when ready.', file=sys.stderr)
    elif dependency == 'presentation-tools' and state == 'commands_completed':
        print('Both presentation dependencies started successfully. This does not assert a document inspection.', file=sys.stderr)
    elif dependency == 'presentation-tools' and state == 'commands_completed_recheck_required':
        print('The selected presentation component is ready. Install the remaining component shown above, then refresh detection.', file=sys.stderr)
    elif dependency == 'pdf-tools' and state == 'commands_completed':
        print('PDF tools installed and both commands started successfully. Original PDF inspection runs when a document is read.', file=sys.stderr)
    elif state == 'external_step_pending':
        print('Complete the vendor installation window, then choose Refresh detection.', file=sys.stderr)
    elif state == 'commands_completed_recheck_required':
        print('The installation step finished. Checking the service and account access next.', file=sys.stderr)
    else:
        raise SetupError('MASC returned an unknown installation state')
    return True


def installed_client(command, choice):
    found = shutil.which(command)
    if found:
        return found
    standard = {'codex': 'codex', 'claude_code': 'claude', 'antigravity': 'agy'}.get(choice)
    if standard is None or command != standard:
        return None  # An explicit custom executable path is not a vendor alias.
    directory = (os.environ.get('CODEX_INSTALL_DIR') if choice == 'codex' else None) or str(Path.home() / '.local/bin')
    candidate = Path(directory) / standard
    return str(candidate.resolve()) if candidate.is_file() and os.access(candidate, os.X_OK) else None


def prepare_connection(source, credentials):
    source = dict(source)
    if source.get('setup_support') == 'unsupported' or source['choice'] is None:
        raise SetupError(source['label'] + ' is listed for visibility but its setup integration is not available yet')
    if CHOICES[source['choice']][1] is not None:
        command = source.get('command') or CHOICES[source['choice']][1]
        while not installed_client(command, source['choice']):
            client = {'claude_code': 'claude-code', 'codex': 'codex', 'antigravity': 'antigravity'}.get(source['choice'])
            if credentials is None or client is None or not prerequisite_menu(credentials.binary, client):
                raise SetupError('Install the selected client, then return to connection setup')
        source['command'] = installed_client(command, source['choice'])
        if source['choice'] == 'antigravity':
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


def refresh_codex_models(binary, source):
    result = subprocess.run([str(binary), 'runtime-codex-models', '--cli-path', source.get('command') or 'codex'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise SetupError('Codex online model refresh unavailable; using cached or bundled metadata.')
    try:
        receipt = json.loads(result.stdout)
        if (receipt.get('schema') != 'masc.codex_model_refresh.v1'
                or receipt.get('source') not in ('isolated_cli_cache', 'cli_list_without_context_cache')
                or not isinstance(receipt.get('models'), list)):
            raise ValueError('invalid refresh')
        rows = receipt['models']
        for row in rows:
            if (not isinstance(row, dict) or not model_text(row.get('id')) or not model_text(row.get('label'))
                    or (row.get('context') is not None and not positive_integer(row['context']))):
                raise ValueError('invalid model')
        source_text = ('Codex refreshed model list and isolated CLI context cache' if receipt['source'] == 'isolated_cli_cache'
                       else 'Codex model list without refreshed context; offline or bundled metadata may be in use')
        return rows, source_text
    except (ValueError, TypeError, KeyError):
        raise SetupError('Codex refresh returned invalid metadata; using cached or bundled metadata.')


def release_metadata(source, model_id):
    # Transport compatibility does not establish model publisher identity.
    publisher = None
    if source.get('provider_kind') == 'glm':
        publisher = 'zai'
    elif not source.get('endpoint') and not source.get('provider_kind'):
        publisher = {'codex': 'openai', 'claude_code': 'anthropic'}.get(source.get('choice'))
    catalog = source.get('model_release_catalog')
    if not publisher or not isinstance(catalog, dict) or catalog.get('schema') != 'masc.model_release_catalog.v1':
        return None
    matches = [row.get('release') for row in catalog.get('models', [])
               if isinstance(row, dict) and row.get('publisher') == publisher and row.get('model_id') == model_id]
    return matches[0] if len(matches) == 1 else None


def recently_released(model):
    evidence = model.get('release')
    return (isinstance(evidence, dict) and evidence.get('status') == 'official_release'
            and evidence.get('recency') == 'within_three_calendar_months'
            and evidence.get('kind') == 'general_availability')


def model_choice_label(model):
    evidence = model.get('release')
    label = model['label'] + (' — existing connection' if model.get('existing') else '')
    if not isinstance(evidence, dict) or evidence.get('status') != 'official_release':
        return label + ' — release date unknown'
    released = evidence.get('released_on')
    kind = {'general_availability': 'released', 'limited_release': 'limited release', 'preview': 'preview'}.get(evidence.get('kind'))
    if not model_text(released) or not kind:
        return label + ' — release date unknown'
    suffix = ' · recent release' if recently_released(model) else ''
    return label + ' — ' + kind + ' ' + released + suffix


def source_models(binary, source, timeout, refresh=False):
    """One source's model list: discovery belongs to the native runtime;
    curated catalog rows lead, workspace bindings are matched onto the rest."""
    choice = source.get('choice')
    if refresh and choice == 'codex':
        try:
            observed, origin = refresh_codex_models(binary, source)
        except SetupError as error:
            observed = catalog_models(binary, choice)
            fallback = ('Installed MASC model catalog (suggestions; model response is not yet verified)' if observed
                        else 'Model list unavailable. Check account access, API credit or the running server, then refresh.')
            origin = str(error) + ' ' + fallback
    elif choice == 'antigravity' and source.get('credential_file'):
        observed, origin = antigravity_models(binary, source), 'Models from the selected Antigravity account'
    elif choice in ('codex', 'claude_code'):
        # CLI clients answer through the binary's client catalog; the wizard
        # never drives the vendor CLI directly.
        observed = catalog_models(binary, choice)
        origin = ('Installed MASC model catalog (suggestions; model response is not yet verified)' if observed
                  else 'Model list unavailable. Check account access, API credit or the running server, then refresh.')
    else:
        can_discover = choice and (source.get('credential_kind', 'none') in ('none', 'env') or source.get('credential_file'))
        observed, origin = native_discover_models(binary, source, timeout) if can_discover else ([], 'Configured models')

    rows = []
    curated = provider_catalog_models(binary, source['provider_id']) if source.get('catalog_provider') and source.get('provider_id') else []
    curated_ids = set()
    if curated:
        # A named catalog source leads with its curated rows: they carry the
        # context, efforts and capabilities the runtime entry needs. Served
        # ids the catalog does not curate still list below, uncurated.
        curated_ids = {row['id'] for row in curated}
        for row in curated:
            discovered = next((item for item in observed if item['id'] == row['id']), None)
            context = (discovered['context'] if discovered and positive_integer(discovered.get('context'))
                       else row.get('max_context'))
            rows.append(dict(id=row['id'], label=row.get('label') or row['id'],
                             context=context, existing=None, catalog=row))
    # An account switch invalidates both membership and effective CLI context.
    declared_rows = [] if choice == 'antigravity' and source.get('credential_replaced') else source['rows']
    for model in observed:
        if model['id'] in curated_ids:
            continue
        existing_rows = [row for row in declared_rows if row['model'] == model['id']]
        # A workspace declaration is relevant only in this exact connection.
        if existing_rows:
            for existing in existing_rows:
                context = model['context'] or existing['max_context']
                label = model['label'] + (' — ' + existing['id'] if len(existing_rows) > 1 else '')
                rows.append(dict(model, label=label, context=context,
                                 existing=None if source.get('credential_replaced') else existing))
        else:
            rows.append(dict(model, existing=None))
    for row in declared_rows:
        if source.get('credential_replaced') and any(item['id'] == row['model'] for item in rows):
            continue
        if not any(item.get('existing', {}).get('id') == row['id'] for item in rows if item.get('existing')):
            duplicates = sum(other['model'] == row['model'] for other in declared_rows) > 1
            label = row['model'] + (' — ' + row['id'] if duplicates else '')
            rows.append(dict(id=row['model'], label=label, context=row['max_context'],
                             existing=None if source.get('credential_replaced') else row))
    for row in rows:
        # Rejoin even catalog suggestions through this connection's publisher;
        # never retain evidence from an unrelated transport-compatible source.
        row['release'] = release_metadata(source, row['id'])
    rows.sort(key=lambda row: (not bool(row.get('existing')), not recently_released(row)))
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
    if source.get('catalog_provider'):
        # A named catalog source writes named provider sections that resolve
        # against the installed catalog. A served id the catalog does not
        # curate cannot resolve an exact-output target, so it is refused here
        # rather than written as a binding that quietly cannot dispatch.
        catalog = model.get('catalog')
        if not catalog:
            raise SetupError(model['id'] + ' is not in the installed catalog for this provider; '
                             'choose a curated model or use "Add another server URL" for arbitrary endpoints')
        if not positive_integer(catalog.get('max_context')):
            raise SetupError(model['id'] + ' declares no context in the installed catalog')
        if catalog.get('supports_tools') is not True:
            # Refuse early with the real reason: a toolless row would pass
            # configuration and only fail live verification later.
            raise SetupError(model['id'] + ' declares no tool support in the installed catalog; '
                             'select a tool-capable model')
        spec = dict(choice=choice, model=model['id'], max_context=catalog['max_context'],
                    tools=catalog.get('supports_tools') is True,
                    streaming=catalog.get('supports_streaming') is True,
                    endpoint=source['endpoint'], api_key_env=source['api_key_env'],
                    provider_id=source['provider_id'], provider_display_name=source['label'],
                    model_key=model_slug(model['id']),
                    provider_declared=source['catalog_provider'].get('declared') is True,
                    thinking_disable_encodable='none' in (catalog.get('accepted_reasoning_efforts') or []))
        if catalog.get('default_reasoning_effort'):
            spec['reasoning_effort'] = catalog['default_reasoning_effort']
        return render(spec, binary)[0], spec
    context = model.get('context')
    if choice == 'antigravity' and binary:
        context = antigravity_context(binary, source, model['id'])
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
        details = native_serving_context(binary, source, model['id'], timeout, load=True)
        if details['tools'] is False:
            raise SetupError('this Ollama model reports no tool support; select a tool-capable model for imp')
        context = details['context']
    elif choice in ('llama_cpp', 'openai_compatible') and context is None:
        try:
            context = native_serving_context(binary, source, model['id'], timeout)['context']
        except SetupError:
            context = None
    if not positive_integer(context):
        action = pick('The server did not report its configured context window.',
                      ['Return to model selection', 'Advanced: enter the documented server limit'])[0]
        if action == 0:
            raise SetupError('select another model or refresh after configuring its server context window')
        while not positive_integer(context):
            answer = ask_text('Configured context tokens (for example, 8192 only if your server declares that limit)')
            context = int(answer) if answer.isascii() and answer.isdigit() else None
    spec = dict(choice=choice, model=model['id'], max_context=context, tools=True,
                streaming=choice in ('claude_code', 'codex', 'antigravity'))
    if CHOICES[choice][1] is None:
        spec.update(endpoint=source['endpoint'])
        spec.update({key: source[key] for key in ('api_key_env', 'credential_file', 'provider_kind', 'request_path') if source.get(key)})
    elif source['command']:
        spec['command'] = source['command']
    if choice == 'antigravity':
        spec.update(credential_file=source['credential_file'], timeout_s=source['provider_timeout_s'])
    return render(spec, binary)[0], spec


def pick_connection_sources(sources):
    def detected(source):
        return (source.get('setup_support') != 'unsupported' and source.get('choice') is not None
                and (bool(source.get('command') and shutil.which(source['command']))
                     or bool(source.get('credential_file'))
                     or bool(source.get('api_key_env') and os.environ.get(source['api_key_env']))))
    found = [source for source in sources if detected(source)]
    show_all = not found
    while True:
        shown = sources if show_all else found
        labels = [source_label(source) for source in shown] + ['Add another server URL', 'Configure later']
        if not show_all:
            labels.append('Browse all providers and advanced connections')
        title = 'Choose connections' if show_all else 'Fast setup · clients and account keys found on this computer'
        chosen = pick(title + ' (Space marks several; Enter chooses)', labels, multiple=True)
        if not show_all and len(shown) + 2 in chosen:
            if len(chosen) != 1:
                print('Choose Browse all on its own, or select the connections to use.', file=sys.stderr)
                continue
            show_all = True
            continue
        return shown, chosen


def select_connections(binary, inventory, timeout, credentials=None):
    sources, chosen = pick_connection_sources(connection_sources(inventory))
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
        refresh_models = False
        while True:
            models, origin = source_models(binary, source, timeout, refresh=refresh_models)
            refresh_models = False
            print(terminal_text(origin) + '\nListed models are checked with a real response and tool call before saving.', file=sys.stderr)
            options = [model_choice_label(item) for item in models]
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
                    refresh_models = True
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


def login_command(binary, runtime_id, specs, inventory):
    spec = next((spec for spec in specs if render(spec, binary)[0] == runtime_id), None)
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
                    active_specs = [spec for spec in specs if render(spec, binary)[0] in ordered]
                    # Once the effectful native child starts, loss of its receipt
                    # cannot prove that it did not commit. Keep selected private
                    # credentials before crossing that process boundary.
                    credentials.retain(active_specs)
                    result = configure_many(binary, base_path, active_specs, ordered, verify=True,
                                            expected_revision=inventory['setup_revision'])
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
                    login = login_command(binary, error.runtime_id, specs, inventory)
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
                # Leaving after a failed save is not the operator deferring the
                # step: nothing was written, so the caller must not report a
                # saved workspace or a successful exit.
                return dict(configured=False, readiness='failed', base_path=str(base_path))


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
        print('This workspace contains state that this version cannot open. This preflight check made no changes; earlier upgrade backups remain available.', file=sys.stderr)
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


def workspace_port(binary, base_path, requested=None, save=False):
    argv = [str(binary), 'workspace-connection', '--base-path', str(base_path)]
    if requested is not None:
        argv += ['--port', str(requested)]
    if save:
        argv += ['--save']
    response = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        observed = json.loads(response.stdout)
        if (response.returncode or observed.get('schema') != 'masc.workspace_connection.v1'
                or observed.get('readiness') != 'not_checked'
                or not positive_integer(observed.get('port')) or observed['port'] > 65535):
            raise ValueError('invalid connection')
        return observed['port']
    except (KeyError, TypeError, ValueError):
        raise SetupError('The workspace HTTP port could not be resolved or saved. Check connection.toml or supply --port.')


def select_setup_server(binary, base_path, port, require_new_owner=False, resume_existing=False):
    while True:
        response = subprocess.run([str(binary), 'setup-server', '--base-path', str(base_path), '--port', str(port)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            observed = json.loads(response.stdout)
            if response.returncode or observed.get('schema') != 'masc.setup_server.v1' or observed.get('read_only') is not True:
                raise ValueError('invalid server observation')
        except (TypeError, ValueError):
            raise SetupError('The setup port could not be inspected. Existing servers were preserved.')
        state = observed.get('status')
        if state == 'free':
            return port
        if state == 'same_workspace':
            server_version = observed['server_version']
            if resume_existing and not require_new_owner and server_version == observed['installed_version']:
                return port
            choices = [('use', 'Continue with this running workspace'),
                       ('stop', 'Stop this server gracefully and continue setup with the installed MASC'),
                       ('later', 'Finish later')]
            if require_new_owner:
                print('This terminal has refreshed Docker access. The existing server keeps its earlier account groups; restart it to prepare the sandbox in this session.', file=sys.stderr)
                choices = [('stop', 'Restart this workspace server with the refreshed Docker access'),
                           ('later', 'Finish later and keep the existing server')]
            elif server_version != observed['installed_version']:
                choices[0], choices[1] = choices[1], choices[0]
            selected = choices[pick('Workspace server ' + server_version + ' · installed MASC ' + observed['installed_version'],
                                    [label for _, label in choices])[0]][0]
            if selected == 'use':
                return port
            if selected == 'later':
                raise SetupError('setup paused; the existing workspace server was preserved')
            result = subprocess.run([str(binary), 'setup-stop-previous-owner', '--base-path', str(base_path),
                                     '--port', str(port), '--expected-version', server_version],
                                    stdout=subprocess.PIPE, text=True)
            try:
                receipt = json.loads(result.stdout)
                if result.returncode:
                    if receipt.get('schema') == 'masc.setup_server_error.v1':
                        print(terminal_text(receipt['error']), file=sys.stderr)
                        return None
                    raise ValueError('invalid error')
                if receipt.get('schema') != 'masc.setup_server_stopped.v1' or receipt.get('owner_stopped') is not True:
                    raise ValueError('invalid shutdown receipt')
            except (TypeError, KeyError, ValueError):
                raise SetupError('The server shutdown result was not confirmed. Inspect the workspace before retrying.')
            if receipt.get('port_available') is True:
                return port
            continue  # server or port might have changed during graceful drain
        if state not in ('other_workspace', 'unknown_server'):
            raise SetupError('MASC returned an unknown server observation')
        if state == 'other_workspace':
            print('Port ' + str(port) + ' belongs to ' + terminal_text(observed['server_workspace']), file=sys.stderr)
        else:
            print('Another service is using port ' + str(port), file=sys.stderr)
        suggested = observed.get('suggested_port')
        if not positive_integer(suggested) or suggested > 65535:
            raise SetupError('MASC could not find an unused local port')
        if pick('Choose this workspace’s port', ['Use available port ' + str(suggested), 'Finish later'])[0]:
            raise SetupError('setup paused; existing services were preserved')
        port = suggested
def select_sandbox(binary, base_path, port=8945):
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
        try:
            pdf = pdf_tools_status(binary)
            pdf_label = ('PDF document inspection · tools available' if pdf['status'] == 'tools_available'
                         else 'PDF document inspection · install missing tools')
        except SetupError:
            pdf_label = 'PDF document inspection · could not check tools'
        try:
            presentation = presentation_tools_status(binary, base_path)
            presentation_label = ('Presentation tools · available on workspace host' if presentation['status'] == 'tools_available'
                                  else 'Presentation tools · install missing dependencies')
        except SetupError:
            presentation_label = 'Presentation tools · could not check dependencies'
        action = pick('4 · Prepare imp’s workspace', labels + [
            'Refresh after installing or starting a service',
            'Show common choices' if advanced else 'Advanced sandbox choices', pdf_label, presentation_label, 'Finish later'])[0]
        if action == len(rows):
            continue
        if action == len(rows) + 1:
            advanced = not advanced
            continue
        if action == len(rows) + 2:
            prerequisite_menu(binary, 'pdf-tools', base_path=base_path, port=port)
            continue
        if action == len(rows) + 3:
            prerequisite_menu(binary, 'presentation-tools', base_path=base_path, port=port)
            continue
        if action == len(rows) + 4:
            return None
        row = rows[action]
        if row['state'] != 'service_ready':
            print(terminal_text(row['reason']), file=sys.stderr)
            prerequisite_menu(binary, row['id'], base_path=base_path, port=port)
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


def local_voices(binary):
    """The voices this machine has, as `say` prints them.

    The list is not a convenience. `say` does not fail on a voice it does not
    have -- it exits 0 and speaks in the system voice -- so a name typed from
    memory is silently a different voice, and a name that exists in several
    languages picks one of them. Measured on macOS 26: "Eddy" read Korean in
    English at 4.7KB where "Eddy (한국어(한국))" gave 72KB.
    """
    result = subprocess.run([str(binary), 'voice-local-setup', '--list-voices'],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if result.returncode != 0 or not result.stdout:
        return []
    try:
        listing = json.loads(result.stdout)
    except ValueError:
        return []
    voices = listing.get('voices')
    return voices if isinstance(voices, list) else []


def whisper_model_path(binary):
    """Where the prerequisite catalog puts the model, read from the catalog.

    The voice section has to name the file the download actually wrote, so the
    path is taken from the action that writes it rather than spelled twice.
    A computer whose catalog only links the downloads page has no such action,
    and the reader is asked for the path instead.
    """
    result = subprocess.run([str(binary), 'prerequisite-actions', 'whisper'],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if result.returncode != 0 or not result.stdout:
        return None
    try:
        catalog = json.loads(result.stdout)
    except ValueError:
        return None
    for action in catalog.get('actions') or []:
        effect = action.get('effect') or {}
        for step in effect.get('argv_steps') or []:
            if not isinstance(step, list) or '-o' not in step:
                continue
            destination = step.index('-o') + 1
            if destination < len(step):
                return step[destination]
    return None


def preferred_language():
    for name in ('LC_ALL', 'LC_MESSAGES', 'LANG'):
        value = os.environ.get(name)
        if value and value not in ('C', 'POSIX'):
            return value.split('.')[0].split('_')[0].lower()
    return 'en'


def select_local_voice(binary, base):
    """Ask for a voice, and never take the journey down with it.

    An optional step cannot fail the thing it is optional to. By the time this
    runs the workspace is initialized and the model connection is saved, and
    the sandbox step is still ahead, so a cancel here means "not this" rather
    than "abandon setup" -- which is what it meant before, complete with a
    `runtime setup failed` line about a step nobody had to take.
    """
    try:
        ask_local_voice(binary, base)
    except SetupError as error:
        print(terminal_text(str(error)) + '\nContinuing without voice. '
              'Run masc voice-local-setup to turn it on later.', file=sys.stderr)


def ask_local_voice(binary, base):
    """Turn on voice, which on a fresh mac needs nothing downloaded to speak.

    `say` is in the base system and runs once per utterance, so speaking is a
    setting rather than a service: there is no port, no process to keep alive
    and nothing to install. Hearing needs whisper-cli and a model, which is
    why it is asked separately and only after the answer to the first is yes.
    """
    voices = local_voices(binary)
    if not voices:
        # Not an error to report: a computer whose `say` publishes no
        # catalogue has no voice to offer, and the journey continues.
        return
    language = preferred_language()
    mine = [voice for voice in voices if str(voice.get('language', '')).lower().startswith(language)]
    shortlist = mine or voices[:12]
    while True:
        labels = [terminal_text(voice.get('name') or voice.get('id')) + ' — ' + terminal_text(voice.get('language', ''))
                  for voice in shortlist]
        extra = ['Show every voice on this computer ({})'.format(len(voices))] if len(shortlist) < len(voices) else []
        choice = pick('3 · Give imp a voice (optional)', labels + extra + ['Stay text only'])[0]
        if choice == len(labels) + len(extra):
            return
        if extra and choice == len(labels):
            shortlist = voices
            continue
        voice = shortlist[choice]
        break
    arguments = ['--voice', voice.get('id')]
    # Hearing is the half that needs a download, so it is a separate question
    # rather than a consequence of answering the first one.
    if pick('Let imp hear you too? whisper-cli transcribes locally; the model it reads is 1.6GB.',
            ['Speak to imp as well', 'Speaking only for now'])[0] == 0:
        while prerequisite_menu(binary, 'whisper'):
            pass
        model = whisper_model_path(binary)
        if model is None:
            model = ask_text('Path to the whisper model file')
        if model and Path(model).is_file() and shutil.which('whisper-cli'):
            arguments += ['--model', model]
        else:
            print('Listening needs both whisper-cli and a model file, so imp will speak but not listen. '
                  'Run masc voice-local-setup --model <file> once both are ready.', file=sys.stderr)
    result = subprocess.run([str(binary), 'voice-local-setup', '--base-path', base] + arguments,
                            stdout=sys.stderr)
    if result.returncode != 0:
        # The writer already said why on stderr, and every reason for it is a
        # configuration one. Voice is optional, so this does not end setup.
        print('Voice was not saved. Everything else is. Run masc voice-local-setup to try again.',
              file=sys.stderr)


def journey(binary, base_path, port, timeout, resume=False):
    state = onboarding_status(binary, base_path)
    conditions = {check['id']: check['condition'] for check in state['checks']}
    # `invalid` is not one condition. Saving a selection repairs some of them —
    # configure_locked stages the edit, lets runtime-default-set rewrite it,
    # and publishes that rewrite — while a declaration the parser cannot
    # resolve is refused ahead of it. Both serialize to the same string here,
    # so this cannot decide which one it is holding. Name what is broken and
    # leave every exit the journey already has, including another workspace.
    for check in state['checks']:
        if check['condition'] == 'invalid':
            print('\n' + check['id'] + ': ' + terminal_text(check['message']), file=sys.stderr)
    # Persistence permits opening existing history, never a readiness badge.
    # The TUI observes/reconnects the server and reports current execution.
    if (resume and state.get('base_path') and conditions.get('workspace') == 'satisfied'
            and conditions.get('keeper_persistence') == 'satisfied'
            and 'invalid' not in conditions.values()):
        base = state['base_path']
        try:
            saved_port = workspace_port(binary, base, port)
        except SetupError as error:
            print(terminal_text(str(error)) + '\nChoose a workspace to continue.', file=sys.stderr)
        else:
            selected_port = select_setup_server(binary, base, saved_port, resume_existing=True)
            return 1 if selected_port is None else open_workspace(binary, base, selected_port)
    print('\nWelcome. Let’s make a home for you and imp.\n'
          'Choose with arrows and Enter; Space selects several connections.', file=sys.stderr)
    proposed = state.get('base_path') or str(Path.home() / 'MASC')
    selection = pick('1 · Your workspace', ['Use ' + proposed, 'Choose another directory', 'Finish later'])[0]
    if selection == 2:
        return 0
    base = proposed if selection == 0 else ask_text('Workspace directory')
    base = workspace_check(binary, base)['base_path']
    port = workspace_port(binary, base, port)
    port = select_setup_server(binary, base, port)
    if port is None:
        return 1
    if subprocess.run([str(binary), 'init', '--base-path', base], stdout=sys.stderr).returncode != 0:
        raise SetupError('Workspace initialization stopped. Existing files were preserved; run masc setup to resume.')
    workspace_port(binary, base, port, save=True)
    print('\n2 · Connect a model\nA subscription or API credit may be required by your provider.', file=sys.stderr)
    configured = wizard(binary, base, timeout)
    if configured.get('readiness') == 'failed':
        # The reason is already on screen, printed where it was raised. Naming
        # a cause here would be a guess: this path is reached by an unreadable
        # workspace, an unreachable server and a refused credential alike.
        print('The model connection was not saved. Run masc again once the '
              'problem above is resolved.', file=sys.stderr)
        return 1
    if configured.get('readiness') != 'verified':
        print('Your workspace is saved. Run masc to continue from here.', file=sys.stderr)
        return 0
    # Before the sandbox rather than after it: voice needs no guest and no
    # service, so a reader who leaves at the sandbox step still leaves with a
    # keeper that can speak.
    select_local_voice(binary, base)
    return sandbox_journey(binary, base, port)


def sandbox_journey(binary, base, port, refresh_owner=False):
    if port is None:
        port = workspace_port(binary, base)
    if refresh_owner:
        port = select_setup_server(binary, base, port, require_new_owner=True)
        if port is None:
            return 1
    sandbox_args = select_sandbox(binary, base, port=port)
    if sandbox_args is None:
        print('Your model connection is saved. Run masc setup to prepare the sandbox later.', file=sys.stderr)
        return 0
    print('\n5 · Open your first conversation', file=sys.stderr)
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
    parser.add_argument('--sandbox-step', action='store_true', help='continue saved model setup at the sandbox step')
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--port', type=int)
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
        if sum(map(bool, (args.spec, args.select_model, args.wizard, args.batch_spec, args.workspace_check, args.journey, args.sandbox_step))) != 1:
            raise SetupError('choose exactly one setup operation')
        if not args.journey and not args.base_path:
            raise SetupError('--base-path is required for this setup operation')
        if not math.isfinite(args.discovery_timeout) or args.discovery_timeout <= 0:
            raise SetupError('discovery timeout must be positive')
        if args.sandbox_step:
            raise SystemExit(sandbox_journey(args.binary, args.base_path, args.port, refresh_owner=True))
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
    except SetupSessionFinished:
        raise SystemExit(0)
    except (SetupError, OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit('runtime setup failed: ' + str(error))


if __name__ == '__main__':
    main()
