#!/usr/bin/env python3
"""Execute the actual producer origin encoder and TUI decoder fragments.

This is an origin wire boundary probe, not a native MASC build or UI test.
No dependency or algorithm ports are needed: both fragments are pure.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo, out = args.repo.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    files = ['lib/keeper/keeper_carried_front.ml', 'bin/masc_tui_context_inspector.ml']
    sources = {p: (repo / p).read_text() for p in files}
    fragments = []

    def take(path, first, after):
        source = sources[path]
        start = source.index(first)
        end = source.index(after, start)
        fragment = source[start:end]
        fragments.append({'path': path, 'first_line': source.count('\n', 0, start) + 1,
                          'last_line': source.count('\n', 0, end),
                          'sha256': hashlib.sha256(fragment.encode()).hexdigest()})
        return fragment

    producer, consumer = files
    prod = take(producer, 'type source =', 'type seed =')
    prod += take(producer, 'type origin =', 'type turn_start =')
    prod += take(producer, 'let rec origin_to_json =', 'type librarian_gap =')
    cons = take(consumer, 'type forecast_carried_origin =', 'type forecast_carried =')
    cons += take(consumer, 'let ( let* ) =', '\n', )
    cons += '\n' + take(consumer, 'let field name fields =', 'let sha256 name =')
    cons += take(consumer, 'let rec decode_forecast_origin =', 'let decode_forecast_carried =')
    tests = r'''
let assertions = ref 0
let check name condition =
  incr assertions;
  if not condition then failwith name
let json fields = `Assoc fields
let s value = `String value
let i value = `Int value
let past front = json ["kind", s "past_librarian_point"; "librarian_end_atom", i 9; "front", front]
let () =
  let open Producer in
  let pairs =
    [ Carried Ledger, Consumer.Carried_from_ledger
    ; Carried (Turn_record {turn=23}), Consumer.Carried_from_turn_record {turn=23}
    ; Carried Turn_start_after_seed_refusal, Consumer.Carried_turn_start_after_seed_refusal
    ; Carried Turn_start_after_librarian_refusal, Consumer.Carried_turn_start_after_librarian_refusal
    ; Librarian_snapshot {end_atom=17;boundary_line=42}, Consumer.Carried_librarian_snapshot {end_atom=17;boundary_line=42}
    ; Librarian_progress {end_atom=19}, Consumer.Carried_librarian_progress {end_atom=19}
    ; Turn_start {end_atom=31}, Consumer.Carried_turn_start {end_atom=31}
    ; Turn_start_unknown {reason="missing witness"}, Consumer.Carried_turn_start_unknown {reason="missing witness"}
    ] in
  let nested = List.map (fun (source, expected) ->
    Past_librarian_point {librarian_end_atom=9;source},
    Consumer.Carried_past_librarian_point {librarian_end_atom=9;front=expected})
    [ Ledger, Consumer.Carried_from_ledger
    ; Turn_record {turn=23}, Consumer.Carried_from_turn_record {turn=23}
    ; Turn_start_after_seed_refusal, Consumer.Carried_turn_start_after_seed_refusal
    ; Turn_start_after_librarian_refusal, Consumer.Carried_turn_start_after_librarian_refusal
    ] in
  List.iteri (fun index (source, expected) ->
    let wire = source |> origin_to_json |> Yojson.Safe.to_string |> Yojson.Safe.from_string in
    check (Printf.sprintf "fresh origin %d round trips" index)
      (Consumer.decode_forecast_origin wire = Ok expected)) (pairs @ nested);
  let retired kind = json ["kind",s kind;"retry",i 3] in
  let invalid =
    [ retired "halved_after_refusal"; retired "evicted_after_refusal"
    ; past (retired "halved_after_refusal"); past (retired "evicted_after_refusal")
    ; json ["kind",s "future_unknown"]
    ; json ["kind",s "turn_record";"turn",i (-1)]
    ; json ["kind",s "turn_start_unknown";"reason",s ""]
    ; past (origin_to_json (Librarian_snapshot {end_atom=2;boundary_line=1}))
    ; past (past (origin_to_json (Carried Ledger)))
    ; json ["kind",s "turn_record"]
    ; `Null
    ] in
  List.iteri (fun index value ->
    check (Printf.sprintf "invalid origin %d refused" index)
      (Result.is_error (Consumer.decode_forecast_origin value))) invalid;
  Printf.printf "%d assertions PASS\n" !assertions
'''
    generated = 'module Producer = struct\n' + prod + '\nend\n'
    generated += 'module Consumer = struct\n' + cons + '\nend\n' + tests
    (out / 'origin_probe.ml').write_text(generated)
    for path, source in sources.items():
        target = out / 'executed-source' / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source)
        if (repo / path).read_text() != source:
            raise RuntimeError(f'Source changed during extraction: {path}')
    (out / 'fragments.json').write_text(json.dumps(fragments, indent=2) + '\n')
    manifest = [{'path': p, 'sha256': hashlib.sha256(s.encode()).hexdigest()} for p, s in sources.items()]
    (out / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    argv = ['ocamlfind', 'ocamlc', '-package', 'yojson', '-linkpkg', '-w', '+a-70',
            '-warn-error', '+a-70', '-o', 'origin_probe.exe', 'origin_probe.ml']
    compiled = subprocess.run(argv, cwd=out, text=True, capture_output=True)
    receipt = {'scope': 'Actual source-fragment encoder/decoder bytecode probe only; no full MASC/native/transport/UI validation.',
               'ports': [], 'source_state': 'working tree; source hashes are authoritative',
               'source_head_role': 'Parent commit only; executed source includes uncommitted Layer 2 changes.',
               'source_head': subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip(),
               'source_git_status': subprocess.check_output(['git','-C',str(repo),'status','--short'],text=True),
               'captured_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'script_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               'ocamlc_version': subprocess.check_output(['ocamlc','-version'],text=True).strip(),
               'compile_argv': argv, 'compile_exit': compiled.returncode,
               'compile_stdout': compiled.stdout, 'compile_stderr': compiled.stderr}
    exit_code = compiled.returncode
    if exit_code == 0:
        executed = subprocess.run([str(out/'origin_probe.exe')], cwd=out, text=True, capture_output=True)
        receipt.update(run_argv=[str(out/'origin_probe.exe')], run_exit=executed.returncode,
                       run_stdout=executed.stdout, run_stderr=executed.stderr)
        exit_code = executed.returncode
    (out / 'execution.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
