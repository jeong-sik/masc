#!/usr/bin/env python3
"""Drive one isolated native machine worker over stdio; retain every exchange."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


class InputError(ValueError):
    pass


class Session:
    def __init__(self, worker, base, machine, evidence):
        self.machine, self.evidence = machine, evidence
        self.sequence = 0
        self.stderr = (evidence / 'worker.stderr.log').open('wb')
        self.process = None
        self.journal = (evidence / 'exchange.jsonl').open('a', encoding='utf-8')
        self.record({'event': 'start', 'worker': str(worker), 'base_path': str(base),
                     'worker_sha256': hashlib.sha256(worker.read_bytes()).hexdigest()})
        try:
            self.process = subprocess.Popen([str(worker), '--base-path', str(base)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
                text=True, encoding='utf-8', bufsize=1)
            self.rpc('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                'clientInfo': {'name': 'masc-local-play', 'version': '1'}})
            self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
            self.tools = {}
            cursor = None
            while True:
                page = self.rpc('tools/list', {} if cursor is None else {'cursor': cursor})
                for tool in page['tools']:
                    self.tools[tool['name']] = tool
                cursor = page.get('nextCursor')
                if cursor is None:
                    break
            (evidence / 'tools.json').write_text(json.dumps(self.tools, indent=2)+'\n')
        except BaseException:
            self.close()
            raise

    def record(self, event):
        self.journal.write(json.dumps(event, ensure_ascii=False)+'\n')
        self.journal.flush()
        os.fsync(self.journal.fileno())

    def send(self, message):
        self.record({'event': 'request', 'message': message})
        self.process.stdin.write(json.dumps(message)+'\n')
        self.process.stdin.flush()

    def rpc(self, method, params):
        self.sequence += 1
        ident = self.sequence
        self.send({'jsonrpc': '2.0', 'id': ident, 'method': method, 'params': params})
        while True:
            line = self.process.stdout.readline()
            if not line:
                self.record({'event': 'outcome_unknown', 'request_id': ident})
                raise RuntimeError('worker ended before replying; inspect journal and stderr, do not replay blindly')
            reply = json.loads(line)
            self.record({'event': 'response', 'message': reply})
            if reply.get('id') != ident:
                continue
            if 'error' in reply:
                raise RuntimeError(json.dumps(reply['error']))
            return reply['result']

    def call(self, operation, arguments):
        name = 'masc_'+self.machine+'_'+operation
        if name not in self.tools:
            raise InputError('operation is not exported by this worker: '+name)
        context = {'tool': name, 'arguments': arguments,
                   'caller': {'kind': 'keeper', 'name': 'local-player'}}
        if self.machine == 'dos' and operation in ('load', 'eject', 'step', 'press', 'click', 'type', 'restore', 'pass'):
            snapshot = self.rpc('tools/call', {'name': 'lane_controller_snapshot', 'arguments': {}})
            if snapshot.get('isError'):
                raise RuntimeError('controller observation failed')
            holder = snapshot['structuredContent']['holder']
            if holder not in (None, 'local-player'):
                raise InputError('another principal holds this isolated worker: '+holder)
            target = arguments.get('to') if operation == 'pass' else None
            if target:
                raise InputError('local play has one principal; omit to when releasing the controller')
            context['controller'] = {'observed_holder': holder, 'release': None, 'handoff_target': None}
        result = self.rpc('tools/call', {'name': 'lane_call', 'arguments': context})
        images = []
        for index, item in enumerate(result.get('content', [])):
            if item.get('type') == 'image' and item.get('mimeType') == 'image/png':
                path = self.evidence / f'{self.sequence:06d}-{index}.png'
                path.write_bytes(base64.b64decode(item['data'], validate=True))
                images.append(str(path))
        return {'isError': result.get('isError', False), 'data': result.get('structuredContent'),
                'text': [item['text'] for item in result.get('content', []) if item.get('type') == 'text'],
                'images': images, 'metadata': result.get('_meta')}

    def close(self):
        if self.process is not None:
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                pass
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
            self.process.stdout.close()
        self.stderr.close()
        self.journal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--base-path', type=Path, required=True, help='isolated workspace containing copied media')
    parser.add_argument('--machine', choices=('msx', 'dos'), required=True)
    args = parser.parse_args()
    base = args.base_path.resolve(strict=True)
    evidence = Path(tempfile.mkdtemp(prefix='play-evidence-', dir=base))
    session = Session(args.worker.resolve(strict=True), base, args.machine, evidence)
    try:
        print(json.dumps({'ready': True, 'evidence': str(evidence), 'tools': str(evidence/'tools.json')}), flush=True)
        for line in sys.stdin:
            try:
                command = json.loads(line)
                if not isinstance(command, dict) or set(command) != {'operation', 'arguments'} or not isinstance(command['arguments'], dict) or not isinstance(command['operation'], str):
                    raise ValueError('expected operation and arguments object')
            except ValueError as error:
                print(json.dumps({'input_error': str(error)}), flush=True)
                continue
            try:
                result = session.call(command['operation'], command['arguments'])
            except InputError as error:
                print(json.dumps({'input_error': str(error)}), flush=True)
                continue
            print(json.dumps(result, ensure_ascii=False), flush=True)
    finally:
        session.close()


if __name__ == '__main__':
    main()
