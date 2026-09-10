"""Prepare an isolated collaboration base from an observed installed binary.

No model call or server restart. The installed binary is copied and hash-bound;
the receipt deliberately does not claim CI artifact provenance.
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--source-config', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--health', type=Path, required=True)
    parser.add_argument('--port', type=int, required=True)
    args = parser.parse_args()
    health = json.loads(args.health.read_text())
    digest = hashlib.sha256(args.binary.read_bytes()).hexdigest()
    assert digest == health['build']['executable_sha256'], 'installed binary changed'
    source = tomllib.loads((args.source_config / 'runtime.toml').read_text())
    providers = ['kimi_coding', 'glm-coding']
    for provider in providers:
        credential = source['providers'][provider]['credentials']
        assert credential['type'] == 'env' and os.environ.get(credential['key']), 'selected credential unavailable'
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', args.port))
    spec = importlib.util.spec_from_file_location('prepare_fusion', Path(__file__).with_name('prepare-fusion-decision-live.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    kimi, glm = 'kimi_coding.kimi-for-coding', 'glm-coding.glm-5.3'
    selected = {
        'runtime': {'default': kimi,
                    'lanes': {kimi: {'candidates': [kimi]}, glm: {'candidates': [glm]}},
                    'exact_output_lanes': {name: {'slots': [kimi]} for name in source['runtime']['exact_output_lanes']}},
        'providers': {name: source['providers'][name] for name in providers},
        'models': {name: source['models'][name] for name in ['kimi-for-coding', 'glm-5.3']},
        'kimi_coding': {'kimi-for-coding': source['kimi_coding']['kimi-for-coding']},
        'glm-coding': {'glm-5.3': source['glm-coding']['glm-5.3']},
        'fusion': {'enabled': True, 'default_preset': 'collaboration', 'presets': {'collaboration': {
            'panel': [kimi, glm], 'judge': kimi, 'web_tools': False,
            'panel_system_prompt': 'Evaluate the supplied decision using its actual evidence and work criteria. State uncertainty and alternatives.',
            'judge_system_prompt': 'Compare the panel reasoning against the original goal. Recommend an action without inventing evidence.'}}}}
    args.base.mkdir(parents=True, exist_ok=False, mode=0o700)
    config = args.base / '.masc/config'
    config.mkdir(parents=True)
    (config / 'runtime.toml').write_text(module.toml_document(selected))
    (config / 'runtime.toml').chmod(0o600)
    shutil.copyfile(args.source_config / 'agent-core-models-overlay.toml', config / 'agent-core-models-overlay.toml')
    (config / 'agent-core-models-overlay.toml').chmod(0o600)
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
               'keeper_runtimes': [kimi, glm], 'verifier_runtime': kimi,
               'limitations': ['single-runtime candidate lists; no failover claim', 'no work admitted yet']}
    (args.base / 'scenario-input.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
