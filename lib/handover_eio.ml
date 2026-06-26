(** MASC Handover - Agent Capsule Transfer (Eio Native)

    Implements the "last will and testament" pattern for agent succession.
    When an agent exits (context limit, timeout, crash), it leaves behind
    structured state for the next agent to inherit.
*)

(* Fiber-safe random state for handover ID generation *)
let handover_rng = Random.State.make_self_init ()

(** Handover record - the capsule passed to next agent *)
type handover_record = {
  id: string;
  from_agent: string;
  to_agent: string option;
  task_id: string;
  session_id: string;

  (* Core state *)
  current_goal: string;
  progress_summary: string;
  completed_steps: string list;
  pending_steps: string list;

  (* Thinking context *)
  key_decisions: string list;
  assumptions: string list;
  warnings: string list;

  (* Error state from PDCA *)
  unresolved_errors: string list;

  (* Files and resources *)
  modified_files: string list;

  (* Metadata *)
  created_at: float;
  context_usage_percent: int;
  handover_reason: string;
}

(** Handover trigger reasons *)
type trigger_reason =
  | ContextLimit of int
  | Timeout of int
  | Explicit
  | FatalError of string
  | TaskComplete

let trigger_reason_to_string = function
  | ContextLimit pct -> Printf.sprintf "context_limit_%d" pct
  | Timeout secs -> Printf.sprintf "timeout_%ds" secs
  | Explicit -> "explicit"
  | FatalError msg -> Printf.sprintf "error: %s" msg
  | TaskComplete -> "task_complete"

(** Generate unique handover ID *)
let generate_id () =
  let timestamp = Time_compat.now () in
  let random = Random.State.int handover_rng 100000 in
  Printf.sprintf "handover-%d-%05d" (int_of_float (timestamp *. 1000.)) random

(** Create empty handover record *)
let create_handover ~from_agent ~task_id ~session_id ~reason : handover_record =
  {
    id = generate_id ();
    from_agent;
    to_agent = None;
    task_id;
    session_id;
    current_goal = "";
    progress_summary = "";
    completed_steps = [];
    pending_steps = [];
    key_decisions = [];
    assumptions = [];
    warnings = [];
    unresolved_errors = [];
    modified_files = [];
    created_at = Time_compat.now ();
    context_usage_percent = 0;
    handover_reason = trigger_reason_to_string reason;
  }

