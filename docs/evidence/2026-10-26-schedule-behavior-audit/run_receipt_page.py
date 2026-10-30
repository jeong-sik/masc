#!/usr/bin/env python3
"""Compile the actual TUI row/list decoder and check mixed receipt pages.

No Dune, server, TUI process, model calls or runtime mutations. Namespace aliases
and production type/function extraction isolate the direct consumer; no decoder
algorithm is replaced. Input mutations are synthetic, based on one archived real
producer row. They are not a fresh backend execution.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
hashes, logs = {}, []


def source(name):
    data = (ROOT / name).read_bytes()
    hashes[name] = hashlib.sha256(data).hexdigest()
    return data.decode()


def region(body, start, end):
    assert body.count(start) == 1, start
    at = body.index(start)
    return body[at:body.index(end, at)]


def run(command, cwd, stdin=None):
    result = subprocess.run(command, cwd=cwd, input=stdin, text=True, capture_output=True)
    logs.append('$ ' + ' '.join(command) + '\n' + result.stdout + result.stderr)
    (args.output / 'receipt-page.log').write_text('\n'.join(logs))
    if result.returncode:
        raise RuntimeError('command failed: ' + ' '.join(command))
    return result.stdout


with tempfile.TemporaryDirectory(prefix='masc-receipt-page-') as directory:
    work = Path(directory)
    files, objects = [], []
    for base in ['lib/shared_types/json_kind', 'lib/schedule/schedule_contract_values',
                 'lib/tui_schedule_observation']:
        for suffix in ['mli', 'ml']:
            name = base + '.' + suffix
            (work / Path(name).name).write_text(source(name))
            files.append(Path(name).name)
        objects.append(Path(base).name + '.cmo')
    json_util = source('lib/core/json_util.ml')
    (work / 'json_util.ml').write_text(
        'module Shared_types = struct module Json_kind = Json_kind end\n'
        + next(line for line in json_util.splitlines(True) if line.startswith('let kind_name ='))
        + region(json_util, 'let assoc_member_opt', 'let assoc_string_opt'))
    files.append('json_util.ml')
    objects.append('json_util.cmo')
    for suffix in ['mli', 'ml']:
        name = 'lib/tui_decode_fields.' + suffix
        (work / Path(name).name).write_text(source(name))
        files.append(Path(name).name)
    objects.append('tui_decode_fields.cmo')
    decode = source('lib/tui_decode.ml')
    (work / 'tui_decode.ml').write_text(
        'open Tui_decode_fields\nlet ( let* ) = Result.bind\n'
        + region(decode, 'type schedule_hold_reason =', 'type schedule_runner_status ='))
    files.append('tui_decode.ml')
    objects.append('tui_decode.cmo')
    (work / 'masc.ml').write_text(
        'module Tui_decode_fields = Tui_decode_fields\n'
        'module Tui_schedule_observation = Tui_schedule_observation\n')
    files.append('masc.ml')
    objects.append('masc.cmo')
    types = source('bin/masc_tui_types.ml')
    (work / 'masc_tui_types.ml').write_text(
        'module Tui_decode = Tui_decode\n'
        'module Tui_schedule_observation = Tui_schedule_observation\n'
        + region(types, 'type schedule_row = {', '(* The server supplies the Keeper name'))
    files.append('masc_tui_types.ml')
    objects.append('masc_tui_types.cmo')
    consumer = source('bin/masc_tui_schedule_decode.ml')
    (work / 'masc_tui_schedule_decode.ml').write_text(consumer[:consumer.index('(* The snapshot keeps')])
    files.append('masc_tui_schedule_decode.ml')
    objects.append('masc_tui_schedule_decode.cmo')
    packages = 'yojson,ppx_enumerate'
    run(['ocamlfind', 'ocamlc', '-w', '+4+32+69', '-warn-error', '+a',
         '-package', packages, '-c', *files], work)
    driver = r'''
let replace key value = function
 | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
 | _ -> invalid_arg "expected object"
let nested key edit row = replace key (edit (Yojson.Safe.Util.member key row)) row
let failures = ref []
let check label ok =
 print_endline ((if ok then "PASS " else "FAIL ") ^ label);
 if not ok then failures := label :: !failures
let unknown row = match row.Masc_tui_types.sch_occurrence.stage with
 | Tui_schedule_observation.Unknown _ -> true
 | No_occurrence | Dispatching | Dispatch_failed _ | Queued | Queued_at _ | Missing
 | Turn_started | Turn_ended | Consumed | Completed | Failed _ | Cancelled _
 | Settling | Transferring -> false
let () =
 let valid = Yojson.Safe.from_channel stdin in
 let missing = valid
  |> nested "last_wake" (nested "detail" (replace "stimulus_id" `Null))
  |> nested "keeper_queue_evidence" (replace "projection_status" (`String "unrecognized_receipt"))
  |> nested "keeper_reaction_evidence"
    (fun reaction -> match reaction with
     | `Assoc fields -> `Assoc (("projection_status", `String "missing_stimulus_id") ::
         List.filter (fun (key, _) -> List.mem key
           ["schedule_instance_id"; "schedule_id"; "keeper_name"; "post_id"]) fields)
     | _ -> assert false) in
 let mixed label rows expected =
  match Masc_tui_schedule_decode.decode_schedule_rows rows with
  | Error why -> print_endline ("DIAGNOSTIC " ^ why); check label false
  | Ok result -> check label (List.map unknown result = expected) in
 mixed "valid and null-stimulus rows preserved in order" [valid; missing] [false; true];
 mixed "null-stimulus first does not hide valid neighbor" [missing; valid] [true; false];
 let absent = missing |> nested "last_wake" (nested "detail"
   (function `Assoc fields -> `Assoc (List.remove_assoc "stimulus_id" fields) | _ -> assert false)) in
 mixed "absent stimulus stays row-local unknown" [valid; absent] [false; true];
 let rejected label row =
  match Masc_tui_schedule_decode.decode_schedule_rows [valid; row] with
  | Error _ -> check label true
  | Ok _ -> check label false in
 rejected "cross-occurrence evidence remains rejected"
  (valid |> nested "keeper_queue_evidence" (replace "post_id" (`String "other-occurrence")));
 rejected "malformed summary boolean remains rejected"
  (valid |> nested "keeper_reaction_evidence" (replace "turn_started_seen" (`String "true")));
 rejected "duplicate core identity remains rejected"
  (match valid with `Assoc fields -> `Assoc (("schedule_id", `String "other") :: fields) | _ -> assert false);
 rejected "missing core identity remains rejected" (valid |> replace "schedule_id" `Null);
 rejected "null stimulus does not bypass Keeper target"
  (missing |> replace "payload_target" (`String "keeper:other"));
 rejected "null stimulus does not bypass instance identity"
  (missing |> replace "schedule_instance_id" (`String "other-instance"));
 rejected "null stimulus does not admit raw positive progress"
  (missing |> nested "keeper_reaction_evidence" (replace "turn_started_seen" (`Bool true)));
 rejected "null stimulus cannot match a pending queue"
  (missing |> nested "keeper_queue_evidence" (replace "projection_status" (`String "matched_pending")));
 rejected "null stimulus cannot borrow a bound reaction"
  (missing |> nested "keeper_reaction_evidence" (replace "stimulus_id" (`String "another-stimulus")));
 rejected "null stimulus validates remaining receipt identity"
  (missing |> nested "keeper_reaction_evidence" (replace "post_id" (`String "another-occurrence")));
 if !failures <> [] then exit 1
'''
    (work / 'probe.ml').write_text(driver)
    run(['ocamlfind', 'ocamlc', '-w', '+4+32+69', '-warn-error', '+a', '-package', packages,
         '-linkpkg', *objects, 'probe.ml', '-o', 'probe'], work)
    rows = json.loads(source('docs/evidence/2026-10-25-schedule-drain-projection/produced-pages.json'))
    run([str(work / 'probe')], work, json.dumps(rows['completed:projected']['row']))
    receipt = {'scope': 'actual source-extracted TUI decode_schedule_rows mixed-page decisions',
               'source_sha256': hashes, 'input_origin': 'one historical real producer row plus explicit synthetic mutations',
               'decisions_passed': 13, 'not_proven': ['full TUI/server integration', 'current backend execution', 'provider/runtime execution']}
    (args.output / 'receipt-page.json').write_text(json.dumps(receipt, indent=2) + '\n')
print('Receipt-page checks completed:', args.output)
