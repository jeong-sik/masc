#!/usr/bin/env python3
"""Bounded actual-source reproduction, with an explicit filesystem read port."""
import hashlib
import json
from pathlib import Path
import subprocess

import argparse
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', required=True, type=Path)
parser.add_argument('--out', required=True, type=Path)
args = parser.parse_args()
REPO = args.repo.resolve()
OUT = args.out.resolve()
OUT.mkdir(exist_ok=False)
BASE = '7501aec032012869d8b979e0d14e1a9a9464ace7'
PACKAGES = 'yojson,ppx_deriving_yojson,ppx_deriving.show'

def source(path, baseline):
    if baseline:
        return subprocess.check_output(['git', 'show', f'{BASE}:{path}'], cwd=REPO, text=True)
    return (REPO / path).read_text()

def run(command, work, log):
    result = subprocess.run(command, cwd=work, capture_output=True, text=True)
    (work / log).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f'{command} exit {result.returncode}: {work / log}')
    return result.stdout

PORT = '''module Workspace_utils = struct let masc_dir config = config end
module Fs_compat = struct
  let load_owned_regular_file ~ownership_root:_ file =
    Ok (Some (In_channel.with_open_bin file In_channel.input_all))
  let save_file file contents = Out_channel.with_open_bin file (fun out -> output_string out contents)
end
type read_error =
  | Source_unavailable of {path:string;message:string}
  | Invalid_record of {path:string;line:int;message:string}
let owned_error path () = Source_unavailable {path;message="input port error"}
let ( let* ) = Result.bind
'''

HARNESS = '''module M = Metrics_store_eio
let row : M.task_metric = {
  id="observation";agent_id="validated";task_id="zero";started_at=100.;
  completed_at=None;success=false;error_message=None;collaborators=[];
  handoff_from=None;handoff_to=None }
let accepted result = match result with Ok () -> true | Error _ -> false
let contract schema =
  match Plan_schema.validate_composable_schema schema with
  | Ok () -> `String "accepted"
  | Error (Unsupported_schema_keyword {path;keyword}) ->
    `Assoc ["kind",`String "unsupported_schema_keyword";"path",`List (List.map (fun s->`String s) path);"keyword",`String keyword]
  | Error _ -> `String "other_error"
let () =
  let invalid = [ {row with task_id=" "};{row with handoff_to=Some " "};
    {row with collaborators=[""]};{row with started_at=Float.nan};
    {row with success=true};{row with completed_at=Some 99.};
    {row with started_at= -.Float.max_float;completed_at=Some Float.max_float} ] in
  assert (List.for_all (fun metric -> not (accepted (M.validate_metric metric))) invalid);
  assert (accepted (M.validate_metric {row with completed_at=Some 100.;success=true}));
  let file = "invalid.jsonl" in
  let reached_reader = ref 0 in
  let last_rejection = ref "" in
  let fixture_result =
    try write_all_invalid file invalid (fun () ->
      match M.read_metrics_file "." ~agent_id:"validated" file with
      | Error (Invalid_record {path;line=1;message}) when path=file ->
        incr reached_reader; last_rejection := message
      | Error _ | Ok _ -> failwith "corrupt metric source accepted");
      `String "all_rejected_by_source_reader"
    with Yojson.Json_error detail -> `Assoc ["serializer_error",`String detail]
  in
  let metrics : M.agent_metrics = {
    agent_id="producer";period_start=0.;period_end=1000.;record_count=3;
    outcome_basis=Task_outcome_measurement.Task_lifecycle;
    external_acceptance=Task_outcome_measurement.Unobserved {completed_tasks=2};
    total_tasks=3;conflicting_tasks=0;completed_tasks=2;successful_tasks=1;failed_tasks=1;
    avg_completion_time_s=Some 30.;task_completion_rate=2./.3.;task_success_rate=Some 0.5;
    error_rate=Some 0.5;handoff_tasks=1;completed_handoff_tasks=1;successful_handoff_tasks=1;
    handoff_task_success_rate=Some 1.;unique_collaborators=[] } in
  let value = M.agent_metrics_to_yojson metrics in
  let fitness = `Assoc ["count",`Int 1;"agents",`List [ `Assoc [
    "agent_id",`String "producer";"metrics",value;
    "components",`Assoc ["completion",`Float (2./.3.);"task_lifecycle_success",`Float 0.5;
      "speed",`Float 1.;"handoff_task_success",`Float 1.] ]]] in
  let validate schema value = accepted (Plan_schema.validate_schema_value ~path:[] schema value) in
  let schemas = ["metrics",Descriptor_schema.get_metrics_output_schema;
                 "fitness",Descriptor_schema.agent_fitness_output_schema] in
  let contracts = List.map (fun (name,schema)->name,contract schema) schemas in
  assert (validate Descriptor_schema.get_metrics_output_schema value);
  assert (validate Descriptor_schema.agent_fitness_output_schema fitness);
  let malformed = match value with `Assoc fields ->
    `Assoc (("outcome_basis",`Int 0)::List.remove_assoc "outcome_basis" fields) | _ -> assert false in
  assert (not (validate Descriptor_schema.get_metrics_output_schema malformed));
  let extra = match value with `Assoc fields -> `Assoc (("unexpected",`Bool true)::fields) | _ -> assert false in
  assert (not (validate Descriptor_schema.get_metrics_output_schema extra));
  print_endline (Yojson.Safe.to_string (`Assoc ["contracts",`Assoc contracts;
    "fixture",fixture_result;"reached_reader",`Int !reached_reader;
    "last_rejection",`String !last_rejection;
    "nonfinite_and_invalid_rows_rejected",`Int (List.length invalid);
    "valid_zero_duration_accepted",`Bool true;"actual_producer_shapes_accepted",`Int 2;
    "malformed_outputs_rejected",`Int 2]))
'''

