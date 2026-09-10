"""Prepare a fresh private real-provider Fusion decision scenario (no model call).

Credentials are read from an explicitly selected local configuration and never
included in the public scenario receipt. Starting the CI binary is separate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tomllib


def toml_document(value):
    lines = []

    def scalar(item):
        if isinstance(item, bool):
            return 'true' if item else 'false'
        if isinstance(item, (str, int, float, list)):
            return json.dumps(item, ensure_ascii=False)
        raise TypeError(type(item).__name__)

    def table(data, path):
        if path:
            lines.append('[' + '.'.join(json.dumps(p) for p in path) + ']')
        for key, item in data.items():
            if not isinstance(item, dict):
                lines.append(json.dumps(key) + ' = ' + scalar(item))
        lines.append('')
        for key, item in data.items():
            if isinstance(item, dict):
                table(item, path + [key])
    table(value, [])
    text = '\n'.join(lines)
    if tomllib.loads(text) != value:
        raise ValueError('Prepared TOML did not roundtrip')
    return text


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-config', type=Path, required=True)
    p.add_argument('--base', type=Path, required=True)
    p.add_argument('--evidence-repo', type=Path, required=True)
    p.add_argument('--evidence-commit', required=True)
    p.add_argument('--port', type=int, required=True)
    args = p.parse_args()
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', args.port))
    args.base.mkdir(parents=True, exist_ok=False, mode=0o700)
    config = args.base / '.masc/config'
    config.mkdir(parents=True, mode=0o700)
    source = tomllib.loads((args.source_config / 'runtime.toml').read_text())
    keeper_runtime = 'kimi_coding.kimi-for-coding'
    judge_runtime = 'glm-coding.glm-5-3'
    selected = {
        'runtime': {'default': keeper_runtime,
                    'exact_output_lanes': {name: {'slots': [judge_runtime]} for name in source['runtime']['exact_output_lanes']},
                    'lanes': {'default': {'candidates': [keeper_runtime]}}},
        'providers': {name: source['providers'][name] for name in ['kimi_coding', 'glm-coding']},
        'models': {name: source['models'][name] for name in ['kimi-for-coding', 'glm-5-3']},
        'kimi_coding': {'kimi-for-coding': source['kimi_coding']['kimi-for-coding']},
        'glm-coding': {'glm-5-3': source['glm-coding']['glm-5-3']},
        'fusion': {'enabled': True, 'default_preset': 'evidence-review',
                   'presets': {'evidence-review': {
                       'panel': [keeper_runtime, judge_runtime], 'judge': judge_runtime,
                       'panel_system_prompt': source['fusion']['presets'][source['fusion']['default_preset']]['panel_system_prompt'],
                       'judge_system_prompt': source['fusion']['presets'][source['fusion']['default_preset']]['judge_system_prompt'],
                       'web_tools': False}}}}
    selected['models']['kimi-for-coding']['thinking-support'] = True
    (config / 'runtime.toml').write_text(toml_document(selected))
    (config / 'runtime.toml').chmod(0o600)
    shutil.copyfile(args.source_config / 'agent-core-models-overlay.toml', config / 'agent-core-models-overlay.toml')
    (config / 'agent-core-models-overlay.toml').chmod(0o600)
    token = args.base / 'operator-token.private'
    token.write_text(secrets.token_hex(32))
    token.chmod(0o600)
    prefix = 'docs/evidence/2026-09-10-keeper-pdf-review/'
    inputs = {}
    for name in ['README.md', 'task-verdict-rejected.json']:
        raw = subprocess.check_output(['git', 'show', args.evidence_commit + ':' + prefix + name], cwd=args.evidence_repo)
        inputs[name] = {'source_commit': args.evidence_commit, 'source_path': prefix + name,
                        'sha256': hashlib.sha256(raw).hexdigest(), 'text': raw.decode()}
    receipt = {'scope': 'Decision about explicitly frozen historical evidence, not a claim about the current PDF or Task state',
               'keeper_runtime': keeper_runtime, 'panel_runtimes': [keeper_runtime, judge_runtime],
               'judge_runtime': judge_runtime, 'port': args.port, 'inputs': inputs,
               'limitations': ['Panel and judge share the GLM model; two panel runtime identities do not establish independent training or absence of shared bias',
                               'Operator supplies the decision problem; initial message does not name or require Fusion tools',
                               'No source Task or PDF is modified; any decision belongs to this isolated evaluation Task']}
    (args.base / 'scenario-input.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'base': str(args.base), 'port': args.port, 'prepared': True}))


if __name__ == '__main__':
    main()
