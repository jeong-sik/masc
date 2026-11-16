"""Execute extracted production codec/history code; not an Eio/run_turn build."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess


def section(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--before', required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    paths = ['lib/runtime/runtime_official_client_json.ml',
             'lib/runtime/runtime_muse_msp.ml', 'lib/runtime/runtime_muse_serve.ml',
             'test/test_runtime_muse_serve.ml']
    sources = {p: (args.repo / p).read_text() for p in paths}
    js, codec, current, tests = [sources[p] for p in paths]
    # The provider-effort adapter is unrelated to history and imports Agent Core.
    codec = codec.replace(section(codec, 'let reasoning_effort_of_requested',
                                  'type model_catalog_source ='), '')
    pure_json = section(js, 'module type Error', '  exception Idle_timeout')
    pure_json += section(js, '  let rec validate_unique_object_keys', '  let invoke_state_callback') + '\nend\n'

    def fixture(name):
        match = re.search(r'let ' + name + r'\s*=\s*\{\|(.*?)\|\}', tests, re.S)
        return json.loads(match.group(1))

    def event(frame):
        frame = json.loads(json.dumps(frame))
        frame.pop('jsonrpc', None)
        pos = {'id': 'record', 'sequence': 1}
        frame['params']['sourceRange'] = {'stream': {'id': 's-1', 'kind': 'session'},
                                          'first': pos, 'last': pos}
        return frame

    def alter(frame, **fields):
        frame = json.loads(json.dumps(frame))
        frame['params']['item'].update(fields)
        return frame

    def page(events, next_cursor=None):
        return {'events': [event(x) for x in events], 'nextCursor': next_cursor}

    start, final, floor = [fixture(x) for x in ['turn_started', 'agent_completed', 'earlier_history']]
    damaged = alter(floor, kind='damagedRange')
    damaged['params']['viewCursor'] = 'damaged'
    usage = {'method': 'session/tokenUsage', 'params': {'sessionId': 's-1', 'turnId': 't-1',
             'viewCursor': 'usage', 'promptTokens': 100, 'usage': {'inputTokens': 100,
              'outputTokens': 7, 'cachedTokens': 50, 'reasoningTokens': 3}}}
    cases = [
        ('whole', [page([start, final])], True),
        ('compacted', [page([floor, final])], True),
        ('paged_compacted', [page([final], 'agent-final'), page([floor])], True),
        ('historical_compaction', [page([floor, start, final])], True),
        ('start_before_compaction', [page([start, floor, final])], True),
        ('compaction_after_final', [page([start, final, floor])], False),
        ('no_final', [page([floor])], False),
        ('only_commentary', [page([floor, alter(final, messagePhase='commentary')])], False),
        ('other_turn_final', [page([floor, alter(final, turnId='other')])], False),
        ('truncated_final', [page([floor, alter(final, truncated=True)])], False),
        ('failed_final', [page([floor, alter(final, status='failed')])], False),
        ('missing_boundary', [page([final])], False),
        ('invalid_boundary_owner', [page([alter(floor, turnId='t-1'), final])], False),
        ('invalid_boundary_kind', [page([alter(floor, kind='unknownHistory'), final])], False),
        ('damaged_compacted', [page([floor, damaged, final])], False),
        ('damaged_whole', [page([start, damaged, final])], False),
        ('wrong_cursor', [page([final], 'wrong')], False),
        ('wrong_cursor_with_start', [page([start, floor, final], 'wrong')], False),
        ('empty_continuation', [page([], 'wrong')], False),
        ('duplicate_cursor', [page([final], 'agent-final'), page([floor, final])], False),
        ('partial_usage', [page([floor, usage, final])], True),
    ]
    prefix = '''#load "yojson.cma";;
module Runtime_official_client_json = struct
''' + pure_json + '\nend;;\nmodule Msp = struct\n' + codec + '''\nend;;
type error = Protocol_error of { stage : string; detail : string }
open Result.Syntax
let protocol_error stage detail = Error (Protocol_error {stage; detail})
let lift result = Result.map_error (fun (e : Msp.error) -> Protocol_error {stage=e.stage; detail=e.detail}) result
type receive_phase = Awaiting_history
type io = {set_receive_phase : receive_phase -> unit; pages : Yojson.Safe.t Queue.t}
let request ?on_view_gap ?pending_decisions io ~method_ encode =
  ignore on_view_gap; ignore pending_decisions;
  let request = encode ~id:4 in
  assert (method_ = "view/page");
  assert (Yojson.Safe.Util.(request |> member "params" |> member "direction") = `String "backward");
  assert (Yojson.Safe.Util.(request |> member "params" |> member "limit") = `Int 1000);
  Ok (Queue.take io.pages)
'''

    def program(runtime, before):
        text = prefix + section(runtime, 'type call_model =', 'type turn_result =')
        text += section(runtime, 'let same_call ', 'type turn_state =')
        text += section(runtime, 'let add_usage ', 'let observation ')
        text += section(runtime, 'let item_in_turn ', '(* Whether an item of this kind')
        text += '''
let analyze input =
  let pages = Queue.create () in List.iter (fun page -> Queue.add page pages) input;
  let io = {set_receive_phase=(fun _ -> ()); pages} in
  let* history = read_durable_turn_events io ~session_id:"s-1" ~turn_id:"t-1" ~terminal_cursor:"terminal-final" in
'''
        text += ('  durable_turn_of_events ~turn_id:"t-1" ~open_items:[] history\n'
                 if before else '  completed_turn_of_history ~turn_id:"t-1" ~open_items:[] history\n')
        text += '''
let run name pages expected =
  let result = analyze pages in
  let success = Result.is_ok result in
  let detail = match result with
    | Error (Protocol_error {detail; _}) -> detail
    | Ok witness ->
      assert (witness.durable_final_text = Some "MASC_MUSE_OK");
      if name = "partial_usage" then (
        assert (witness.durable_usage = None);
        let observed = Observing_usage witness.durable_usage in
        assert (terminal_usage ~observed ~terminal:None = None);
        let aggregate : Msp.token_usage = {input_tokens=300;output_tokens=30;cached_tokens=50;
          reasoning_tokens=3;prompt_tokens=None;cache_read_tokens=None;cache_write_tokens=None} in
        assert (terminal_usage ~observed ~terminal:(Some aggregate) = Some aggregate));
      "verified final" in
  print_endline (Yojson.Safe.to_string (`Assoc ["case",`String name;"success",`Bool success;"detail",`String detail]));
  assert (success = expected)
'''
        selected = cases[:2] if before else cases
        for name, pages, expected in selected:
            if before and name == 'compacted':
                expected = False
            quoted = '{wire|' + json.dumps(pages, ensure_ascii=True) + '|wire}'
            text += '\nlet () = run ' + json.dumps(name) + ' (Yojson.Safe.Util.to_list (Yojson.Safe.from_string ' + quoted + ')) ' + str(expected).lower() + ';;\n'
        return text

    old = subprocess.check_output(['git', 'show', args.before + ':lib/runtime/runtime_muse_serve.ml'],
                                   cwd=args.repo, text=True)
    yojson = subprocess.check_output(['ocamlfind', 'query', 'yojson'], text=True).strip()
    enumerate_runtime = subprocess.check_output(['ocamlfind', 'query', 'ppx_enumerate.runtime-lib'], text=True).strip()
    deriving = Path(subprocess.check_output(['ocamlfind', 'query', 'ppx_deriving'], text=True).strip()) / 'ppx_deriving'
    reports = {}
    for name, runtime, before in [('before', old, True), ('after', current, False)]:
        script = args.out / (name + '.ml')
        script.write_text(program(runtime, before))
        result = subprocess.run(['ocaml', '-I', yojson, '-I', enumerate_runtime,
                                 'ppx_enumerate_lib.cma', '-ppx',
                                 shlex.quote(str(deriving)) + ' package:ppx_enumerate', str(script)],
                                text=True, capture_output=True)
        (args.out / (name + '.stdout')).write_text(result.stdout)
        (args.out / (name + '.stderr')).write_text(result.stderr)
        if result.returncode:
            print(result.stderr[-5000:])
            raise SystemExit(result.returncode)
        reports[name] = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    reports['scope'] = 'Actual source-extracted codec, history reader and final/usage policy, with injected RPC pages; not run_turn/Eio integration or a repository typecheck.'
    reports['before_commit'] = args.before
    reports['source_sha256'] = {p: hashlib.sha256(s.encode()).hexdigest() for p, s in sources.items()}
    (args.out / 'results.json').write_text(json.dumps(reports, indent=2) + '\n')
    print(json.dumps({'before_compacted_success': reports['before'][1]['success'],
                      'candidate_cases_passed': len(reports['after']), 'results': str(args.out / 'results.json')}))


if __name__ == '__main__':
    main()