manifest = {'baseline_commit':BASE, 'compiler':subprocess.check_output(['ocamlc','-version'],text=True).strip(),
            'scope':'Actual composable-schema contract/value validator, descriptor schemas, typed serialization, finite validation and read_metrics_file. Filesystem ownership/loading is an explicit ordinary-file input port. No full Plan.create, workspace, Dune, CI or live runtime claim.',
            'port':PORT,'harness':HARNESS,'snapshots':{}}
observations = {}
for label, baseline in [('before',True),('after',False)]:
    work=OUT/label
    work.mkdir(exist_ok=False)
    hashes={}
    def retain(path):
        data=source(path,baseline)
        hashes[path]=hashlib.sha256(data.encode()).hexdigest()
        return data
    plan=retain('lib/keeper/keeper_tool_plan.ml')
    (work/'plan_schema.ml').write_text(
        plan[plan.index('let nullable_schema_type ='):plan.index('module Json_pointer =')]+
        plan[plan.index('type json_type ='):plan.index('type node =')])
    descriptor=retain('lib/keeper/keeper_tool_descriptor.ml')
    (work/'descriptor_schema.ml').write_text(
        descriptor[descriptor.index('let object_output_schema '):descriptor.index('(* Producers: Keeper_tool_filesystem_runtime')]+
        descriptor[descriptor.index('let metric_number_schema ='):descriptor.index('let masc_board_descriptor ')])
    metric=retain('lib/metrics_store_eio.ml')
    fixture=retain('test/test_metrics_store_eio.ml')
    invalid_fixture=fixture[fixture.index('let test_invalid_observations_and_real_zero ()'):fixture.index('let test_generate_id ()')]
    if baseline:
        writer=next(line.strip() for line in invalid_fixture.splitlines() if 'Fs_compat.save_file file (Yojson.Safe.to_string' in line)
        assert writer.endswith(';')
        fixture_code='module Fs_compat = Metrics_store_eio.Fs_compat\nlet write_all_invalid file invalid on_read = List.iter (fun row -> '+writer+' on_read ()) invalid\n'
    else:
        writer=invalid_fixture[invalid_fixture.index('    let invalid_sources ='):invalid_fixture.index('    List.iter (fun bytes ->')]
        fixture_code='module Fs_compat = Metrics_store_eio.Fs_compat\nlet write_all_invalid file rows on_read =\nlet invalid = List.filter (fun (row : Metrics_store_eio.task_metric) -> Float.is_finite row.started_at) rows in\n'+writer+'List.iter (fun bytes -> Fs_compat.save_file file bytes; on_read ()) invalid_sources\n'
    (work/'metrics_store_eio.ml').write_text(
        metric[metric.index('type task_metric ='):metric.index('(** Config type alias for clarity *)')]+
        PORT+metric[metric.index('let valid_agent_id '):metric.index('let owned_error ')]+
        metric[metric.index('let validate_metric '):metric.index('let store_schema =')]+
        metric[metric.index('let read_metrics_file '):metric.index('let safe_yield ()')])
    for path in ['lib/types/task_outcome_measurement.mli','lib/types/task_outcome_measurement.ml']:
        (work/Path(path).name).write_text(retain(path))
    order=['task_outcome_measurement.mli','task_outcome_measurement.ml','plan_schema.ml','descriptor_schema.ml','metrics_store_eio.ml']
    for path in order:
        run(['ocamlfind','ocamlc','-package',PACKAGES,'-w','+4+32+69','-warn-error','+a','-c',path],work,path+'.compile.txt')
    (work/'harness.ml').write_text(fixture_code+HARNESS)
    run(['ocamlfind','ocamlc','-package',PACKAGES,'-linkpkg',
         'task_outcome_measurement.cmo','plan_schema.cmo','descriptor_schema.cmo','metrics_store_eio.cmo',
         'harness.ml','-o','probe'],work,'link.txt')
    observations[label]=json.loads(run([str(work/'probe')],work,'observations.json'))
    manifest['snapshots'][label]={'source_sha256':hashes,'fixture_writer':writer}
assert all(value.get('keyword')=='enum' for value in observations['before']['contracts'].values())
assert list(observations['after']['contracts'].values())==['accepted','accepted']
assert observations['after']['reached_reader']==7
assert observations['after']['fixture']=='all_rejected_by_source_reader'
assert observations['after']['last_rejection']=='start time must be finite'
(OUT/'source-manifest.json').write_text(json.dumps(manifest,indent=2))
(OUT/'observations.json').write_text(json.dumps(observations,indent=2))
print(json.dumps(observations,indent=2))
