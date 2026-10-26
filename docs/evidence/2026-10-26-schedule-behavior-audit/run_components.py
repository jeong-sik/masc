#!/usr/bin/env python3
"""Repeat bounded schedule checks without Dune, a model call or runtime mutation.

This compiles real leaf sources and existing tests. The selection check extracts
production declarations/function; Tui_decode supplies only its real type fragment.
It is not a complete TUI/server typecheck, model execution or screen test.
"""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
inputs = {}
logs = []


def source(name):
    data = (ROOT / name).read_bytes()
    inputs[name] = hashlib.sha256(data).hexdigest()
    return data.decode()


def region(body, start, end):
    assert body.count(start) == 1, start
    at = body.index(start)
    return body[at:body.index(end, at)]


def run(command, cwd, stdin=None):
    result = subprocess.run(command, cwd=cwd, input=stdin, capture_output=True, text=True)
    logs.append('$ ' + ' '.join(command) + '\n' + result.stdout + result.stderr)
    if result.returncode:
        (args.output / 'components.log').write_text('\n'.join(logs))
        raise RuntimeError('command failed: ' + ' '.join(command))
    return result.stdout


packages = 'ppx_enumerate,yojson,digestif.c,mirage-crypto-rng.unix,uuidm,alcotest,ptime,unix,threads'
with tempfile.TemporaryDirectory(prefix='masc-schedule-audit-') as directory:
    work = Path(directory)
    files = []
    objects = []
    for base in ['lib/crypto_rng/crypto_rng', 'lib/random_id/random_id',
                 'lib/schedule/schedule_contract_values', 'lib/schedule/schedule_domain',
                 'lib/time_codec/time_codec', 'lib/tui_schedule_observation']:
        if base.endswith('schedule_domain'):
            body = source('lib/core/json_util.ml')
            (work / 'json_util.ml').write_text(region(body, 'let reject_unknown_fields', 'let require_field_string'))
            files.append('json_util.ml')
            objects.append('json_util.cmo')
        for suffix in ['mli', 'ml']:
            name = base + '.' + suffix
            (work / Path(name).name).write_text(source(name))
            files.append(Path(name).name)
        objects.append(Path(base).name + '.cmo')
    run(['ocamlfind', 'ocamlc', '-thread', '-w', '+4+32+69', '-warn-error', '+a',
         '-package', packages, '-c', *files], work)
    for name in ['test_schedule_domain', 'test_tui_schedule_observation']:
        (work / (name + '.ml')).write_text(source('test/' + name + '.ml'))
        # Existing domain test flags disable fragile-match, as test/dune does.
        warnings = '+32+69-4' if name == 'test_schedule_domain' else '+4+32+69'
        run(['ocamlfind', 'ocamlc', '-thread', '-w', warnings, '-warn-error', '+a',
             '-package', packages, '-linkpkg', *objects, name + '.ml', '-o', name], work)
        run([str(work / name), '--color=never'], work)

    replay = '''let () = Yojson.Safe.from_channel stdin |> Yojson.Safe.Util.to_assoc |> List.iter (fun (name, entry) ->
      let row = Yojson.Safe.Util.member "row" entry in
      match Tui_schedule_observation.decode row with
      | Error why -> failwith (name ^ ": " ^ why)
      | Ok result -> let stage = match result.stage with
        | No_occurrence -> "none" | Dispatching -> "dispatching" | Dispatch_failed _ -> "dispatch_failed"
        | Queued -> "queued" | Queued_at owner -> "queued_at:" ^ owner | Missing -> "missing"
        | Turn_started -> "started" | Turn_ended -> "ended" | Consumed -> "consumed" | Completed -> "completed"
        | Failed _ -> "failed" | Cancelled _ -> "cancelled" | Settling -> "settling"
        | Transferring -> "transferring" | Unknown _ -> "unknown" in Printf.printf "%s %s\\n" name stage)'''
    (work / 'replay.ml').write_text(replay)
    run(['ocamlfind', 'ocamlc', '-package', 'yojson', '-linkpkg', 'tui_schedule_observation.cmo',
         'replay.ml', '-o', 'replay'], work)
    rows_name = 'docs/evidence/2026-10-25-schedule-drain-projection/produced-pages.json'
    data = source(rows_name)
    actual = dict(line.split(' ', 1) for line in run([str(work / 'replay')], work, data).splitlines())
    expected = {}
    for name, entry in json.loads(data).items():
        case, phase = name.split(':', 1)
        if case == 'transferred':
            stage = ('queued_at:' + entry['row']['keeper_queue_evidence']['resolved_owner']) if phase == 'projected' else 'transferring'
        elif phase == 'unreadable_receipt':
            stage = 'unknown'
        else:
            stage = case if phase in ['projected', 'retired'] else 'settling'
        expected[name] = stage
    assert actual == expected, (actual, expected)

    # Source-extracted consumer, complete production row records and shared
    # domain/time implementations; no copied selection algorithm or UI text test.
    types = source('bin/masc_tui_types.ml')
    wire_types = source('lib/tui_decode.mli')
    (work / 'tui_decode.ml').write_text(
        region(wire_types, 'type schedule_hold_reason =', 'val latest_drawable_unix_seconds')
        + region(wire_types, 'type schedule_runner_status =', 'val decode_schedule_runner_status'))
    fixture = source('test/test_tui_keys.ml')
    selection = 'module Masc = struct module Tui_schedule_observation = Tui_schedule_observation end\n'
    selection += region(types, 'type schedule_row = {', '(* The server supplies the Keeper name')
    selection += region(types, 'type schedule_snapshot = {', 'let chat_schedule_toggle_key')
    selection += region(types, 'let chat_schedule_entries ~keeper_name snapshot =', '(** One recorded wake attempt')
    selection += region(fixture, 'let schedule_form_row : schedule_row =', '(* The wire carries both an encoded target')
    selection += '''
let page rows = { scs_observed_at_iso = "2026-10-26T09:00:00Z"; scs_status = "ok"; scs_read_error = None;
 scs_request_count = Some (List.length rows); scs_truncated = false; scs_next_due_iso = None; scs_counts = None;
 scs_rows = rows; scs_runner_status = Tui_decode.Runner_status Schedule_contract_values.Runner_ok }
let select rows = chat_schedule_entries ~keeper_name:"edgar.a.poe" (page rows)
let verify label condition = if not condition then failwith label else print_endline ("PASS " ^ label)
let () =
 let queued = { schedule_form_row with sch_status = "succeeded"; sch_next_due_at_iso = None;
   sch_occurrence = { stage = Tui_schedule_observation.Queued; due_at_iso = Some "2026-09-02T00:00:00Z" } } in
 verify "one-shot pending retained" (List.length (select [queued]) = 1);
 let running = { queued with sch_occurrence = { queued.sch_occurrence with stage = Turn_started } } in
 verify "one-shot started retained" (List.length (select [running]) = 1);
 let recurring = { queued with sch_status = "scheduled"; sch_next_due_at_iso = Some "2026-09-03T00:00:00Z" } in
 verify "occurrence clock preserved" (match select [recurring] with [_, due] -> due = Time_codec.parse_rfc3339_opt "2026-09-02T00:00:00Z" | _ -> false);
 verify "other Keeper excluded" (select [{ queued with sch_payload_target = Some "keeper:other" }] = []);
 let closed name at = { queued with sch_schedule_id = name; sch_reaction_latest_at_iso = Some at;
   sch_occurrence = { queued.sch_occurrence with stage = Completed } } in
 verify "latest historical result only" (match select [closed "old" "2026-09-02T00:00:00Z"; closed "new" "2026-09-03T00:00:00Z"] with [row, _] -> row.sch_schedule_id = "new" | _ -> false);
 verify "pending before future declaration" (match select [schedule_form_row; queued] with (row, _) :: _ -> row.sch_status = "succeeded" | [] -> false);
 verify "missing one-shot remains actionable" (List.length (select [{ queued with sch_occurrence = { queued.sch_occurrence with stage = Missing } }]) = 1);
 verify "transferred pending remains visible" (List.length (select [{ queued with sch_occurrence = { queued.sch_occurrence with stage = Queued_at "recipient" } }]) = 1)
'''
    (work / 'selection.ml').write_text(selection)
    run(['ocamlfind', 'ocamlc', '-thread', '-w', '+4+32+69', '-warn-error', '+a', '-package', packages,
         '-linkpkg', *objects, 'tui_decode.ml', 'selection.ml', '-o', 'selection'], work)
    run([str(work / 'selection')], work)
    receipt = {'schema': 'schedule-behavior-component-audit.v1',
               'base_head': run(['git', 'rev-parse', 'HEAD'], ROOT).strip(),
               'source_state': 'Worktree inputs identified by source_sha256; base_head is provenance, not an executed commit.',
               'source_sha256': inputs, 'producer_replay': actual,
               'scope': 'domain, occurrence-decoder, historical producer-row replay, source-extracted selection',
               'not_proven': ['full integration typecheck', 'backend current-head execution',
                              'model/result destination delivery', 'complete TUI execution', 'installation']}
    (args.output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
(args.output / 'components.log').write_text('\n'.join(logs))
print('Component checks completed. Receipt and logs:', args.output)
