"""Execute extracted actual carrier module plus production splitter core.
This is isolated source execution, not a project build or consumer integration.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    here = Path(__file__).resolve().parent
    lib = here.parents[2] / 'packages/agent_core/lib/llm_provider'
    types = (lib / 'types.ml').read_text()
    carrier = types[types.index('module Inline_content_replay = struct'):types.index('module Response_replay = struct')]
    splitter = (lib / 'inline_reasoning_split.ml').read_text()
    splitter_core = splitter[:splitter.index('let%test')]
    stub = '''type content_block = Text of string
      | Thinking of {content:string;signature:string option}
      | ReasoningDetails of string | RedactedThinking of string
      | ToolUse of string | ToolResult of string | Image of string
      | Document of string | Audio of string
    [@@deriving show,yojson]
    '''
    with tempfile.TemporaryDirectory(prefix='masc-inline-carrier-') as tmp:
        tmp = Path(tmp)
        (tmp / 'inline_reasoning_split.ml').write_text(splitter_core)
        (tmp / 'inline_reasoning_split.mli').write_bytes((lib / 'inline_reasoning_split.mli').read_bytes())
        (tmp / 'carrier_slice.ml').write_text(stub + carrier)
        for name in ['reasoning_replay_contract.mli','reasoning_replay_contract.ml']:
            (tmp / name).write_bytes((lib / name).read_bytes())
        (tmp / 'fixture.ml').write_bytes((here / 'fixture.ml').read_bytes())
        subprocess.run(['ocamlfind','ocamlc','-package','yojson,ppx_deriving.show,ppx_deriving.eq,ppx_deriving_yojson',
            '-linkpkg','reasoning_replay_contract.mli','reasoning_replay_contract.ml','inline_reasoning_split.mli','inline_reasoning_split.ml','carrier_slice.ml','fixture.ml','-o','fixture'],cwd=tmp,check=True)
        checks = json.loads(subprocess.check_output([str(tmp / 'fixture')],text=True))
    report = {
        'scope':'actual extracted Inline_content_replay and production splitter core with fixture content payload types',
        'source_sha256':{'types.ml':hashlib.sha256(types.encode()).hexdigest(),
            'carrier_slice':hashlib.sha256(carrier.encode()).hexdigest(),
            'reasoning_replay_contract.ml':hashlib.sha256((lib / 'reasoning_replay_contract.ml').read_bytes()).hexdigest(),
            'splitter_core':hashlib.sha256(splitter_core.encode()).hexdigest()},
        'project_linked':False,'production_parser_serializer_executed':False,
        'production_stream_accumulator_executed':False,'provider_called':False,'checks':checks}
    print(json.dumps(report,indent=2))
    if not all(checks.values()):raise SystemExit(1)


if __name__ == '__main__':main()
