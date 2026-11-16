"""Run the production grouping helper against the original selector, without Dune.

The fragment payloads are opaque strings in this isolated probe. Real turn IDs,
the old selector and the new index are extracted unchanged from the named source
files. This does not execute the full capture/consumer or the Eio runtime.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def section(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--sparse-only', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    paths = ['lib/types/ids.ml', 'lib/keeper/keeper_turn_fragments.ml',
             'lib/keeper/keeper_librarian_durable_capture.ml']
    sources = {path: (args.repo / path).read_text() for path in paths}
    ids, fragments, capture = (sources[path] for path in paths)
    program = '''module Json_util = struct let kind_name _ = "probe" end
module Ids = struct
''' + section(ids, 'module Turn_ref : sig', '(** Thread identifier') + '\nend\n'
    program += '''module F = struct
type fragment = Message of {turn_ref:Ids.Turn_ref.t; payload:string}
  | Tool_observation of {turn_ref:Ids.Turn_ref.t; payload:string}
type line = Fragment of fragment | Untagged
type read_error = Refused
'''
    program += section(fragments, 'let fragment_turn_ref =', 'type line =')
    program += section(fragments, 'let of_turn turn_ref lines =', 'let first_refused lines =') + '\nend\n'
    program += '''module R = struct
type official_line = {line:int; turn_ref:Ids.Turn_ref.t; recorded_at:float}
end
type official_trace = {trace_id:string; main:(int * (F.line,F.read_error) result) list;
 internal:(int * (F.line,F.read_error) result) list}
type official = {selected:R.official_line list; traces:official_trace list}
'''
    program += section(capture, 'module Trace_map =', 'let project_source ~boundaries source =')
    program += r'''
let turn trace_id absolute_turn = Ids.Turn_ref.make ~trace_id ~absolute_turn
let cut line turn_ref : R.official_line = {line; turn_ref; recorded_at=float_of_int line}
let indexed official =
  let traces = index_official_fragments official in
  List.map (fun (cut:R.official_line) ->
    match Trace_map.find_opt (Ids.Turn_ref.trace_id cut.turn_ref) traces with
    | None -> Error "missing trace"
    | Some turns -> Ok (match Turn_map.find_opt cut.turn_ref turns with
        | None -> [] | Some rows -> rows)) official.selected
let original official =
  List.map (fun (cut:R.official_line) ->
    match List.find_opt (fun trace -> trace.trace_id=Ids.Turn_ref.trace_id cut.turn_ref) official.traces with
    | None -> Error "missing trace"
    | Some trace -> Ok (F.of_turn cut.turn_ref (trace.main @ trace.internal))) official.selected
let row index id =
  index, match index mod 11 with
  | 0 -> Error F.Refused
  | 1 -> Ok F.Untagged
  | 2 -> Ok (F.Fragment (F.Tool_observation {turn_ref=id;payload=string_of_int index}))
  | _ -> Ok (F.Fragment (F.Message {turn_ref=id;payload=string_of_int index}))
let () =
  let random = Random.State.make [|732;184|] in
  for case = 0 to 399 do
    let keys = Array.init 37 (fun i -> turn (if i mod 2=0 then "alpha#part" else "beta") i) in
    let rows trace_id = List.init (Random.State.int random 180) (fun i ->
      let key=keys.(Random.State.int random (Array.length keys)) in
      row i (if i mod 7=0 then turn trace_id 999 else key)) in
    let traces = [{trace_id="alpha#part";main=rows "alpha#part";internal=rows "alpha#part"};
      {trace_id="beta";main=rows "beta";internal=rows "beta"};
      {trace_id="alpha#part";main=[row 44 keys.(0)];internal=[]};
      {trace_id="unused";main=[row 44 keys.(0)];internal=[]}] in
    let selected = List.init (Random.State.int random 50) (fun i ->
      cut i (if i mod 13=0 then turn "missing" 1 else keys.(Random.State.int random (Array.length keys)))) in
    let official={selected;traces} in
    if original official <> indexed official then failwith ("oracle mismatch " ^ string_of_int case)
  done;
  Printf.printf "{\"oracle_cases\":400,\"passed\":true}\n%!"
let allocated () = Gc.allocated_bytes () /. float_of_int (Sys.word_size / 8)
let measure name f input =
  Gc.full_major ();
  let cpu=Sys.time () and wall=Unix.gettimeofday () and words=allocated () in
  let answer=f input in
  let cpu=Sys.time () -. cpu and wall=Unix.gettimeofday () -. wall and words=allocated () -. words in
  Printf.printf "{\"algorithm\":%S,\"cpu_seconds\":%.6f,\"wall_seconds\":%.6f,\"allocated_words\":%.0f}\n%!"
    name cpu wall words;
  answer
let () =
  List.iter (fun (rows,turns,cuts) ->
    let keys=Array.init turns (fun i -> turn "benchmark#trace" i) in
    let trace={trace_id="benchmark#trace";
      main=List.init (rows/2) (fun i -> row i keys.(i mod turns));
      internal=List.init (rows-rows/2) (fun i -> row (i+rows/2) keys.(i mod turns))} in
    let input={selected=List.init cuts (fun i -> cut i keys.(i));traces=[trace]} in
    Printf.printf "{\"history_rows\":%d,\"distinct_turns\":%d,\"selected_cuts\":%d}\n%!" rows turns cuts;
    let before=measure "original" original input in
    let after=measure "indexed" indexed input in
    if before<>after then failwith "benchmark output differs") BENCHMARK_CASES
'''
    cases = [(75752,3774,0),(75752,3774,1),(75752,3774,10)]
    if not args.sparse_only:
        cases = [(10000,500,500),(20000,1000,1000),(75752,3774,3774)] + cases
    program = program.replace('BENCHMARK_CASES', '[' + ';'.join(','.join(map(str,c)) for c in cases) + ']')
    source = args.out / 'probe.ml'
    source.write_text(program)
    binary = args.out / 'probe'
    commands = [
        ['ocamlfind', 'ocamlopt', '-w', '+4+8', '-warn-error', '+4+8',
         '-package', 'yojson,unix', '-linkpkg', '-o', str(binary), str(source)],
        [str(binary)],
    ]
    for name, command in zip(['compile', 'run'], commands):
        result = subprocess.run(command, capture_output=True, text=True)
        (args.out / (name + '.stdout')).write_text(result.stdout)
        (args.out / (name + '.stderr')).write_text(result.stderr)
        print(result.stdout, end='')
        if result.returncode:
            print(result.stderr)
            raise SystemExit(result.returncode)
    manifest = {'scope': __doc__, 'source_sha256': {
        path: hashlib.sha256(text.encode()).hexdigest() for path, text in sources.items()},
        'commands': commands}
    (args.out / 'manifest.json').write_text(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
