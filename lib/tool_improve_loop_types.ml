(** Tool_improve_loop_types — type definitions, JSON serde helpers, and
    constants for the improve-loop substrate. *)

module U = Yojson.Safe.Util

type result = bool * string

type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t option;
  clock : 'a Eio.Time.clock option;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
}

type loop_status =
  | Disabled
  | Running
  | Paused

type candidate_kind =
  | Merge_ready_pr
  | Conflict_pr
  | Failing_pr
  | Priority_issue
  | Backlog_issue

type pr_summary = {
  number : int;
  title : string;
  url : string option;
  head_ref_name : string;
  base_ref_name : string option;
  mergeable : string option;
  merge_state_status : string option;
  is_draft : bool;
  failing_checks : string list;
  pending_checks : string list;
}

type issue_summary = {
  number : int;
  title : string;
  url : string option;
  labels : string list;
}

type candidate = {
  kind : candidate_kind;
  number : int;
  title : string;
  url : string option;
  head_ref_name : string option;
  base_ref_name : string option;
  mergeable : string option;
  merge_state_status : string option;
  labels : string list;
  failing_checks : string list;
  pending_checks : string list;
}

type state = {
  enabled : bool;
  status : loop_status;
  keeper_name : string;
  poll_interval_sec : int;
  repo : string;
  repo_scope : string;
  merge_policy : string;
  dry_run : bool;
  current_candidate : candidate option;
  current_phase : string option;
  last_success : string option;
  last_failure : string option;
  consecutive_failures : int;
  last_merged_pr : int option;
  last_closed_issue : int option;
  paused_reason : string option;
  updated_at : float;
}

type command_result = {
  exit_code : int;
  stdout : string;
  stderr : string;
}

type driver = {
  list_prs : repo:string -> (pr_summary list, string) Stdlib.result;
  list_issues : repo:string -> (issue_summary list, string) Stdlib.result;
  run_command : string list -> command_result;
  now : unit -> float;
}

type action_plan = {
  action_id : string;
  phase : string;
  summary : string;
  candidate : candidate;
  worktree_path : string option;
  branch_name : string option;
  commands : string list;
  merge_command : string option;
  requires_team_session : bool;
  notes : string list;
}

(* ================================================================ *)
(* Constants                                                        *)
(* ================================================================ *)

let default_repo = "jeong-sik/masc-mcp"
let default_keeper_name = "masc-improver"
let default_poll_interval_sec = 300
let default_repo_scope = "masc-mcp-only"
let default_merge_policy = "squash"

(* ================================================================ *)
(* JSON helpers                                                     *)
(* ================================================================ *)

let string_member name json =
  match U.member name json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let bool_member name json =
  match U.member name json with
  | `Bool value -> Some value
  | _ -> None

let int_member name json =
  match U.member name json with
  | `Int value -> Some value
  | `Intlit raw -> Some (Safe_ops.int_of_string_with_default ~default:0 raw)
  | _ -> None

let float_member name json =
  match U.member name json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit raw -> Some (float_of_int (Safe_ops.int_of_string_with_default ~default:0 raw))
  | _ -> None

let list_string_member name json =
  match U.member name json with
  | `List values ->
      values
      |> List.filter_map (function
           | `String value ->
               let trimmed = String.trim value in
               if trimmed = "" then None else Some trimmed
           | _ -> None)
  | _ -> []

(* ================================================================ *)
(* Utility helpers                                                  *)
(* ================================================================ *)

let shell_join argv =
  String.concat " " (List.map Filename.quote argv)

let option_or_else left right =
  match left with
  | Some _ -> left
  | None -> right ()

let option_exists pred = function
  | Some value -> pred value
  | None -> false

let list_hd_opt = function
  | head :: _ -> Some head
  | [] -> None

let slugify title =
  let lowered = String.lowercase_ascii title in
  let buf = Buffer.create (String.length lowered) in
  let push_dash () =
    if Buffer.length buf > 0 && Buffer.nth buf (Buffer.length buf - 1) <> '-' then
      Buffer.add_char buf '-'
  in
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z' | '0' .. '9' -> Buffer.add_char buf c
      | _ -> push_dash ())
    lowered;
  let rec trim_bounds s =
    let len = String.length s in
    if len = 0 then "item"
    else if s.[0] = '-' then trim_bounds (String.sub s 1 (len - 1))
    else if s.[len - 1] = '-' then trim_bounds (String.sub s 0 (len - 1))
    else s
  in
  trim_bounds (Buffer.contents buf)

(* ================================================================ *)
(* Status/kind string conversions                                   *)
(* ================================================================ *)

let loop_status_to_string = function
  | Disabled -> "disabled"
  | Running -> "running"
  | Paused -> "paused"

let loop_status_of_string = function
  | "running" -> Running
  | "paused" -> Paused
  | _ -> Disabled

let candidate_kind_to_string = function
  | Merge_ready_pr -> "merge_ready_pr"
  | Conflict_pr -> "conflict_pr"
  | Failing_pr -> "failing_pr"
  | Priority_issue -> "priority_issue"
  | Backlog_issue -> "backlog_issue"

let candidate_kind_of_string = function
  | "merge_ready_pr" -> Merge_ready_pr
  | "conflict_pr" -> Conflict_pr
  | "failing_pr" -> Failing_pr
  | "priority_issue" -> Priority_issue
  | _ -> Backlog_issue

(* ================================================================ *)
(* Candidate / state JSON serde                                     *)
(* ================================================================ *)

let candidate_id (candidate : candidate) =
  Printf.sprintf "%s#%d"
    (candidate_kind_to_string candidate.kind)
    candidate.number

let candidate_to_json (candidate : candidate) =
  `Assoc
    [
      ("id", `String (candidate_id candidate));
      ("kind", `String (candidate_kind_to_string candidate.kind));
      ("number", `Int candidate.number);
      ("title", `String candidate.title);
      ("url", Option.fold ~none:`Null ~some:(fun value -> `String value) candidate.url);
      ( "head_ref_name",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          candidate.head_ref_name );
      ( "base_ref_name",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          candidate.base_ref_name );
      ( "mergeable",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          candidate.mergeable );
      ( "merge_state_status",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          candidate.merge_state_status );
      ("labels", `List (List.map (fun value -> `String value) candidate.labels));
      ( "failing_checks",
        `List (List.map (fun value -> `String value) candidate.failing_checks) );
      ( "pending_checks",
        `List (List.map (fun value -> `String value) candidate.pending_checks) );
    ]

