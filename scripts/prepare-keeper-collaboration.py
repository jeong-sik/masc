"""Prepare an isolated collaboration base from an observed installed binary.

No model call or server restart. The installed binary is copied and hash-bound;
the receipt deliberately does not claim CI artifact provenance.

Select two exact direct runtime IDs with --primary-runtime and --secondary-runtime.
Each must have an explicit [provider.model] binding table plus its [providers]
and [models] declarations in the source runtime.toml. Lane names, implicit
bindings, aliases and spelling substitutions are not resolved by this copy tool.
Both IDs must be distinct and enabled, with env credentials available. Providers
using model-set declarations are unsupported; their dependencies are not copied.
The primary runtime remains the default, verifier and Fusion judge.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import tomllib


def declared_binding(source, runtime_id):
    matches = [
        (provider, model)
        for provider in source['providers']
        for model, binding in source.get(provider, {}).items()
        if isinstance(binding, dict) and f'{provider}.{model}' == runtime_id
    ]
    if len(matches) != 1:
        raise ValueError(f'{runtime_id!r} must name one explicit provider/model binding')
    provider, model = matches[0]
    if model not in source['models']:
        raise ValueError(f'{runtime_id!r} has no model declaration for {model!r}')
    if (source['providers'][provider].get('enabled', True) is False
            or source[provider][model].get('enabled', True) is False):
        raise ValueError(f'{runtime_id!r} is disabled')
    if 'model-set' in source['providers'][provider]:
        raise ValueError(f'{provider!r} model-set is unsupported by this copy tool')
    return provider, model


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--source-config', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--health', type=Path, required=True)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--primary-runtime', required=True,
                        help='Exact declared runtime ID for the default, verifier and judge')
    parser.add_argument('--secondary-runtime', required=True,
                        help='Exact declared runtime ID for the second Keeper/panel choice')
    args = parser.parse_args()
    health = json.loads(args.health.read_text())
    digest = hashlib.sha256(args.binary.read_bytes()).hexdigest()
    assert digest == health['build']['executable_sha256'], 'installed binary changed'
    source = tomllib.loads((args.source_config / 'runtime.toml').read_text())
    primary, secondary = args.primary_runtime, args.secondary_runtime
    try:
        if primary == secondary:
            raise ValueError('primary and secondary runtime IDs must be distinct')
        bindings = [declared_binding(source, identity) for identity in (primary, secondary)]
    except ValueError as error:
        parser.error(f'{args.source_config / "runtime.toml"}: {error}')
    providers = list(dict.fromkeys(provider for provider, _ in bindings))
    for provider in providers:
        credential = source['providers'][provider].get('credentials')
        if not isinstance(credential, dict) or credential.get('type') != 'env':
            parser.error(f'{provider!r} requires env credentials for this copy tool')
        key = credential.get('key')
        if not isinstance(key, str) or not key or not os.environ.get(key):
            parser.error(f'{provider!r}: selected credential unavailable')
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', args.port))
    spec = importlib.util.spec_from_file_location('prepare_fusion', Path(__file__).with_name('prepare-fusion-decision-live.py'))
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    selected = {
        'runtime': {'default': primary,
                    'lanes': {identity: {'candidates': [identity]} for identity in (primary, secondary)},
                    'exact_output_lanes': {name: {'slots': [primary]} for name in source['runtime']['exact_output_lanes']}},
        'providers': {name: source['providers'][name] for name in providers},
        'models': {model: source['models'][model] for _, model in bindings},
        'fusion': {'enabled': True, 'default_preset': 'collaboration', 'presets': {'collaboration': {
            'panel': [primary, secondary], 'judge': primary, 'web_tools': False,
            'panel_system_prompt': 'Evaluate the supplied decision using its actual evidence and work criteria. State uncertainty and alternatives.',
            'judge_system_prompt': 'Compare the panel reasoning against the original goal. Recommend an action without inventing evidence.'}}}}
    for provider, model in bindings:
        selected.setdefault(provider, {})[model] = source[provider][model]
    args.base.mkdir(parents=True, exist_ok=False, mode=0o700)
    config = args.base / '.masc/config'
    config.mkdir(parents=True)
    (config / 'runtime.toml').write_text(module.toml_document(selected))
    (config / 'runtime.toml').chmod(0o600)
    binary = args.base / 'masc-observed.exe'
    shutil.copyfile(args.binary, binary)
    binary.chmod(0o700)
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == digest
    token = args.base / 'operator-token.private'
    token.write_text(secrets.token_hex(32))
    token.chmod(0o600)
    receipt = {'port': args.port, 'scope': 'isolated real-provider collaboration baseline',
               'binary_commit': health['build']['binary_commit'], 'binary_sha256': digest,
               'provenance': 'observed installed file matched live health; copied without rebuilding',
               'runtime_config_sha256': hashlib.sha256((config / 'runtime.toml').read_bytes()).hexdigest(),
               'keeper_runtimes': [primary, secondary], 'verifier_runtime': primary,
               'limitations': ['single-runtime candidate lists; no failover claim', 'no work admitted yet']}
    (args.base / 'scenario-input.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
