"""Run exact pure query/cursor/revision source; no full native Task tool claim."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
BASE = '0596143ca7393557f072662e11d7e8359d23743b'


def source(path):
    return (ROOT / path).read_text()


def fragment(text, start, end):
    return text[text.index(start):text.index(end)]


domain = fragment(source('lib/types/types_core.ml'), 'type task_status =', '(* Manual yojson conversion for task_status')
domain += '\ntype task = {id:string; title:string; description:string; task_status:task_status}\n'
old_runtime = subprocess.check_output(['git', 'show', BASE + ':lib/keeper/keeper_tool_task_runtime.ml'], cwd=ROOT, text=True)
old_visible = fragment(old_runtime, '       let visible (task : Masc_domain.task) =', '       let page_key (task : Masc_domain.task) =')
runtime = source('lib/keeper/keeper_tool_task_runtime.ml')
projection = fragment(runtime, 'type task_projection =', 'let task_projection_of_args')
projection += fragment(runtime, 'let task_projection_to_string =', '(* Cluster sub-dispatch')
revision = fragment(runtime, '       let revision =\n', '       let response =\n')
probe = r'''
module Q = Keeper_tasks_list_query
module C = Keeper_tasks_list_cursor
module D = Masc_domain
let count = ref 0
let check label yes = if not yes then failwith label else
  (incr count; Printf.printf "PASS %s\n" label)
let okay = function Ok value -> value | Error message -> failwith message
let statuses =
  [D.Todo; D.Claimed {assignee="a";claimed_at="t"};
   D.InProgress {assignee="a";started_at="t"};
   D.AwaitingVerification {assignee="a";started_at="t";submitted_at="t";verification_id="v"};
   D.Done {assignee="a";completed_at="t";notes=None};
   D.Cancelled {cancelled_by="a";cancelled_at="t";reason=None}]
let tasks = List.map (fun task_status ->
  let id = D.task_status_to_string task_status in
  {D.id;title=id;description="requested task";task_status}) statuses
let ids = List.map (fun (task : D.task) -> task.id)
let requested = `List (List.map (fun id -> `String id) (ids tasks))
let exact = ["task_ids",requested;"projection",`String "full"]
let resolved fields =
  let args = `Assoc fields in
  let selection = okay (Q.of_args args) in
  let lifecycle = okay (Q.lifecycle_filter_of_args ~selection args) in
  selection,lifecycle
let selected fields =
  let selection,lifecycle = resolved fields in
  List.filter (Q.matches_lifecycle lifecycle) tasks
  |> List.filter (Q.matches selection ~goal_task_ids:None)
let () =
  let selection,all = resolved exact in
  let before = List.filter (Baseline.visible ~status_filter:None ~include_done:false) tasks
    |> List.filter (Q.matches selection ~goal_task_ids:None) in
  check "baseline known IDs hide Done and Cancelled" (ids before = ["todo";"claimed";"in_progress";"awaiting_verification"]);
  check "repaired known IDs read all six actual lifecycle variants" (ids (selected exact) = ids tasks);
  check "general discovery remains active-only" (ids (selected []) = ids before);
  check "explicit false remains active-only" (ids (selected (("include_done",`Bool false)::exact)) = ids before);
  check "explicit true includes Done and excludes Cancelled"
    (ids (selected (("include_done",`Bool true)::exact)) = ["todo";"claimed";"in_progress";"awaiting_verification";"done"]);
  check "explicit null status retains active semantics" (ids (selected (("status",`Null)::exact)) = ids before);
  List.iter (fun (task : D.task) -> check ("explicit status selects " ^ task.id)
    (ids (selected (["status",`String task.id;"include_done",`Bool false] @ exact)) = [task.id])) tasks;
  List.iter (fun value ->
    let args = `Assoc (("include_done",value)::exact) in
    check "a supplied nonboolean is not a silent default"
      (match Q.lifecycle_filter_of_args ~selection args with Error _->true | Ok _->false))
    [`Null;`String "true";`Int 1];
  let all_filter = {C.lifecycle=all;projection="full";selection} in
  let key = {C.priority=3;created_at="2026-10-24T14:00:00Z";id="done"} in
  let cursor = {C.after=key;filter=all_filter} in
  let encoded = C.to_string cursor in
  check "resolved exact lookup cursor round-trips"
    (match C.of_string ~call:all_filter encoded with Ok _->true | Error _->false);
  List.iter (fun flag ->
    let _,lifecycle = resolved (("include_done",`Bool flag)::exact) in
    check "a cursor cannot cross to an explicit lifecycle filter"
      (match C.of_string ~call:{all_filter with lifecycle} encoded with
       | Error (C.Cursor_filter_mismatch _) -> true | Error Cursor_unparseable | Ok _ -> false)) [false;true];
  let old_shape = `Assoc ["after",`Assoc ["priority",`Int 3;"created_at",`String key.created_at;"id",`String key.id];
      "filter",`Assoc ["status",`Null;"include_done",`Bool false;"projection",`String "full";
                       "selection",Q.to_yojson selection]] in
  let old_encoded = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet (Yojson.Safe.to_string old_shape) in
  check "old opaque cursor shape is refused, never reinterpreted"
    (match C.of_string ~call:all_filter old_encoded with Error Cursor_unparseable -> true | Error (Cursor_filter_mismatch _) | Ok _ -> false);
  List.iter (fun lifecycle -> check "closed lifecycle serialization preserves identity"
    (Option.fold ~none:false ~some:(Q.lifecycle_filter_equal lifecycle)
      (Q.lifecycle_filter_of_yojson (Q.lifecycle_filter_to_yojson lifecycle))))
    [Q.Active_tasks;Q.Active_and_done_tasks;Q.All_statuses;Q.Exact_status D.Task_status_tag.Cancelled];
  check "unknown lifecycle is unavailable" (Q.lifecycle_filter_of_yojson (`Assoc ["kind",`String "unknown"]) = None);
  let revision lifecycle = Runtime_revision.revision ~lifecycle ~selection ~matching_count:1
      ~cursor:None ~tasks_json:(`List [`Assoc ["id",`String "same visible row"]]) ~new_tasks_json:(`List []) in
  let current = revision all in
  let _,explicit = resolved (("include_done",`Bool true)::exact) in
  check "actual production revision binds lifecycle even when page bytes match"
    (current <> revision explicit);
  check "matching revision uses production unchanged response"
    (match Snapshot_protocol.respond ~revision:current ~if_revision:(Some current) (`List []) with
     | Unchanged _->true | Snapshot _->false);
  check "another lifecycle cannot inherit that unchanged response"
    (match Snapshot_protocol.respond ~revision:(revision explicit) ~if_revision:(Some current) (`List []) with
     | Snapshot _->true | Unchanged _->false);
  Printf.printf "%d exact-source lookup checks passed\n" !count
'''

with tempfile.TemporaryDirectory(prefix='masc-exact-task-lookup-') as temporary:
    directory = Path(temporary)
    sources, records = [], []

    def put(name, text, scope):
        (directory / name).write_text(text)
        sources.append(name)
        records.append({'compiled': name, 'scope': scope, 'sha256': hashlib.sha256(text.encode()).hexdigest()})

    put('masc_domain.ml', domain, 'exact Task status/tag/actor source; minimal task-record port for unrelated fields')
    put('string_util.ml', fragment(source('lib/string_util/string_util.ml'), 'let contains_substring ', '(* Byte-wise substring search:'), 'exact substring helper')
    for module in ['lib/keeper/keeper_tasks_list_query', 'lib/keeper/keeper_tasks_list_cursor', 'lib/snapshot_protocol']:
        for extension in ['.mli','.ml']:
            put(Path(module + extension).name, source(module + extension), module + extension)
    put('baseline.ml', 'let visible ~status_filter ~include_done =\n' + old_visible + ' visible\n', 'exact baseline runtime visibility predicate')
    put('runtime_revision.ml', projection + '\nlet revision ~lifecycle ~selection ~matching_count ~cursor ~tasks_json ~new_tasks_json =\nlet recovered_from=None in\nlet limit=1 in\nlet projection=Full in\n' + revision + ' revision\n', 'exact current runtime revision statements; minimal unrelated local ports')
    (directory/'probe.ml').write_text(probe)
    built = subprocess.run(['ocamlfind','ocamlc','-package','yojson,digestif.ocaml,base64,ppx_deriving.eq,ppx_enumerate,ppx_deriving.show',
                            '-w','+4+32+69','-warn-error','+4+32+69','-linkpkg',*sources,'probe.ml','-o','probe'], cwd=directory,capture_output=True,text=True)
    if built.returncode:
        print(built.stdout+built.stderr)
        raise SystemExit(built.returncode)
    ran = subprocess.run([str(directory/'probe')],cwd=directory,capture_output=True,text=True)
    print(ran.stdout+ran.stderr)
    (OUT/'source-check.json').write_text(json.dumps({'scope':'Actual pure Query/Cursor/Snapshot modules + baseline visibility/current production revision fragments. Minimal unrelated typed ports; no full native Task tool, Keeper, SDK or model execution claim.',
        'baseline':BASE,'sources':records,'compile_exit':built.returncode,'compile_stderr':built.stderr,'run_exit':ran.returncode,'output':ran.stdout+ran.stderr},indent=2)+'\n')
    raise SystemExit(ran.returncode)
