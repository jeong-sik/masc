(** Execution Memory (Run) - Track task runs in .masc/runs/{task_id}

    Pure synchronous operations.
    Stores:
    - run.json (metadata)
    - plan.md
*)

open Workspace_utils

(** Run metadata *)
type run_record = {
  task_id: string;
  agent_name: string option;
  plan: string;
  created_at: string;
  updated_at: string;
}

let now_iso () = Masc_domain.now_iso ()

let run_record_to_json (r : run_record) : Yojson.Safe.t =
  `Assoc [
    ("task_id", `String r.task_id);
    ("agent_name", Json_util.string_opt_to_json r.agent_name);
    ("plan", `String r.plan);
    ("created_at", `String r.created_at);
    ("updated_at", `String r.updated_at);
  ]

let run_record_of_json (json : Yojson.Safe.t) : run_record option =
  let task_id = Safe_ops.json_string_opt "task_id" json in
  let created_at = Safe_ops.json_string_opt "created_at" json in
  let updated_at = Safe_ops.json_string_opt "updated_at" json in
  match task_id, created_at, updated_at with
  | Some task_id, Some created_at, Some updated_at ->
    let agent_name = Safe_ops.json_string_opt "agent_name" json in
    let plan = Safe_ops.json_string ~default:"" "plan" json in
    Some { task_id; agent_name; plan; created_at; updated_at }
  | _ ->
    Otel_metric_store.inc_counter Otel_metric_store.metric_error_events ~labels:[("type", Error_event_type.(to_label Parsing))] ();
    Log.Misc.error "run_of_json: missing required fields (task_id=%s created_at=%s updated_at=%s)"
      (match task_id with Some s -> s | None -> "(absent)")
      (match created_at with Some s -> s | None -> "(absent)")
      (match updated_at with Some s -> s | None -> "(absent)");
    None

let runs_dir (config : config) =
  Filename.concat (masc_dir config) "runs"

let run_dir (config : config) task_id =
  Filename.concat (runs_dir config) task_id

let run_json_path config task_id =
  Filename.concat (run_dir config task_id) "run.json"

let plan_path config task_id =
  Filename.concat (run_dir config task_id) "plan.md"

let ensure_run_dir config task_id =
  let dir = run_dir config task_id in
  if not (Sys.file_exists dir) then mkdir_p dir

let read_text_file path =
  if Sys.file_exists path then
    Fs_compat.load_file path
  else
    ""

let write_text_file path content =
  mkdir_p (Filename.dirname path);
  Fs_compat.save_file path content

let write_run_result config (run : run_record) =
  let path = run_json_path config run.task_id in
  write_json_result config path (run_record_to_json run)

let write_run config run =
  match write_run_result config run with
  | Ok () -> ()
  | Error error -> raise (Sys_error error)

let read_run config task_id : (run_record, string) result =
  let path = run_json_path config task_id in
  if not (path_exists config path) then
    Error
      (Printf.sprintf
         "No execution run record exists yet for task %s (expected run.json at %s)."
         task_id path)
  else
    match run_record_of_json (read_json config path) with
    | Some r -> Ok r
    | None ->
      Error
        (Printf.sprintf
           "Failed to parse run.json at %s (task %s) — file exists but \
            run_record_of_json returned None; check schema drift or \
            truncated write"
           path
           task_id)

(** Initialize run for task *)
let init config ~task_id ~agent_name : (run_record, string) result =
  try
    ensure_initialized config;
    ensure_run_dir config task_id;
    let created_at = Masc_domain.now_iso () in
    let run = {
      task_id;
      agent_name;
      plan = "";
      created_at;
      updated_at = created_at;
    } in
    (* Create default files *)
    let plan_file = plan_path config task_id in
    if not (path_exists config plan_file) then
      write_text_file plan_file "# Run Plan\n\n";
    (match write_run_result config run with
     | Ok () -> Ok run
     | Error _ as error -> error)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** Update plan.

    The read_run → modify → write_run sequence is a read-modify-write
    on [run.json]; two concurrent callers (different fibers handling
    [tool_run] MCP requests for the same task) would each read the
    same snapshot and the later writer would overwrite the earlier
    [plan] update.  Wrapped in a [with_file_lock] on [run.json] to
    serialise those writes.  The [plan.md] mirror at [plan_path] is a
    single full-content overwrite, so it does not need a separate
    lock — writing the mirror and the [run.json] record inside the
    same critical section keeps them consistent. *)
let update_plan config ~task_id ~content : (run_record, string) result =
  try
    let run_file = run_json_path config task_id in
    with_file_lock config run_file (fun () ->
      match read_run config task_id with
      | Error e -> Error e
      | Ok run ->
          let updated = { run with plan = content; updated_at = Masc_domain.now_iso () } in
          let path = plan_path config task_id in
          write_text_file path content;
          (match write_run_result config updated with
           | Ok () -> Ok updated
           | Error _ as error -> error))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** Get run details. Missing runs are bootstrapped so resume/read paths do
    not block autonomous keeper turns before any explicit masc_run_init call. *)
let get ?agent_name config ~task_id : (Yojson.Safe.t, string) result =
  let read_or_create_run () =
    let path = run_json_path config task_id in
    if path_exists config path then
      read_run config task_id
    else
      init config ~task_id ~agent_name
  in
  match read_or_create_run () with
  | Error e -> Error e
  | Ok run ->
    let plan_content =
      let text = read_text_file (plan_path config task_id) in
      if text = "" then run.plan else text
    in
    let json = `Assoc [
      ("run", run_record_to_json run);
      ("plan", `String plan_content);
    ] in
    Ok json

(** List runs *)
let list config : Yojson.Safe.t =
  let dir = runs_dir config in
  if not (Sys.file_exists dir) then
    `Assoc [("count", `Int 0); ("runs", `List [])]
  else
    let entries = Sys.readdir dir |> Array.to_list in
    let runs = List.filter_map (fun task_id ->
      let path = run_json_path config task_id in
      if path_exists config path then
        run_record_of_json (read_json config path)
      else None
    ) entries in
    `Assoc [
      ("count", `Int (List.length runs));
      ("runs", `List (List.map run_record_to_json runs));
    ]