let candidate_of_json json =
  {
    kind =
      string_member "kind" json
      |> Option.map candidate_kind_of_string
      |> Option.value ~default:Backlog_issue;
    number = int_member "number" json |> Option.value ~default:0;
    title = string_member "title" json |> Option.value ~default:"";
    url = string_member "url" json;
    head_ref_name = string_member "head_ref_name" json;
    base_ref_name = string_member "base_ref_name" json;
    mergeable = string_member "mergeable" json;
    merge_state_status = string_member "merge_state_status" json;
    labels = list_string_member "labels" json;
    failing_checks = list_string_member "failing_checks" json;
    pending_checks = list_string_member "pending_checks" json;
  }

let default_state ?(repo = default_repo) ?(now = Time_compat.now ()) () =
  {
    enabled = false;
    status = Disabled;
    keeper_name = default_keeper_name;
    poll_interval_sec = default_poll_interval_sec;
    repo;
    repo_scope = default_repo_scope;
    merge_policy = default_merge_policy;
    dry_run = false;
    current_candidate = None;
    current_phase = None;
    last_success = None;
    last_failure = None;
    consecutive_failures = 0;
    last_merged_pr = None;
    last_closed_issue = None;
    paused_reason = None;
    updated_at = now;
  }

let state_to_json (state : state) =
  `Assoc
    [
      ("enabled", `Bool state.enabled);
      ("status", `String (loop_status_to_string state.status));
      ("keeper_name", `String state.keeper_name);
      ("poll_interval_sec", `Int state.poll_interval_sec);
      ("repo", `String state.repo);
      ("repo_scope", `String state.repo_scope);
      ("merge_policy", `String state.merge_policy);
      ("dry_run", `Bool state.dry_run);
      ( "current_candidate",
        Option.fold ~none:`Null ~some:candidate_to_json state.current_candidate );
      ( "current_phase",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          state.current_phase );
      ( "last_success",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          state.last_success );
      ( "last_failure",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          state.last_failure );
      ("consecutive_failures", `Int state.consecutive_failures);
      ( "last_merged_pr",
        Option.fold ~none:`Null ~some:(fun value -> `Int value)
          state.last_merged_pr );
      ( "last_closed_issue",
        Option.fold ~none:`Null ~some:(fun value -> `Int value)
          state.last_closed_issue );
      ( "paused_reason",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          state.paused_reason );
      ("updated_at", `Float state.updated_at);
    ]

let state_of_json json =
  let default = default_state () in
  {
    enabled = bool_member "enabled" json |> Option.value ~default:default.enabled;
    status =
      string_member "status" json
      |> Option.map loop_status_of_string
      |> Option.value ~default:default.status;
    keeper_name =
      string_member "keeper_name" json |> Option.value ~default:default.keeper_name;
    poll_interval_sec =
      int_member "poll_interval_sec" json |> Option.value ~default:default.poll_interval_sec;
    repo = string_member "repo" json |> Option.value ~default:default.repo;
    repo_scope =
      string_member "repo_scope" json |> Option.value ~default:default.repo_scope;
    merge_policy =
      string_member "merge_policy" json |> Option.value ~default:default.merge_policy;
    dry_run = bool_member "dry_run" json |> Option.value ~default:default.dry_run;
    current_candidate =
      (match U.member "current_candidate" json with
       | `Assoc _ as payload -> Some (candidate_of_json payload)
       | _ -> None);
    current_phase = string_member "current_phase" json;
    last_success = string_member "last_success" json;
    last_failure = string_member "last_failure" json;
    consecutive_failures =
      int_member "consecutive_failures" json
      |> Option.value ~default:default.consecutive_failures;
    last_merged_pr = int_member "last_merged_pr" json;
    last_closed_issue = int_member "last_closed_issue" json;
    paused_reason = string_member "paused_reason" json;
    updated_at = float_member "updated_at" json |> Option.value ~default:default.updated_at;
  }

(* ================================================================ *)
(* Persistence paths                                                *)
(* ================================================================ *)

let loop_dir config =
  Filename.concat (Room.masc_dir config) "improve-loop"

let state_file config =
  Filename.concat (loop_dir config) "state.json"

let events_file config =
  Filename.concat (loop_dir config) "events.jsonl"

let save_state config (state : state) =
  let dir = loop_dir config in
  Fs_compat.mkdir_p dir;
  Fs_compat.save_file (state_file config)
    (Yojson.Safe.pretty_to_string (state_to_json state))

let load_state config =
  let path = state_file config in
  if Sys.file_exists path then
    try Yojson.Safe.from_file path |> state_of_json
    with exn ->
      Log.warn ~ctx:"ImproveLoop" "state load failed (%s), resetting: %s"
        path (Printexc.to_string exn);
      default_state ()
  else
    default_state ()

let append_event config event_type json =
  let dir = loop_dir config in
  Fs_compat.mkdir_p dir;
  Fs_compat.append_jsonl (events_file config)
    (`Assoc
      [
        ("timestamp", `Float (Time_compat.now ()));
        ("event_type", `String event_type);
        ("payload", json);
      ])

(* ================================================================ *)
(* Action plan JSON                                                 *)
(* ================================================================ *)

let action_plan_to_json (plan : action_plan) =
  `Assoc
    [
      ("action_id", `String plan.action_id);
      ("phase", `String plan.phase);
      ("summary", `String plan.summary);
      ("candidate", candidate_to_json plan.candidate);
      ( "worktree_path",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          plan.worktree_path );
      ( "branch_name",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          plan.branch_name );
      ("commands", `List (List.map (fun value -> `String value) plan.commands));
      ( "merge_command",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          plan.merge_command );
      ("requires_team_session", `Bool plan.requires_team_session);
      ("notes", `List (List.map (fun value -> `String value) plan.notes));
    ]

(* ================================================================ *)
(* Status/queue JSON helpers                                        *)
(* ================================================================ *)

let command_ok result =
  result.exit_code = 0

let run_and_capture driver argv =
  driver.run_command argv

let queue_json queue ~limit =
  queue
  |> (fun rows ->
       let rec take acc n = function
         | [] -> List.rev acc
         | _ when n <= 0 -> List.rev acc
         | row :: rest -> take (row :: acc) (n - 1) rest
       in
       take [] limit rows)
  |> List.map candidate_to_json
  |> fun rows -> `List rows

let state_status_json ?plan ?queue (state : state) =
  let base =
    match state_to_json state with
    | `Assoc fields -> fields
    | _ -> []
  in
  let extra =
    (match plan with Some value -> [ ("plan", action_plan_to_json value) ] | None -> [])
    @
    match queue with
    | Some (rows, limit) -> [ ("queue", queue_json rows ~limit); ("queue_size", `Int (List.length rows)) ]
    | None -> []
  in
  `Assoc (base @ extra)

let tick_due (state : state) ~now =
  if not state.enabled || state.status <> Running then
    false
  else if state.last_success = None && state.last_failure = None
          && state.current_candidate = None
  then
    true
  else
    now -. state.updated_at >= float_of_int (max 30 state.poll_interval_sec)

(* ================================================================ *)
(* State transition helpers                                         *)
(* ================================================================ *)

let mark_success state ?merged_pr ?closed_issue ~now ~phase message =
  {
    state with
    status = Running;
    enabled = true;
    current_phase = Some phase;
    last_success = Some message;
    last_failure = None;
    consecutive_failures = 0;
    last_merged_pr = (match merged_pr with Some value -> Some value | None -> state.last_merged_pr);
    last_closed_issue = (match closed_issue with Some value -> Some value | None -> state.last_closed_issue);
    paused_reason = None;
    updated_at = now;
  }

let mark_failure state ~now message =
  let consecutive_failures = state.consecutive_failures + 1 in
  if consecutive_failures >= 3 then
    {
      state with
      enabled = true;
      status = Paused;
      current_phase = Some "paused_after_failures";
      last_failure = Some message;
      consecutive_failures;
      paused_reason = Some "paused_after_three_consecutive_failures";
      updated_at = now;
    }
  else
    {
      state with
      enabled = true;
      status = Running;
      last_failure = Some message;
      consecutive_failures;
      updated_at = now;
    }