(** Handover to JSON *)
let handover_to_json (h : handover_record) : Yojson.Safe.t =
  `Assoc [
    ("id", `String h.id);
    ("from_agent", `String h.from_agent);
    ("to_agent", Json_util.string_opt_to_json h.to_agent);
    ("task_id", `String h.task_id);
    ("session_id", `String h.session_id);
    ("current_goal", `String h.current_goal);
    ("progress_summary", `String h.progress_summary);
    ("completed_steps", `List (List.map (fun s -> `String s) h.completed_steps));
    ("pending_steps", `List (List.map (fun s -> `String s) h.pending_steps));
    ("key_decisions", `List (List.map (fun s -> `String s) h.key_decisions));
    ("assumptions", `List (List.map (fun s -> `String s) h.assumptions));
    ("warnings", `List (List.map (fun s -> `String s) h.warnings));
    ("unresolved_errors", `List (List.map (fun s -> `String s) h.unresolved_errors));
    ("modified_files", `List (List.map (fun s -> `String s) h.modified_files));
    ("created_at", `Float h.created_at);
    ("context_usage_percent", `Int h.context_usage_percent);
    ("handover_reason", `String h.handover_reason);
  ]

(** JSON to handover *)
let handover_of_json (json : Yojson.Safe.t) : handover_record option =
  let ( let* ) = Option.bind in
  let field fields key = List.assoc_opt key fields in
  let string_field fields key =
    match field fields key with
    | Some (`String value) -> Some value
    | _ -> None
  in
  let string_opt_field fields key =
    match field fields key with
    | Some (`String value) -> Some (Some value)
    | Some `Null -> Some None
    | _ -> None
  in
  let string_list_field fields key =
    match field fields key with
    | Some (`List values) ->
        let rec loop acc = function
          | [] -> Some (List.rev acc)
          | `String value :: rest -> loop (value :: acc) rest
          | _ -> None
        in
        loop [] values
    | _ -> None
  in
  let int_field fields key =
    match field fields key with
    | Some (`Int value) -> Some value
    | _ -> None
  in
  let float_field fields key =
    match field fields key with
    | Some (`Float value) -> Some value
    | Some (`Int value) -> Some (float_of_int value)
    | _ -> None
  in
  match json with
  | `Assoc fields ->
      let* id = string_field fields "id" in
      let* from_agent = string_field fields "from_agent" in
      let* to_agent = string_opt_field fields "to_agent" in
      let* task_id = string_field fields "task_id" in
      let* session_id = string_field fields "session_id" in
      let* current_goal = string_field fields "current_goal" in
      let* progress_summary = string_field fields "progress_summary" in
      let* completed_steps = string_list_field fields "completed_steps" in
      let* pending_steps = string_list_field fields "pending_steps" in
      let* key_decisions = string_list_field fields "key_decisions" in
      let* assumptions = string_list_field fields "assumptions" in
      let* warnings = string_list_field fields "warnings" in
      let* unresolved_errors = string_list_field fields "unresolved_errors" in
      let* modified_files = string_list_field fields "modified_files" in
      let* created_at = float_field fields "created_at" in
      let* context_usage_percent = int_field fields "context_usage_percent" in
      let* handover_reason = string_field fields "handover_reason" in
      Some
        {
          id;
          from_agent;
          to_agent;
          task_id;
          session_id;
          current_goal;
          progress_summary;
          completed_steps;
          pending_steps;
          key_decisions;
          assumptions;
          warnings;
          unresolved_errors;
          modified_files;
          created_at;
          context_usage_percent;
          handover_reason;
        }
  | _ -> None

(** Storage paths *)
let handover_dir_path (config : Workspace_utils.config) =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path:config.base_path)
    "handovers"

let handover_file_path config handover_id =
  Filename.concat (handover_dir_path config) (handover_id ^ ".json")

(** Ensure directory exists using Eio *)
let ensure_dir fs dir_path =
  let path = Eio.Path.(fs / dir_path) in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 path

(** Save handover to filesystem *)
let save_handover ~fs config (h : handover_record) : (unit, string) result =
  let dir = handover_dir_path config in
  ensure_dir fs dir;
  let file = handover_file_path config h.id in
  let json = handover_to_json h in
  try
    let path = Eio.Path.(fs / file) in
    Eio.Path.save ~create:(`Or_truncate 0o600) path (Yojson.Safe.pretty_to_string json);
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error (Printf.sprintf "Failed to save handover: %s" (Printexc.to_string exn))

(** Load handover from filesystem *)
let load_handover ~fs config handover_id : (handover_record, string) result =
  let file = handover_file_path config handover_id in
  let path = Eio.Path.(fs / file) in
  try
    let content = Eio.Path.load path in
    let json = Yojson.Safe.from_string content in
    match handover_of_json json with
    | Some h -> Ok h
    | None -> Error "Failed to parse handover JSON"
  with
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
      Error (Printf.sprintf "Handover not found: %s" handover_id)
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Error (Printf.sprintf "Failed to load handover: %s" (Printexc.to_string exn))

(** List all handovers *)
let list_handovers ~fs config : handover_record list =
  let surface = "handover_eio" in
  let observe_drop ~reason =
    Otel_metric_store.inc_counter Otel_metric_store.metric_persistence_read_drops
      ~labels:[("surface", surface); ("reason", reason)] ()
  in
  let report_drop ~reason ~path ~detail =
    Safe_ops.report_persistence_read_drop
      ~on_drop:(fun () -> observe_drop ~reason)
      ~surface
      ~reason
      ~path
      ~detail
  in
  let dir = handover_dir_path config in
  if not (Sys.file_exists dir) then
    []
  else
    match Safe_ops.list_dir_safe dir with
    | Error detail ->
      report_drop ~reason:Safe_ops.persistence_read_drop_reason_list_dir_error ~path:dir ~detail;
      []
    | Ok files ->
      let json_files = List.filter (fun f ->
        Filename.check_suffix f ".json" && f <> "pending.json"
      ) files in
      let handovers = List.filter_map (fun f ->
        let id = Filename.chop_suffix f ".json" in
        Safe_ops.result_to_option_logged
          ~on_drop:(fun () ->
            observe_drop ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error)
          ~surface
          ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
          ~path:(Filename.concat dir f)
          (load_handover ~fs config id)
      ) json_files in
      List.sort (fun a b -> compare b.created_at a.created_at) handovers

(** Get pending handovers *)
let get_pending_handovers ~fs config : handover_record list =
  let all = list_handovers ~fs config in
  List.filter (fun h -> h.to_agent = None) all

(** Claim a handover *)
let claim_handover ~fs config ~handover_id ~agent_name : (handover_record, string) result =
  match load_handover ~fs config handover_id with
  | Error e -> Error e
  | Ok h ->
    match h.to_agent with
    | Some claimed_by ->
      Error (Printf.sprintf "Handover already claimed by %s" claimed_by)
    | None ->
      let h' = { h with to_agent = Some agent_name } in
      match save_handover ~fs config h' with
      | Error e -> Error e
      | Ok () -> Ok h'

(** Format handover as markdown *)
let format_as_markdown (h : handover_record) : string =
  let buf = Buffer.create 2048 in
  let add s = Buffer.add_string buf s; Buffer.add_char buf '\n' in

  add "# Handover Capsule";
  add "";
  add (Printf.sprintf "**From**: %s → **To**: %s" h.from_agent
    (Option.value h.to_agent ~default:"(unclaimed)"));
  add (Printf.sprintf "**Task**: %s | **Reason**: %s" h.task_id h.handover_reason);
  add "";

  add "## Current Goal";
  add h.current_goal;
  add "";

  add "## Progress";
  add h.progress_summary;
  add "";

  if h.completed_steps <> [] then begin
    add "### Completed";
    List.iter (fun s -> add ("- " ^ s)) h.completed_steps;
    add ""
  end;

  if h.pending_steps <> [] then begin
    add "### Pending";
    List.iter (fun s -> add ("- " ^ s)) h.pending_steps;
    add ""
  end;

  if h.key_decisions <> [] then begin
    add "## Key Decisions (Why)";
    List.iter (fun s -> add ("- " ^ s)) h.key_decisions;
    add ""
  end;

  if h.assumptions <> [] then begin
    add "## 💭 Assumptions";
    List.iter (fun s -> add ("- " ^ s)) h.assumptions;
    add ""
  end;

  if h.warnings <> [] then begin
    add "## Warnings";
    List.iter (fun s -> add ("- " ^ s)) h.warnings;
    add ""
  end;

  if h.unresolved_errors <> [] then begin
    add "## Unresolved Errors";
    List.iter (fun s -> add ("- " ^ s)) h.unresolved_errors;
    add ""
  end;

  if h.modified_files <> [] then begin
    add "## 📁 Modified Files";
    List.iter (fun s -> add ("- " ^ s)) h.modified_files;
    add ""
  end;

  Buffer.contents buf
