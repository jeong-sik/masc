open Json_util

type agent = {
  name : string;
  status : string;
  current_task : string option;
  last_seen : string;
}

type task = {
  id : string;
  title : string;
  status : Masc_domain.task_status;
  priority : int;
  goal_ids : string list;
}

type keeper = {
  k_name : string;
  k_trace_id : string;
  k_paused : bool;
  k_current_task_id : string option;
  k_total_turns : int;
  k_total_tokens : int;
  k_total_cost_usd : float;
  k_last_turn_ts : string;
  k_last_proactive_outcome : string;
  k_created_at : string;
  k_updated_at : string;
}

(* One row of GET /api/v1/gate/keepers. That route is [masc_keeper_list], which
   renders [status] through [Keeper_status_runtime.keeper_surface_status] — the
   six-member surface vocabulary, with no "paused" member. Operator pause is
   durable metadata and arrives on the [keeper] record instead, so a reader
   that wants the published control-plane status composes the two. Parsing the
   status into the closed variant here means a producer that grows a seventh
   label is a rejected row, not a row that silently reads as something else. *)
type keeper_phase = Keeper_state_machine.phase

let keeper_phase_of_string = Keeper_state_machine.phase_of_string

type keeper_health = Keeper_types.keeper_health
let keeper_health_to_string = Keeper_status_runtime.keeper_health_to_string
let keeper_health_of_string = Keeper_status_runtime.keeper_health_of_string_opt

type keeper_health_reading =
  | Health_running
  | Health_idle
  | Health_offline
  | Health_stale
  | Health_degraded
  | Health_zombie

(* Exhaustive on purpose: a seventh member of [Keeper_types.keeper_health]
   stops the build here rather than arriving on screen as one of these six. *)
let keeper_health_reading : keeper_health -> keeper_health_reading = function
  | Keeper_types.KH_healthy -> Health_running
  | Keeper_types.KH_idle -> Health_idle
  | Keeper_types.KH_offline -> Health_offline
  | Keeper_types.KH_stale -> Health_stale
  | Keeper_types.KH_degraded -> Health_degraded
  | Keeper_types.KH_zombie -> Health_zombie

let keeper_next_action_of_string =
  Keeper_status_runtime.keeper_next_action_path_of_string_opt
let keeper_phase_to_string = Keeper_state_machine.phase_to_string

(* Exhaustive on purpose, like [keeper_health_reading]: a tenth phase stops
   the build here instead of silently counting as not-running on screen. *)
let keeper_phase_is_running : keeper_phase -> bool = function
  | Keeper_state_machine.Running -> true
  | Keeper_state_machine.Offline | Keeper_state_machine.Failing
  | Keeper_state_machine.Draining
  | Keeper_state_machine.Paused | Keeper_state_machine.Stopped
  | Keeper_state_machine.Crashed | Keeper_state_machine.Restarting ->
      false

type keeper_runtime = {
  kr_name : string;
  kr_health : keeper_health;
  kr_paused : bool;
  kr_next_action : Keeper_status_runtime.keeper_next_action_path option;
  kr_keepalive_running : bool;
  kr_autoboot_enabled : bool;
  kr_proactive_enabled : bool;
  kr_runtime_id : string;
  kr_phase : keeper_phase;
  (* Declared, not observed. It answers "which sandbox is this keeper set
     to", which is what a settings view is for; whether a given tool call
     actually ran there is a different reading and lives with the call. *)
  kr_sandbox_profile : string;
}

type keeper_lane_phase =
  | Lane_phase_offline
  | Lane_phase_running
  | Lane_phase_failing
  | Lane_phase_draining
  | Lane_phase_paused
  | Lane_phase_stopped
  | Lane_phase_crashed
  | Lane_phase_restarting
  | Lane_phase_unknown of string

type keeper_lane_turn_phase =
  | Lane_turn_idle
  | Lane_turn_prompting
  | Lane_turn_routing
  | Lane_turn_executing
  | Lane_turn_finalizing
  | Lane_turn_exhausted
  | Lane_turn_unknown of string

type keeper_lane_last_outcome = {
  klo_runtime_state : string;
  klo_selected_model : string option;
}

type keeper_lane = {
  kl_keeper : string;
  kl_phase : keeper_lane_phase;
  kl_turn_phase : keeper_lane_turn_phase;
  kl_idle_seconds : int;
  kl_last_outcome : keeper_lane_last_outcome option;
  kl_diagnosis : string option;
}

type keeper_lanes_snapshot = {
  kls_generated_at : float;
  kls_count : int;
  kls_lanes : keeper_lane list;
}

type standalone_lane_status =
  | Standalone_running
  | Standalone_idle
  | Standalone_degraded
  | Standalone_no_retained_observation
  | Standalone_unavailable

type standalone_lane_slot_count = {
  slsc_slot_id : string;
  slsc_count : int;
}

type standalone_lane = {
  sl_lane_id : string;
  sl_label : string;
  sl_required : bool;
  sl_status : standalone_lane_status;
  sl_configuration_state : string;
  sl_admitted_slots : string list;
  sl_cli_slots : string list;
  sl_dropped_slots : string list;
  sl_admission_error : string option;
  sl_retained_run_count : int;
  sl_running_count : int;
  sl_succeeded_count : int;
  sl_failed_count : int;
  sl_cancelled_count : int;
  sl_last_started_at : float option;
  sl_last_terminal_at : float option;
  sl_last_outcome : string option;
  sl_p50_elapsed_s : float option;
  sl_selected_slots : standalone_lane_slot_count list;
}

type standalone_lanes_snapshot = {
  sls_observed_at_unix : float;
  sls_exact_run_projection_count : int;
  sls_exact_run_source_total : int;
  sls_exact_run_projection_truncated : bool;
  sls_lanes : standalone_lane list;
}

type keeper_secret_status =
  | Secret_ready
  | Secret_empty
  | Secret_absent
  | Secret_error
  | Secret_status_unknown of string

type keeper_secret_projection = {
  ksp_keeper : string;
  ksp_status : keeper_secret_status;
  ksp_root : string;
  ksp_env_names : string list;
  ksp_file_paths : string list;
  ksp_values_validated : bool;
  ksp_error : string option;
}

type fusion_run_status =
  | Fusion_running
  | Fusion_completed
  | Fusion_failed of {
      frs_failure_code : string;
      frs_error : string;
    }

type fusion_run_stage =
  | Fusion_stage_accepted
  | Fusion_stage_panel of { frs_expected : int }
  | Fusion_stage_judge of
      { frs_expected : int
      ; frs_answered : int
      ; frs_failed : int
      }
  | Fusion_stage_computed of
      { frs_expected : int
      ; frs_answered : int
      ; frs_failed : int
      }
  | Fusion_stage_recording_evidence of
      { frs_expected : int
      ; frs_answered : int
      ; frs_failed : int
      }
  | Fusion_stage_completed
  | Fusion_stage_failed

type fusion_run = {
  fur_run_id : string;
  fur_keeper : string;
  fur_preset : string;
  fur_topology : Fusion_types.fusion_topology;
  fur_started_at : float;
  fur_status : fusion_run_status;
  fur_stage : fusion_run_stage;
  fur_decision : string option;
  fur_summary : string option;
}

type fusion_snapshot = {
  fus_generated_at : string;
  fus_runs : fusion_run list;
}

type fusion_panel_answer = {
  fpa_model : string;
  fpa_answer : string;
  fpa_input_tokens : int;
  fpa_output_tokens : int;
}

type fusion_panel_failure = {
  fpf_model : string;
  fpf_reason_code : string;
  fpf_reason_detail : string;
}

type fusion_panel_result =
  | Fusion_panel_answered of fusion_panel_answer
  | Fusion_panel_failed of fusion_panel_failure

type fusion_judge =
  | Fusion_judge_synthesized of {
      fj_decision : string;
      fj_resolved_answer : string;
      fj_reason : string;
    }
  | Fusion_judge_failed of {
      fj_failure_code : string;
      fj_error : string;
    }

type fusion_tool_phase =
  | Fusion_tool_panel
  | Fusion_tool_judge of string

type fusion_tool_actor =
  { fta_phase : fusion_tool_phase
  ; fta_identity : string
  }

type fusion_tool_preview =
  { ftp_text : string
  ; ftp_bytes : int
  ; ftp_truncated : bool
  }

type fusion_tool_completion =
  | Fusion_tool_succeeded of fusion_tool_preview
  | Fusion_tool_failed of
      { ftc_output : fusion_tool_preview
      ; ftc_recoverable : bool
      ; ftc_error_class : string option
      }

type fusion_tool_event =
  | Fusion_tool_called of
      { fte_actor : fusion_tool_actor
      ; fte_agent_name : string
      ; fte_tool_use_id : string
      ; fte_turn : int
      ; fte_planned_index : int
      ; fte_tool_name : string
      ; fte_input : fusion_tool_preview
      }
  | Fusion_tool_completed of
      { fte_actor : fusion_tool_actor
      ; fte_agent_name : string
      ; fte_tool_use_id : string
      ; fte_turn : int
      ; fte_planned_index : int
      ; fte_tool_name : string
      ; fte_completion : fusion_tool_completion
      }

type fusion_tool_gap =
  { ftg_actor : fusion_tool_actor
  ; ftg_reason : string
  }

type fusion_tool_trace =
  { ftt_complete : bool
  ; ftt_observed_actors : fusion_tool_actor list
  ; ftt_dropped_events : int
  ; ftt_gaps : fusion_tool_gap list
  ; ftt_events : fusion_tool_event list
  }

type fusion_evidence = {
  fe_post_id : string;
  fe_title : string;
  fe_question : string;
  fe_panel : fusion_panel_result list;
  fe_judge : fusion_judge;
  fe_tool_trace : fusion_tool_trace option;
}

type fusion_evidence_status =
  | Fusion_evidence_recorded
  | Fusion_evidence_pending
  | Fusion_evidence_absent

type fusion_detail = {
  fud_generated_at : string;
  fud_run : fusion_run;
  fud_evidence_status : fusion_evidence_status;
  fud_evidence : fusion_evidence option;
}

type goal_proof =
  | Proof_idle
  | Proof_pending
  | Proof_proven of string option
  | Proof_refuted of string option
  | Proof_unreadable of string option

type planning_goal = {
  pg_id : string;
  pg_title : string;
  pg_phase : Goal_phase.t;
  pg_priority : int;
  pg_due_date : string option;
  pg_metric : string option;
  pg_target_value : string option;
  pg_proof : goal_proof;
  pg_last_review_note : string option;
  (* RFC 3339 server timestamps. Optional because an older server build may
     not emit them; the TUI renders what is there rather than refusing the
     goal. *)
  pg_last_review_at : string option;
  pg_created_at : string option;
  pg_updated_at : string option;
}

type planning_rollup = {
  pr_active : int;
  pr_verifying : int;
  pr_done : int;
  pr_dropped : int;
}

type planning_backlog = {
  pb_todo : int;
  pb_claimed : int;
  pb_running : int;
  pb_done : int;
  pb_cancelled : int;
}

type planning_snapshot = {
  pl_goals : planning_goal list;
  pl_rollup : planning_rollup;
  pl_backlog : planning_backlog;
  pl_generated_at : string;
}

(* One tool call a keeper is holding for an operator's answer, from
   GET /api/v1/keepers/tool-approvals. [kta_asked_at] is the server clock's
   epoch reading when the wait opened; the drawing side derives age from it. *)
type keeper_tool_approval = {
  kta_keeper : string;
  kta_tool_call_id : string;
  kta_tool : string;
  kta_args : string;
  kta_question : string;
  kta_because : string option;
  kta_asked_at : float;
  kta_timeout_sec : float;
}

type fleet_safety = {
  fs_status : string;
  fs_blocker : string option;
  fs_operator_action_required : bool;
  fs_bootable_count : int;
  fs_running_count : int;
  fs_executable_count : int;
  fs_failing_count : int;
  fs_recovering_count : int;
  fs_paused_count : int;
  fs_target_reaction_capacity : int;
  fs_reaction_capacity_shortfall : int;
  fs_bootable_names : string list;
  fs_running_names : string list;
  fs_executable_names : string list;
  fs_active_task_owner_without_fiber_count : int;
  fs_completion_authority_pending_count : int;
}

type log_kind =
  | Log_turn
  | Log_heartbeat

type log_channel =
  | Log_channel_turn
  | Log_channel_scheduled_autonomous
  | Log_channel_heartbeat

type log_entry = {
  le_kind : log_kind;
  le_ts : string;
  le_channel : log_channel;
  le_message_count : int option;
  le_input_tokens : int option;
  le_output_tokens : int option;
  le_latency_ms : int option;
  le_cost_usd : float option;
  le_work_kind : string option;
  le_tools_used : string list;
}

type context_unavailable_reason =
  | Context_measurement_missing
  | Context_turn_record_undecodable
  | Context_turn_record_read_failed
  | Context_turn_record_without_usage
  | Context_turn_record_trace_mismatch
  | Context_conversation_cumulative_usage of
      { raw_input_tokens : int option
      ; context_window : int option
      }
  | Context_usage_scope_unavailable of
      { raw_input_tokens : int option
      ; context_window : int option
      }
  | Context_tokens_exceed_window of
      { raw_input_tokens : int
      ; context_window : int
      }

type context_observation =
  | Context_observed of {
      ratio : float option;
      tokens : int;
      maximum : int option;
      observed_at : string;
      turn_ref : string;
    }
  | Context_unavailable of context_unavailable_reason

let ( let* ) = Result.bind

let member key json =
  match Json_util.assoc_member_opt key json with
  | Some v -> v
  | None -> `Null

let required_member json key =
  match Json_util.assoc_member_opt key json with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing required field '%s'" key)

let optional_string json key =
  match member key json with
  | `Null -> Ok None
  | `String s -> Ok (Some s)
  | other ->
      Error
        (Printf.sprintf "field '%s' must be a string (received %s)" key
           (Json_util.kind_name other))

let required_nullable_int_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok None
  | Some (`Int n) -> Ok (Some n)
  | Some (`Intlit s) -> (
      match int_of_string_opt s with
      | Some n -> Ok (Some n)
      | None ->
          Error (Printf.sprintf "field '%s' has non-integer intlit %S" key s))
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be an int or null (received %s)" key
           (Json_util.kind_name other))

let required_nullable_float_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok None
  | Some (`Float value) -> Ok (Some value)
  | Some (`Int value) -> Ok (Some (Float.of_int value))
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be a float or null (received %s)" key
           (Json_util.kind_name other))

let required_nullable_string_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be a string or null (received %s)" key
           (Json_util.kind_name other))

let required_nullable_bool_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok None
  | Some (`Bool value) -> Ok (Some value)
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be a bool or null (received %s)" key
           (Json_util.kind_name other))

let require_null_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok ()
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be null (received %s)" key
           (Json_util.kind_name other))

let require_string_field json key = require_string json key
let require_int_field json key = require_int json key
let require_float_field json key = require_float json key
let required_bool_field json key =
  match member key json with
  | `Bool value -> Ok value
  | `Null -> Error (Printf.sprintf "missing required field '%s'" key)
  | bad ->
      Error
        (Printf.sprintf "field '%s' must be a bool (received %s)" key
           (Json_util.kind_name bad))

let require_string_list json key =
  match member key json with
  | `List items ->
      List.mapi
        (fun idx item ->
          match item with
          | `String value -> Ok value
          | bad ->
              Error
                (Printf.sprintf
                   "field '%s[%d]' must be a string (received %s)" key idx
                   (Json_util.kind_name bad)))
        items
      |> List.fold_left
           (fun acc item ->
             let* parsed = acc in
             let* value = item in
             Ok (value :: parsed))
           (Ok [])
      |> Result.map List.rev
  | `Null -> Error (Printf.sprintf "missing required field '%s'" key)
  | other ->
      Error
        (Printf.sprintf "field '%s' must be an array (received %s)" key
           (Json_util.kind_name other))

let decode_status json =
  match member "status" json with
  | `String s -> Ok s
  | `List (`String s :: _) -> Ok s
  | `List [] -> Error "field 'status' list must not be empty"
  | `List (bad :: _) ->
      Error
        (Printf.sprintf
           "field 'status' list head must be a string (received %s)"
           (Json_util.kind_name bad))
  | `Null -> Error "missing required field 'status'"
  | other ->
      Error
        (Printf.sprintf
           "field 'status' must be a string or non-empty string array \
            (received %s)"
           (Json_util.kind_name other))

let decode_agent json =
  let* name = require_string_field json "name" in
  let* status = decode_status json in
  let* current_task = optional_string json "current_task" in
  let* last_seen = require_string_field json "last_seen" in
  Ok { name; status; current_task; last_seen }

let task_of_domain ?(goal_ids = []) (task : Masc_domain.task) =
  {
    id = task.id;
    title = task.title;
    status = task.task_status;
    priority = task.priority;
    goal_ids;
  }

let active_tasks_of_domain ?goals_for_task tasks =
  let goal_ids (task : Masc_domain.task) =
    match goals_for_task with None -> [] | Some lookup -> lookup task.id
  in
  let active =
    tasks
    |> List.map (fun task -> task_of_domain ~goal_ids:(goal_ids task) task)
    |> List.filter (fun task ->
         not (Masc_domain.task_status_is_terminal task.status))
  in
  (* Rows that serve the same goal sit next to each other, so the flat list
     reads as goal clusters without header rows (headers would need their own
     cursor and scroll arithmetic). A cluster takes the priority of its hottest
     task: grouping must not bury an urgent row under a calmer goal that sorts
     earlier alphabetically. Ties fall to the goal id, goalless rows after
     goal-linked ones, then priority and id, so equal rows keep one order
     across refreshes. *)
  let cluster_of (task : task) =
    match task.goal_ids with [] -> None | goal :: _ -> Some goal
  in
  (* Goalless rows are not a cluster of each other: each carries its own
     priority, so one urgent standalone task does not hoist its unrelated
     goalless neighbours over a goal's rows. *)
  let hottest : (string, int) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (task : task) ->
      match cluster_of task with
      | None -> ()
      | Some cluster -> (
          match Hashtbl.find_opt hottest cluster with
          | Some best when best <= task.priority -> ()
          | Some _ | None -> Hashtbl.replace hottest cluster task.priority))
    active;
  let cluster_heat task =
    match cluster_of task with
    | None -> task.priority
    | Some cluster -> (
        match Hashtbl.find_opt hottest cluster with
        | Some heat -> heat
        | None -> task.priority)
  in
  List.stable_sort
    (fun (left : task) (right : task) ->
      let by_heat = Int.compare (cluster_heat left) (cluster_heat right) in
      if by_heat <> 0 then by_heat
      else
        match (cluster_of left, cluster_of right) with
        | Some l, Some r when not (String.equal l r) -> String.compare l r
        | Some _, None -> -1
        | None, Some _ -> 1
        | Some _, Some _ | None, None ->
            let by_priority = Int.compare left.priority right.priority in
            if by_priority <> 0 then by_priority
            else String.compare left.id right.id)
    active

let decode_task json =
  let* task = Masc_domain.task_of_yojson json in
  Ok (task_of_domain task)

let sanitize_terminal_text text =
  let escaped_byte byte = Printf.sprintf "\\x%02X" byte in
  let escaped_codepoint byte = Printf.sprintf "\\u00%02X" byte in
  let output = Buffer.create (String.length text) in
  let byte_at index = Char.code text.[index] in
  let is_continuation byte = byte >= 0x80 && byte <= 0xBF in
  let valid_utf8_length index =
    let remaining = String.length text - index in
    let first = byte_at index in
    if first >= 0xC2 && first <= 0xDF && remaining >= 2
       && is_continuation (byte_at (index + 1))
    then Some 2
    else if first = 0xE0 && remaining >= 3
            && byte_at (index + 1) >= 0xA0
            && byte_at (index + 1) <= 0xBF
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first >= 0xE1 && first <= 0xEC && remaining >= 3
            && is_continuation (byte_at (index + 1))
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first = 0xED && remaining >= 3
            && byte_at (index + 1) >= 0x80
            && byte_at (index + 1) <= 0x9F
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first >= 0xEE && first <= 0xEF && remaining >= 3
            && is_continuation (byte_at (index + 1))
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first = 0xF0 && remaining >= 4
            && byte_at (index + 1) >= 0x90
            && byte_at (index + 1) <= 0xBF
            && is_continuation (byte_at (index + 2))
            && is_continuation (byte_at (index + 3))
    then Some 4
    else if first >= 0xF1 && first <= 0xF3 && remaining >= 4
            && is_continuation (byte_at (index + 1))
            && is_continuation (byte_at (index + 2))
            && is_continuation (byte_at (index + 3))
    then Some 4
    else if first = 0xF4 && remaining >= 4
            && byte_at (index + 1) >= 0x80
            && byte_at (index + 1) <= 0x8F
            && is_continuation (byte_at (index + 2))
            && is_continuation (byte_at (index + 3))
    then Some 4
    else None
  in
  let rec append index =
    if index < String.length text
    then (
      let byte = Char.code text.[index] in
      if
        byte < 0x20 || (byte >= 0x7F && byte <= 0x9F)
      then (
        Buffer.add_string output (escaped_byte byte);
        append (index + 1))
      else if byte < 0x80
      then (
        Buffer.add_char output text.[index];
        append (index + 1))
      else if
        byte = 0xC2
        && index + 1 < String.length text
        && let next = Char.code text.[index + 1] in
           next >= 0x80 && next <= 0x9F
      then (
        Buffer.add_string output (escaped_codepoint (Char.code text.[index + 1]));
        append (index + 2))
      else
        match valid_utf8_length index with
        | Some length ->
          Buffer.add_substring output text index length;
          append (index + length)
        | None ->
          Buffer.add_string output (escaped_byte byte);
          append (index + 1))
  in
  append 0;
  Buffer.contents output
;;

let short_timestamp_for_terminal text =
  sanitize_terminal_text
    (if String.length text > 19 then String.sub text 0 19
     else if String.length text = 0 then "(never)"
     else text)
;;

(* The clock beside a row, in the zone the operator's terminal is in. The
   server writes RFC 3339 on the UTC timeline; slicing HH:MM:SS straight out
   of that string put a UTC clock on every log row under a header that showed
   local time, nine hours apart in Seoul. [localtime] is the conversion the
   caller chooses -- the terminal's own zone on a screen, a fixed one in a
   test -- so this stays a function of its inputs. A timestamp the codec
   cannot read keeps the old slice: the byte positions are still where a
   clock would be, and the sanitizer still makes them safe to draw. *)
let clock_timestamp_for_terminal ~localtime text =
  sanitize_terminal_text
    (match Time_codec.parse_rfc3339_opt text with
     | Some unix_seconds ->
         let tm = localtime unix_seconds in
         Printf.sprintf "%02d:%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min
           tm.Unix.tm_sec
     | None -> if String.length text >= 19 then String.sub text 11 8 else text)
;;

let keeper_of_meta (meta : Keeper_meta_contract.keeper_meta) =
  let runtime = meta.runtime in
  let usage = runtime.usage in
  let proactive = runtime.proactive_rt in
  let k_last_turn_ts =
    if Float.compare usage.last_turn_ts 0.0 <= 0 then ""
    else Masc_domain.iso8601_of_unix_seconds usage.last_turn_ts
  in
  {
    k_name = meta.name;
    k_trace_id = Keeper_id.Trace_id.to_string runtime.trace_id;
    k_paused = meta.paused;
    k_current_task_id =
      Option.map Keeper_id.Task_id.to_string meta.current_task_id;
    k_total_turns = usage.total_turns;
    k_total_tokens = usage.total_tokens;
    k_total_cost_usd = usage.total_cost_usd;
    k_last_turn_ts;
    k_last_proactive_outcome =
      Keeper_meta_contract.proactive_cycle_outcome_to_string
        proactive.last_outcome;
    k_created_at = meta.created_at;
    k_updated_at = meta.updated_at;
  }

let decode_keeper json =
  let* meta = Keeper_meta_json_parse.meta_of_json json in
  Ok (keeper_of_meta meta)

let decode_turn_channel raw =
  match Keeper_world_observation.channel_of_string raw with
  | Some Keeper_world_observation.Reactive -> Ok Log_channel_turn
  | Some Keeper_world_observation.Scheduled_autonomous ->
      Ok Log_channel_scheduled_autonomous
  | None -> Error (Printf.sprintf "unknown current turn channel %S" raw)

let decode_turn_mode json =
  let* raw = require_string_field json "turn_mode" in
  match Turn_mode_codec.turn_mode_of_string raw with
  | Some mode -> Ok mode
  | None -> Error (Printf.sprintf "unknown current turn mode %S" raw)

let validate_usage_projection ~input_tokens ~output_tokens
    ~cache_creation_tokens ~cache_read_tokens ~total_tokens ~cost_usd
    ~inner_trust ~inner_anomaly ~inner_reasons ~outer_trust ~outer_reasons =
  let classified =
    match
      ( input_tokens,
        output_tokens,
        cache_creation_tokens,
        cache_read_tokens,
        total_tokens,
        cost_usd )
    with
    | ( Some input_tokens,
        Some output_tokens,
        Some cache_creation_tokens,
        Some cache_read_tokens,
        Some total_tokens,
        Some cost_usd ) ->
        if total_tokens <> input_tokens + output_tokens then
          Error "usage total_tokens does not equal input_tokens + output_tokens"
        else
          let usage : Agent_core.Types.api_usage =
            { input_tokens;
              output_tokens;
              cache_creation_input_tokens = cache_creation_tokens;
              cache_read_input_tokens = cache_read_tokens;
              cost_usd = Some cost_usd;
            }
          in
          Ok (Keeper_usage_trust.classify ~usage_reported:true ~usage)
    | None, None, None, None, None, None ->
        let usage : Agent_core.Types.api_usage =
          { input_tokens = 0;
            output_tokens = 0;
            cache_creation_input_tokens = 0;
            cache_read_input_tokens = 0;
            cost_usd = None;
          }
        in
        Ok (Keeper_usage_trust.classify ~usage_reported:false ~usage)
    | _ ->
        Error
          "usage tokens, cost, and trust must form one current atomic observation"
  in
  let* classified = classified in
  let expected_trust = Keeper_usage_trust.to_string classified in
  let expected_reasons = Keeper_usage_trust.reasons classified in
  let expected_anomaly =
    match classified with
    | Keeper_usage_trust.Usage_untrusted _ -> true
    | Keeper_usage_trust.Usage_missing | Keeper_usage_trust.Usage_trusted ->
        false
  in
  if
    not
      (String.equal inner_trust expected_trust
      && String.equal outer_trust expected_trust)
  then Error "usage trust does not match the current counter observation"
  else if inner_anomaly <> expected_anomaly then
    Error "usage anomaly flag does not match the current trust classification"
  else if inner_reasons <> expected_reasons || outer_reasons <> expected_reasons
  then Error "usage anomaly reasons do not match the current trust classification"
  else Ok ()

let decode_log_entry json =
  let* kind =
    match Keeper_metrics_record.kind_of_json json with
    | Some kind -> Ok kind
    | None -> Error "unknown current keeper metrics schema or record kind"
  in
  let* le_ts = require_string_field json "ts" in
  let* _ts_unix = require_float_field json "ts_unix" in
  let* raw_channel = require_string_field json "channel" in
  let* _name = require_string_field json "name" in
  let* _agent_name = require_string_field json "agent_name" in
  let* _trace_id = require_string_field json "trace_id" in
  match kind with
  | Keeper_metrics_record.Heartbeat ->
      if not (String.equal raw_channel "heartbeat") then
        Error
          (Printf.sprintf "heartbeat metrics row has invalid channel %S"
             raw_channel)
      else
        let* le_message_count =
          required_nullable_int_field json "message_count"
        in
        let* () =
          if Option.exists (fun count -> count < 0) le_message_count then
            Error "heartbeat message_count must be non-negative"
          else Ok ()
        in
        Ok
          { le_kind = Log_heartbeat;
            le_ts;
            le_channel = Log_channel_heartbeat;
            le_message_count;
            le_input_tokens = None;
            le_output_tokens = None;
            le_latency_ms = None;
            le_cost_usd = None;
            le_work_kind = None;
            le_tools_used = [];
          }
  | Keeper_metrics_record.Turn ->
      let* le_channel = decode_turn_channel raw_channel in
      let* le_message_count = require_int_field json "message_count" in
      let* () =
        if le_message_count < 0 then
          Error "turn message_count must be non-negative"
        else Ok ()
      in
      let* usage =
        match member "usage" json with
        | `Assoc _ as usage -> Ok usage
        | `Null -> Error "missing required field 'usage'"
        | other ->
            Error
              (Printf.sprintf "field 'usage' must be an object (received %s)"
                 (Json_util.kind_name other))
      in
      let* le_input_tokens =
        required_nullable_int_field usage "input_tokens"
      in
      let* le_output_tokens =
        required_nullable_int_field usage "output_tokens"
      in
      let* cache_creation_tokens =
        required_nullable_int_field usage "cache_creation_tokens"
      in
      let* cache_read_tokens =
        required_nullable_int_field usage "cache_read_tokens"
      in
      let* total_tokens = required_nullable_int_field usage "total_tokens" in
      let* inner_usage_trust = require_string_field usage "usage_trust" in
      let* inner_usage_anomaly = require_bool usage "usage_anomaly" in
      let* inner_usage_anomaly_reasons =
        require_string_list usage "usage_anomaly_reasons"
      in
      let* outer_usage_trust = require_string_field json "usage_trust" in
      let* outer_usage_anomaly_reasons =
        require_string_list json "usage_anomaly_reasons"
      in
      let* latency_ms = require_int_field json "latency_ms" in
      let* () =
        if latency_ms < 0 then Error "latency_ms must be non-negative" else Ok ()
      in
      let* le_cost_usd = required_nullable_float_field json "cost_usd" in
      let* () =
        validate_usage_projection ~input_tokens:le_input_tokens
          ~output_tokens:le_output_tokens ~cache_creation_tokens
          ~cache_read_tokens ~total_tokens ~cost_usd:le_cost_usd
          ~inner_trust:inner_usage_trust
          ~inner_anomaly:inner_usage_anomaly
          ~inner_reasons:inner_usage_anomaly_reasons
          ~outer_trust:outer_usage_trust
          ~outer_reasons:outer_usage_anomaly_reasons
      in
      let* turn_mode = decode_turn_mode json in
      let* tool_call_count = require_int_field json "tool_call_count" in
      let* le_tools_used = require_string_list json "tools_used" in
      let* () =
        if tool_call_count < 0 then Error "tool_call_count must be non-negative"
        else if tool_call_count <> List.length le_tools_used then
          Error "tool_call_count does not match tools_used"
        else
          match turn_mode with
          | Turn_mode_codec.Tool_use -> Ok ()
          | Turn_mode_codec.Text_response
          | Turn_mode_codec.Skip_text
          | Turn_mode_codec.Noop ->
              if tool_call_count = 0 then Ok ()
              else Error "non-tool turn mode cannot carry tool calls"
      in
      Ok
        { le_kind = Log_turn;
          le_ts;
          le_channel;
          le_message_count = Some le_message_count;
          le_input_tokens;
          le_output_tokens;
          le_latency_ms = Some latency_ms;
          le_cost_usd;
          le_work_kind =
            Some (Turn_mode_codec.work_kind_of_turn_mode turn_mode);
          le_tools_used;
        }

let parse_log_entry line =
  let json =
    try Ok (Yojson.Safe.from_string line)
    with Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
  in
  let* json = json in
  decode_log_entry json

let optional_int_field json key =
  match Json_util.assoc_member_opt key json with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some other ->
    Error
      (Printf.sprintf
         "field '%s' must be an integer or null (received %s)"
         key
         (Json_util.kind_name other))
;;

let context_unavailable_reason_of_json json raw =
  let* raw_input_tokens = optional_int_field json "raw_input_tokens" in
  let* context_window = optional_int_field json "context_window" in
  let usage_scope =
    match Json_util.assoc_member_opt "usage_scope" json with
    | Some (`String value) -> Some value
    | Some _ | None -> None
  in
  match raw with
  | "context_measurement_missing" -> Ok Context_measurement_missing
  | "turn_record_undecodable" -> Ok Context_turn_record_undecodable
  | "turn_record_read_failed" -> Ok Context_turn_record_read_failed
  | "turn_record_without_usage" -> Ok Context_turn_record_without_usage
  | "turn_record_trace_mismatch" -> Ok Context_turn_record_trace_mismatch
  | "conversation_cumulative_usage"
    when usage_scope = Some "conversation_cumulative" ->
    Ok (Context_conversation_cumulative_usage { raw_input_tokens; context_window })
  | "usage_scope_unavailable" when usage_scope = Some "unavailable" ->
    Ok (Context_usage_scope_unavailable { raw_input_tokens; context_window })
  | "context_tokens_exceed_window" ->
    (match usage_scope, raw_input_tokens, context_window with
     | Some "per_request", Some raw_input_tokens, Some context_window ->
       Ok (Context_tokens_exceed_window { raw_input_tokens; context_window })
     | _ -> Error "context token overflow diagnostics are incomplete")
  | raw -> Error (Printf.sprintf "unknown context unavailable reason %S" raw)

let context_unavailable_reason_to_string = function
  | Context_measurement_missing -> "context measurement missing"
  | Context_turn_record_undecodable -> "turn record undecodable"
  | Context_turn_record_read_failed -> "turn record read failed"
  | Context_turn_record_without_usage -> "turn record has no provider usage"
  | Context_turn_record_trace_mismatch -> "turn record belongs to a prior trace"
  | Context_conversation_cumulative_usage { raw_input_tokens; context_window } ->
    Printf.sprintf
      "cumulative usage %s tokens (window %s); occupancy not observed"
      (Option.fold ~none:"unknown" ~some:string_of_int raw_input_tokens)
      (Option.fold ~none:"unknown" ~some:string_of_int context_window)
  | Context_usage_scope_unavailable { raw_input_tokens; context_window } ->
    Printf.sprintf
      "usage scope unavailable (input %s, window %s)"
      (Option.fold ~none:"unknown" ~some:string_of_int raw_input_tokens)
      (Option.fold ~none:"unknown" ~some:string_of_int context_window)
  | Context_tokens_exceed_window { raw_input_tokens; context_window } ->
    Printf.sprintf
      "per-request usage exceeds window: %d / %d tokens"
      raw_input_tokens
      context_window

let require_object_member json key =
  let* value = required_member json key in
  match value with
  | `Assoc _ as object_value -> Ok object_value
  | other ->
      Error
        (Printf.sprintf "field '%s' must be an object (received %s)" key
           (Json_util.kind_name other))

let decode_context_unavailable_payload json =
  let* kind = require_string_field json "kind" in
  if not (String.equal kind "not_observed") then
    Error (Printf.sprintf "unknown context unavailable kind %S" kind)
  else
    let* reason = require_string_field json "reason" in
    context_unavailable_reason_of_json json reason

let validate_context_ratio ~tokens ~maximum ~ratio =
  match maximum, ratio with
  | Some maximum, Some ratio when maximum > 0 ->
      let expected = Float.of_int tokens /. Float.of_int maximum in
      let tolerance = 1e-12 *. Float.max 1.0 (Float.abs expected) in
      if Float.is_finite ratio && Float.abs (ratio -. expected) <= tolerance then
        Ok ()
      else Error "context ratio does not match tokens / context window"
  | Some maximum, None when maximum > 0 ->
      Error "positive context window requires an observed ratio"
  | (None | Some 0), None -> Ok ()
  | (None | Some 0), Some _ ->
      Error "context ratio requires a positive context window"
  | Some _, (Some _ | None) -> Error "context window must be non-negative"

let decode_context_observation ~expected_trace_id json =
  match Json_util.assoc_member_opt "context_metrics_unavailable" json with
  | None -> Error "missing required field 'context_metrics_unavailable'"
  | Some (`Assoc _ as unavailable) ->
      let* reason = decode_context_unavailable_payload unavailable in
      let* () = require_null_field json "context_ratio" in
      let* () = require_null_field json "context_tokens" in
      let* () = require_null_field json "context_max" in
      let* () = require_null_field json "context_source" in
      let* context = require_object_member json "context" in
      let* () = require_null_field context "source" in
      let* () = require_null_field context "context_ratio" in
      let* () = require_null_field context "context_tokens" in
      let* () = require_null_field context "context_max" in
      let* nested_unavailable =
        require_object_member context "metrics_unavailable"
      in
      let* nested_reason =
        decode_context_unavailable_payload nested_unavailable
      in
      if nested_reason <> reason then
        Error "nested and top-level context unavailable reasons disagree"
      else Ok (Context_unavailable reason)
  | Some `Null ->
      let* ratio = required_nullable_float_field json "context_ratio" in
      let* tokens = require_int_field json "context_tokens" in
      let* maximum = required_nullable_int_field json "context_max" in
      let* source = require_string_field json "context_source" in
      if not (String.equal source "turn_record") then
        Error (Printf.sprintf "unknown context observation source %S" source)
      else if
        tokens < 0
        || Option.exists (fun value -> not (Float.is_finite value)) ratio
      then
        Error "context observation has an invalid numeric range"
      else
        let* () = validate_context_ratio ~tokens ~maximum ~ratio in
        let* context = require_object_member json "context" in
        let* nested_source = require_string_field context "source" in
        let* nested_ratio =
          required_nullable_float_field context "context_ratio"
        in
        let* nested_tokens = require_int_field context "context_tokens" in
        let* nested_maximum =
          required_nullable_int_field context "context_max"
        in
        let* () = require_null_field context "metrics_unavailable" in
        if not (String.equal nested_source source) then
          Error "nested and top-level context sources disagree"
        else if
          nested_ratio <> ratio || nested_tokens <> tokens
          || nested_maximum <> maximum
        then Error "nested and top-level context measurements disagree"
        else
          let* observed_at = require_string_field context "observed_at" in
          let* turn_ref_json = required_member context "turn_ref" in
          let* turn_ref = Ids.Turn_ref.of_yojson turn_ref_json in
          let* absolute_turn = require_int_field context "absolute_turn" in
          let* request_body_bytes =
            required_nullable_int_field context "request_body_bytes"
          in
          if
            not
              (String.equal (Ids.Turn_ref.trace_id turn_ref) expected_trace_id)
          then Error "context turn reference belongs to a different trace"
          else if absolute_turn <> Ids.Turn_ref.absolute_turn turn_ref then
            Error "context absolute turn disagrees with its turn reference"
          else if Option.exists (fun value -> value < 0) request_body_bytes then
            Error "context request body bytes must be non-negative"
          else
            Ok
              (Context_observed
                 { ratio;
                   tokens;
                   maximum;
                   observed_at;
                   turn_ref = Ids.Turn_ref.to_string turn_ref;
                 })
  | Some other ->
      Error
        (Printf.sprintf
           "field 'context_metrics_unavailable' must be an object or null (received %s)"
           (Json_util.kind_name other))

let trim = String.trim

let split_headers_body response =
  let marker = "\r\n\r\n" in
  let rec find idx =
    if idx + String.length marker > String.length response then None
    else if String.sub response idx (String.length marker) = marker then
      Some (idx + String.length marker)
    else
      find (idx + 1)
  in
  match find 0 with
  | Some idx -> Some (String.sub response idx (String.length response - idx))
  | None -> None

let is_success_http_status status_code = status_code >= 200 && status_code < 300

let http_status_error ~status_code ~body =
  let body = String.trim body in
  let detail =
    if body = "" then "empty response body"
    else if String.length body > 240 then String.sub body 0 240 ^ "..."
    else body
  in
  Printf.sprintf "HTTP %d: %s" status_code detail

let decode_json_response_body ~allow_empty ~status_code ~body :
    (Yojson.Safe.t, string) result =
  if not (is_success_http_status status_code) then
    Error (http_status_error ~status_code ~body)
  else if String.length (String.trim body) = 0 then
    if allow_empty then Ok (`Assoc []) else Error "empty response body"
  else
    try Ok (Yojson.Safe.from_string body)
    with Yojson.Json_error e -> Error (Printf.sprintf "(JSON parse: %s)" e)

(** The [/api/v1/tools/*] write endpoints answer one envelope,
    [{ok : bool; message : string}]. Reduced to a one-line outcome here so
    every call site reports the server's own message instead of re-decoding
    the envelope -- and a shape the endpoint never sends is an error rather
    than a guessed success. *)
let tool_envelope_outcome (json : Yojson.Safe.t) : (string, string) result =
  let envelope_message fields =
    match List.assoc_opt "message" fields with
    | Some (`String message) -> message
    | Some _ | None -> ""
  in
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "ok" fields with
      | Some (`Bool ok) ->
          let message = envelope_message fields in
          if ok then
            Ok (if String.equal message "" then "posted" else message)
          else
            Error
              (if String.equal message "" then "request rejected" else message)
      | _ -> Error "unexpected tool response envelope")
  | _ -> Error "unexpected tool response envelope"

(* [POST /api/v1/verification/verdict] answers [{ok = true; message; noop}]
   on the success status; a refusal rides a non-2xx status and never reaches
   this decoder through [post_json]. [noop = true] says the verdict already
   stood and this call changed nothing -- the caller words its event with
   that rather than reading "recorded" off a write that did not happen. *)
let verification_verdict_outcome (json : Yojson.Safe.t) :
    (string * bool, string) result =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "ok" fields with
      | Some (`Bool true) ->
          let message =
            match List.assoc_opt "message" fields with
            | Some (`String m) when String.trim m <> "" -> m
            | Some _ | None -> "verdict recorded"
          in
          let noop =
            match List.assoc_opt "noop" fields with
            | Some (`Bool b) -> b
            | Some _ | None -> false
          in
          Ok (message, noop)
      | Some (`Bool false) -> (
          match List.assoc_opt "error" fields with
          | Some (`String e) -> Error e
          | Some _ | None -> Error "verdict rejected")
      | Some _ | None -> Error "unexpected verdict response envelope")
  | _ -> Error "unexpected verdict response envelope"

(** Decode one SGR-encoded mouse report ([CSI ?1006;1000h] mode) into a key.

    A wheel report becomes [wheel-up] / [wheel-down] rather than the arrow keys
    it used to share. Two things wanted to be told apart: a wheel notch moves
    further than one row, and the chat composer answers the arrows with its own
    history. A surface that scrolls binds both. Wheel-up is button [64],
    wheel-down [65]; the horizontal wheel, clicks, and releases stay [None] -- the
    terminal sends them, but nothing consumes them yet, and an unconsumed
    report must not masquerade as a claimed key. [parameters] is the raw CSI
    parameter span (["<64;10;5"] for a wheel-up at column 10, row 5) and
    [final] the CSI final byte. *)
let sgr_wheel_key (parameters : string) (final : char) : string option =
  if final <> 'M' then None
  else
    match String.split_on_char ';' parameters with
    | button :: _ ->
        if String.equal button "<64" then Some "wheel-up"
        else if String.equal button "<65" then Some "wheel-down"
        else None
    | [] -> None

(** Decode an SGR mouse report into the position of a plain left-button press.

    Only the unmodified press (button [0], final [M]) answers: a release
    (final [m]) would act twice per click, and modifier/motion bits mean the
    operator was dragging or chord-clicking rather than choosing a row. The
    position is 1-based, the way the terminal reports it, and stays row/column
    ordered the way a frame thinks. Everything else stays [None] for the same
    reason [sgr_wheel_key] gives: an unconsumed report must not masquerade as
    a claimed key. *)
let sgr_left_press (parameters : string) (final : char) : (int * int) option =
  if final <> 'M' then None
  else
    match String.split_on_char ';' parameters with
    | [ "<0"; column; row ] -> (
        match int_of_string_opt column, int_of_string_opt row with
        | Some column, Some row when column > 0 && row > 0 -> Some (row, column)
        | _, _ -> None)
    | _ -> None

(** Decode the button byte of a legacy X10 mouse report ([CSI M] followed by
    three raw bytes) into the same key an SGR report produces.

    Terminals that do not implement SGR ([?1006]) still answer the tracking
    request ([?1000]) in this older shape. Apple Terminal is one, and it is the
    macOS default: the combined [?1006;1000h] request leaves it reporting X10,
    so a reader that only understands SGR sees [CSI M], calls the sequence
    unknown, and leaves the three coordinate bytes in the stream to be typed as
    text. Live shape 2026-08-24: one wheel notch put three characters in the
    chat composer.

    Each byte is offset by 32. Wheel-up is button 64 and wheel-down 65, the
    same numbers SGR uses. Clicks, releases, and drags return [None] — nothing
    consumes them yet — but the caller must still consume their bytes. *)
let x10_wheel_key (button : char) : string option =
  match Char.code button - 32 with
  | 64 -> Some "wheel-up"
  | 65 -> Some "wheel-down"
  | _ -> None
;;

let missing_field key =
  Error (Printf.sprintf "missing required field '%s'" key)

let field_type_error key expected value =
  Error
    (Printf.sprintf "field '%s' must be %s (received %s)" key expected
       (Json_util.kind_name value))

let required_string_field json key =
  match member key json with
  | `String value -> Ok value
  | `Null -> missing_field key
  | bad -> field_type_error key "a string" bad

let optional_string_field json key =
  match member key json with
  | `String value -> Ok (Some value)
  | `Null -> Ok None
  | bad -> field_type_error key "a string or null" bad

let optional_bool_field json key =
  match member key json with
  | `Bool value -> Ok (Some value)
  | `Null -> Ok None
  | bad -> field_type_error key "a boolean or null" bad

(* Absent reads as [None] here: the exact-lane run summary omits its
   completion fields entirely while a run is still running, rather than
   sending null. *)
let optional_float_field json key =
  match member key json with
  | `Float value -> Ok (Some value)
  | `Int value -> Ok (Some (Float.of_int value))
  | `Null -> Ok None
  | bad -> field_type_error key "a float or null" bad

let required_int_field json key =
  match member key json with
  | `Int value -> Ok value
  | `Intlit raw -> (
      match int_of_string_opt raw with
      | Some value -> Ok value
      | None -> Error (Printf.sprintf "field '%s' has invalid int %S" key raw))
  | `Null -> missing_field key
  | bad -> field_type_error key "an int" bad

let int_field_or json key ~default =
  match member key json with
  | `Null -> Ok default
  | _ -> required_int_field json key

let required_display_field json key =
  match member key json with
  | `String value -> Ok value
  | `Int value -> Ok (string_of_int value)
  | `Intlit value -> Ok value
  | `Float value -> Ok (Printf.sprintf "%.0f" value)
  | `Null -> missing_field key
  | bad -> field_type_error key "a scalar display value" bad

let required_display_any_field json keys =
  let rec loop = function
    | [] ->
        Error
          (Printf.sprintf "missing required field '%s'"
             (String.concat "' or '" keys))
    | key :: rest -> (
        match member key json with
        | `Null -> loop rest
        | _ -> required_display_field json key)
  in
  loop keys

let optional_body_field json =
  match member "body" json with
  | `String value -> Ok value
  | `Null -> (
      match member "content" json with
      | `String value -> Ok value
      | `Null -> Ok ""
      | bad -> field_type_error "content" "a string" bad)
  | bad -> field_type_error "body" "a string" bad

let required_body_field json =
  match member "body" json with
  | `String value -> Ok value
  | `Null -> required_string_field json "content"
  | bad -> field_type_error "body" "a string" bad

let required_list_field json key =
  match member key json with
  | `List items -> Ok items
  | `Null -> missing_field key
  | bad -> field_type_error key "an array" bad

let optional_list_field json key =
  match member key json with
  | `List items -> Ok items
  | `Null -> Ok []
  | bad -> field_type_error key "an array" bad

let required_object_field json key =
  match member key json with
  | `Assoc _ as obj -> Ok obj
  | `Null -> missing_field key
  | bad -> field_type_error key "an object" bad

let optional_object_field json key =
  match member key json with
  | `Assoc _ as obj -> Ok (Some obj)
  | `Null -> Ok None
  | bad -> field_type_error key "an object" bad

let decode_list label decode items =
  let rec loop idx acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest -> (
        match decode item with
        | Ok decoded -> loop (idx + 1) (decoded :: acc) rest
        | Error err -> Error (Printf.sprintf "%s[%d]: %s" label idx err))
  in
  loop 0 [] items

(* The ledger row the server joins onto each goal. Two shapes reach here: the
   record, whose [completion] names the state, and [ledger_error_to_yojson],
   which puts ["ledger_error"] at the top with a [detail]. Read leniently — this
   is a projection for a pane and a shape it cannot read must not cost the
   operator the goal list — but every branch says something different, so an
   unreadable ledger never renders as an unreviewed goal.

   The text comes from [evidence] before [reason]: an approval carries its text
   in [evidence] and leaves [reason] null, while a refusal fills both with the
   same string. *)
let decode_goal_proof json =
  let string_at container key =
    match member key container with
    | `String value when String.trim value <> "" -> Some (String.trim value)
    | `String _ | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _
    | `Null ->
      None
  in
  let verdict_text completion =
    let verdict = member "verdict" completion in
    match string_at verdict "evidence" with
    | Some _ as text -> text
    | None -> string_at verdict "reason"
  in
  match json with
  | `Assoc _ ->
    (match string_at json "state" with
     | Some "ledger_error" -> Proof_unreadable (string_at json "detail")
     | Some other -> Proof_unreadable (Some other)
     | None ->
       let completion = member "completion" json in
       (match string_at completion "state" with
        | Some "proof_proven" -> Proof_proven (verdict_text completion)
        | Some "proof_refuted" -> Proof_refuted (verdict_text completion)
        | Some "proof_pending" -> Proof_pending
        | Some "idle" -> Proof_idle
        | Some other -> Proof_unreadable (Some other)
        (* The server never leaves this out: a goal with no ledger row gets
           the default record and a store that will not decode gets the
           ledger_error marker, precisely so corruption is not dressed up as
           "not verified yet". Reading an absent state as idle would put that
           disguise back on this side of the wire. *)
        | None -> Proof_unreadable (Some "no completion state on the goal")))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Proof_unreadable (Some "no verification block on the goal")
;;

let decode_planning_goal json =
  let* pg_id = required_string_field json "id" in
  let* pg_title = required_string_field json "title" in
  let* raw_phase = required_string_field json "phase" in
  let* pg_phase =
    match Goal_phase.parse raw_phase with
    | Some phase -> Ok phase
    | None -> Error (Printf.sprintf "unknown planning goal phase %S" raw_phase)
  in
  let* pg_priority = required_int_field json "priority" in
  let* pg_due_date = optional_string_field json "due_date" in
  let* pg_metric = optional_string_field json "metric" in
  let* pg_target_value = optional_string_field json "target_value" in
  let* pg_last_review_note = optional_string_field json "last_review_note" in
  let* pg_last_review_at = optional_string_field json "last_review_at" in
  let* pg_created_at = optional_string_field json "created_at" in
  let* pg_updated_at = optional_string_field json "updated_at" in
  let pg_proof = decode_goal_proof (member "verification" json) in
  Ok
    {
      pg_id;
      pg_title;
      pg_phase;
      pg_priority;
      pg_due_date;
      pg_metric;
      pg_target_value;
      pg_proof;
      pg_last_review_note;
      pg_last_review_at;
      pg_created_at;
      pg_updated_at;
    }

let decode_planning_rollup json =
  let* pr_active = required_int_field json "active_count" in
  let* pr_verifying = required_int_field json "verifying_count" in
  let* pr_done = required_int_field json "done_count" in
  let* pr_dropped = required_int_field json "dropped_count" in
  Ok { pr_active; pr_verifying; pr_done; pr_dropped }

let decode_planning_backlog json =
  let* pb_todo = required_int_field json "todo" in
  let* pb_claimed = required_int_field json "claimed" in
  let* pb_running = required_int_field json "in_progress" in
  let* pb_done = required_int_field json "done" in
  let* pb_cancelled = required_int_field json "cancelled" in
  Ok { pb_todo; pb_claimed; pb_running; pb_done; pb_cancelled }

type system_log_level =
  | System_debug
  | System_info
  | System_warn
  | System_error
  | System_level_unknown of string

type keeper_call = {
  kc_at : float;
  kc_tool : string;
  kc_input : string;
  kc_output : string option;
  kc_success : bool;
  kc_duration_ms : float option;
  kc_turn : int option;
  kc_task_id : string option;
  kc_model : string option;
}

type keeper_calls_snapshot = {
  kcs_keeper : string;
  kcs_entries : keeper_call list;
  kcs_count : int;
  kcs_health : string;
  kcs_latest_age_s : float option;
  kcs_stale_reason : string option;
  kcs_mismatched : int;
}

type system_log_entry = {
  sl_seq : int;
  sl_ts : string;
  sl_level : system_log_level;
  sl_module : string;
  sl_keeper : string option;
  sl_message : string;
  sl_category : string option;
}

type system_log_snapshot = {
  sys_entries : system_log_entry list;
  sys_total : int;
  sys_latest_seq : int;
}

(* The server accepts "warn" and "warning" for one level and writes levels in
   upper case. An unrecognised spelling keeps its text instead of becoming
   Info, so a level added on the server shows up here as itself. *)
let system_log_level_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "debug" -> System_debug
  | "info" -> System_info
  | "warn" | "warning" -> System_warn
  | "error" -> System_error
  | _ -> System_level_unknown raw

let system_log_level_label = function
  | System_debug -> "DEBUG"
  | System_info -> "INFO "
  | System_warn -> "WARN "
  | System_error -> "ERROR"
  | System_level_unknown raw ->
      let raw = String.trim raw in
      if String.length raw >= 5 then String.sub raw 0 5
      else raw ^ String.make (5 - String.length raw) ' '

let decode_system_log_entry json =
  let* sl_seq = required_int_field json "seq" in
  let* sl_ts = required_string_field json "ts" in
  let* level_raw = required_string_field json "level" in
  let* sl_module = required_string_field json "module" in
  let* sl_message = required_string_field json "message" in
  let* sl_keeper = optional_string_field json "keeper_name" in
  let* sl_category = optional_string_field json "category" in
  Ok
    { sl_seq
    ; sl_ts
    ; sl_level = system_log_level_of_string level_raw
    ; sl_module
    ; sl_keeper
    ; sl_message
    ; sl_category
    }

(* The category vocabulary the Logs filter cycles through is the one the
   loaded rows actually carry, so the TUI never duplicates the server's
   closed category set and never offers a name the page cannot show.
   Sorted for a cycle order that holds still across refreshes. *)
let system_log_categories entries =
  entries
  |> List.filter_map (fun entry -> entry.sl_category)
  |> List.sort_uniq String.compare

(* None -> first -> ... -> last -> None. A current value the page no longer
   carries steps back to None rather than to a neighbour it no longer has. *)
let next_system_log_category ~current entries =
  let categories = system_log_categories entries in
  match current with
  | None -> ( match categories with [] -> None | first :: _ -> Some first)
  | Some current ->
      (* Found at the last position and not found at all both come back
         None: the wrap to "everything" and the vanished-value reset are
         the same answer. *)
      let rec step = function
        | [] | [ _ ] -> None
        | one :: (two :: _ as rest) ->
            if String.equal one current then Some two else step rest
      in
      step categories

(* The verbose ladder. [None] asks the server for everything (its own
   default is debug); each press raises the floor. Debug and unknown
   spellings are readings, not rungs this cycle produces. *)
let next_system_log_min_level = function
  | None -> Some System_info
  | Some System_info -> Some System_warn
  | Some System_warn -> Some System_error
  | Some System_error -> None
  | Some System_debug | Some (System_level_unknown _) -> None

(* The wire spelling the /logs route validates (lowercase, fail-closed). *)
let system_log_level_query = function
  | System_debug -> "debug"
  | System_info -> "info"
  | System_warn -> "warn"
  | System_error -> "error"
  | System_level_unknown raw -> raw

type tool_entry = {
  tl_name : string;
  tl_description : string;
  tl_surfaces : string list;
  tl_direct_call : bool;
}

type inventory_freshness =
  | Warming
  | Settled

type effective_tool = {
  et_name : string;
  et_origin : string;
  et_group : string option;
  et_skill_source : string option;
}

type effective_tool_delivery =
  | Effective_tools_delivered
  | Effective_tools_suppressed_runtime_unsupported

type skill_flow_dependency = {
  sfd_node_id : string;
  sfd_kind : string;
}

type skill_flow_node = {
  sfn_id : string;
  sfn_tool_name : string;
  sfn_dependencies : skill_flow_dependency list;
  sfn_batch_index : int;
  sfn_execution_mode : string;
}

type skill_flow_batch = {
  sfb_index : int;
  sfb_execution_mode : string;
  sfb_node_ids : string list;
}

type skill_flow = {
  sf_nodes : skill_flow_node list;
  sf_batches : skill_flow_batch list;
}

type effective_skill_load_reason =
  | Skill_catalog_default
  | Skill_keeper_profile
  | Skill_task of string

type effective_skill_profile = {
  esp_reference : Skill_reference.t;
  esp_name : string;
  esp_kind : string;
  esp_execution : string;
  esp_body_bytes : int;
  esp_discovery_bytes : int;
  esp_load_reasons : effective_skill_load_reason list;
  esp_node_count : int;
  esp_batch_count : int;
  esp_max_parallelism : int;
  esp_flow : skill_flow option;
}

type effective_tool_surface =
  | Effective_surface_available of {
      ets_keeper_name : string;
      ets_runtime_id : string;
      ets_official_client_kind : string;
      ets_tool_delivery : effective_tool_delivery;
      ets_native_posture : string option;
      ets_skill_snapshot_revision : string;
      ets_skill_resource_read_max_bytes : int option;
      ets_instruction_skills : Skill_reference.t list;
      (* Documents the catalog could not read. Beside the skills rather than
         missing from them: a skill left out is absent from what the Keeper
         can call, and absence with no reason reads as a skill nobody
         wrote. *)
      ets_skills_left_out : string list;
      ets_composition_skills : Skill_reference.t list;
      ets_skill_profiles : effective_skill_profile list;
      ets_tool_surface_bytes : int;
      ets_skill_tool_surface_bytes : int;
      ets_skill_discovery_bytes : int;
      ets_skill_eager_body_bytes : int;
      ets_skill_body_bytes : int;
      ets_tools : effective_tool list;
      ets_tool_surface_sha256 : string option;
    }
  | Effective_surface_unavailable of {
      ets_keeper_name : string;
      ets_reason : string;
      ets_detail : string;
    }
  | Effective_surface_warming of { ets_keeper_name : string }

type skill_activation_projection =
  | Skill_activations_available of
      { sap_keeper_name : string
      ; sap_ledger : Keeper_skill_activation_ledger.t
      }
  | Skill_activations_no_session of { sap_keeper_name : string }
  | Skill_activations_unavailable of
      { sap_keeper_name : string
      ; sap_reason : string
      ; sap_detail : string
      }

type tool_snapshot = {
  ts_tools : tool_entry list;
  ts_count : int;
  ts_freshness : inventory_freshness;
  ts_effective : effective_tool_surface option;
  ts_skill_activations : skill_activation_projection option;
}

type connector = {
  cn_id : string;
  cn_display_name : string;
  cn_available : bool;
  cn_connected : bool;
  cn_status : string;
  cn_channel : string option;
}

type connector_snapshot = {
  cs_connectors : connector list;
  cs_total : int;
  cs_active : int;
}

type runtime_probe_refresh_state =
  | Runtime_probe_fresh
  | Runtime_probe_recent
  | Runtime_probe_served_stale
  | Runtime_probe_warming_up

type runtime_probe_status =
  | Runtime_probe_reachable
  | Runtime_probe_no_http_runtimes
  | Runtime_probe_degraded
  | Runtime_probe_unreachable
  | Runtime_probe_warming

type runtime_provider_status =
  | Runtime_provider_reachable
  | Runtime_provider_missing_auth
  | Runtime_provider_auth_failed
  | Runtime_provider_network_error
  | Runtime_provider_server_error
  | Runtime_provider_endpoint_not_found
  | Runtime_provider_http_error
  | Runtime_provider_unknown_http_status
  | Runtime_provider_skipped_cli
  | Runtime_provider_invalid_endpoint
  | Runtime_provider_invalid_execution_transport

type runtime_probe_transport =
  | Runtime_probe_http
  | Runtime_probe_cli

type runtime_provider_probe = {
  rpp_runtime_id : string;
  rpp_transport : runtime_probe_transport;
  rpp_status : runtime_provider_status;
  rpp_reachable : bool option;
  rpp_http_status : int option;
  rpp_latency_ms : float option;
  rpp_error : string option;
  rpp_checked_at : string;
}

type runtime_probe_summary = {
  rpsu_runtimes : int;
  rpsu_probed : int;
  rpsu_reachable : int;
  rpsu_failed : int;
  rpsu_skipped : int;
  rpsu_default_runtime_id : string option;
}

type runtime_probe_snapshot = {
  rps_generated_at : string;
  rps_refreshed_at_unix : float option;
  rps_cache_ttl_sec : float;
  rps_cache_age_sec : float option;
  rps_cache_hit : bool;
  rps_refresh_state : runtime_probe_refresh_state;
  rps_status : runtime_probe_status;
  rps_probe_ok : bool;
  rps_checked_at : string;
  rps_summary : runtime_probe_summary;
  rps_providers : runtime_provider_probe list;
  rps_errors : string list;
  rps_observations : string list;
  rps_limitations : string list;
}

(* One decoder-owned resolved runtime row shared by the Keeper picker and the
   Runtime surface. [ro_is_default] comes from the document's top-level
   [default_runtime], not the row's independent binding flag. *)
type runtime_option = {
  ro_id : string;
  ro_provider : string;
  ro_model : string;
  ro_dispatchable : bool;
  ro_blocked_reason : string option;
  ro_is_default : bool;
}

type runtime_resolved_lane = {
  rrl_id : string;
  rrl_runtime_ids : string list;
  rrl_preferred_candidate : string option;
  rrl_preferred_at_ts : float option;
}

type runtime_resolved_snapshot = {
  rrs_generated_at_iso : string;
  rrs_config_path : string option;
  rrs_default_runtime_id : string option;
  rrs_runtimes : runtime_option list;
  rrs_lanes : runtime_resolved_lane list;
}

type runtime_candidate_row = {
  rcr_lane_id : string;
  rcr_position : int;
  rcr_candidate_count : int;
  rcr_runtime : runtime_option;
  rcr_preferred_at_ts : float option;
  rcr_probe : runtime_provider_probe option;
}

type runtime_surface_snapshot = {
  rss_probe : runtime_probe_snapshot option;
  rss_probe_error : string option;
  rss_resolved : runtime_resolved_snapshot;
  rss_candidates : runtime_candidate_row list;
  rss_unassigned_probe_count : int;
}

type repository = {
  rp_id : string;  (** what the workspace routes' [?repo_id=] resolves *)
  rp_name : string;
  (* The server-minted codebase slug the IDE annotation routes scope by
     (RFC-0378: clients carry this value, they do not re-derive it from the
     url). [None] when the remote cannot canonicalize. *)
  rp_codebase : string option;
  (* The remote as registered, for building links to it. *)
  rp_url : string;
  rp_local_path : string;
  rp_resolved_local_path : string;
  rp_default_branch : string;
  rp_status : string;
  rp_keepers : string list;
  rp_auto_sync : bool;
}

type repository_snapshot = {
  rs_repositories : repository list;
  rs_total : int;
}

type repository_change = {
  rc_path : string;
  rc_staged : bool;
  rc_unstaged : bool;
  rc_untracked : bool;
  rc_conflicted : bool;
}

type repository_change_scope =
  | Repository_change_project
  | Repository_change_repository of string

type repository_change_snapshot = {
  rcs_scope : repository_change_scope;
  rcs_changes : repository_change list;
  rcs_total : int;
}

type memory_alert = {
  ma_code : string;
  ma_severity : string;
  ma_label : string;
  ma_message : string;
}

type memory_keeper_health = {
  mkh_keeper_id : string;
  mkh_revision : int;
  mkh_facts : int;
  mkh_snapshot_bytes : int;
  mkh_added : int;
  mkh_removed : int;
  mkh_snapshot_present : bool;
  mkh_librarian_lane_busy : int;
  mkh_librarian_failures : int;
  mkh_read_error : string option;
  mkh_alerts : memory_alert list;
}

type memory_health_snapshot = {
  mhs_generated_at : float;
  mhs_keepers : memory_keeper_health list;
  mhs_total_facts : int;
  mhs_total_snapshot_bytes : int;
  mhs_total_librarian_failures : int;
  mhs_total_read_errors : int;
  mhs_warn_alerts : int;
  mhs_error_alerts : int;
  mhs_starving_keepers : int;
}

type harness_verdict = {
  hv_at : float;
  hv_task_id : string;
  hv_task_title : string;
  hv_agent : string;
  hv_gate : string;
  hv_verdict : string;
  hv_evaluator : string;
  hv_fallback_reason : string option;
  hv_notes_hash : string;
}

type harness_calibration = {
  hcal_total : int;
  hcal_approve : int;
  hcal_reject : int;
  hcal_labeled : int;
  hcal_gates : (string * int) list;
}

type harness_overview = {
  hov_evaluator_status : string;
  hov_last_signal_at : float option;
}

type harness_snapshot = {
  hs_verdicts : harness_verdict list;
  hs_calibration : harness_calibration option;
  hs_overview : harness_overview option;
}

type verification_request = {
  vr_request_id : string;
  vr_task_id : string;
  vr_task_title : string;
  vr_submitted_by : string;
  vr_created_at : string;
  vr_required_artifacts : string list;
  vr_submitted_evidence : string list;
  vr_evidence_error : string option;
}

type verification_snapshot = {
  vs_requests : verification_request list;
  vs_total : int;
}

let decode_string_name_list json key =
  let* items = optional_list_field json key in
  decode_list key
    (fun item ->
       match item with
       | `String value -> Ok value
       | bad -> field_type_error key "a string" bad)
    items

let decode_bool_field_or json key ~default =
  match member key json with
  | `Bool value -> Ok value
  | `Null -> Ok default
  | bad -> field_type_error key "a bool or null" bad

let decode_tool_entry json =
  let* tl_name = required_string_field json "name" in
  let* tl_description = required_string_field json "description" in
  let* tl_surfaces = decode_string_name_list json "surfaces" in
  let* tl_direct_call =
    decode_bool_field_or json "direct_call_allowed" ~default:false
  in
  Ok { tl_name; tl_description; tl_surfaces; tl_direct_call }

let decode_effective_tool json =
  let* et_name = required_string_field json "name" in
  let* origin = required_object_field json "origin" in
  let* et_origin = required_string_field origin "kind" in
  let* et_group = optional_string_field origin "group" in
  let* et_skill_source = optional_string_field origin "skill_source" in
  Ok { et_name; et_origin; et_group; et_skill_source }

let decode_skill_reference_list json field =
  let* values = required_list_field json field in
  match Skill_reference.list_of_yojson (`List values) with
  | Ok references -> Ok references
  | Error _ -> Error (Printf.sprintf "%s is not a canonical Skill reference list" field)

let decode_effective_tool_delivery json =
  let* status = required_string_field json "status" in
  match status with
  | "delivered" -> Ok Effective_tools_delivered
  | "suppressed" ->
      let* reason = required_string_field json "reason" in
      (match reason with
       | "runtime_tools_unsupported" ->
         Ok Effective_tools_suppressed_runtime_unsupported
       | unknown ->
         Error (Printf.sprintf "tool_delivery.reason has unknown value %S" unknown))
  | unknown ->
      Error (Printf.sprintf "tool_delivery.status has unknown value %S" unknown)

let decode_skill_flow_dependency json =
  let* sfd_node_id = required_string_field json "node_id" in
  let* sfd_kind = required_string_field json "kind" in
  Ok { sfd_node_id; sfd_kind }

let decode_skill_flow_node json =
  let* sfn_id = required_string_field json "id" in
  let* sfn_tool_name = required_string_field json "tool_name" in
  let* dependencies = required_list_field json "dependencies" in
  let* sfn_dependencies =
    decode_list "skill flow dependencies" decode_skill_flow_dependency dependencies
  in
  let* sfn_batch_index = required_int_field json "batch_index" in
  let* sfn_execution_mode = required_string_field json "execution_mode" in
  Ok
    { sfn_id
    ; sfn_tool_name
    ; sfn_dependencies
    ; sfn_batch_index
    ; sfn_execution_mode
    }

let decode_skill_flow_batch json =
  let* sfb_index = required_int_field json "index" in
  let* sfb_execution_mode = required_string_field json "execution_mode" in
  let* node_ids = required_list_field json "node_ids" in
  let* sfb_node_ids =
    decode_list
      "skill flow batch node ids"
      (function
        | `String value -> Ok value
        | bad -> field_type_error "node_ids" "a string" bad)
      node_ids
  in
  Ok { sfb_index; sfb_execution_mode; sfb_node_ids }

let decode_skill_flow json =
  let* nodes = required_list_field json "nodes" in
  let* sf_nodes = decode_list "skill flow nodes" decode_skill_flow_node nodes in
  let* batches = required_list_field json "batches" in
  let* sf_batches = decode_list "skill flow batches" decode_skill_flow_batch batches in
  Ok { sf_nodes; sf_batches }

let decode_effective_skill_load_reason json =
  let* kind = required_string_field json "kind" in
  match kind with
  | "catalog_default" -> Ok Skill_catalog_default
  | "keeper_profile" -> Ok Skill_keeper_profile
  | "task" ->
    let* task_id = required_string_field json "task_id" in
    Ok (Skill_task task_id)
  | value ->
    Error (Printf.sprintf "effective Skill load reason has unknown kind %S" value)
;;

let decode_effective_skill_profile json =
  let* reference = required_object_field json "reference" in
  let* esp_reference =
    Skill_reference.of_yojson reference
    |> Result.map_error (fun _ -> "effective Skill profile reference is invalid")
  in
  let* identity = required_object_field reference "identity" in
  let* esp_name = required_string_field identity "name" in
  let* esp_kind = required_string_field json "kind" in
  let* esp_execution = required_string_field json "execution" in
  let* context = required_object_field json "context" in
  let* esp_body_bytes = required_int_field context "body_bytes" in
  let* esp_discovery_bytes = required_int_field context "discovery_bytes" in
  let* load_reasons = required_list_field json "load_reasons" in
  let* esp_load_reasons =
    decode_list
      "effective Skill profile load reasons"
      decode_effective_skill_load_reason
      load_reasons
  in
  let* plan = required_object_field json "plan" in
  let* esp_node_count = required_int_field plan "node_count" in
  let* esp_batch_count = required_int_field plan "batch_count" in
  let* esp_max_parallelism = required_int_field plan "max_parallelism" in
  let* flow = optional_object_field json "flow" in
  let* esp_flow =
    match flow with
    | None -> Ok None
    | Some json -> decode_skill_flow json |> Result.map Option.some
  in
  Ok
    { esp_reference
    ; esp_name
    ; esp_kind
    ; esp_execution
    ; esp_body_bytes
    ; esp_discovery_bytes
    ; esp_load_reasons
    ; esp_node_count
    ; esp_batch_count
    ; esp_max_parallelism
    ; esp_flow
    }

let decode_effective_tool_surface json =
  let* status = required_string_field json "status" in
  let* ets_keeper_name = required_string_field json "keeper_name" in
  match status with
  | "warming" -> Ok (Effective_surface_warming { ets_keeper_name })
  | "unavailable" ->
      let* ets_reason = required_string_field json "reason" in
      let* ets_detail = required_string_field json "detail" in
      Ok
        (Effective_surface_unavailable
           { ets_keeper_name; ets_reason; ets_detail })
  | "available" ->
      let* ets_runtime_id = required_string_field json "runtime_id" in
      let* ets_official_client_kind =
        required_string_field json "official_client_kind"
      in
      let* tool_delivery = required_object_field json "tool_delivery" in
      let* ets_tool_delivery = decode_effective_tool_delivery tool_delivery in
      let* ets_native_posture = optional_string_field json "native_posture" in
      let* ets_skill_snapshot_revision =
        required_string_field json "skill_snapshot_revision"
      in
      let* ets_skill_resource_read_max_bytes =
        optional_int_field json "skill_resource_read_max_bytes"
      in
      let* ets_skills_left_out =
        decode_string_name_list json "skills_left_out"
      in
      let* ets_instruction_skills =
        decode_skill_reference_list json "instruction_skills"
      in
      let* ets_composition_skills =
        decode_skill_reference_list json "composition_skills"
      in
      let* skill_profiles_json = optional_list_field json "skill_profiles" in
      let* ets_skill_profiles =
        decode_list
          "effective_keeper_surface.skill_profiles"
          decode_effective_skill_profile
          skill_profiles_json
      in
      let* tool_surface_bytes = optional_int_field json "tool_surface_bytes" in
      let ets_tool_surface_bytes = Option.value ~default:0 tool_surface_bytes in
      let* ets_skill_tool_surface_bytes =
        optional_int_field json "skill_tool_surface_bytes"
      in
      let ets_skill_tool_surface_bytes =
        Option.value ~default:0 ets_skill_tool_surface_bytes
      in
      let* ets_skill_discovery_bytes =
        required_int_field json "skill_discovery_bytes"
      in
      let* ets_skill_eager_body_bytes =
        required_int_field json "skill_eager_body_bytes"
      in
      let* skill_body_bytes = optional_int_field json "skill_body_bytes" in
      let ets_skill_body_bytes = Option.value ~default:0 skill_body_bytes in
      let* tools_json = required_list_field json "tools" in
      let* ets_tools =
        decode_list "effective_keeper_surface.tools" decode_effective_tool
          tools_json
      in
      let* ets_tool_surface_sha256 =
        optional_string_field json "tool_surface_sha256"
      in
      Ok
        (Effective_surface_available
           { ets_keeper_name;
             ets_runtime_id;
             ets_official_client_kind;
             ets_tool_delivery;
             ets_native_posture;
             ets_skill_snapshot_revision;
             ets_skill_resource_read_max_bytes;
             ets_instruction_skills;
             ets_skills_left_out;
             ets_composition_skills;
             ets_skill_profiles;
             ets_tool_surface_bytes;
             ets_skill_tool_surface_bytes;
             ets_skill_discovery_bytes;
             ets_skill_eager_body_bytes;
             ets_skill_body_bytes;
             ets_tools;
             ets_tool_surface_sha256;
           })
  | unknown ->
      Error
        (Printf.sprintf
           "effective_keeper_surface.status has unknown value %S" unknown)

let decode_skill_activation_ledger ~keeper_name json =
  Keeper_skill_activation_ledger.of_projection_yojson json
  |> Result.map (fun sap_ledger ->
    Skill_activations_available
      { sap_keeper_name = keeper_name; sap_ledger })
  |> Result.map_error (fun error ->
    "skill activation ledger is invalid: "
    ^ Keeper_skill_activation_ledger.decode_error_code error)

let decode_skill_activation_projection json =
  let* status = required_string_field json "status" in
  let* sap_keeper_name = required_string_field json "keeper_name" in
  match status with
  | "available" ->
      let* ledger = required_object_field json "ledger" in
      decode_skill_activation_ledger ~keeper_name:sap_keeper_name ledger
  | "no_session" -> Ok (Skill_activations_no_session { sap_keeper_name })
  | "unavailable" ->
      let* sap_reason = required_string_field json "reason" in
      let* sap_detail = required_string_field json "detail" in
      Ok
        (Skill_activations_unavailable
           { sap_keeper_name; sap_reason; sap_detail })
  | unknown ->
      Error (Printf.sprintf "skill_activations.status has unknown value %S" unknown)

(* ── Workspace skills catalog (/api/v1/skills) ─────────────────────
   The dashboard renders the full surface set; the TUI Tools screen reads
   per-skill usage rows (cross-keeper tracking) and reuses the skill_flow
   decoder the effective-surface profiles already share. Usage may be absent
   while the ledger side is warming. A valid instruction/composition surface
   always carries its profile; only an unavailable surface has none. *)

type skill_usage_row =
  { su_keeper : string
  ; su_invocations : int
  ; su_deliveries : int
  ; su_actions : int
  ; su_last_used_at : string option
  }

type skills_catalog_surface =
  { scs_name : string
  ; scs_kind : string
  ; scs_usage : skill_usage_row list
  ; scs_flow : skill_flow option
  }

module Skill_document = Agent_core.Skill_document

type skill_rejection_diagnostic =
  { srd_diagnostic : Skill_document.diagnostic
  ; srd_message : string
  }

type skill_rejection_reason =
  | Skill_document_rejected of skill_rejection_diagnostic list
  | Skill_document_unreadable
  | Skill_exact_identity_duplicate
  | Skill_invalid_package_id

type skill_catalog_rejection =
  { scr_source_index : int
  ; scr_source_id : string
  ; scr_package_id : string option
  ; scr_content_revision : string option
  ; scr_reason : skill_rejection_reason
  }

type skills_catalog_state =
  | Skills_ready
  | Skills_not_registered
  | Skills_uninitialized
  | Skills_invalid_workspace

type skills_catalog =
  { sc_state : skills_catalog_state
  ; sc_surfaces : skills_catalog_surface list
  ; sc_rejections : skill_catalog_rejection list
  }

let skills_catalog_state_to_string = function
  | Skills_ready -> "ready"
  | Skills_not_registered -> "not_registered"
  | Skills_uninitialized -> "uninitialized"
  | Skills_invalid_workspace -> "invalid_workspace"

let skill_diagnostic_code_to_string = function
  | Skill_document.Missing_frontmatter -> "missing_frontmatter"
  | Skill_document.Byte_order_mark -> "byte_order_mark"
  | Skill_document.Unterminated_frontmatter -> "unterminated_frontmatter"
  | Skill_document.Malformed_yaml _ -> "malformed_yaml"
  | Skill_document.Frontmatter_not_mapping -> "frontmatter_not_mapping"
  | Skill_document.Duplicate_field _ -> "duplicate_field"
  | Skill_document.Duplicate_metadata_key _ -> "duplicate_metadata_key"
  | Skill_document.Unexpected_frontmatter_field _ ->
    "unexpected_frontmatter_field"
  | Skill_document.Missing_name -> "missing_name"
  | Skill_document.Missing_description -> "missing_description"
  | Skill_document.Invalid_field_type _ -> "invalid_field_type"
  | Skill_document.Invalid_name _ -> "invalid_name"
  | Skill_document.Name_mismatch _ -> "name_mismatch"
  | Skill_document.Description_too_long _ -> "description_too_long"
  | Skill_document.Compatibility_empty -> "compatibility_empty"
  | Skill_document.Compatibility_too_long _ -> "compatibility_too_long"
  | Skill_document.Invalid_metadata_value _ -> "invalid_metadata_value"

let validate_closed_object ~label ~allowed = function
  | `Assoc fields ->
    let rec find_duplicate seen = function
      | [] -> None
      | (key, _) :: rest ->
        if List.mem key seen then Some key else find_duplicate (key :: seen) rest
    in
    (match find_duplicate [] fields with
     | Some key ->
       Error (Printf.sprintf "%s duplicates field %S" label key)
     | None ->
       (match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
        | Some (key, _) ->
          Error (Printf.sprintf "%s has unexpected field %S" label key)
        | None -> Ok ()))
  | bad -> field_type_error label "an object" bad

let required_nonempty_string_field json key =
  let* value = required_string_field json key in
  if String.equal value ""
  then Error (Printf.sprintf "field '%s' must be a non-empty string" key)
  else Ok value

let required_nullable_nonempty_string_field json key =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | None -> missing_field key
     | Some `Null -> Ok None
     | Some (`String "") ->
       Error (Printf.sprintf "field '%s' must be non-empty or null" key)
     | Some (`String value) -> Ok (Some value)
     | Some bad -> field_type_error key "a non-empty string or null" bad)
  | bad -> field_type_error "skill snapshot rejection" "an object" bad

let required_nonnegative_int_field json key =
  let* value = required_int_field json key in
  if value < 0
  then Error (Printf.sprintf "field '%s' must be non-negative" key)
  else Ok value

let decode_skill_document_field json =
  let* () = validate_closed_object ~label:"diagnostic.field" ~allowed:[ "kind"; "name" ] json in
  let* kind = required_string_field json "kind" in
  let* name = required_string_field json "name" in
  match kind, name with
  | "standard", "name" -> Ok (Skill_document.Standard Skill_document.Name)
  | "standard", "description" ->
    Ok (Skill_document.Standard Skill_document.Description)
  | "standard", "license" -> Ok (Skill_document.Standard Skill_document.License)
  | "standard", "compatibility" ->
    Ok (Skill_document.Standard Skill_document.Compatibility)
  | "standard", "metadata" -> Ok (Skill_document.Standard Skill_document.Metadata)
  | "standard", "allowed-tools" ->
    Ok (Skill_document.Standard Skill_document.Allowed_tools_syntax_only)
  | "standard", unknown ->
    Error (Printf.sprintf "diagnostic.field has unknown standard name %S" unknown)
  | "extension", name -> Ok (Skill_document.Extension name)
  | unknown, _ ->
    Error (Printf.sprintf "diagnostic.field has unknown kind %S" unknown)

let decode_skill_expected_shape json =
  match json with
  | `String "string" -> Ok Skill_document.String_value
  | `String "string_mapping" -> Ok Skill_document.String_mapping
  | `String unknown ->
    Error (Printf.sprintf "diagnostic.expected has unknown value %S" unknown)
  | bad -> field_type_error "diagnostic.expected" "a string" bad

let decode_skill_name_violation json =
  let* kind = required_string_field json "kind" in
  let closed fields =
    validate_closed_object
      ~label:"diagnostic.violations[]"
      ~allowed:("kind" :: fields)
      json
  in
  match kind with
  | "empty_name" ->
    let* () = closed [] in
    Ok Skill_document.Empty_name
  | "name_too_long" ->
    let* () = closed [ "length"; "maximum" ] in
    let* length = required_nonnegative_int_field json "length" in
    let* maximum = required_int_field json "maximum" in
    if maximum <= 0
    then Error "field 'maximum' must be positive"
    else Ok (Skill_document.Name_too_long { length; maximum })
  | "name_not_lowercase" ->
    let* () = closed [] in
    Ok Skill_document.Name_not_lowercase
  | "name_starts_with_hyphen" ->
    let* () = closed [] in
    Ok Skill_document.Name_starts_with_hyphen
  | "name_ends_with_hyphen" ->
    let* () = closed [] in
    Ok Skill_document.Name_ends_with_hyphen
  | "name_has_consecutive_hyphens" ->
    let* () = closed [] in
    Ok Skill_document.Name_has_consecutive_hyphens
  | "name_has_invalid_character" ->
    let* () = closed [] in
    Ok Skill_document.Name_has_invalid_character
  | unknown ->
    Error (Printf.sprintf "skill name violation has unknown kind %S" unknown)

let decode_skill_rejection_diagnostic json =
  let* code = required_string_field json "code" in
  let* srd_message = required_nonempty_string_field json "message" in
  let closed payload =
    validate_closed_object
      ~label:"skill rejection diagnostic"
      ~allowed:("code" :: "message" :: payload)
      json
  in
  let* srd_diagnostic =
    match code with
    | "missing_frontmatter" ->
      let* () = closed [] in
      Ok Skill_document.Missing_frontmatter
    | "byte_order_mark" ->
      let* () = closed [] in
      Ok Skill_document.Byte_order_mark
    | "unterminated_frontmatter" ->
      let* () = closed [] in
      Ok Skill_document.Unterminated_frontmatter
    | "malformed_yaml" ->
      let* () = closed [ "detail" ] in
      let* detail = required_nonempty_string_field json "detail" in
      Ok (Skill_document.Malformed_yaml detail)
    | "frontmatter_not_mapping" ->
      let* () = closed [] in
      Ok Skill_document.Frontmatter_not_mapping
    | "duplicate_field" ->
      let* () = closed [ "field" ] in
      let* field_json = required_object_field json "field" in
      let* field = decode_skill_document_field field_json in
      Ok (Skill_document.Duplicate_field field)
    | "duplicate_metadata_key" ->
      let* () = closed [ "key" ] in
      let* key = required_string_field json "key" in
      Ok (Skill_document.Duplicate_metadata_key key)
    | "unexpected_frontmatter_field" ->
      let* () = closed [ "field" ] in
      let* field = required_string_field json "field" in
      Ok (Skill_document.Unexpected_frontmatter_field field)
    | "missing_name" ->
      let* () = closed [] in
      Ok Skill_document.Missing_name
    | "missing_description" ->
      let* () = closed [] in
      Ok Skill_document.Missing_description
    | "invalid_field_type" ->
      let* () = closed [ "field"; "expected" ] in
      let* field_json = required_object_field json "field" in
      let* field = decode_skill_document_field field_json in
      let* expected_json = required_member json "expected" in
      let* expected = decode_skill_expected_shape expected_json in
      Ok (Skill_document.Invalid_field_type { field; expected })
    | "invalid_name" ->
      let* () = closed [ "name"; "violations" ] in
      let* name = required_string_field json "name" in
      let* violations_json = required_list_field json "violations" in
      let* violations =
        decode_list
          "skill rejection diagnostic.violations"
          decode_skill_name_violation
          violations_json
      in
      Ok (Skill_document.Invalid_name { name; violations })
    | "name_mismatch" ->
      let* () = closed [ "declared"; "directory" ] in
      let* declared = required_string_field json "declared" in
      let* directory = required_string_field json "directory" in
      Ok (Skill_document.Name_mismatch { declared; directory })
    | "description_too_long" ->
      let* () = closed [ "length" ] in
      let* length = required_nonnegative_int_field json "length" in
      Ok (Skill_document.Description_too_long { length })
    | "compatibility_empty" ->
      let* () = closed [] in
      Ok Skill_document.Compatibility_empty
    | "compatibility_too_long" ->
      let* () = closed [ "length" ] in
      let* length = required_nonnegative_int_field json "length" in
      Ok (Skill_document.Compatibility_too_long { length })
    | "invalid_metadata_value" ->
      let* () = closed [ "key" ] in
      let* key = required_string_field json "key" in
      Ok (Skill_document.Invalid_metadata_value { key })
    | unknown ->
      Error (Printf.sprintf "skill diagnostic code has unknown value %S" unknown)
  in
  Ok { srd_diagnostic; srd_message }

let decode_skill_usage_row json =
  let* su_keeper = required_string_field json "keeper" in
  let* su_invocations = required_int_field json "invocations" in
  let* su_deliveries = required_int_field json "deliveries" in
  let* su_actions = required_int_field json "actions" in
  let* su_last_used_at = optional_string_field json "last_used_at" in
  Ok { su_keeper; su_invocations; su_deliveries; su_actions; su_last_used_at }

let decode_skills_catalog_surface json =
  let* reference = required_object_field json "reference" in
  let* identity = required_object_field reference "identity" in
  let* scs_name = required_string_field identity "name" in
  let* scs_kind = required_string_field json "kind" in
  let* usage_json = optional_list_field json "usage" in
  let* scs_usage = decode_list "usage" decode_skill_usage_row usage_json in
  let* scs_flow =
    match scs_kind, member "profile" json with
    | ("instruction" | "composition"), (`Assoc _ as profile) ->
        let* flow_field = required_member profile "flow" in
        (match flow_field with
         | `Null -> Ok None
         | `Assoc _ as flow ->
             decode_skill_flow flow |> Result.map Option.some
         | bad -> field_type_error "profile.flow" "an object or null" bad)
    | ("instruction" | "composition"), bad ->
      field_type_error "profile" "an object" bad
    | "unavailable", `Null -> Ok None
    | "unavailable", bad -> field_type_error "profile" "absent" bad
    | unknown, _ ->
      Error (Printf.sprintf "skills surface kind has unknown value %S" unknown)
  in
  Ok { scs_name; scs_kind; scs_usage; scs_flow }

let decode_skill_catalog_rejection json =
  let* () =
    validate_closed_object
      ~label:"skill snapshot rejection"
      ~allowed:
        [ "source_index"
        ; "source_id"
        ; "package_id"
        ; "content_revision"
        ; "reason"
        ]
      json
  in
  let* scr_source_index = required_nonnegative_int_field json "source_index" in
  let* scr_source_id = required_nonempty_string_field json "source_id" in
  let* scr_package_id =
    required_nullable_nonempty_string_field json "package_id"
  in
  let* scr_content_revision =
    required_nullable_nonempty_string_field json "content_revision"
  in
  let* reason = required_object_field json "reason" in
  let* kind = required_string_field reason "kind" in
  let* scr_reason =
    match kind with
    | "document_rejected" ->
      let* () =
        validate_closed_object
          ~label:"skill snapshot rejection.reason"
          ~allowed:[ "kind"; "diagnostics" ]
          reason
      in
      let* diagnostics_json = required_list_field reason "diagnostics" in
      let* diagnostics =
        decode_list
          "snapshot.rejections.reason.diagnostics"
          decode_skill_rejection_diagnostic
          diagnostics_json
      in
      Ok (Skill_document_rejected diagnostics)
    | "document_unreadable" ->
      let* () =
        validate_closed_object
          ~label:"skill snapshot rejection.reason"
          ~allowed:[ "kind" ]
          reason
      in
      Ok Skill_document_unreadable
    | "exact_identity_duplicate" ->
      let* () =
        validate_closed_object
          ~label:"skill snapshot rejection.reason"
          ~allowed:[ "kind" ]
          reason
      in
      Ok Skill_exact_identity_duplicate
    | "invalid_package_id" ->
      let* () =
        validate_closed_object
          ~label:"skill snapshot rejection.reason"
          ~allowed:[ "kind" ]
          reason
      in
      Ok Skill_invalid_package_id
    | unknown ->
      Error (Printf.sprintf "skill rejection kind has unknown value %S" unknown)
  in
  Ok
    { scr_source_index
    ; scr_source_id
    ; scr_package_id
    ; scr_content_revision
    ; scr_reason
    }

let decode_skill_snapshot_rejections json =
  let* () =
    validate_closed_object
      ~label:"skills snapshot"
      ~allowed:
        [ "snapshot_revision"
        ; "catalog_revision"
        ; "config"
        ; "sources"
        ; "skills"
        ; "effective_skills"
        ; "shadows"
        ; "rejections"
        ]
      json
  in
  let* _snapshot_revision =
    required_nonempty_string_field json "snapshot_revision"
  in
  let* _catalog_revision =
    required_nonempty_string_field json "catalog_revision"
  in
  let* _config = required_object_field json "config" in
  let* _sources = required_list_field json "sources" in
  let* _skills = required_list_field json "skills" in
  let* _effective_skills = required_list_field json "effective_skills" in
  let* _shadows = required_list_field json "shadows" in
  let* rejections_json = required_list_field json "rejections" in
  decode_list
    "snapshot.rejections"
    decode_skill_catalog_rejection
    rejections_json

let decode_skills_catalog json =
  let* schema = required_string_field json "schema" in
  if not (String.equal schema "masc.skill-snapshot/v1")
  then Error (Printf.sprintf "skills catalog has unknown schema %S" schema)
  else
    let* state = required_string_field json "state" in
    match state with
    | "ready" ->
      let* () =
        validate_closed_object
          ~label:"skills catalog"
          ~allowed:[ "schema"; "state"; "snapshot"; "surfaces"; "usage_coverage" ]
          json
      in
      let* snapshot = required_object_field json "snapshot" in
      let* sc_rejections = decode_skill_snapshot_rejections snapshot in
      let* surfaces_json = required_list_field json "surfaces" in
      let* sc_surfaces =
        decode_list "surfaces" decode_skills_catalog_surface surfaces_json
      in
      Ok { sc_state = Skills_ready; sc_surfaces; sc_rejections }
    | "not_registered" ->
      let* () =
        validate_closed_object
          ~label:"skills catalog"
          ~allowed:[ "schema"; "state" ]
          json
      in
      Ok
        { sc_state = Skills_not_registered
        ; sc_surfaces = []
        ; sc_rejections = []
        }
    | "uninitialized" ->
      let* () =
        validate_closed_object
          ~label:"skills catalog"
          ~allowed:[ "schema"; "state" ]
          json
      in
      Ok
        { sc_state = Skills_uninitialized
        ; sc_surfaces = []
        ; sc_rejections = []
        }
    | "invalid_workspace" ->
      let* () =
        validate_closed_object
          ~label:"skills catalog"
          ~allowed:[ "schema"; "state"; "reason" ]
          json
      in
      let* reason = required_object_field json "reason" in
      let* () =
        validate_closed_object
          ~label:"skills catalog.reason"
          ~allowed:[ "code" ]
          reason
      in
      let* code = required_string_field reason "code" in
      if not (String.equal code "invalid_workspace")
      then Error (Printf.sprintf "invalid workspace has unknown reason %S" code)
      else
        Ok
          { sc_state = Skills_invalid_workspace
          ; sc_surfaces = []
          ; sc_rejections = []
          }
    | unknown ->
      Error (Printf.sprintf "skills catalog has unknown state %S" unknown)

let decode_tool_snapshot json =
  (* The tools envelope carries config and runtime resolution beside the
     inventory; this reads the inventory and leaves the rest to the dashboard,
     which has room to show it. *)
  let* inventory = required_object_field json "tool_inventory" in
  let* tools_json = required_list_field inventory "tools" in
  let* ts_tools = decode_list "tools" decode_tool_entry tools_json in
  let* ts_count = required_int_field inventory "count" in
  (* Only the warming placeholder carries this flag, and it carries it as
     [true]; a payload built from a real inventory does not mention it. So an
     absent flag is a built inventory, and the pane can tell "the server has
     not looked yet" apart from "there are none" -- which it could not, and so
     reported a warming server as a workspace with no tools registered. *)
  let* warming = optional_bool_field json "is_warming" in
  let ts_freshness =
    match warming with Some true -> Warming | Some false | None -> Settled
  in
  let* effective_json = required_member json "effective_keeper_surface" in
  let* ts_effective =
    match effective_json with
    | `Null -> Ok None
    | `Assoc _ as value ->
        Result.map Option.some (decode_effective_tool_surface value)
    | bad -> field_type_error "effective_keeper_surface" "an object or null" bad
  in
  let* skill_activations_json = required_member json "skill_activations" in
  let* ts_skill_activations =
    match skill_activations_json with
    | `Null -> Ok None
    | `Assoc _ as value ->
        Result.map Option.some (decode_skill_activation_projection value)
    | bad -> field_type_error "skill_activations" "an object or null" bad
  in
  Ok
    { ts_tools
    ; ts_count
    ; ts_freshness
    ; ts_effective
    ; ts_skill_activations
    }

let decode_connector json =
  let* cn_id = required_string_field json "connector_id" in
  let* cn_display_name = required_string_field json "display_name" in
  let* cn_status = required_string_field json "status" in
  (* Both default to false: a connector that does not say it is available or
     connected is not, and defaulting the other way would draw a dead
     connector as a working one. *)
  let* cn_available = decode_bool_field_or json "available" ~default:false in
  let* cn_connected = decode_bool_field_or json "connected" ~default:false in
  let* cn_channel = optional_string_field json "channel" in
  Ok { cn_id; cn_display_name; cn_available; cn_connected; cn_status; cn_channel }

let decode_connector_snapshot json =
  let* connectors_json = required_list_field json "connectors" in
  let* cs_connectors =
    decode_list "connectors" decode_connector connectors_json
  in
  let* cs_total = required_int_field json "total" in
  let* cs_active = required_int_field json "active_count" in
  Ok { cs_connectors; cs_total; cs_active }

let runtime_probe_refresh_state_to_string = function
  | Runtime_probe_fresh -> "fresh"
  | Runtime_probe_recent -> "recent"
  | Runtime_probe_served_stale -> "served_stale"
  | Runtime_probe_warming_up -> "warming_up"

(* The word the wire uses, so the badge shows what the server said. This
   spelled two of them "reachable" and "no_http_runtimes" while the producer
   wrote "ok" and "idle", and the only caller is the status badge -- so the
   screen would have named a reading the system never used. One vocabulary,
   read and written. *)
let runtime_probe_status_to_string = function
  | Runtime_probe_reachable -> "ok"
  | Runtime_probe_no_http_runtimes -> "idle"
  | Runtime_probe_degraded -> "degraded"
  (* The producer writes both "unavailable" and "unreachable" for this
     reading; one of them has to be the one written back. *)
  | Runtime_probe_unreachable -> "unreachable"
  | Runtime_probe_warming -> "warming_up"

let runtime_provider_status_to_string = function
  | Runtime_provider_reachable -> "reachable"
  | Runtime_provider_missing_auth -> "missing_auth"
  | Runtime_provider_auth_failed -> "auth_failed"
  | Runtime_provider_network_error -> "network_error"
  | Runtime_provider_server_error -> "server_error"
  | Runtime_provider_endpoint_not_found -> "endpoint_not_found"
  | Runtime_provider_http_error -> "http_error"
  | Runtime_provider_unknown_http_status -> "unknown_http_status"
  | Runtime_provider_skipped_cli -> "skipped_cli"
  | Runtime_provider_invalid_endpoint -> "invalid_endpoint"
  | Runtime_provider_invalid_execution_transport ->
      "invalid_execution_transport"

let runtime_probe_refresh_state_of_string = function
  | "fresh" -> Ok Runtime_probe_fresh
  | "recent" -> Ok Runtime_probe_recent
  | "served_stale" -> Ok Runtime_probe_served_stale
  | "warming_up" -> Ok Runtime_probe_warming_up
  | value -> Error (Printf.sprintf "unknown runtime probe refresh_state %S" value)

(* The words the producer writes, not a list that grew beside it.

   [Server_dashboard_http_runtime_info] fills this field from three places:
   the live summary picks between [Health_status.Ok], [Idle], [Degraded] and
   [Unavailable]; the failure envelope writes ["unreachable"]; the cold-start
   envelope writes ["warming_up"]. Those six are the whole vocabulary.

   This list had ["reachable"] and ["no_http_runtimes"] instead of ["ok"] and
   ["idle"], and nothing has written those two -- searched for the literals
   across lib/ and bin/. So every response failed the decode and the surface
   drew "probe unavailable / read failed" with all twenty-nine candidates
   reading "unobserved". A dead column that looks like an observation nobody
   made is worse than an empty one: it answers the question wrongly instead
   of declining to.

   The variant names stay: they say what the reading means, and the meaning
   did not drift -- only the spelling the wire uses. *)
let runtime_probe_status_of_string = function
  | "ok" -> Ok Runtime_probe_reachable
  | "idle" -> Ok Runtime_probe_no_http_runtimes
  | "degraded" -> Ok Runtime_probe_degraded
  (* Two spellings for one reading, both live: the summary path writes
     ["unavailable"] and the failure envelope writes ["unreachable"]. *)
  | "unavailable" | "unreachable" -> Ok Runtime_probe_unreachable
  | "warming_up" -> Ok Runtime_probe_warming
  | value -> Error (Printf.sprintf "unknown runtime probe status %S" value)

let runtime_provider_status_of_string = function
  | "reachable" -> Ok Runtime_provider_reachable
  | "missing_auth" -> Ok Runtime_provider_missing_auth
  | "auth_failed" -> Ok Runtime_provider_auth_failed
  | "network_error" -> Ok Runtime_provider_network_error
  | "server_error" -> Ok Runtime_provider_server_error
  | "endpoint_not_found" -> Ok Runtime_provider_endpoint_not_found
  | "http_error" -> Ok Runtime_provider_http_error
  | "unknown_http_status" -> Ok Runtime_provider_unknown_http_status
  | "skipped_cli" -> Ok Runtime_provider_skipped_cli
  | "invalid_endpoint" -> Ok Runtime_provider_invalid_endpoint
  | "invalid_execution_transport" ->
      Ok Runtime_provider_invalid_execution_transport
  | value -> Error (Printf.sprintf "unknown runtime provider status %S" value)

let runtime_probe_transport_of_string = function
  | "http" -> Ok Runtime_probe_http
  | "cli" -> Ok Runtime_probe_cli
  | value -> Error (Printf.sprintf "unknown runtime probe transport %S" value)

let decode_runtime_provider_probe json =
  let* rpp_runtime_id = required_string_field json "runtime_id" in
  let* transport = required_string_field json "transport" in
  let* rpp_transport = runtime_probe_transport_of_string transport in
  let* status = required_string_field json "status" in
  let* rpp_status = runtime_provider_status_of_string status in
  let* rpp_reachable = required_nullable_bool_field json "reachable" in
  let* rpp_http_status = required_nullable_int_field json "http_status" in
  let* rpp_latency_ms = required_nullable_float_field json "latency_ms" in
  let* rpp_error = required_nullable_string_field json "error" in
  let* rpp_checked_at = required_string_field json "checked_at" in
  let expected_reachable =
    match rpp_status with
    | Runtime_provider_reachable -> Some true
    | Runtime_provider_skipped_cli -> None
    | Runtime_provider_missing_auth
    | Runtime_provider_auth_failed
    | Runtime_provider_network_error
    | Runtime_provider_server_error
    | Runtime_provider_endpoint_not_found
    | Runtime_provider_http_error
    | Runtime_provider_unknown_http_status
    | Runtime_provider_invalid_endpoint
    | Runtime_provider_invalid_execution_transport -> Some false
  in
  let* () =
    if rpp_reachable = expected_reachable then Ok ()
    else
      Error
        (Printf.sprintf "runtime %S status %S disagrees with reachable"
           rpp_runtime_id status)
  in
  let* () =
    match rpp_transport, rpp_status with
    | Runtime_probe_cli, Runtime_provider_skipped_cli
    | Runtime_probe_http,
      ( Runtime_provider_reachable
      | Runtime_provider_missing_auth
      | Runtime_provider_auth_failed
      | Runtime_provider_network_error
      | Runtime_provider_server_error
      | Runtime_provider_endpoint_not_found
      | Runtime_provider_http_error
      | Runtime_provider_unknown_http_status
      | Runtime_provider_invalid_endpoint
      | Runtime_provider_invalid_execution_transport ) -> Ok ()
    | Runtime_probe_cli, _ ->
        Error (Printf.sprintf "CLI runtime %S was not skipped" rpp_runtime_id)
    | Runtime_probe_http, Runtime_provider_skipped_cli ->
        Error (Printf.sprintf "HTTP runtime %S was marked skipped_cli" rpp_runtime_id)
  in
  let nonnegative name = function
    | Some value when value < 0 ->
        Error (Printf.sprintf "runtime %S has negative %s" rpp_runtime_id name)
    | Some _ | None -> Ok ()
  in
  let* () = nonnegative "http_status" rpp_http_status in
  let* () =
    match rpp_latency_ms with
    | Some value when value < 0.0 ->
        Error (Printf.sprintf "runtime %S has negative latency_ms" rpp_runtime_id)
    | Some _ | None -> Ok ()
  in
  Ok
    { rpp_runtime_id
    ; rpp_transport
    ; rpp_status
    ; rpp_reachable
    ; rpp_http_status
    ; rpp_latency_ms
    ; rpp_error
    ; rpp_checked_at
    }

let decode_runtime_probe_summary json =
  let* rpsu_runtimes = required_int_field json "runtimes" in
  let* rpsu_probed = required_int_field json "probed" in
  let* rpsu_reachable = required_int_field json "reachable" in
  let* rpsu_failed = required_int_field json "failed" in
  let* rpsu_skipped = required_int_field json "skipped" in
  let* rpsu_default_runtime_id =
    required_nullable_string_field json "default_runtime_id"
  in
  let counts =
    [ "runtimes", rpsu_runtimes
    ; "probed", rpsu_probed
    ; "reachable", rpsu_reachable
    ; "failed", rpsu_failed
    ; "skipped", rpsu_skipped
    ]
  in
  match List.find_opt (fun (_, value) -> value < 0) counts with
  | Some (name, _) -> Error (Printf.sprintf "runtime probe summary %s is negative" name)
  | None ->
      Ok
        { rpsu_runtimes
        ; rpsu_probed
        ; rpsu_reachable
        ; rpsu_failed
        ; rpsu_skipped
        ; rpsu_default_runtime_id
        }

let decode_runtime_probe_snapshot json =
  let* rps_generated_at = required_string_field json "generated_at" in
  let* rps_refreshed_at_unix =
    required_nullable_float_field json "refreshed_at_unix"
  in
  let* rps_cache_ttl_sec = require_float_field json "cache_ttl_sec" in
  let* rps_cache_age_sec = required_nullable_float_field json "cache_age_sec" in
  let* rps_cache_hit = required_bool_field json "cache_hit" in
  let* refresh_state = required_string_field json "refresh_state" in
  let* rps_refresh_state = runtime_probe_refresh_state_of_string refresh_state in
  let* probe = required_object_field json "probe" in
  let* source = required_string_field probe "source" in
  let* () =
    if String.equal source "runtime.toml" then Ok ()
    else Error (Printf.sprintf "runtime probe source is %S, expected runtime.toml" source)
  in
  let* status = required_string_field probe "status" in
  let* rps_status = runtime_probe_status_of_string status in
  let* rps_probe_ok = required_bool_field probe "probe_ok" in
  let* rps_checked_at = required_string_field probe "checked_at" in
  let* summary = required_object_field probe "summary" in
  let* rps_summary = decode_runtime_probe_summary summary in
  let* providers = required_list_field probe "providers" in
  let* rps_providers =
    decode_list "providers" decode_runtime_provider_probe providers
  in
  let* rps_errors = require_string_list probe "errors" in
  let* rps_observations = require_string_list probe "observations" in
  let* rps_limitations = require_string_list probe "limitations" in
  let* () =
    if rps_cache_ttl_sec <= 0.0 then Error "runtime probe cache_ttl_sec must be positive"
    else
      match rps_cache_age_sec with
      | Some age when age < 0.0 -> Error "runtime probe cache_age_sec is negative"
      | Some _ | None -> Ok ()
  in
  let* () =
    match rps_refreshed_at_unix, rps_cache_age_sec with
    | Some _, Some _ | None, None -> Ok ()
    | Some _, None | None, Some _ ->
        Error "runtime probe refreshed_at_unix and cache_age_sec disagree"
  in
  let* () =
    match rps_refresh_state, rps_cache_hit with
    | (Runtime_probe_fresh | Runtime_probe_recent), true
    | (Runtime_probe_served_stale | Runtime_probe_warming_up), false -> Ok ()
    | _ ->
        Error
          (Printf.sprintf "runtime probe refresh_state %S disagrees with cache_hit"
             refresh_state)
  in
  let observed_reachable, observed_failed, observed_skipped =
    List.fold_left
      (fun (reachable, failed, skipped) provider ->
         match provider.rpp_reachable with
         | Some true -> reachable + 1, failed, skipped
         | Some false -> reachable, failed + 1, skipped
         | None -> reachable, failed, skipped + 1)
      (0, 0, 0) rps_providers
  in
  let row_count = List.length rps_providers in
  let* () =
    if rps_summary.rpsu_runtimes <> row_count then
      Error
        (Printf.sprintf "runtime probe summary has %d runtimes but providers has %d rows"
           rps_summary.rpsu_runtimes row_count)
    else if rps_summary.rpsu_reachable <> observed_reachable then
      Error "runtime probe reachable count disagrees with providers"
    else if rps_summary.rpsu_failed <> observed_failed then
      Error "runtime probe failed count disagrees with providers"
    else if rps_summary.rpsu_skipped <> observed_skipped then
      Error "runtime probe skipped count disagrees with providers"
    else if rps_summary.rpsu_probed <> observed_reachable + observed_failed then
      Error "runtime probe probed count disagrees with providers"
    else Ok ()
  in
  let* () =
    let seen = Hashtbl.create (max 1 row_count) in
    let rec loop = function
      | [] -> Ok ()
      | row :: rest ->
          if Hashtbl.mem seen row.rpp_runtime_id then
            Error
              (Printf.sprintf "duplicate runtime probe id %S" row.rpp_runtime_id)
          else begin
            Hashtbl.add seen row.rpp_runtime_id ();
            loop rest
          end
    in
    loop rps_providers
  in
  let* () =
    match rps_summary.rpsu_default_runtime_id with
    | None -> Ok ()
    | Some default_id ->
        if List.exists (fun row -> String.equal row.rpp_runtime_id default_id) rps_providers
        then Ok ()
        else Error (Printf.sprintf "default runtime %S is absent from providers" default_id)
  in
  let status_counts_valid =
    match rps_status with
    | Runtime_probe_reachable -> observed_failed = 0 && observed_reachable > 0
    | Runtime_probe_no_http_runtimes ->
        observed_failed = 0 && observed_reachable = 0
    | Runtime_probe_degraded -> observed_failed > 0 && observed_reachable > 0
    | Runtime_probe_unreachable ->
        observed_reachable = 0 && (observed_failed > 0 || row_count = 0)
    | Runtime_probe_warming -> row_count = 0
  in
  let* () =
    if status_counts_valid then Ok ()
    else
      Error
        (Printf.sprintf "runtime probe status %S disagrees with provider counts" status)
  in
  let expected_probe_ok =
    match rps_status with
    | Runtime_probe_reachable | Runtime_probe_no_http_runtimes -> true
    | Runtime_probe_degraded | Runtime_probe_unreachable | Runtime_probe_warming -> false
  in
  let* () =
    if rps_probe_ok = expected_probe_ok then Ok ()
    else Error (Printf.sprintf "runtime probe status %S disagrees with probe_ok" status)
  in
  let* () =
    match rps_refresh_state, rps_status, rps_refreshed_at_unix with
    | Runtime_probe_warming_up, Runtime_probe_warming, None -> Ok ()
    | Runtime_probe_warming_up, _, _ ->
        Error "runtime probe warming_up refresh must carry a warming probe without a cache time"
    | (Runtime_probe_fresh | Runtime_probe_recent | Runtime_probe_served_stale), _, Some _ ->
        Ok ()
    | (Runtime_probe_fresh | Runtime_probe_recent | Runtime_probe_served_stale), _, None ->
        Error "runtime probe cached refresh is missing refreshed_at_unix"
  in
  Ok
    { rps_generated_at
    ; rps_refreshed_at_unix
    ; rps_cache_ttl_sec
    ; rps_cache_age_sec
    ; rps_cache_hit
    ; rps_refresh_state
    ; rps_status
    ; rps_probe_ok
    ; rps_checked_at
    ; rps_summary
    ; rps_providers
    ; rps_errors
    ; rps_observations
    ; rps_limitations
    }

let decode_runtime_option ~default_id json =
  let* ro_id = required_string_field json "id" in
  let* ro_provider = required_string_field json "provider" in
  let* ro_model = required_string_field json "model" in
  let* _binding_is_default = required_bool_field json "is_default" in
  let* ro_dispatchable = required_bool_field json "keeper_dispatchable" in
  let* ro_blocked_reason =
    required_nullable_string_field json "keeper_dispatch_blocked_reason"
  in
  let* () =
    match ro_dispatchable, ro_blocked_reason with
    | true, None | false, Some _ -> Ok ()
    | true, Some _ ->
        Error
          (Printf.sprintf "dispatchable runtime %S carries a blocker" ro_id)
    | false, None ->
        Error (Printf.sprintf "blocked runtime %S omits its blocker" ro_id)
  in
  let ro_is_default = Option.equal String.equal default_id (Some ro_id) in
  Ok
    { ro_id
    ; ro_provider
    ; ro_model
    ; ro_dispatchable
    ; ro_blocked_reason
    ; ro_is_default
    }

let decode_runtime_default_member json =
  match Json_util.assoc_member_opt "default_runtime" json with
  | None -> missing_field "default_runtime"
  | Some `Null -> Ok (None, None)
  | Some (`Assoc _ as value) ->
      let* id = required_string_field value "id" in
      Ok (Some value, Some id)
  | Some bad -> field_type_error "default_runtime" "an object or null" bad

let decode_runtime_resolved_lane json =
  let* rrl_id = required_string_field json "id" in
  let* runtime_ids = required_list_field json "runtime_ids" in
  let* rrl_runtime_ids =
    decode_list "runtime_ids"
      (function
        | `String value -> Ok value
        | bad -> field_type_error "runtime_ids" "a string" bad)
      runtime_ids
  in
  let* rrl_preferred_candidate =
    required_nullable_string_field json "preferred_candidate"
  in
  let* rrl_preferred_at_ts =
    required_nullable_float_field json "preferred_at_ts"
  in
  let* () =
    match rrl_runtime_ids with
    | [] -> Error (Printf.sprintf "runtime lane %S has no candidates" rrl_id)
    | _ -> Ok ()
  in
  let* () =
    let seen = Hashtbl.create (List.length rrl_runtime_ids) in
    let rec loop = function
      | [] -> Ok ()
      | runtime_id :: rest ->
          if Hashtbl.mem seen runtime_id then
            Error
              (Printf.sprintf "runtime lane %S repeats candidate %S" rrl_id
                 runtime_id)
          else begin
            Hashtbl.add seen runtime_id ();
            loop rest
          end
    in
    loop rrl_runtime_ids
  in
  let* () =
    match rrl_preferred_candidate, rrl_preferred_at_ts with
    | None, None -> Ok ()
    | Some candidate, Some at
      when at >= 0.0 && List.mem candidate rrl_runtime_ids -> Ok ()
    | Some candidate, Some at when at < 0.0 ->
        Error
          (Printf.sprintf "runtime lane %S has negative preferred_at_ts" rrl_id)
    | Some candidate, Some _ ->
        Error
          (Printf.sprintf "runtime lane %S prefers absent candidate %S" rrl_id
             candidate)
    | Some _, None | None, Some _ ->
        Error
          (Printf.sprintf
             "runtime lane %S preferred_candidate and preferred_at_ts disagree"
             rrl_id)
  in
  Ok
    { rrl_id
    ; rrl_runtime_ids
    ; rrl_preferred_candidate
    ; rrl_preferred_at_ts
    }

let decode_runtime_resolved_snapshot json =
  let* rrs_generated_at_iso = required_string_field json "generated_at_iso" in
  let* source = required_string_field json "source" in
  let* () =
    if String.equal source "/api/v1/runtime/resolved" then Ok ()
    else
      Error
        (Printf.sprintf "runtime resolved source is %S, expected endpoint path"
           source)
  in
  let* rrs_config_path = required_nullable_string_field json "config_path" in
  let* default_json, rrs_default_runtime_id =
    decode_runtime_default_member json
  in
  let* runtime_items = required_list_field json "runtimes" in
  let* rrs_runtimes =
    decode_list "runtimes"
      (decode_runtime_option ~default_id:rrs_default_runtime_id)
      runtime_items
  in
  let runtime_by_id = Hashtbl.create (max 1 (List.length rrs_runtimes)) in
  let* () =
    let rec loop = function
      | [] -> Ok ()
      | runtime :: rest ->
          if Hashtbl.mem runtime_by_id runtime.ro_id then
            Error (Printf.sprintf "duplicate resolved runtime id %S" runtime.ro_id)
          else begin
            Hashtbl.add runtime_by_id runtime.ro_id runtime;
            loop rest
          end
    in
    loop rrs_runtimes
  in
  let* default_runtime =
    match default_json with
    | None -> Ok None
    | Some value ->
        let* runtime =
          decode_runtime_option ~default_id:rrs_default_runtime_id value
        in
        Ok (Some runtime)
  in
  let* () =
    match default_runtime with
    | None -> Ok ()
    | Some default ->
        (match Hashtbl.find_opt runtime_by_id default.ro_id with
         | None -> Error "default_runtime is absent from the resolved runtime list"
         | Some listed
           when String.equal default.ro_provider listed.ro_provider
                && String.equal default.ro_model listed.ro_model
                && Bool.equal default.ro_dispatchable listed.ro_dispatchable
                && Option.equal String.equal default.ro_blocked_reason
                     listed.ro_blocked_reason -> Ok ()
         | Some _ ->
             Error "default_runtime disagrees with its resolved runtime row")
  in
  let* lane_items = required_list_field json "lanes" in
  let* rrs_lanes =
    decode_list "lanes" decode_runtime_resolved_lane lane_items
  in
  let lane_by_id = Hashtbl.create (max 1 (List.length rrs_lanes)) in
  let* () =
    let rec loop = function
      | [] -> Ok ()
      | lane :: rest ->
          if Hashtbl.mem lane_by_id lane.rrl_id then
            Error (Printf.sprintf "duplicate runtime lane id %S" lane.rrl_id)
          else begin
            Hashtbl.add lane_by_id lane.rrl_id lane;
            match List.find_opt (fun id -> not (Hashtbl.mem runtime_by_id id)) lane.rrl_runtime_ids with
            | Some runtime_id ->
                Error
                  (Printf.sprintf "runtime lane %S names absent runtime %S"
                     lane.rrl_id runtime_id)
            | None -> loop rest
          end
    in
    loop rrs_lanes
  in
  Ok
    { rrs_generated_at_iso
    ; rrs_config_path
    ; rrs_default_runtime_id
    ; rrs_runtimes
    ; rrs_lanes
    }

let join_runtime_surface ~probe ~probe_error ~resolved =
  let probe_rows =
    match probe with
    | Some snapshot -> snapshot.rps_providers
    | None -> []
  in
  let probe_by_runtime = Hashtbl.create (max 1 (List.length probe_rows)) in
  List.iter
    (fun row -> Hashtbl.add probe_by_runtime row.rpp_runtime_id row)
    probe_rows;
  let runtime_by_id = Hashtbl.create (max 1 (List.length resolved.rrs_runtimes)) in
  List.iter
    (fun runtime -> Hashtbl.add runtime_by_id runtime.ro_id runtime)
    resolved.rrs_runtimes;
  let rows_of_lane lane =
    let candidate_count = List.length lane.rrl_runtime_ids in
    let rec loop position acc = function
      | [] -> Ok (List.rev acc)
      | runtime_id :: rest ->
          (match Hashtbl.find_opt runtime_by_id runtime_id with
           | None ->
               Error
                 (Printf.sprintf "runtime lane %S names absent runtime %S"
                    lane.rrl_id runtime_id)
           | Some runtime ->
               let rcr_preferred_at_ts =
                 match lane.rrl_preferred_candidate with
                 | Some preferred when String.equal preferred runtime_id ->
                     lane.rrl_preferred_at_ts
                 | Some _ | None -> None
               in
               loop (position + 1)
                 ({ rcr_lane_id = lane.rrl_id
                  ; rcr_position = position
                  ; rcr_candidate_count = candidate_count
                  ; rcr_runtime = runtime
                  ; rcr_preferred_at_ts
                  ; rcr_probe = Hashtbl.find_opt probe_by_runtime runtime_id
                  }
                  :: acc)
                 rest)
    in
    loop 1 [] lane.rrl_runtime_ids
  in
  let* reversed_candidates =
    List.fold_left
      (fun result lane ->
         let* acc = result in
         let* rows = rows_of_lane lane in
         Ok (List.rev_append rows acc))
      (Ok []) resolved.rrs_lanes
  in
  let rss_candidates = List.rev reversed_candidates in
  let candidate_ids = Hashtbl.create (max 1 (List.length rss_candidates)) in
  List.iter
    (fun row -> Hashtbl.replace candidate_ids row.rcr_runtime.ro_id ())
    rss_candidates;
  let rss_unassigned_probe_count =
    List.fold_left
      (fun count row ->
         if Hashtbl.mem candidate_ids row.rpp_runtime_id then count else count + 1)
      0 probe_rows
  in
  Ok
    { rss_probe = probe
    ; rss_probe_error = probe_error
    ; rss_resolved = resolved
    ; rss_candidates
    ; rss_unassigned_probe_count
    }

let decode_runtime_surface_snapshot ~probe_json ~resolved_json =
  match decode_runtime_probe_snapshot probe_json with
  | Error detail -> Error ("runtime probe decode failed: " ^ detail)
  | Ok probe ->
      (match decode_runtime_resolved_snapshot resolved_json with
       | Error detail -> Error ("runtime resolved decode failed: " ^ detail)
       | Ok resolved ->
           join_runtime_surface ~probe:(Some probe) ~probe_error:None ~resolved)

let decode_repository json =
  let* rp_id = required_string_field json "id" in
  let* rp_name = required_string_field json "name" in
  let* rp_codebase = optional_string_field json "codebase" in
  let* rp_url = required_string_field json "url" in
  let* rp_local_path = required_string_field json "local_path" in
  let* rp_resolved_local_path =
    required_string_field json "resolved_local_path"
  in
  let* rp_default_branch = required_string_field json "default_branch" in
  let* rp_status = required_string_field json "status" in
  let* rp_keepers = decode_string_name_list json "keepers" in
  let* rp_auto_sync =
    match member "auto_sync" json with
    | `Bool value -> Ok value
    | `Null -> Ok false
    | bad -> field_type_error "auto_sync" "a bool or null" bad
  in
  Ok
    { rp_id; rp_name; rp_codebase; rp_url; rp_local_path
    ; rp_resolved_local_path
    ; rp_default_branch; rp_status; rp_keepers; rp_auto_sync
    }

let decode_repository_snapshot json =
  let* repos_json = required_list_field json "repositories" in
  let* rs_repositories =
    decode_list "repositories" decode_repository repos_json
  in
  let* rs_total = required_int_field json "total" in
  Ok { rs_repositories; rs_total }

let decode_repository_change json =
  let* rc_path = required_string_field json "path" in
  let* rc_staged = required_bool_field json "staged" in
  let* rc_unstaged = required_bool_field json "unstaged" in
  let* rc_untracked = required_bool_field json "untracked" in
  let* rc_conflicted = required_bool_field json "conflicted" in
  Ok { rc_path; rc_staged; rc_unstaged; rc_untracked; rc_conflicted }

let decode_repository_change_scope json =
  let* kind = required_string_field json "kind" in
  match kind with
  | "project" -> Ok Repository_change_project
  | "repository" ->
      let* repository_id = required_string_field json "repository_id" in
      Ok (Repository_change_repository repository_id)
  | unknown ->
      Error (Printf.sprintf "repository change scope has unknown kind %S" unknown)

let decode_repository_change_snapshot json =
  let* scope_json = required_object_field json "scope" in
  let* rcs_scope = decode_repository_change_scope scope_json in
  let* changes_json = required_list_field json "changes" in
  let* rcs_changes =
    decode_list "changes" decode_repository_change changes_json
  in
  let* rcs_total = required_int_field json "total" in
  Ok { rcs_scope; rcs_changes; rcs_total }

let decode_memory_alert json =
  let* ma_code = required_string_field json "code" in
  let* ma_severity = required_string_field json "severity" in
  let* ma_label = required_string_field json "label" in
  let* ma_message = required_string_field json "message" in
  Ok { ma_code; ma_severity; ma_label; ma_message }

let decode_memory_keeper_health json =
  let* mkh_keeper_id = required_string_field json "keeper_id" in
  let* mkh_revision = required_int_field json "revision" in
  let* mkh_facts = required_int_field json "facts" in
  let* mkh_snapshot_bytes = required_int_field json "snapshot_bytes" in
  let* mkh_added = required_int_field json "added" in
  let* mkh_removed = required_int_field json "removed" in
  let* mkh_snapshot_present = required_bool_field json "snapshot_present" in
  let* mkh_librarian_lane_busy = required_int_field json "librarian_lane_busy" in
  let* mkh_librarian_failures = required_int_field json "librarian_failures" in
  let* mkh_read_error = optional_string json "read_error" in
  let* alerts_json = required_list_field json "alerts" in
  let* mkh_alerts = decode_list "alerts" decode_memory_alert alerts_json in
  Ok
    { mkh_keeper_id
    ; mkh_revision
    ; mkh_facts
    ; mkh_snapshot_bytes
    ; mkh_added
    ; mkh_removed
    ; mkh_snapshot_present
    ; mkh_librarian_lane_busy
    ; mkh_librarian_failures
    ; mkh_read_error
    ; mkh_alerts
    }

let decode_memory_health_snapshot json =
  let* mhs_generated_at = require_float_field json "generated_at" in
  let* keepers_json = required_list_field json "keepers" in
  let* mhs_keepers =
    decode_list "keepers" decode_memory_keeper_health keepers_json
  in
  let* totals_json = required_member json "totals" in
  let* mhs_total_facts = required_int_field totals_json "facts" in
  let* mhs_total_snapshot_bytes =
    required_int_field totals_json "snapshot_bytes"
  in
  let* mhs_total_librarian_failures =
    required_int_field totals_json "librarian_failures"
  in
  let* mhs_total_read_errors = required_int_field totals_json "read_errors" in
  let* summary_json = required_member json "alert_summary" in
  let* mhs_warn_alerts = required_int_field summary_json "warn_alerts" in
  let* mhs_error_alerts = required_int_field summary_json "error_alerts" in
  let* mhs_starving_keepers =
    required_int_field summary_json "librarian_starving_keepers"
  in
  Ok
    { mhs_generated_at
    ; mhs_keepers
    ; mhs_total_facts
    ; mhs_total_snapshot_bytes
    ; mhs_total_librarian_failures
    ; mhs_total_read_errors
    ; mhs_warn_alerts
    ; mhs_error_alerts
    ; mhs_starving_keepers
    }

let decode_harness_verdict json =
  let* hv_task_id = required_string_field json "task_id" in
  let* hv_task_title = required_string_field json "task_title" in
  let* hv_agent = required_string_field json "agent_name" in
  let* hv_gate = required_string_field json "gate" in
  let* hv_verdict = required_string_field json "verdict" in
  let* hv_evaluator = required_string_field json "evaluator_runtime" in
  let* hv_fallback_reason = optional_string_field json "fallback_reason" in
  let* hv_at = require_float_field json "timestamp" in
  let* hv_notes_hash = required_string_field json "notes_hash" in
  Ok
    { hv_at
    ; hv_task_id
    ; hv_task_title
    ; hv_agent
    ; hv_gate
    ; hv_verdict
    ; hv_evaluator
    ; hv_fallback_reason
    ; hv_notes_hash
    }

(* Counts keyed by gate name, highest first and ties by name so two reads of
   the same numbers order them the same. An entry that is not a count is
   dropped rather than read as zero: the pane reports proportions from this
   section, and a malformed entry counted as nothing moves every one of
   them. *)
let decode_gate_distribution json =
  match member "gate_distribution" json with
  | `Assoc fields ->
      fields
      |> List.filter_map (fun (gate, value) ->
             match value with `Int count -> Some (gate, count) | _ -> None)
      |> List.sort (fun (left_gate, left) (right_gate, right) ->
             match Int.compare right left with
             | 0 -> String.compare left_gate right_gate
             | order -> order)
  | _ -> []

let decode_harness_calibration json =
  match member "calibration" json with
  | `Assoc _ as calibration ->
      let count key =
        match member key calibration with `Int value -> value | _ -> 0
      in
      Some
        { hcal_total = count "total_verdicts"
        ; hcal_approve = count "approve_count"
        ; hcal_reject = count "reject_count"
        ; hcal_labeled = count "labeled_count"
        ; hcal_gates = decode_gate_distribution calibration
        }
  | _ -> None

let decode_harness_overview json =
  match member "overview" json with
  | `Assoc _ as overview ->
      let status =
        match member "evaluator_status" overview with
        | `String value -> value
        | _ -> "unknown"
      in
      let last_signal_at =
        match member "last_signal_at" overview with
        | `Float value -> Some value
        | `Int value -> Some (Float.of_int value)
        | _ -> None
      in
      Some { hov_evaluator_status = status; hov_last_signal_at = last_signal_at }
  | _ -> None

let decode_harness_snapshot json =
  let* verdicts_json = required_list_field json "recent_verdicts" in
  let* hs_verdicts =
    decode_list "recent_verdicts" decode_harness_verdict verdicts_json
  in
  Ok
    { hs_verdicts
    ; hs_calibration = decode_harness_calibration json
    ; hs_overview = decode_harness_overview json
    }

let decode_verification_request json =
  let* vr_request_id = required_string_field json "request_id" in
  let* vr_task_id = required_string_field json "task_id" in
  let* vr_task_title = required_string_field json "task_title" in
  let* vr_submitted_by = required_string_field json "submitted_by" in
  let* vr_created_at = required_string_field json "created_at" in
  let* vr_required_artifacts =
    decode_string_name_list json "required_artifacts"
  in
  let* vr_submitted_evidence =
    decode_string_name_list json "submitted_evidence"
  in
  let* vr_evidence_error =
    optional_string_field json "evidence_projection_error"
  in
  Ok
    { vr_request_id
    ; vr_task_id
    ; vr_task_title
    ; vr_submitted_by
    ; vr_created_at
    ; vr_required_artifacts
    ; vr_submitted_evidence
    ; vr_evidence_error
    }

let decode_verification_snapshot json =
  let* requests_json = required_list_field json "requests" in
  let* vs_requests =
    decode_list "requests" decode_verification_request requests_json
  in
  let* vs_total = required_int_field json "total" in
  Ok { vs_requests; vs_total }

let decode_keeper_call json =
  let* kc_at = require_float_field json "ts" in
  let* kc_tool = required_string_field json "tool" in
  let* keeper = required_string_field json "keeper" in
  let* kc_success =
    match member "success" json with
    | `Bool value -> Ok value
    | `Null -> Error "keeper call has no success field"
    | _ -> Error "keeper call success is not a bool"
  in
  let kc_input =
    match member "input" json with
    | `String value -> value
    | other -> Yojson.Safe.to_string other
  in
  (* What came back, as the server serves it. The row already said a call ran
     and what it was called with; without this it never said what the call
     answered, which is the question a failed call leaves open. The server
     bounds it (the envelope carries [truncated_to]), so this is a read, not a
     second budget. A row that carries no result says nothing rather than an
     empty string: "returned nothing" and "was not recorded" are different. *)
  let kc_output =
    match member "output" json with
    | `String value when String.trim value <> "" -> Some value
    | `String _ | `Null -> None
    | other -> Some (Yojson.Safe.to_string other)
  in
  let kc_duration_ms =
    match member "duration_ms" json with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | _ -> None
  in
  let kc_turn = match member "turn" json with `Int value -> Some value | _ -> None in
  let string_opt key =
    match member key json with
    | `String value when String.trim value <> "" -> Some value
    | _ -> None
  in
  Ok
    ( keeper
    , { kc_at
      ; kc_tool
      ; kc_input
      ; kc_output
      ; kc_success
      ; kc_duration_ms
      ; kc_turn
      ; kc_task_id = string_opt "task_id"
      ; kc_model = string_opt "model"
      } )

let decode_keeper_calls_snapshot ~requested_keeper json =
  let* kcs_keeper = required_string_field json "keeper" in
  let* kcs_count = required_int_field json "count" in
  let* kcs_health = required_string_field json "health" in
  let* entries_json = required_list_field json "entries" in
  let* rows =
    decode_list "entries" decode_keeper_call entries_json
  in
  (* A row naming another keeper is the store's problem to surface, not a
     row to draw under this keeper's name. *)
  let kcs_entries, kcs_mismatched =
    List.fold_left
      (fun (kept, mismatched) (keeper, row) ->
        if String.equal keeper requested_keeper then (row :: kept, mismatched)
        else (kept, mismatched + 1))
      ([], 0) rows
  in
  let kcs_latest_age_s =
    match member "latest_age_s" json with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | _ -> None
  in
  let kcs_stale_reason =
    match member "stale_reason" json with
    | `String value when String.trim value <> "" && not (String.equal value "fresh")
      ->
        Some value
    | _ -> None
  in
  Ok
    { kcs_keeper
    ; kcs_entries = List.rev kcs_entries
    ; kcs_count
    ; kcs_health
    ; kcs_latest_age_s
    ; kcs_stale_reason
    ; kcs_mismatched
    }

let decode_system_log_snapshot json =
  let* entries_json = required_list_field json "entries" in
  let* sys_entries = decode_list "entries" decode_system_log_entry entries_json in
  let* sys_total = required_int_field json "total" in
  let* sys_latest_seq = required_int_field json "latest_seq" in
  Ok { sys_entries; sys_total; sys_latest_seq }

let decode_planning_snapshot json =
  let* goals_json = required_list_field json "goals" in
  let* pl_goals = decode_list "goals" decode_planning_goal goals_json in
  let* rollup_json = required_object_field json "rollup" in
  let* pl_rollup = decode_planning_rollup rollup_json in
  let* backlog_json = required_object_field json "task_backlog" in
  let* pl_backlog = decode_planning_backlog backlog_json in
  let* pl_generated_at = required_string_field json "generated_at" in
  Ok { pl_goals; pl_rollup; pl_backlog; pl_generated_at }

let decode_keeper_runtime json =
  let* kr_name = required_string_field json "name" in
  let* raw_health = required_string_field json "health" in
  let* kr_health =
    match keeper_health_of_string raw_health with
    | Some health -> Ok health
    | None ->
        Error
          (Printf.sprintf "keeper %S has unknown health %S" kr_name raw_health)
  in
  let* kr_paused = required_bool_field json "paused" in
  (* An absent action is absent, not a default one: the server publishes null
     when the diagnostic named none, and a keeper with nothing to do is a
     different reading from a keeper whose action this build cannot spell. *)
  let* kr_next_action =
    match member "next_action" json with
    | `Null -> Ok None
    | `String raw -> (
      match keeper_next_action_of_string raw with
      | Some action -> Ok (Some action)
      | None ->
          Error
            (Printf.sprintf "keeper %S has unknown next action %S" kr_name raw))
    | bad -> field_type_error "next_action" "a string or null" bad
  in
  let* kr_keepalive_running = required_bool_field json "keepalive_running" in
  let* kr_autoboot_enabled = required_bool_field json "autoboot_enabled" in
  let* kr_proactive_enabled = required_bool_field json "proactive_enabled" in
  let* kr_runtime_id = required_string_field json "runtime_id" in
  (* Under [meta] because the row already carries the keeper's own
     declaration there; a second top-level copy would be a second place to
     update. *)
  let* row_meta = required_object_field json "meta" in
  let* kr_sandbox_profile = required_string_field row_meta "sandbox_profile" in
  let* raw_phase = required_string_field json "phase" in
  let* kr_phase =
    match keeper_phase_of_string raw_phase with
    | Some phase -> Ok phase
    | None ->
        Error
          (Printf.sprintf "keeper %S has unknown lifecycle phase %S" kr_name
             raw_phase)
  in
  Ok
    { kr_name
    ; kr_health
    ; kr_paused
    ; kr_next_action
    ; kr_keepalive_running
    ; kr_autoboot_enabled
    ; kr_proactive_enabled
    ; kr_runtime_id
    ; kr_phase
    ; kr_sandbox_profile
    }

(* [truncated] is carried out rather than dropped: the route clamps its own
   limit, so a workspace with more keepers than one response holds would
   otherwise present a short list as the whole fleet. *)
let decode_keeper_runtime_list json =
  let* items = required_list_field json "keepers" in
  let* rows = decode_list "keepers" decode_keeper_runtime items in
  let* truncated =
    match member "truncated" json with
    | `Bool value -> Ok value
    | `Null -> Ok false
    | bad -> field_type_error "truncated" "a bool or null" bad
  in
  let* total = int_field_or json "total" ~default:(List.length rows) in
  Ok (rows, truncated, total)

let keeper_lane_phase_of_string raw =
  match keeper_phase_of_string raw with
  | None -> Lane_phase_unknown raw
  | Some phase -> (
      match phase with
      | Keeper_state_machine.Offline -> Lane_phase_offline
      | Keeper_state_machine.Running -> Lane_phase_running
      | Keeper_state_machine.Failing -> Lane_phase_failing
      | Keeper_state_machine.Draining -> Lane_phase_draining
      | Keeper_state_machine.Paused -> Lane_phase_paused
      | Keeper_state_machine.Stopped -> Lane_phase_stopped
      | Keeper_state_machine.Crashed -> Lane_phase_crashed
      | Keeper_state_machine.Restarting -> Lane_phase_restarting)

let keeper_lane_phase_to_string = function
  | Lane_phase_offline -> keeper_phase_to_string Keeper_state_machine.Offline
  | Lane_phase_running -> keeper_phase_to_string Keeper_state_machine.Running
  | Lane_phase_failing -> keeper_phase_to_string Keeper_state_machine.Failing
  | Lane_phase_draining -> keeper_phase_to_string Keeper_state_machine.Draining
  | Lane_phase_paused -> keeper_phase_to_string Keeper_state_machine.Paused
  | Lane_phase_stopped -> keeper_phase_to_string Keeper_state_machine.Stopped
  | Lane_phase_crashed -> keeper_phase_to_string Keeper_state_machine.Crashed
  | Lane_phase_restarting ->
      keeper_phase_to_string Keeper_state_machine.Restarting
  | Lane_phase_unknown raw -> raw

let keeper_lane_turn_phase_of_string = function
  | "idle" -> Lane_turn_idle
  | "prompting" -> Lane_turn_prompting
  | "routing" -> Lane_turn_routing
  | "executing" -> Lane_turn_executing
  | "finalizing" -> Lane_turn_finalizing
  | "exhausted" -> Lane_turn_exhausted
  | raw -> Lane_turn_unknown raw

let keeper_lane_turn_phase_to_string = function
  | Lane_turn_idle -> "idle"
  | Lane_turn_prompting -> "prompting"
  | Lane_turn_routing -> "routing"
  | Lane_turn_executing -> "executing"
  | Lane_turn_finalizing -> "finalizing"
  | Lane_turn_exhausted -> "exhausted"
  | Lane_turn_unknown raw -> raw

let decode_keeper_lane_last_outcome json =
  let* klo_runtime_state = required_string_field json "runtime_state" in
  let* klo_selected_model =
    required_nullable_string_field json "selected_model"
  in
  Ok { klo_runtime_state; klo_selected_model }

let decode_keeper_lane json =
  let* kl_keeper = required_string_field json "keeper" in
  let* raw_phase = required_string_field json "phase" in
  let kl_phase = keeper_lane_phase_of_string raw_phase in
  let* raw_turn_phase = required_string_field json "turn_phase" in
  let kl_turn_phase = keeper_lane_turn_phase_of_string raw_turn_phase in
  let* kl_idle_seconds = required_int_field json "idle_seconds" in
  let* kl_last_outcome =
    match Json_util.assoc_member_opt "last_outcome" json with
    | None -> missing_field "last_outcome"
    | Some `Null -> Ok None
    | Some (`Assoc _ as outcome) ->
        let* decoded = decode_keeper_lane_last_outcome outcome in
        Ok (Some decoded)
    | Some bad -> field_type_error "last_outcome" "an object or null" bad
  in
  let* diagnosis = required_object_field json "phase_diagnosis" in
  let* kl_diagnosis =
    required_nullable_string_field diagnosis "determining_condition"
  in
  Ok
    { kl_keeper
    ; kl_phase
    ; kl_turn_phase
    ; kl_idle_seconds
    ; kl_last_outcome
    ; kl_diagnosis
    }

let decode_keeper_lanes_snapshot json =
  let* kls_generated_at = require_float_field json "generated_at" in
  let* kls_count = required_int_field json "count" in
  let* items = required_list_field json "snapshots" in
  let* kls_lanes = decode_list "snapshots" decode_keeper_lane items in
  Ok { kls_generated_at; kls_count; kls_lanes }

let standalone_lane_status_of_string = function
  | "running" -> Ok Standalone_running
  | "idle" -> Ok Standalone_idle
  | "degraded" -> Ok Standalone_degraded
  | "no_retained_observation" -> Ok Standalone_no_retained_observation
  | "unavailable" -> Ok Standalone_unavailable
  | other -> Error ("standalone lane status: unknown value " ^ other)

let standalone_lane_status_to_string = function
  | Standalone_running -> "running"
  | Standalone_idle -> "idle"
  | Standalone_degraded -> "degraded"
  (* Thirteen cells, not twenty-three. This is what the screen prints in a
     column sized for the other four words, and the long spelling pushed its
     whole row nine columns right of every other one. The row already says
     the rest -- [runs 0], [observed none] -- so the state word only has to
     name the state. *)
  | Standalone_no_retained_observation -> "none retained"
  | Standalone_unavailable -> "unavailable"

let decode_standalone_lane_slot_count json =
  let* slsc_slot_id = required_string_field json "slot_id" in
  let* slsc_count = required_int_field json "count" in
  Ok { slsc_slot_id; slsc_count }

let decode_standalone_lane json =
  let* sl_lane_id = required_string_field json "lane_id" in
  let* sl_label = required_string_field json "label" in
  let* sl_required = required_bool_field json "required" in
  let* observation_only = required_bool_field json "observation_only" in
  let* () =
    if observation_only then Ok ()
    else Error "standalone lane row is not observation-only"
  in
  let* _configured = required_nullable_bool_field json "configured" in
  let* sl_configuration_state = required_string_field json "configuration_state" in
  let* admitted_slots = required_list_field json "admitted_slots" in
  let* sl_admitted_slots =
    decode_list
      "admitted_slots"
      (function
        | `String slot_id -> Ok slot_id
        | _ -> Error "admitted_slots: expected a string")
      admitted_slots
  in
  let* cli_slots = required_list_field json "cli_slots" in
  let* sl_cli_slots =
    decode_list
      "cli_slots"
      (function
        | `String runtime_id -> Ok runtime_id
        | _ -> Error "cli_slots: expected a string")
      cli_slots
  in
  let* dropped_slots = required_list_field json "dropped_slots" in
  let* sl_dropped_slots =
    decode_list
      "dropped_slots"
      (function
        | `String slot_id -> Ok slot_id
        | _ -> Error "dropped_slots: expected a string")
      dropped_slots
  in
  let* sl_admission_error = required_nullable_string_field json "admission_error" in
  let* status = required_string_field json "status" in
  let* sl_status = standalone_lane_status_of_string status in
  let* sl_retained_run_count = required_int_field json "retained_run_count" in
  let* sl_running_count = required_int_field json "running_count" in
  let* sl_succeeded_count = required_int_field json "succeeded_count" in
  let* sl_failed_count = required_int_field json "failed_count" in
  let* sl_cancelled_count = required_int_field json "cancelled_count" in
  let* sl_last_started_at = required_nullable_float_field json "last_started_at" in
  let* sl_last_terminal_at = required_nullable_float_field json "last_terminal_at" in
  let* sl_last_outcome = required_nullable_string_field json "last_outcome" in
  let* sl_p50_elapsed_s = required_nullable_float_field json "p50_elapsed_s" in
  let* selected_slots = required_list_field json "selected_slots" in
  let* sl_selected_slots =
    decode_list "selected_slots" decode_standalone_lane_slot_count selected_slots
  in
  Ok
    { sl_lane_id
    ; sl_label
    ; sl_required
    ; sl_status
    ; sl_configuration_state
    ; sl_admitted_slots
    ; sl_cli_slots
    ; sl_dropped_slots
    ; sl_admission_error
    ; sl_retained_run_count
    ; sl_running_count
    ; sl_succeeded_count
    ; sl_failed_count
    ; sl_cancelled_count
    ; sl_last_started_at
    ; sl_last_terminal_at
    ; sl_last_outcome
    ; sl_p50_elapsed_s
    ; sl_selected_slots
    }

let decode_standalone_lanes_snapshot json =
  let* schema = required_string_field json "schema" in
  let* () =
    if String.equal schema "masc.standalone_llm_lanes.v1" then Ok ()
    else Error ("standalone lanes: unsupported schema " ^ schema)
  in
  let* _generated_at = required_string_field json "generated_at" in
  let* sls_observed_at_unix = require_float_field json "observed_at_unix" in
  let* sls_exact_run_projection_count =
    required_int_field json "exact_run_projection_count"
  in
  let* sls_exact_run_source_total = required_int_field json "exact_run_source_total" in
  let* sls_exact_run_projection_truncated =
    required_bool_field json "exact_run_projection_truncated"
  in
  let* () =
    if
      sls_exact_run_projection_count <= sls_exact_run_source_total
      && Bool.equal
           sls_exact_run_projection_truncated
           (sls_exact_run_projection_count < sls_exact_run_source_total)
    then Ok ()
    else Error "standalone lanes: exact run projection metadata is inconsistent"
  in
  let* observation_only = required_bool_field json "observation_only" in
  let* () =
    if observation_only then Ok ()
    else Error "standalone lanes snapshot is not observation-only"
  in
  let* items = required_list_field json "lanes" in
  let* sls_lanes = decode_list "lanes" decode_standalone_lane items in
  let expected_lane_ids =
    (* The registry owns the exact-lane spellings; only the verifier lane
       lives outside it. Spelling them here again was the drift the
       lane_key export exists to close. *)
    Runtime.verifier_exact_lane_id
    :: List.map Exact_lane_run_registry.lane_key Exact_lane_run_registry.all_lanes
    |> List.sort String.compare
  in
  let observed_lane_ids =
    sls_lanes |> List.map (fun lane -> lane.sl_lane_id) |> List.sort String.compare
  in
  if observed_lane_ids = expected_lane_ids
  then
    Ok
      { sls_observed_at_unix
      ; sls_exact_run_projection_count
      ; sls_exact_run_source_total
      ; sls_exact_run_projection_truncated
      ; sls_lanes
      }
  else Error "standalone lanes: expected each known lane exactly once"

let keeper_secret_status_of_string = function
  | "ready" -> Secret_ready
  | "empty" -> Secret_empty
  | "absent" -> Secret_absent
  | "error" -> Secret_error
  | other -> Secret_status_unknown other

let keeper_secret_status_to_string = function
  | Secret_ready -> "ready"
  | Secret_empty -> "empty"
  | Secret_absent -> "absent"
  | Secret_error -> "error"
  | Secret_status_unknown other -> other

let decode_string_list label items =
  decode_list label
    (fun item ->
      match item with
      | `String value -> Ok value
      | _ -> Error (Printf.sprintf "%s: expected a string" label))
    items

(* The producer sends file mounts as objects carrying both sides of the bind.
   The screen names the path the Keeper sees, because that is the one a
   Keeper's own error message will quote back. *)
let decode_file_mount_paths items =
  decode_list "file_mounts"
    (fun item -> required_string_field item "container_path")
    items

let decode_keeper_secret_projection ~keeper json =
  let* status = required_string_field json "status" in
  let ksp_status = keeper_secret_status_of_string status in
  let* ksp_root = required_string_field json "root" in
  let* env_items = optional_list_field json "env_names" in
  let* ksp_env_names = decode_string_list "env_names" env_items in
  let* mount_items = optional_list_field json "file_mounts" in
  let* ksp_file_paths = decode_file_mount_paths mount_items in
  let* validated = optional_bool_field json "values_validated" in
  let ksp_values_validated = Option.value validated ~default:false in
  let* ksp_error = optional_string_field json "error" in
  Ok
    { ksp_keeper = keeper
    ; ksp_status
    ; ksp_root
    ; ksp_env_names
    ; ksp_file_paths
    ; ksp_values_validated
    ; ksp_error
    }

let decode_keeper_secret_projections json =
  let* items = required_list_field json "snapshots" in
  List.fold_left
    (fun acc snapshot ->
      let* acc in
      match Json_util.assoc_member_opt "secret_projection" snapshot with
      | None | Some `Null -> Ok acc
      | Some projection ->
        let* keeper = required_string_field snapshot "keeper" in
        let* decoded = decode_keeper_secret_projection ~keeper projection in
        Ok (decoded :: acc))
    (Ok [])
    items
  |> Result.map List.rev

let fusion_run_status_to_string = function
  | Fusion_running -> "running"
  | Fusion_completed -> "completed"
  | Fusion_failed _ -> "failed"

let fusion_run_stage_to_string = function
  | Fusion_stage_accepted -> "accepted"
  | Fusion_stage_panel _ -> "panel"
  | Fusion_stage_judge _ -> "judge"
  | Fusion_stage_computed _ -> "computed"
  | Fusion_stage_recording_evidence _ -> "recording evidence"
  | Fusion_stage_completed -> "completed"
  | Fusion_stage_failed -> "failed"

let decode_fusion_progress_counts progress =
  let* frs_expected = required_int_field progress "panel_expected" in
  let* frs_answered = required_int_field progress "panel_answered" in
  let* frs_failed = required_int_field progress "panel_failed" in
  if frs_expected < 0 || frs_answered < 0 || frs_failed < 0 then
    Error "fusion progress counts must be non-negative"
  else if frs_answered + frs_failed <> frs_expected then
    Error "fusion answered + failed counts must equal panel_expected"
  else Ok (frs_expected, frs_answered, frs_failed)

let decode_fusion_stage ~status ~stage ~progress =
  match status, stage, progress with
  | Fusion_running, "accepted", `Assoc _ -> Ok Fusion_stage_accepted
  | Fusion_running, "panel", (`Assoc _ as progress) ->
      let* frs_expected = required_int_field progress "panel_expected" in
      if frs_expected < 0 then
        Error "fusion panel_expected must be non-negative"
      else Ok (Fusion_stage_panel { frs_expected })
  | Fusion_running, "judge", (`Assoc _ as progress) ->
      let* frs_expected, frs_answered, frs_failed =
        decode_fusion_progress_counts progress
      in
      Ok (Fusion_stage_judge { frs_expected; frs_answered; frs_failed })
  | Fusion_running, "computed", (`Assoc _ as progress) ->
      let* frs_expected, frs_answered, frs_failed =
        decode_fusion_progress_counts progress
      in
      Ok (Fusion_stage_computed { frs_expected; frs_answered; frs_failed })
  | Fusion_running, "recording_evidence", (`Assoc _ as progress) ->
      let* frs_expected, frs_answered, frs_failed =
        decode_fusion_progress_counts progress
      in
      Ok
        (Fusion_stage_recording_evidence
           { frs_expected; frs_answered; frs_failed })
  | Fusion_completed, "completed", `Null -> Ok Fusion_stage_completed
  | Fusion_failed _, "failed", `Null -> Ok Fusion_stage_failed
  | _ ->
      Error
        (Printf.sprintf "fusion status/stage/progress disagree: status=%s stage=%S"
           (fusion_run_status_to_string status) stage)

let decode_fusion_run json =
  let* fur_run_id = required_string_field json "run_id" in
  let* fur_keeper = required_string_field json "keeper" in
  let* fur_preset = required_string_field json "preset" in
  let* topology = required_string_field json "topology" in
  let* fur_topology =
    match Fusion_types.fusion_topology_of_string topology with
    | Some topology -> Ok topology
    | None -> Error (Printf.sprintf "unknown fusion topology %S" topology)
  in
  let* fur_started_at = require_float_field json "started_at" in
  let* status = required_string_field json "status" in
  let* fur_status =
    match status with
    | "running" -> Ok Fusion_running
    | "completed" -> Ok Fusion_completed
    | "failed" ->
        let* frs_failure_code = required_string_field json "failure_code" in
        let* frs_error = required_string_field json "error" in
        Ok (Fusion_failed { frs_failure_code; frs_error })
    | other -> Error (Printf.sprintf "unknown fusion run status %S" other)
  in
  let* stage = required_string_field json "stage" in
  let* progress = required_member json "progress" in
  let* fur_stage = decode_fusion_stage ~status:fur_status ~stage ~progress in
  let* fur_decision = optional_string_field json "decision" in
  let* fur_summary = optional_string_field json "summary" in
  let* () =
    match fur_status, fur_decision, fur_summary with
    | Fusion_completed, None, None
    | Fusion_completed, Some _, Some _
    | Fusion_running, None, None
    | Fusion_failed _, None, None -> Ok ()
    | Fusion_completed, (Some _ | None), (Some _ | None) ->
        Error "fusion completion decision and summary must appear together"
    | (Fusion_running | Fusion_failed _), (Some _ | None), (Some _ | None) ->
        Error "only a completed Fusion run may carry decision and summary"
  in
  Ok
    { fur_run_id
    ; fur_keeper
    ; fur_preset
    ; fur_topology
    ; fur_started_at
    ; fur_status
    ; fur_stage
    ; fur_decision
    ; fur_summary
    }

let decode_fusion_snapshot json =
  let* fus_generated_at = required_string_field json "generated_at" in
  let* count = required_int_field json "count" in
  let* runs_json = required_list_field json "runs" in
  let* fus_runs = decode_list "runs" decode_fusion_run runs_json in
  if count <> List.length fus_runs then
    Error
      (Printf.sprintf "fusion run count is %d but runs contains %d rows" count
         (List.length fus_runs))
  else Ok { fus_generated_at; fus_runs }

let decode_fusion_panel_result json =
  let* model = required_string_field json "model" in
  let* status = required_string_field json "status" in
  match status with
  | "answered" ->
      let* fpa_answer = required_string_field json "answer" in
      let* fpa_input_tokens = required_int_field json "input_tokens" in
      let* fpa_output_tokens = required_int_field json "output_tokens" in
      Ok
        (Fusion_panel_answered
           { fpa_model = model
           ; fpa_answer
           ; fpa_input_tokens
           ; fpa_output_tokens
           })
  | "failed" ->
      let* fpf_reason_code = required_string_field json "reason_code" in
      let* fpf_reason_detail = required_string_field json "reason_detail" in
      Ok
        (Fusion_panel_failed
           { fpf_model = model; fpf_reason_code; fpf_reason_detail })
  | other -> Error (Printf.sprintf "unknown fusion panel status %S" other)

let decode_fusion_judge json =
  let* status = required_string_field json "status" in
  match status with
  | "synthesized" ->
      let* fj_decision = required_string_field json "decision" in
      let* fj_resolved_answer = required_string_field json "resolved_answer" in
      let* fj_reason = required_string_field json "synthesis" in
      Ok
        (Fusion_judge_synthesized
           { fj_decision; fj_resolved_answer; fj_reason })
  | "failed" ->
      let* fj_failure_code = required_string_field json "failure_code" in
      let* fj_error = required_string_field json "error" in
      Ok (Fusion_judge_failed { fj_failure_code; fj_error })
  | other -> Error (Printf.sprintf "unknown fusion judge status %S" other)

let decode_fusion_tool_actor json =
  let* phase = required_string_field json "phase" in
  let* fta_identity = required_string_field json "actor" in
  let* judge_role = optional_string_field json "judge_role" in
  match phase, judge_role with
  | "panel", None -> Ok { fta_phase = Fusion_tool_panel; fta_identity }
  | "judge", Some role
    when List.mem role
           [ "single"; "refine"; "first"; "meta"; "stage_meta"; "final_meta" ] ->
      Ok { fta_phase = Fusion_tool_judge role; fta_identity }
  | "panel", Some _ -> Error "fusion panel tool actor cannot carry judge_role"
  | "judge", None -> Error "fusion judge tool actor requires judge_role"
  | "judge", Some role ->
      Error (Printf.sprintf "unknown fusion tool judge_role %S" role)
  | phase, _ -> Error (Printf.sprintf "unknown fusion tool phase %S" phase)

let decode_fusion_tool_preview json =
  let* ftp_text = required_string_field json "text" in
  let* ftp_bytes = required_int_field json "bytes" in
  let* ftp_truncated = required_bool_field json "truncated" in
  let shown_bytes = String.length ftp_text in
  if ftp_bytes < 0 then Error "fusion tool preview bytes must be non-negative"
  else if (not ftp_truncated) && ftp_bytes <> shown_bytes then
    Error "fusion complete tool preview byte count disagrees with text"
  else if ftp_truncated && ftp_bytes <= shown_bytes then
    Error "fusion truncated tool preview must report a larger source byte count"
  else Ok { ftp_text; ftp_bytes; ftp_truncated }

let decode_fusion_tool_common json =
  let* fte_actor = decode_fusion_tool_actor json in
  let* fte_agent_name = required_string_field json "agent_name" in
  let* fte_tool_use_id = required_string_field json "tool_use_id" in
  let* fte_turn = required_int_field json "turn" in
  let* fte_planned_index = required_int_field json "planned_index" in
  let* fte_tool_name = required_string_field json "tool_name" in
  if fte_turn < 0 || fte_planned_index < 0 then
    Error "fusion tool turn and planned_index must be non-negative"
  else
    Ok
      ( fte_actor
      , fte_agent_name
      , fte_tool_use_id
      , fte_turn
      , fte_planned_index
      , fte_tool_name )

let decode_fusion_tool_event json =
  let* event = required_string_field json "event" in
  let* ( fte_actor
       , fte_agent_name
       , fte_tool_use_id
       , fte_turn
       , fte_planned_index
       , fte_tool_name ) =
    decode_fusion_tool_common json
  in
  match event with
  | "called" ->
      let* input = required_object_field json "input" in
      let* fte_input = decode_fusion_tool_preview input in
      Ok
        (Fusion_tool_called
           { fte_actor
           ; fte_agent_name
           ; fte_tool_use_id
           ; fte_turn
           ; fte_planned_index
           ; fte_tool_name
           ; fte_input
           })
  | "completed" ->
      let* status = required_string_field json "status" in
      let* output = required_object_field json "output" in
      let* output = decode_fusion_tool_preview output in
      let* recoverable = optional_bool_field json "recoverable" in
      let* error_class = optional_string_field json "error_class" in
      let* fte_completion =
        match status, recoverable, error_class with
        | "succeeded", None, None -> Ok (Fusion_tool_succeeded output)
        | "failed", Some ftc_recoverable, ftc_error_class
          when Option.for_all
                 (fun class_ ->
                    List.mem class_ [ "transient"; "deterministic"; "unknown" ])
                 ftc_error_class ->
          Ok
            (Fusion_tool_failed
               { ftc_output = output; ftc_recoverable; ftc_error_class })
        | "succeeded", (Some _ | None), (Some _ | None) ->
          Error "successful fusion tool completion cannot carry failure fields"
        | "failed", None, _ ->
          Error "failed fusion tool completion requires recoverable"
        | "failed", Some _, Some class_ ->
          Error (Printf.sprintf "unknown fusion tool error_class %S" class_)
        | status, _, _ ->
          Error (Printf.sprintf "unknown fusion tool completion status %S" status)
      in
      Ok
        (Fusion_tool_completed
           { fte_actor
           ; fte_agent_name
           ; fte_tool_use_id
           ; fte_turn
           ; fte_planned_index
           ; fte_tool_name
           ; fte_completion
           })
  | event -> Error (Printf.sprintf "unknown fusion tool event %S" event)

let decode_fusion_tool_gap json =
  let* ftg_actor = decode_fusion_tool_actor json in
  let* ftg_reason = required_string_field json "reason" in
  if String.equal ftg_reason "official_client_uninstrumented"
  then Ok { ftg_actor; ftg_reason }
  else Error (Printf.sprintf "unknown fusion tool trace gap %S" ftg_reason)

let decode_fusion_tool_trace json =
  let* status = required_string_field json "status" in
  let* actor_json = required_list_field json "observed_actors" in
  let* ftt_observed_actors =
    decode_list "observed_actors" decode_fusion_tool_actor actor_json
  in
  let* ftt_dropped_events = required_int_field json "dropped_events" in
  let* gap_json = required_list_field json "gaps" in
  let* ftt_gaps = decode_list "gaps" decode_fusion_tool_gap gap_json in
  let* event_json = required_list_field json "events" in
  let* ftt_events = decode_list "events" decode_fusion_tool_event event_json in
  if ftt_dropped_events < 0 then
    Error "fusion tool dropped_events must be non-negative"
  else
    let expected_status =
      if ftt_dropped_events = 0 && ftt_gaps = [] then "complete" else "partial"
    in
    if not (String.equal status expected_status) then
      Error
        (Printf.sprintf
           "fusion tool trace status %S disagrees with drops/gaps; expected %S"
           status expected_status)
    else
      Ok
        { ftt_complete = String.equal status "complete"
        ; ftt_observed_actors
        ; ftt_dropped_events
        ; ftt_gaps
        ; ftt_events
        }

let decode_fusion_evidence ~run_id json =
  let* fe_post_id = required_string_field json "id" in
  let* fe_title = required_string_field json "title" in
  let* origin = required_object_field json "origin" in
  let* source = required_string_field origin "source" in
  let* origin_run_id = required_string_field origin "fusion_run_id" in
  let* () =
    if String.equal source "fusion" then Ok ()
    else
      Error
        (Printf.sprintf "fusion evidence origin.source is %S, expected \"fusion\""
           source)
  in
  let* () =
    if String.equal origin_run_id run_id then Ok ()
    else
      Error
        (Printf.sprintf
           "fusion evidence origin run id is %S, expected %S" origin_run_id
           run_id)
  in
  let* meta = required_object_field json "meta" in
  let* fe_question = required_string_field meta "question" in
  let* panel_json = required_list_field meta "panel" in
  let* fe_panel = decode_list "panel" decode_fusion_panel_result panel_json in
  let* judge_json = required_object_field meta "judge" in
  let* fe_judge = decode_fusion_judge judge_json in
  let* tool_trace_json = optional_object_field meta "tool_trace" in
  let* fe_tool_trace =
    match tool_trace_json with
    | Some tool_trace -> Result.map Option.some (decode_fusion_tool_trace tool_trace)
    | None -> Ok None
  in
  Ok
    { fe_post_id
    ; fe_title
    ; fe_question
    ; fe_panel
    ; fe_judge
    ; fe_tool_trace
    }

let decode_fusion_detail json =
  let* fud_generated_at = required_string_field json "generated_at" in
  let* run_json = required_object_field json "run" in
  let* fud_run = decode_fusion_run run_json in
  let* evidence = required_object_field json "evidence" in
  let* status = required_string_field evidence "status" in
  let* post =
    match Json_util.assoc_member_opt "post" evidence with
    | None -> missing_field "post"
    | Some post -> Ok post
  in
  match status, post with
  | "recorded", (`Assoc _ as post_json) ->
      let* fud_evidence =
        decode_fusion_evidence ~run_id:fud_run.fur_run_id post_json
      in
      Ok
        { fud_generated_at
        ; fud_run
        ; fud_evidence_status = Fusion_evidence_recorded
        ; fud_evidence = Some fud_evidence
        }
  | "recorded", bad ->
      field_type_error "evidence.post" "an object when status is recorded" bad
  | "pending", `Null ->
      (match fud_run.fur_status with
       | Fusion_running ->
           Ok
             { fud_generated_at
             ; fud_run
             ; fud_evidence_status = Fusion_evidence_pending
             ; fud_evidence = None
             }
       | Fusion_completed | Fusion_failed _ ->
           Error "only a running fusion run may have pending evidence")
  | "pending", _ -> Error "pending fusion evidence must carry post:null"
  | "absent", `Null ->
      (match fud_run.fur_status with
       | Fusion_running ->
           Error "a running fusion run cannot have absent evidence"
       | Fusion_completed | Fusion_failed _ ->
           Ok
             { fud_generated_at
             ; fud_run
             ; fud_evidence_status = Fusion_evidence_absent
             ; fud_evidence = None
             })
  | "absent", _ -> Error "absent fusion evidence must carry post:null"
  | other, _ -> Error (Printf.sprintf "unknown fusion evidence status %S" other)

(* The counts are read with a default rather than required: the server adds
   fields to this section over time, and a TUI that refuses the whole reading
   because one counter is new would hide the fleet exactly when it changed.
   The three that name the fleet's own verdict -- status, blocker, and whether
   an operator has to act -- are required, because a reading without them says
   nothing. *)
let decode_keeper_tool_approval json =
  let* kta_keeper = required_string_field json "keeper" in
  let* kta_tool_call_id = required_string_field json "tool_call_id" in
  let* kta_tool = required_string_field json "tool" in
  let* kta_args = required_string_field json "args" in
  let* kta_question = required_string_field json "question" in
  let* kta_because = optional_string_field json "because" in
  let* kta_asked_at = require_float_field json "asked_at" in
  let* kta_timeout_sec = require_float_field json "timeout_sec" in
  Ok
    { kta_keeper
    ; kta_tool_call_id
    ; kta_tool
    ; kta_args
    ; kta_question
    ; kta_because
    ; kta_asked_at
    ; kta_timeout_sec
    }

(* GET /api/v1/keepers/tool-approval-mode: the keepers moved off the default
   stance. Decoded to (keeper, mode) pairs; the caller decides what a mode
   means — this module carries the wire vocabulary only. *)
let decode_tool_approval_mode_overrides json =
  let* items = required_list_field json "overrides" in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
        let* keeper = required_string_field item "keeper" in
        let* mode = required_string_field item "mode" in
        loop ((keeper, mode) :: acc) rest
  in
  loop [] items

type gate_pending_phase =
  | Gate_queued
  | Gate_judging
  | Gate_human_required
  | Gate_blocked

type gate_pending = {
  gp_id : string;
  gp_keeper : string;
  gp_operation : string;
  gp_display_tool : string;
  gp_input_preview : string option;
  gp_execution_cwd : string option;
  gp_execution_sandbox : string option;
  gp_waiting_s : float option;
  gp_phase : gate_pending_phase;
}

type gate_lane_modes = {
  glm_workspace : string;
  glm_external : string;
}

(* An always-allow rule standing behind the queue. It answers a request
   before it ever becomes a pending ask, so a screen that shows only the
   queue shows nothing at all once a rule covers a call. The fingerprint is
   the whole match: a rule fires for one Keeper, one tool, and one exact
   input shape. *)
type gate_rule = {
  gr_id : string;
  gr_keeper : string;
  gr_tool : string;
  gr_fingerprint : string;
  gr_created_at : float;
  gr_created_by : string option;
  gr_expires_at : float option;
}

type gate_snapshot = {
  gs_pending : gate_pending list;
  gs_modes : gate_lane_modes option;
  gs_queue_unavailable : string option;
  gs_rules : gate_rule list;
  gs_rules_unavailable : string option;
}

(* What a human decides on. An identity_call row carries the real target
   inside its input; the closed operation name alone would make every
   outside-service row read the same. The literal comes from the producer so
   the two cannot drift. *)
let gate_display_tool ~operation input =
  if not (String.equal operation Keeper_identity_gate.gate_operation) then
    operation
  else
    match input with
    | Some input -> (
        let provider =
          match optional_string_field input "provider_id" with
          | Ok (Some value) when String.trim value <> "" -> Some value
          | Ok _ | Error _ -> None
        in
        let remote =
          match optional_string_field input "remote_name" with
          | Ok (Some value) when String.trim value <> "" -> Some value
          | Ok _ | Error _ -> None
        in
        match provider, remote with
        | Some provider, Some remote -> provider ^ " \xc2\xb7 " ^ remote
        | None, Some remote -> remote
        | Some _, None | None, None -> operation)
    | None -> operation

(* What the operator is actually deciding on a tool_execute row.

   [Keeper_tool_execute_runtime.execute_gate_input] wraps the tool arguments
   in an envelope whose [cwd] and sandbox fields say where the approval was
   granted. The server flattens that whole envelope into [input_preview], so
   the cell opens with the schema URN and an absolute path and the command
   runs off the right edge of the row -- at any terminal width, because the
   path comes first. Seven rows read that way while this was written: an
   operator pressing y/n could see the schema name and a directory, and not
   the command they were authorising.

   The arguments the producer stored verbatim under [input] are the decision,
   so they lead. Nothing is recovered from the preview text: the structured
   input is already here, and a shape this does not recognise keeps the
   server's preview rather than inventing a summary. *)
let json_string_list = function
  | `List items ->
    (* All or nothing. A non-string element that quietly vanished would show
       a command missing one of its words, which is worse than showing the
       envelope. *)
    List.fold_right
      (fun item acc ->
        match item, acc with
        | `String value, Some rest -> Some (value :: rest)
        | _, _ -> None)
      items (Some [])
  | _ -> None

let shell_word word =
  let needs_quotes =
    word = ""
    || String.exists
         (fun c -> c = ' ' || c = '\t' || c = '"' || c = '\'' || c = '\\')
         word
  in
  if not needs_quotes then word
  else "\"" ^ String.concat "\\\"" (String.split_on_char '"' word) ^ "\""

let command_text argv = String.concat " " (List.map shell_word argv)

let execute_gate_command envelope =
  let stage_command args =
    match json_string_list (member "argv" args) with
    | Some (_ :: _ as argv) -> Some (command_text argv)
    | Some [] | None -> None
  in
  let script_command args =
    (* The script form is already the command line the operator is
       approving; there is nothing to assemble. *)
    match member "script" args with
    | `String script when String.trim script <> "" -> Some script
    | _ -> None
  in
  match member "input" envelope with
  | `Assoc _ as args -> (
    match stage_command args with
    | Some command -> Some command
    | None -> (
      match script_command args with
      | Some command -> Some command
      | None -> (
      (* A staged call carries no top-level argv; the tool takes one shape or
         the other, never both. Stages read the way they run. *)
      match member "pipeline" args with
      | `List (_ :: _ as stages) ->
        List.fold_right
          (fun stage acc ->
            match stage_command stage, acc with
            | Some command, Some rest -> Some (command :: rest)
            | _, _ -> None)
          stages (Some [])
        |> Option.map (String.concat " | ")
      | _ -> None)))
  | _ -> None

(* Where the command would run. The same envelope carries it, and it decides
   what the command means: [git clone] into a container is not the decision
   [git clone] onto the host is. It rode along inside the flattened preview
   until the command took that cell, so it moves to the detail pane rather
   than disappearing. *)
let execute_gate_site envelope =
  let field name =
    match member name envelope with
    | `String value when String.trim value <> "" -> Some value
    | _ -> None
  in
  (field "cwd", field "sandbox_target")

let gate_execution_site ~operation envelope =
  if not (String.equal operation Keeper_tool_execute_runtime.gate_operation)
  then (None, None)
  else match envelope with Some envelope -> execute_gate_site envelope | None -> (None, None)

let gate_input_preview ~operation ~server_preview envelope =
  if not (String.equal operation Keeper_tool_execute_runtime.gate_operation)
  then server_preview
  else
    match envelope with
    | Some envelope -> (
      match execute_gate_command envelope with
      | Some command -> Some command
      | None -> server_preview)
    | None -> server_preview

(* The queue row is durable after Auto Judge stops. Calling every such row
   "waiting" made a completed [require_human] judgment look like a worker that
   had been computing for hours, and hid quarantined/failed attempts behind
   the same word. Project only the closed backend states already carried by
   the row; absent legacy fields remain queued rather than gaining invented
   success. *)
let gate_pending_phase_of_json json =
  let summary = member "summary_status" json in
  let disposition = member "summary_attempt_disposition" json in
  let disposition_code =
    match member "code" disposition with
    | `String value -> value
    | _ -> ""
  in
  let pre_worker_reason =
    match member "reason_code" disposition with
    | `String value -> value
    | _ -> ""
  in
  let summary_status =
    match summary with
    | `String value -> value
    | `Assoc _ ->
      (match member "status" summary with
       | `String value -> value
       | _ -> "")
    | _ -> ""
  in
  let judgment =
    match member "summary" summary |> member "judgment" with
    | `String value -> value
    | _ -> ""
  in
  match disposition_code, pre_worker_reason, summary_status, judgment with
  | ("identity_unbound" | "persistence_uncertain"), _, _, _ -> Gate_blocked
  (* A start reservation is a pre-worker state like its siblings: the worker is
     not judging yet. Rendering it as judging hid reservations that a restart
     stranded (now recovered by [release_orphaned_start_reservation]) behind a
     healthy-looking in-progress row. Blocked surfaces a lingering one; a healthy
     reservation clears within a poll. *)
  | "pre_worker_unavailable", _, _, _ -> Gate_blocked
  | _, _, "failed", _ -> Gate_blocked
  | _, _, "available", "require_human" -> Gate_human_required
  | "in_flight", _, _, _ | _, _, "pending", _ -> Gate_judging
  | "settled", _, "available", ("approve" | "deny") -> Gate_judging
  | _ -> Gate_queued

let decode_gate_pending json =
  let* gp_id = required_string_field json "id" in
  let* gp_keeper = required_string_field json "keeper_name" in
  let* gp_operation = required_string_field json "tool_name" in
  let* gp_input_preview = optional_string_field json "input_preview" in
  let gp_waiting_s =
    match member "waiting_s" json with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | _ -> None
  in
  let input =
    match member "input" json with
    | `Assoc _ as input -> Some input
    | _ -> None
  in
  Ok
    {
      gp_id;
      gp_keeper;
      gp_operation;
      gp_display_tool = gate_display_tool ~operation:gp_operation input;
      gp_input_preview =
        gate_input_preview ~operation:gp_operation
          ~server_preview:gp_input_preview input;
      gp_execution_cwd = fst (gate_execution_site ~operation:gp_operation input);
      gp_execution_sandbox =
        snd (gate_execution_site ~operation:gp_operation input);
      gp_waiting_s;
      gp_phase = gate_pending_phase_of_json json;
    }

let decode_gate_lane_modes json =
  let* workspace = required_object_field json "gate_mode" in
  let* glm_workspace = required_string_field workspace "mode" in
  let* external_lane = required_object_field json "external_gate_mode" in
  let* glm_external = required_string_field external_lane "mode" in
  Ok { glm_workspace; glm_external }

let decode_gate_rule json =
  let* gr_id = required_string_field json "id" in
  let* gr_keeper = required_string_field json "keeper_name" in
  let* gr_tool = required_string_field json "tool_name" in
  let* gr_fingerprint = required_string_field json "request_fingerprint" in
  let* gr_created_at =
    match member "created_at" json with
    | `Float value -> Ok value
    | `Int value -> Ok (float_of_int value)
    | _ -> Error "approval rule created_at must be a number"
  in
  let optional_string field =
    match member field json with
    | `String value -> Some value
    | _ -> None
  in
  let gr_expires_at =
    match member "expires_at" json with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | _ -> None
  in
  Ok
    { gr_id
    ; gr_keeper
    ; gr_tool
    ; gr_fingerprint
    ; gr_created_at
    ; gr_created_by = optional_string "created_by"
    ; gr_expires_at
    }

let decode_gate_snapshot json =
  let* gs_pending =
    match member "approval_queue" json with
    (* The server sends [null] when the queue store is unavailable; the
       snapshot still carries the lanes, so this is not a decode failure —
       but it is not "no pending approvals" either. The companion
       [approval_queue_state] below carries which of the two it was, the
       same field the dashboard reads. *)
    | `Null -> Ok []
    | `List items ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | item :: rest ->
              let* decoded = decode_gate_pending item in
              loop (decoded :: acc) rest
        in
        loop [] items
    | _ -> Error "approval_queue is neither a list nor null"
  in
  let* gs_queue_unavailable =
    match member "approval_queue_state" json with
    | `Null -> Ok None
    | state_json ->
        (match member "state" state_json with
         | `String "ready" -> Ok None
         | `String _ ->
             let detail =
               match member "operator_detail" state_json with
               | `String detail -> detail
               | _ -> "approval queue store is unreadable"
             in
             Ok (Some detail)
         | _ -> Error "approval_queue_state.state must be a string")
  in
  let* gs_modes =
    match member "hitl" json with
    | `Null -> Ok None
    | hitl ->
        let* modes = decode_gate_lane_modes hitl in
        Ok (Some modes)
  in
  let* gs_rules =
    match member "approval_rules" json with
    | `Null -> Ok []
    | `List items ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | item :: rest ->
              let* decoded = decode_gate_rule item in
              loop (decoded :: acc) rest
        in
        loop [] items
    | _ -> Error "approval_rules is neither a list nor null"
  in
  let* gs_rules_unavailable =
    match member "approval_rules_state" json with
    | `Null -> Ok None
    | state_json ->
        (match member "state" state_json with
         | `String "ready" -> Ok None
         | `String _ ->
             let detail =
               match member "error" state_json with
               | `String detail -> detail
               | _ -> "approval rule store is unreadable"
             in
             Ok (Some detail)
         | _ -> Error "approval_rules_state.state must be a string")
  in
  Ok { gs_pending; gs_modes; gs_queue_unavailable; gs_rules; gs_rules_unavailable }

(* The durable per-Keeper Gate settings, which are a different thing from the
   in-memory YOLO stance above: this is what the Gate decides an external
   effect under, and it survives a restart. Both lists carry only Keepers
   somebody singled out, so an empty one means everybody follows the
   workspace. *)
let decode_keeper_gate_settings json =
  let pairs field value_key =
    let* items = required_list_field json field in
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        let* keeper = required_string_field item "keeper_name" in
        let* value = required_string_field item value_key in
        loop ((keeper, value) :: acc) rest
    in
    loop [] items
  in
  let* modes = pairs "modes" "mode" in
  let* judges = pairs "judges" "slot_id" in
  Ok (modes, judges)

(* Keep the JSON spelling, including quotes around strings.  The Config pane
   now hands this exact spelling to its inline editor and sends the parsed
   value back to the typed runtime-parameter route.  Flattening strings to
   their display text made it impossible to distinguish ["30"] from [30] at
   the write boundary.  The renderer removes quotes for display only. *)
type runtime_param_row =
  { rpr_key : string
  ; rpr_current_json : string
  ; rpr_default_json : string
  ; rpr_has_override : bool
  ; rpr_description : string
  ; rpr_value_type : string
  ; rpr_min_json : string option
  ; rpr_max_json : string option
  }

let decode_runtime_params json =
  let* items = required_list_field json "parameters" in
  let text = Yojson.Safe.to_string in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      let* key = required_string_field item "key" in
      let field name =
        match item with
        | `Assoc fields -> List.assoc_opt name fields
        | _ -> None
      in
      let current = match field "current" with Some v -> text v | None -> "-" in
      let default = match field "default" with Some v -> text v | None -> "-" in
      let overridden =
        match field "has_override" with Some (`Bool b) -> b | Some _ | None -> false
      in
      let meta_field name =
        match field "meta" with
        | Some (`Assoc fields) -> List.assoc_opt name fields
        | Some _ | None -> None
      in
      let meta_string name =
        match meta_field name with Some (`String value) -> value | Some _ | None -> ""
      in
      let meta_json name = Option.map text (meta_field name) in
      let row =
        { rpr_key = key
        ; rpr_current_json = current
        ; rpr_default_json = default
        ; rpr_has_override = overridden
        ; rpr_description = meta_string "description"
        ; rpr_value_type = meta_string "value_type"
        ; rpr_min_json = meta_json "min_value"
        ; rpr_max_json = meta_json "max_value"
        }
      in
      loop (row :: acc) rest
  in
  loop [] items

let decode_keeper_tool_approvals json =
  let* items = required_list_field json "pending" in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
        let* decoded = decode_keeper_tool_approval item in
        loop (decoded :: acc) rest
  in
  loop [] items

type keeper_turn_lane =
  | Turn_lane_autonomous
  | Turn_lane_chat_operation
  | Turn_lane_maintenance

let keeper_turn_lane_of_string = function
  | "autonomous" -> Some Turn_lane_autonomous
  | "chat_operation" -> Some Turn_lane_chat_operation
  | "maintenance" -> Some Turn_lane_maintenance
  | _ -> None

type keeper_turn_preview = {
  ktp_text_tail : string;
  ktp_current_tool : string option;
}

type keeper_turn_state =
  | Keeper_turn_idle
  | Keeper_turn_running of {
      lane : keeper_turn_lane;
      started_at_unix : float;
      preview : keeper_turn_preview option;
    }
  | Keeper_turn_unavailable of string

type keeper_turn_row = {
  ktr_keeper_name : string;
  ktr_state : keeper_turn_state;
}

let decode_keeper_turn_row json =
  let* ktr_keeper_name = required_string_field json "keeper_name" in
  let* status = required_string_field json "status" in
  match status with
  | "unavailable" ->
      let* detail = required_string_field json "detail" in
      Ok { ktr_keeper_name; ktr_state = Keeper_turn_unavailable detail }
  | "ok" -> (
      match Json_util.assoc_member_opt "turn" json with
      | None -> Error "keeper turn row is missing required field 'turn'"
      | Some `Null -> Ok { ktr_keeper_name; ktr_state = Keeper_turn_idle }
      | Some (`Assoc _ as turn_json) ->
          let* lane_raw = required_string_field turn_json "lane" in
          let* lane =
            match keeper_turn_lane_of_string lane_raw with
            | Some lane -> Ok lane
            | None ->
                Error (Printf.sprintf "unknown keeper turn lane %S" lane_raw)
          in
          let* started_at_unix =
            match Json_util.assoc_member_opt "started_at_unix" turn_json with
            | Some (`Float value) -> Ok value
            | Some (`Int value) -> Ok (Float.of_int value)
            | Some other ->
                Error
                  (Printf.sprintf
                     "turn field 'started_at_unix' must be a number (received \
                      %s)"
                     (Json_util.kind_name other))
            | None -> Error "turn is missing required field 'started_at_unix'"
          in
          let* preview =
            match Json_util.assoc_member_opt "preview" turn_json with
            | None | Some `Null -> Ok None
            | Some (`Assoc _ as preview_json) ->
                let* ktp_text_tail =
                  required_string_field preview_json "text_tail"
                in
                let* ktp_current_tool =
                  required_nullable_string_field preview_json "current_tool"
                in
                Ok (Some { ktp_text_tail; ktp_current_tool })
            | Some other ->
                Error
                  (Printf.sprintf
                     "turn field 'preview' must be an object or null (received %s)"
                     (Json_util.kind_name other))
          in
          Ok
            {
              ktr_keeper_name;
              ktr_state = Keeper_turn_running { lane; started_at_unix; preview };
            }
      | Some other ->
          Error
            (Printf.sprintf "field 'turn' must be an object or null (received %s)"
               (Json_util.kind_name other)))
  | value -> Error (Printf.sprintf "unknown keeper turn row status %S" value)

let decode_keeper_turns json =
  let* schema = required_string_field json "schema" in
  let* () =
    if String.equal schema "masc.keeper_turns.v1" then Ok ()
    else Error (Printf.sprintf "unknown keeper turns schema %S" schema)
  in
  let* items = required_list_field json "keepers" in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
        let* decoded = decode_keeper_turn_row item in
        loop (decoded :: acc) rest
  in
  loop [] items

type runtime_assignment = {
  ra_keeper : string;
  ra_source : string;  (* "default" | "explicit" *)
  ra_target_id : string option;
}

let decode_runtime_assignment json =
  let* ra_keeper = required_string_field json "keeper" in
  let* ra_source = required_string_field json "assignment_source" in
  let* () =
    match ra_source with
    | "default" | "explicit" -> Ok ()
    | value -> Error (Printf.sprintf "unknown runtime assignment source %S" value)
  in
  let* resolved = required_object_field json "resolved" in
  let* kind = required_string_field resolved "kind" in
  let* id = required_nullable_string_field resolved "id" in
  let* ra_target_id =
    match kind, id with
    | "lane", Some lane_id -> Ok (Some lane_id)
    | "missing", None -> Ok None
    | "lane", None -> Error "runtime lane assignment is missing its id"
    | "missing", Some _ -> Error "missing runtime assignment carries an id"
    | value, _ -> Error (Printf.sprintf "unknown resolved runtime kind %S" value)
  in
  Ok { ra_keeper; ra_source; ra_target_id }

let decode_runtime_resolved json =
  let* snapshot = decode_runtime_resolved_snapshot json in
  let* assignment_items = required_list_field json "assignments" in
  let* assignments =
    decode_list "assignments" decode_runtime_assignment assignment_items
  in
  let* () =
    match
      List.find_opt
        (fun assignment ->
           match assignment.ra_target_id with
           | None -> false
           | Some lane_id ->
               not
                 (List.exists
                    (fun lane -> String.equal lane.rrl_id lane_id)
                    snapshot.rrs_lanes))
        assignments
    with
    | None -> Ok ()
    | Some assignment ->
        Error
          (Printf.sprintf "runtime assignment for %S names an absent lane"
             assignment.ra_keeper)
  in
  Ok (snapshot.rrs_runtimes, assignments)

type server_identity = {
  sid_version : string;
  sid_binary_commit : string;
  sid_binary_commit_age_s : float option;
  sid_base_path : string;
  sid_masc_root : string;
  sid_executable_in_worktree : bool option;
}

(* [/health] answers before the workspace is fully up, so every field here is
   optional in practice: a server that cannot yet name its base path still has
   a version to show, and a footer that fails to render because one string was
   missing tells the operator less than a footer with a gap in it. *)
let decode_server_identity json =
  let* build = optional_object_field json "build" in
  let* paths = optional_object_field json "paths" in
  (* A section the probe did not carry leaves its fields unread. Standing an
     empty object in for it would read the same here and mean something else:
     absent is what the footer draws as unread. *)
  let string_in section field =
    match Option.map (member field) section with
    | Some (`String value) -> value
    | Some _ | None -> ""
  in
  let sid_binary_commit_age_s =
    match Option.map (member "binary_commit_age_seconds") build with
    | Some (`Float value) -> Some value
    | Some (`Int value) -> Some (float_of_int value)
    | Some _ | None -> None
  in
  let sid_executable_in_worktree =
    (* Three-valued on purpose: [None] is an older server that does not
       carry the field, and the footer must not warn (or vouch) on it. *)
    match Option.map (member "executable_in_worktree") build with
    | Some (`Bool value) -> Some value
    | Some _ | None -> None
  in
  Ok
    { sid_version =
        (match member "version" json with
         | `String value -> value
         | _ -> "")
    ; sid_binary_commit = string_in build "binary_commit"
    ; sid_binary_commit_age_s
    ; sid_base_path = string_in paths "effective_base_path"
    ; sid_masc_root = string_in paths "effective_masc_root"
    ; sid_executable_in_worktree
    }
;;

type prompt_row = {
  pr_key : string;
  pr_category : string;
  pr_description : string;
  pr_effective : string;
  pr_has_override : bool;
  pr_file_exists : bool;
  pr_file_path : string;
  pr_source : string;
  pr_template_variables : string list;
}

type prompts_snapshot = { ps_rows : prompt_row list }

(* A prompt with no description, or none on disk, is still a prompt the
   registry serves; only the key has to be there for a row to name itself. *)
let decode_prompt_row json =
  let* pr_key = required_string_field json "key" in
  let string_or field =
    match member field json with
    | `String value -> value
    | _ -> ""
  in
  let bool_or field =
    match member field json with
    | `Bool value -> value
    | _ -> false
  in
  let string_list_or_empty field =
    match member field json with
    | `Null -> Ok []
    | `List _ -> require_string_list json field
    | value ->
        Error
          (Printf.sprintf
             "field '%s' must be a string list (received %s)"
             field
             (Yojson.Safe.to_string value))
  in
  let* pr_template_variables = string_list_or_empty "template_variables" in
  Ok
    { pr_key
    ; pr_category = string_or "category"
    ; pr_description = string_or "description"
    ; pr_effective = string_or "effective"
    ; pr_has_override = bool_or "has_override"
    ; pr_file_exists = bool_or "file_exists"
    ; pr_file_path = string_or "file_path"
    ; pr_source = string_or "source"
    ; pr_template_variables
    }
;;

let decode_prompts json =
  let* rows_json = required_list_field json "prompts" in
  let* reversed =
    List.fold_left
      (fun result row_json ->
         let* acc = result in
         let* row = decode_prompt_row row_json in
         Ok (row :: acc))
      (Ok []) rows_json
  in
  Ok { ps_rows = List.rev reversed }
;;

type librarian_run_page =
  { lrp_run_id : string option
  ; lrp_next : (float * string) option
  }

let decode_librarian_run_page json =
  let* runs = required_list_field json "runs" in
  let* has_more = required_bool_field json "has_more" in
  let rec find_librarian = function
    | [] -> Ok None
    | run :: rest ->
        let* lane = required_string_field run "lane" in
        if
          String.equal
            lane
            (Exact_lane_run_registry.lane_key Exact_lane_run_registry.Librarian)
        then
          let* run_id = required_string_field run "run_id" in
          Ok (Some run_id)
        else find_librarian rest
  in
  let* run_id = find_librarian runs in
  let* lrp_next =
    if not has_more then Ok None
    else
      match List.rev runs with
      | [] -> Error "exact lane page says has_more but has no cursor row"
      | last :: _ ->
          let* started_at = require_float_field last "started_at" in
          let* last_run_id = required_string_field last "run_id" in
          Ok (Some (started_at, last_run_id))
  in
  Ok { lrp_run_id = run_id; lrp_next }
;;

let decode_latest_librarian_run_id json =
  let* page = decode_librarian_run_page json in
  page.lrp_run_id
  |> Option.to_result ~none:"no Librarian exact run on this page"
;;

let decode_librarian_actual_input ~run_id json =
  let* run = required_object_field json "run" in
  let* actor = required_string_field run "actor" in
  let* status = required_string_field run "status" in
  let* input = required_object_field run "input" in
  let* payload = required_object_field input "payload" in
  match member "actual_input" payload with
  | `Assoc _ as actual_input ->
      Ok
        ((Printf.sprintf
            "LATEST LIBRARIAN RUN  %s \xc2\xb7 %s \xc2\xb7 %s"
            run_id actor status)
         :: (Yojson.Safe.pretty_to_string actual_input
             |> String.split_on_char '\n'))
  | `Null -> Error "latest Librarian run has no actual_input"
  | _ -> Error "latest Librarian actual_input is not an object"
;;

(* One exact-lane run as the paged listing serves it: identity and outcome,
   never the payloads (the payloads are why the listing omits them — see
   Exact_lane_run_registry.run_summary_fields). Completion fields are absent
   while the run is still running. *)

(* The producer's [Exact_lane_run_registry.status_label] vocabulary, decoded
   back into a variant so consumers match on the type rather than the string.
   An unrecognized label keeps its text under [Lane_run_other] — dropping the
   word would be a silent decode, rejecting it would fail the whole page on
   one unfamiliar run. *)
type lane_run_status =
  | Lane_run_running
  | Lane_run_succeeded
  | Lane_run_cancelled
  | Lane_run_failed
  | Lane_run_completion_persistence_failed
  | Lane_run_completion_durability_unknown
  | Lane_run_other of string

let lane_run_status_of_string = function
  | "running" -> Lane_run_running
  | "succeeded" -> Lane_run_succeeded
  | "cancelled" -> Lane_run_cancelled
  | "failed" -> Lane_run_failed
  | "completion_persistence_failed" -> Lane_run_completion_persistence_failed
  | "completion_durability_unknown" -> Lane_run_completion_durability_unknown
  | other -> Lane_run_other other

let lane_run_status_label = function
  | Lane_run_running -> "running"
  | Lane_run_succeeded -> "succeeded"
  | Lane_run_cancelled -> "cancelled"
  | Lane_run_failed -> "failed"
  | Lane_run_completion_persistence_failed -> "completion_persistence_failed"
  | Lane_run_completion_durability_unknown -> "completion_durability_unknown"
  | Lane_run_other other -> other

type lane_run_summary =
  { lrs_run_id : string
  ; lrs_lane : string
  ; lrs_actor : string
  ; lrs_started_at : float
  ; lrs_status : lane_run_status
  ; lrs_elapsed_s : float option
  ; lrs_selected_slot : string option
  }

type lane_run_page =
  { lrpg_runs : lane_run_summary list
  ; lrpg_next : (float * string) option
  }

type lane_run_detail =
  { lrd_run_id : string
  ; lrd_lane : string
  ; lrd_actor : string
  ; lrd_started_at : float
  ; lrd_status : lane_run_status
  ; lrd_elapsed_s : float option
  ; lrd_selected_slot : string option
  ; lrd_input_payload : Yojson.Safe.t
  ; lrd_output : Yojson.Safe.t option
  }

let decode_lane_run_summary json =
  let* lrs_run_id = required_string_field json "run_id" in
  let* lrs_lane = required_string_field json "lane" in
  let* lrs_actor = required_string_field json "actor" in
  let* lrs_started_at = require_float_field json "started_at" in
  let* lrs_status = required_string_field json "status" in
  let* lrs_elapsed_s = optional_float_field json "elapsed_s" in
  let* lrs_selected_slot = optional_string_field json "selected_slot" in
  Ok
    { lrs_run_id
    ; lrs_lane
    ; lrs_actor
    ; lrs_started_at
    ; lrs_status = lane_run_status_of_string lrs_status
    ; lrs_elapsed_s
    ; lrs_selected_slot
    }
;;

(* The page answers every lane mixed together; the caller is after one. The
   cursor still comes from the page's last row, filtered or not — filtering
   first would stall paging on a page where the lane simply has no runs. *)
let decode_lane_run_page ~lane json =
  let* runs_json = required_list_field json "runs" in
  let* has_more = required_bool_field json "has_more" in
  let* runs = decode_list "runs" decode_lane_run_summary runs_json in
  let lrpg_runs =
    List.filter (fun run -> String.equal run.lrs_lane lane) runs
  in
  let* lrpg_next =
    if not has_more
    then Ok None
    else
      match List.rev runs with
      | [] -> Error "exact lane page says has_more but has no cursor row"
      | last :: _ -> Ok (Some (last.lrs_started_at, last.lrs_run_id))
  in
  Ok { lrpg_runs; lrpg_next }
;;

let decode_lane_run_detail json =
  let* run = required_object_field json "run" in
  let* summary = decode_lane_run_summary run in
  let* input = required_object_field run "input" in
  let* lrd_input_payload = required_member input "payload" in
  let lrd_output =
    match member "output" run with
    | `Null -> None
    | value -> Some value
  in
  Ok
    { lrd_run_id = summary.lrs_run_id
    ; lrd_lane = summary.lrs_lane
    ; lrd_actor = summary.lrs_actor
    ; lrd_started_at = summary.lrs_started_at
    ; lrd_status = summary.lrs_status
    ; lrd_elapsed_s = summary.lrs_elapsed_s
    ; lrd_selected_slot = summary.lrs_selected_slot
    ; lrd_input_payload
    ; lrd_output
    }
;;

let decode_fleet_safety json =
  let* section = required_object_field json "keeper_fleet_safety" in
  let* fs_status = required_string_field section "status" in
  let* fs_blocker = optional_string_field section "blocker" in
  let* fs_operator_action_required =
    match member "operator_action_required" section with
    | `Bool value -> Ok value
    | `Null -> Ok false
    | bad -> field_type_error "operator_action_required" "a bool or null" bad
  in
  let* fs_bootable_count = int_field_or section "bootable_keeper_count" ~default:0 in
  let* fs_running_count = int_field_or section "running_keeper_fiber_count" ~default:0 in
  let* fs_executable_count =
    int_field_or section "executable_keeper_fiber_count" ~default:0
  in
  let* fs_failing_count = int_field_or section "failing_keeper_fiber_count" ~default:0 in
  let* fs_recovering_count =
    int_field_or section "recovering_keeper_fiber_count" ~default:0
  in
  let* fs_paused_count = int_field_or section "paused_keeper_count" ~default:0 in
  let* fs_target_reaction_capacity =
    int_field_or section "target_reaction_capacity_count" ~default:0
  in
  let* fs_reaction_capacity_shortfall =
    int_field_or section "reaction_capacity_shortfall_count" ~default:0
  in
  let* fs_bootable_names = decode_string_name_list section "bootable_keeper_names" in
  let* fs_running_names = decode_string_name_list section "running_keeper_names" in
  let* fs_executable_names =
    decode_string_name_list section "executable_keeper_names"
  in
  let* fs_active_task_owner_without_fiber_count =
    int_field_or section "active_task_owner_without_executable_fiber_count" ~default:0
  in
  let* fs_completion_authority_pending_count =
    int_field_or section "completion_authority_pending_task_count" ~default:0
  in
  Ok
    { fs_status
    ; fs_blocker
    ; fs_operator_action_required
    ; fs_bootable_count
    ; fs_running_count
    ; fs_executable_count
    ; fs_failing_count
    ; fs_recovering_count
    ; fs_paused_count
    ; fs_target_reaction_capacity
    ; fs_reaction_capacity_shortfall
    ; fs_bootable_names
    ; fs_running_names
    ; fs_executable_names
    ; fs_active_task_owner_without_fiber_count
    ; fs_completion_authority_pending_count
    }

let bounded_parent_depth ?(max_depth = 64) ~(id_of : 'a -> string)
    ~(parent_id_of : 'a -> string option) (items : 'a list) (item : 'a) : int =
  let module StringSet = Set.Make (String) in
  let rec loop seen depth current =
    if depth >= max_depth then depth
    else
      match parent_id_of current with
      | None -> depth
      | Some parent_id when StringSet.mem parent_id seen -> depth
      | Some parent_id -> (
          match List.find_opt (fun candidate -> id_of candidate = parent_id) items with
          | Some parent ->
              loop (StringSet.add parent_id seen) (depth + 1) parent
          | None -> depth)
  in
  loop (StringSet.singleton (id_of item)) 0 item

type chat_event =
  | Delta of string
  | Complete of string
  | Ignore

let decode_chat_event json =
  let event_type = get_string json "type" in
  match event_type with
  | Some ("TEXT_MESSAGE_CONTENT" | "content_delta" | "delta") -> (
      match get_string json "delta" with
      | Some text -> Ok (Delta text)
      | None -> Error "delta event missing string 'delta'")
  | Some ("RUN_FINISHED" | "content_complete" | "complete") -> (
      match get_string json "text" with
      | Some text -> Ok (Complete text)
      | None -> Ok (Complete ""))
  | Some "RUN_ERROR" -> (
      match get_string json "message" with
      | Some message -> Error message
      | None -> (
          match get_object json "error" with
          | Some err_json -> (
              match get_string err_json "message" with
              | Some message -> Error message
              | None -> Error "RUN_ERROR payload missing string 'message'")
          | None -> Error "RUN_ERROR payload missing string 'message'"))
  | _ -> (
      match get_object json "error" with
      | Some err_json -> (
          match get_string err_json "message" with
          | Some message -> Error message
          | None -> Error "error payload missing string 'message'")
      | None -> Ok Ignore)

let parse_keeper_chat_response response =
  let lines = String.split_on_char '\n' response in
  let result = Buffer.create 256 in
  let completion_text = ref None in
  let saw_terminal = ref false in
  let rec consume_sse = function
    | [] -> Ok ()
    | raw_line :: rest ->
        let line = trim raw_line in
        if String.length line > 6 && String.starts_with line ~prefix:"data: " then (
          let payload = String.sub line 6 (String.length line - 6) |> trim in
          if payload = "[DONE]" || payload = "" then consume_sse rest
          else
            let* json =
              try Ok (Yojson.Safe.from_string payload)
              with Yojson.Json_error msg ->
                Error ("invalid SSE JSON payload: " ^ msg)
            in
            let* chunk = decode_chat_event json in
            (match chunk with
             | Delta text -> Buffer.add_string result text
             | Complete text when Buffer.length result = 0 ->
                 saw_terminal := true;
                 if text <> "" then completion_text := Some text
             | Complete _ -> saw_terminal := true
             | Ignore -> ());
            consume_sse rest
        ) else
          consume_sse rest
  in
  let* () = consume_sse lines in
  if Buffer.length result > 0 then
    Ok (Buffer.contents result)
  else
    match !completion_text with
    | Some text when text <> "" -> Ok text
    | _ when !saw_terminal -> Ok ""
    | _ -> (
        let body =
          match split_headers_body response with
          | Some body -> body
          | None -> response
        in
            let* json =
              try Ok (Yojson.Safe.from_string (trim body))
              with Yojson.Json_error msg ->
                Error ("invalid response JSON: " ^ msg)
            in
            match get_object json "result" with
            | Some result_json -> (
                match get_string result_json "text" with
                | Some text when text <> "" -> Ok text
                | _ -> Error "response JSON missing result.text")
            | None -> (
                match get_object json "error" with
                | Some err_json -> (
                    match get_string err_json "message" with
                    | Some message -> Error message
                    | None -> Error "response JSON missing error.message")
                | None -> Error "response JSON missing result"))

type transport_health = {
  th_primary_path : Transport_metrics.primary_path_kind;
  th_queue_pressure : Transport_metrics.queue_pressure_kind;
  th_sse_sessions : int;
  th_websocket_sessions : int option;
  th_grpc_port : int option;
  th_events_dropped : int;
}

let require_object json key =
  match member key json with
  | `Assoc _ as obj -> Ok obj
  | `Null -> Error (Printf.sprintf "missing required field '%s'" key)
  | other ->
      Error
        (Printf.sprintf "field '%s' must be an object (received %s)" key
           (Json_util.kind_name other))

let decode_transport_health json =
  let ( let* ) = Result.bind in
  let* summary = require_object json "summary" in
  (* Parsed into the producer's own type rather than carried as text. A
     spelling this build does not know is a decode failure here, where the
     surface can say so, instead of a word the TUI prints as if it were a
     transport path (#27652). *)
  let* th_primary_path =
    let* raw = require_string_field summary "primary_path" in
    match Transport_metrics.primary_path_kind_of_string raw with
    | Some kind -> Ok kind
    | None -> Error (Printf.sprintf "summary.primary_path: unknown value %S" raw)
  in
  let* th_queue_pressure =
    let* raw = require_string_field summary "queue_pressure" in
    match Transport_metrics.queue_pressure_kind_of_string raw with
    | Some kind -> Ok kind
    | None ->
      Error (Printf.sprintf "summary.queue_pressure: unknown value %S" raw)
  in
  let* sse = require_object json "sse" in
  let* th_sse_sessions = require_int_field sse "sessions_total" in
  let* websocket = require_object json "websocket" in
  let* websocket_listening = require_bool websocket "listening" in
  (* A path that is not listening has no sessions to report. Reporting zero
     would read as "listening, nobody connected", which is a different fact. *)
  let* th_websocket_sessions =
    if websocket_listening then
      Result.map Option.some (require_int_field websocket "sessions")
    else Ok None
  in
  let* grpc = require_object json "grpc" in
  let* grpc_listening = require_bool grpc "listening" in
  let* th_grpc_port =
    if grpc_listening then Result.map Option.some (require_int_field grpc "port")
    else Ok None
  in
  let* th_events_dropped = require_int_field grpc "events_dropped" in
  Ok
    {
      th_primary_path;
      th_queue_pressure;
      th_sse_sessions;
      th_websocket_sessions;
      th_grpc_port;
      th_events_dropped;
    }

(* ── Keeper file changes (/api/v1/keepers/<name>/file-changes) ──────────

   The route answers with the projection in [Keeper_tool_call_file_change],
   and the three location shapes are the ones that projection distinguishes.
   Decoded into a variant here rather than kept as a tagged object: a reader
   that wants to open a file needs to know whether it has a repository
   address or an absolute path, and a string tag would make every such reader
   re-decide. *)

type file_change_location =
  | Fc_in_repo of {
      repo_id : string;
      relative_path : string;
    }
  | Fc_in_bundle of { bundle_path : string }
  | Fc_at_absolute_path of { path : string }

type file_change_kind =
  | Fc_edited of {
      before : string;
      after : string;
      replace_all : bool;
    }
  | Fc_written of { content : string }

type file_change = {
  fc_at : float;
  fc_keeper : string;
  fc_turn : int option;
  fc_task_id : string option;
  fc_execution_id : string option;
  fc_line_evidence : Keeper_file_change_evidence.t option;
  fc_location : file_change_location;
  fc_kind : file_change_kind;
  fc_succeeded : bool;
}

type file_change_snapshot = {
  fcs_keeper : string;
  fcs_window_hours : float;
  fcs_calls_in_window : int;
  fcs_changes : file_change list;
  fcs_over_budget : int;
      (** Changes whose text the tool-call log did not keep. Carried to the
          surface because a list that silently omitted them would say a turn
          wrote less than it did. *)
  fcs_malformed : int;
}

let optional_int_or_null json key =
  match member key json with
  | `Int value -> Ok (Some value)
  | `Intlit raw -> (
      match int_of_string_opt raw with
      | Some value -> Ok (Some value)
      | None -> Error (Printf.sprintf "field '%s' has invalid int %S" key raw))
  | `Null -> Ok None
  | bad -> field_type_error key "an int or null" bad

let decode_file_change_location json =
  let* kind = required_string_field json "kind" in
  match kind with
  | "repo" ->
      let* repo_id = required_string_field json "repo_id" in
      let* relative_path = required_string_field json "path" in
      Ok (Fc_in_repo { repo_id; relative_path })
  | "bundle" ->
      let* bundle_path = required_string_field json "path" in
      Ok (Fc_in_bundle { bundle_path })
  | "absolute" ->
      let* path = required_string_field json "path" in
      Ok (Fc_at_absolute_path { path })
  | other ->
      (* A tag this build does not know is an error, not a bundle path. The
         producer and this reader are the same repository; a new shape means
         one of them moved without the other. *)
      Error (Printf.sprintf "unknown file change location kind %S" other)

let decode_file_change_kind json =
  let* kind = required_string_field json "kind" in
  match kind with
  | "edit" ->
      let* before = required_string_field json "before" in
      let* after = required_string_field json "after" in
      let* replace_all = optional_bool_field json "replace_all" in
      Ok (Fc_edited { before; after; replace_all = Option.value ~default:false replace_all })
  | "write" ->
      let* content = required_string_field json "content" in
      Ok (Fc_written { content })
  | other -> Error (Printf.sprintf "unknown file change kind %S" other)

let validate_line_evidence_contract
      ~execution_id
      ~succeeded
      kind
      evidence
  =
  match kind, evidence with
  | _, None -> Ok ()
  | _, Some _
    when Option.fold
           ~none:true
           ~some:(fun value -> String.trim value = "")
           execution_id ->
    Error "line_evidence has no canonical execution_id"
  | _, Some _ when not succeeded ->
    Error "failed change carries completed line_evidence"
  | Fc_edited { replace_all = false; _ },
    Some
      (Keeper_file_change_evidence.Edited
        { occurrence_count; occurrences = _ })
    when occurrence_count <> 1 ->
    Error "single Edit carries an occurrence_count other than one"
  | Fc_edited _, Some (Keeper_file_change_evidence.Edited _) -> Ok ()
  | Fc_written _, Some (Keeper_file_change_evidence.Written _) -> Ok ()
  | Fc_edited _, Some (Keeper_file_change_evidence.Written _) ->
    Error "Edit change carries Write line_evidence"
  | Fc_written _, Some (Keeper_file_change_evidence.Edited _) ->
    Error "Write change carries Edit line_evidence"

let decode_file_change json =
  let* fc_at = require_float_field json "at" in
  let* fc_keeper = required_string_field json "keeper" in
  let* fc_turn = optional_int_or_null json "turn" in
  let* fc_task_id = optional_string_field json "task_id" in
  let* fc_execution_id = optional_string_field json "execution_id" in
  let* fc_line_evidence =
    match member "line_evidence" json with
    | `Null -> Ok None
    | (`Assoc _ as evidence) ->
      (match Keeper_file_change_evidence.of_yojson evidence with
       | Ok evidence -> Ok (Some evidence)
       | Error detail -> Error ("line_evidence: " ^ detail))
    | bad -> field_type_error "line_evidence" "an object or null" bad
  in
  let* location_json = required_object_field json "location" in
  let* fc_location = decode_file_change_location location_json in
  let* kind_json = required_object_field json "change" in
  let* fc_kind = decode_file_change_kind kind_json in
  let* fc_succeeded = required_bool_field json "succeeded" in
  let* () =
    validate_line_evidence_contract
      ~execution_id:fc_execution_id
      ~succeeded:fc_succeeded
      fc_kind
      fc_line_evidence
  in
  Ok
    { fc_at
    ; fc_keeper
    ; fc_turn
    ; fc_task_id
    ; fc_execution_id
    ; fc_line_evidence
    ; fc_location
    ; fc_kind
    ; fc_succeeded
    }

let file_change_target_line change =
  match change.fc_line_evidence with
  | Some (Keeper_file_change_evidence.Written { new_range = Some range }) ->
    range.start_line
  | Some
      (Keeper_file_change_evidence.Edited
        { occurrences = Some (first :: _); _ }) ->
    (match first.new_range with
     | Some range -> range.start_line
     | None -> first.old_range.start_line)
  | Some (Keeper_file_change_evidence.Written { new_range = None })
  | Some (Keeper_file_change_evidence.Edited { occurrences = None | Some []; _ })
  | None -> 1

(* ── Workspace tree (/api/v1/workspace/tree, /workspace/children) ──────

   The Code surface browses one directory at a time through the lazy
   /children route; the node shape is the tree family's flat node object.
   Unknown extra fields are the dashboard's (diff badges, keeper hues) and
   are ignored here. *)

type workspace_tree_node = {
  wt_path : string;  (** relative to the workspace base *)
  wt_label : string;
  wt_has_children : bool;  (** a directory the /children route can open *)
}

let decode_workspace_tree_node json =
  let* wt_path = required_string_field json "path" in
  let* wt_label = required_string_field json "label" in
  let* wt_has_children = required_bool_field json "hasChildren" in
  Ok { wt_path; wt_label; wt_has_children }

let decode_workspace_tree json =
  match json with
  | `List nodes -> decode_list "nodes" decode_workspace_tree_node nodes
  | other ->
      Error
        (Printf.sprintf "workspace tree must be a list (received %s)"
           (Json_util.kind_name other))

(* /api/v1/workspace/file answers {ok, content}; anything else is a decode
   failure, not an empty file. *)
let decode_workspace_file json =
  let* ok = required_bool_field json "ok" in
  if not ok then Error "workspace file answered ok=false"
  else required_string_field json "content"

type git_diff_row_kind =
  | Gd_context
  | Gd_added
  | Gd_removed

type git_diff_row = {
  gdr_kind : git_diff_row_kind;
  gdr_old_line : int option;
  gdr_new_line : int option;
  gdr_text : string;
}

type git_diff = {
  gd_has_changes : bool;
  gd_rows : git_diff_row list;
}

let decode_file_change_snapshot json =
  let* fcs_keeper = required_string_field json "keeper" in
  let* fcs_window_hours = require_float_field json "window_hours" in
  let* fcs_calls_in_window = required_int_field json "calls_in_window" in
  let* changes_json = required_list_field json "changes" in
  let* fcs_changes = decode_list "changes" decode_file_change changes_json in
  let* () =
    match
      List.find_opt
        (fun (change : file_change) ->
          not (String.equal change.fc_keeper fcs_keeper))
        fcs_changes
    with
    | None -> Ok ()
    | Some change ->
        Error
          (Printf.sprintf
             "file-change row named keeper %s inside snapshot for %s"
             change.fc_keeper fcs_keeper)
  in
  let* fcs_over_budget = required_int_field json "over_budget" in
  let* fcs_malformed = required_int_field json "malformed" in
  Ok
    { fcs_keeper
    ; fcs_window_hours
    ; fcs_calls_in_window
    ; fcs_changes
    ; fcs_over_budget
    ; fcs_malformed
    }

(* ── git diff: what the tree holds ─────────────────────────────────── *)

let decode_git_diff_row json =
  let* kind = required_string_field json "kind" in
  let* text = required_string_field json "text" in
  let* gdr_old_line = optional_int_or_null json "oldLine" in
  let* gdr_new_line = optional_int_or_null json "newLine" in
  (* An unknown kind is an error, not a context line. git's vocabulary is
     closed and a fourth word means the server changed under us; drawing it as
     unchanged would report the opposite of whatever happened. *)
  let* gdr_kind =
    match kind with
    | "context" -> Ok Gd_context
    | "add" -> Ok Gd_added
    | "delete" -> Ok Gd_removed
    | other -> Error (Printf.sprintf "unknown git diff row kind: %s" other)
  in
  Ok { gdr_kind; gdr_old_line; gdr_new_line; gdr_text = text }

let decode_git_diff json =
  let* gd_has_changes = required_bool_field json "has_changes" in
  let* rows_json = required_list_field json "unified" in
  let* gd_rows = decode_list "unified" decode_git_diff_row rows_json in
  Ok { gd_has_changes; gd_rows }

(* ── git log: who touched this file, most recent first ─────────────── *)

(* The git-log route stamps its rows with [timestamp_ms]; the history view
   orders its timeline by this number. *)
let timestamp_ms_field json =
  match member "timestamp_ms" json with
  | `Intlit s -> (
      match Float.of_string_opt s with
      | Some f -> Ok f
      | None -> Error "timestamp_ms is not a number")
  | `Int n -> Ok (float_of_int n)
  | bad -> field_type_error "timestamp_ms" "an integer" bad

type git_log_row = {
  gl_hash : string;
  gl_at_ms : float;
  gl_author : string;
  gl_subject : string;
}

let decode_git_log_row json =
  let* gl_hash = required_string_field json "hash" in
  let* gl_at_ms = timestamp_ms_field json in
  let* gl_author = required_string_field json "author" in
  let* gl_subject = required_string_field json "subject" in
  Ok { gl_hash; gl_at_ms; gl_author; gl_subject }

let decode_git_log json =
  let* ok = required_bool_field json "ok" in
  if not ok then Error "git log answered ok=false"
  else
    let* rows_json = required_list_field json "commits" in
    decode_list "commits" decode_git_log_row rows_json

(* ── IDE annotations: notes anchored to lines of a codebase ────────── *)

type ide_annotation = {
  ia_line_start : int;
  ia_line_end : int;
  ia_keeper : string;
  (* The server's kind vocabulary (comment / decision / question /
     bookmark), carried as its own word: the TUI only prints it, so an
     added kind shows itself instead of killing the listing. *)
  ia_kind : string;
  ia_content : string;
  ia_task : string option;
}

let decode_ide_annotation json =
  let* ia_line_start = required_int_field json "line_start" in
  let* ia_line_end = required_int_field json "line_end" in
  let* ia_keeper = required_string_field json "keeper_id" in
  let* ia_kind = required_string_field json "kind" in
  let* ia_content = required_string_field json "content" in
  let* ia_task = optional_string_field json "task_id" in
  Ok { ia_line_start; ia_line_end; ia_keeper; ia_kind; ia_content; ia_task }

let decode_ide_annotations json =
  let* ok = required_bool_field json "ok" in
  if not ok then Error "annotations answered ok=false"
  else
    let* rows_json = required_list_field json "data" in
    decode_list "data" decode_ide_annotation rows_json

(* ── the /api/v1/lsp/question answer ───────────────────────────────── *)

type lsp_location = {
  ll_path : string;
  ll_inside : bool;
  ll_line : int;  (** 1-based, as the route answers *)
}

type lsp_answer =
  | Lsp_locations of lsp_location list
  | Lsp_hover of string option

let decode_lsp_location json =
  let* ll_path = required_string_field json "path" in
  let* ll_inside = required_bool_field json "inside_workspace" in
  let* ll_line = required_int_field json "line" in
  Ok { ll_path; ll_inside; ll_line }

let decode_lsp_answer json =
  let* ok = required_bool_field json "ok" in
  if not ok then Error "lsp question answered ok=false"
  else
    let* data =
      match member "data" json with
      | `Assoc _ as data -> Ok data
      | bad -> field_type_error "data" "an object" bad
    in
    let* kind = required_string_field data "kind" in
    match kind with
    | "locations" ->
        let* rows = required_list_field data "locations" in
        let* locations = decode_list "locations" decode_lsp_location rows in
        Ok (Lsp_locations locations)
    | "hover" -> (
        match member "text" data with
        | `String t -> Ok (Lsp_hover (Some t))
        | `Null -> Ok (Lsp_hover None)
        | bad -> field_type_error "text" "a string or null" bad)
    | other -> Error (Printf.sprintf "unknown lsp answer kind: %s" other)

(* Questions a Keeper put to the operator ([GET /api/v1/keepers/asks]).

   Decoding is strict about the two shapes a surface renders controls from:
   an unknown mode or free-text shape fails rather than defaulting, because a
   surface that guessed would offer the operator a control the server refuses
   on submit. *)

type ask_choice = {
  ac_id : string;
  ac_label : string;
  ac_description : string option;
}

type ask_mode =
  | Ask_single
  | Ask_multi

type ask_free_text =
  | Ask_free_text_allowed of { aft_hint : string option }
  | Ask_choices_only

type ask_question = {
  aq_id : string;
  aq_header : string;
  aq_prompt : string;
  aq_mode : ask_mode;
  aq_free_text : ask_free_text;
  aq_choices : ask_choice list;
}

type ask_resolution =
  | Ask_open
  | Ask_answered of {
      aa_answered_at : float;
      aa_question_ids : string list;
    }
  | Ask_withdrawn of {
      aw_reason : string;
      aw_withdrawn_at : float;
    }

type ask_row = {
  ar_keeper : string;
  ar_id : string;
  ar_asked_at : float;
  ar_context : string option;
  ar_questions : ask_question list;
  ar_resolution : ask_resolution;
}

type asks_snapshot = {
  asn_keeper : string option;
  asn_open_count : int;
  asn_rows : ask_row list;
}

let ( let* ) = Result.bind

let ask_string json key =
  match member key json with
  | `String s -> Ok s
  | `Null -> Error (Printf.sprintf "asks: '%s' is required" key)
  | _ -> Error (Printf.sprintf "asks: '%s' must be a string" key)

let ask_string_opt json key =
  match member key json with `String s -> Some s | _ -> None

let ask_float json key =
  match member key json with
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | _ -> Error (Printf.sprintf "asks: '%s' must be a number" key)

let ask_int json key =
  match member key json with
  | `Int i -> Ok i
  | _ -> Error (Printf.sprintf "asks: '%s' must be an integer" key)

let ask_list json key =
  match member key json with
  | `List items -> Ok items
  | `Null -> Ok []
  | _ -> Error (Printf.sprintf "asks: '%s' must be an array" key)

let rec ask_map_results f = function
  | [] -> Ok []
  | x :: rest ->
      let* y = f x in
      let* ys = ask_map_results f rest in
      Ok (y :: ys)

let decode_ask_choice json =
  let* ac_id = ask_string json "choice_id" in
  let* ac_label = ask_string json "label" in
  Ok { ac_id; ac_label; ac_description = ask_string_opt json "description" }

let decode_ask_mode json =
  let* label = ask_string json "mode" in
  match label with
  | "single" -> Ok Ask_single
  | "multi" -> Ok Ask_multi
  | other -> Error (Printf.sprintf "asks: unknown mode '%s'" other)

let decode_ask_free_text json =
  match member "free_text" json with
  | `Null -> Ok Ask_choices_only
  | free_text_json -> (
      match member "allowed" free_text_json with
      | `Bool false -> Ok Ask_choices_only
      | `Bool true ->
          Ok (Ask_free_text_allowed { aft_hint = ask_string_opt free_text_json "hint" })
      | `Null -> Error "asks: free_text is missing 'allowed'"
      | _ -> Error "asks: free_text.allowed must be a boolean")

let decode_ask_question json =
  let* aq_id = ask_string json "question_id" in
  let* aq_header = ask_string json "header" in
  let* aq_prompt = ask_string json "prompt" in
  let* aq_mode = decode_ask_mode json in
  let* aq_free_text = decode_ask_free_text json in
  let* choice_items = ask_list json "choices" in
  let* aq_choices = ask_map_results decode_ask_choice choice_items in
  Ok { aq_id; aq_header; aq_prompt; aq_mode; aq_free_text; aq_choices }

let decode_ask_resolution json =
  let* state = ask_string json "state" in
  match state with
  | "open" -> Ok Ask_open
  | "answered" ->
      let* aa_answered_at = ask_float json "answered_at" in
      let* id_items = ask_list json "answered_question_ids" in
      let* aa_question_ids =
        ask_map_results
          (function
            | `String id -> Ok id
            | _ -> Error "asks: answered_question_ids must be strings")
          id_items
      in
      Ok (Ask_answered { aa_answered_at; aa_question_ids })
  | "withdrawn" ->
      let* aw_reason = ask_string json "reason" in
      let* aw_withdrawn_at = ask_float json "withdrawn_at" in
      Ok (Ask_withdrawn { aw_reason; aw_withdrawn_at })
  | other -> Error (Printf.sprintf "asks: unknown resolution state '%s'" other)

let decode_ask_row json =
  let* ar_keeper = ask_string json "keeper" in
  let* ar_id = ask_string json "ask_id" in
  let* ar_asked_at = ask_float json "asked_at" in
  let* question_items = ask_list json "questions" in
  let* ar_questions = ask_map_results decode_ask_question question_items in
  let* ar_resolution = decode_ask_resolution (member "resolution" json) in
  Ok
    {
      ar_keeper;
      ar_id;
      ar_asked_at;
      ar_context = ask_string_opt json "context";
      ar_questions;
      ar_resolution;
    }

let decode_asks_snapshot json =
  let asn_keeper = ask_string_opt json "keeper" in
  let* asn_open_count = ask_int json "open_count" in
  let* row_items = ask_list json "asks" in
  let* asn_rows = ask_map_results decode_ask_row row_items in
  Ok { asn_keeper; asn_open_count; asn_rows }

(* Goal detail timeline (GET /api/v1/dashboard/goals/detail). The server
   merges task/approval/keeper/goal events into one list of uniform
   six-field rows, and the TUI carries all six. It used to keep four, which
   dropped exactly the two that say which thing the row is about: a goal with
   thirteen task rows drew "task  todo" thirteen times, and the id and title
   the server had already sent were thrown away in the decoder. [timeline] is
   [`Null] exactly when the approval-queue store could not be read — the
   same discriminated failure the gate snapshot carries — so that case is
   an explicit constructor, never an empty list. *)
type goal_timeline_event = {
  gt_ts : string;
  gt_kind : string;
  gt_lane : string;
      (** The row's subject as a typed reference: ["task:task-1013"],
          ["approval:appr-…"], ["keeper:<name>"], ["goal"]. *)
  gt_title : string;
  gt_summary : string;
  gt_severity : string;  (** producer emits ok | warn | bad; open for renderers *)
}

type goal_timeline =
  | Goal_timeline_ready of goal_timeline_event list
  | Goal_timeline_unavailable of string

let decode_goal_timeline_event json =
  let required field =
    match member field json with
    | `String value -> Ok value
    | _ -> Error (Printf.sprintf "timeline event %s must be a string" field)
  in
  let* gt_ts = required "ts" in
  let* gt_kind = required "kind" in
  let* gt_lane = required "lane" in
  let* gt_title = required "title" in
  let* gt_summary = required "summary" in
  let* gt_severity = required "severity" in
  Ok { gt_ts; gt_kind; gt_lane; gt_title; gt_summary; gt_severity }

let decode_goal_detail_timeline json =
  match member "timeline" json with
  | `Null ->
      let detail =
        match member "operator_detail" (member "approval_queue_state" json) with
        | `String detail -> detail
        | _ -> "approval queue store is unreadable"
      in
      Ok (Goal_timeline_unavailable detail)
  | `List items ->
      let rec loop acc = function
        | [] -> Ok (Goal_timeline_ready (List.rev acc))
        | item :: rest ->
            let* event = decode_goal_timeline_event item in
            loop (event :: acc) rest
      in
      loop [] items
  | _ -> Error "goal detail timeline is neither a list nor null"

(* One task's event history (GET /api/v1/dashboard/tasks/history). Rows are
   raw event-stream lines, not a uniform projection, so every field except
   [ts] is optional and an unknown event type still renders as its type
   string instead of being dropped. *)
type task_history_event = {
  th_ts : string;
  th_label : string;  (** [action] when present, else [type], else "event" *)
  th_from_status : string option;
  th_to_status : string option;
  th_actor : string option;
  th_note : string option;  (** handoff_context.summary when present *)
}

let decode_task_history json =
  match json with
  | `List rows ->
      let event_of_row row =
        let str field =
          match member field row with
          | `String value when String.trim value <> "" -> Some value
          | _ -> None
        in
        let th_label =
          match str "action" with
          | Some action -> action
          | None -> (match str "type" with Some t -> t | None -> "event")
        in
        {
          th_ts = Option.value (str "ts") ~default:"";
          th_label;
          th_from_status = str "from_status";
          th_to_status = str "to_status";
          th_actor = (match str "agent" with Some a -> Some a | None -> str "actor");
          th_note =
            (match member "handoff_context" row with
             | `Assoc _ as handoff ->
                 (match member "summary" handoff with
                  | `String s when String.trim s <> "" -> Some s
                  | _ -> None)
             | _ -> None);
        }
      in
      Ok (List.map event_of_row rows)
  | _ -> Error "task history is not a list"

(* Operator evidence bundle (GET /api/v1/verification/evidence). The
   verification snapshot already lists evidence references; this carries what
   the verifier can actually inspect — artifact content prefixes (the server
   caps and marks truncation) and the typed reason when an artifact could not
   be read. The item vocabulary is the producer's closed set
   (Workspace_verification_store.submitted_evidence_item_to_yojson), so an
   unknown kind fails the decode rather than rendering as an empty row. *)
type verification_evidence_item =
  | Ev_note of string
  | Ev_artifact of {
      ev_reference : string;
      ev_content : string;
      ev_bytes : int;
      ev_truncated : bool;
    }
  | Ev_artifact_unreadable of {
      ev_u_reference : string option;
      ev_u_reason : string;
    }

type verification_evidence =
  | Evidence_items of verification_evidence_item list
  | Evidence_access_unavailable of string

let decode_verification_evidence json =
  let result = member "result" json in
  let evidence = member "evidence" result in
  match member "access" evidence with
  | `String "unavailable" ->
      let reason =
        match member "reason" evidence with
        | `String reason -> reason
        | _ -> "evidence store is unreadable"
      in
      Ok (Evidence_access_unavailable reason)
  | `String "available" ->
      let decode_item item =
        let str field =
          match member field item with `String s -> Some s | _ -> None
        in
        match member "kind" item with
        | `String "note" ->
            (match str "content" with
             | Some content -> Ok (Ev_note content)
             | None -> Error "evidence note is missing content")
        | `String "artifact" ->
            (match str "reference", str "content", member "bytes" item with
             | Some ev_reference, Some ev_content, `Int ev_bytes ->
                 let ev_truncated =
                   match member "truncated" item with
                   | `Bool b -> b
                   | _ -> false
                 in
                 Ok (Ev_artifact { ev_reference; ev_content; ev_bytes; ev_truncated })
             | _ -> Error "evidence artifact is missing reference/content/bytes")
        | `String "artifact_unreadable" ->
            let ev_u_reason =
              match member "reason" item with
              | `Null -> "unreadable"
              | reason -> Yojson.Safe.to_string reason
            in
            Ok (Ev_artifact_unreadable { ev_u_reference = str "reference"; ev_u_reason })
        | `String kind -> Error ("unknown evidence item kind: " ^ kind)
        | _ -> Error "evidence item is missing kind"
      in
      (match member "items" evidence with
       | `List items ->
           let rec loop acc = function
             | [] -> Ok (Evidence_items (List.rev acc))
             | item :: rest ->
                 let* decoded = decode_item item in
                 loop (decoded :: acc) rest
           in
           loop [] items
       | _ -> Error "available evidence carries no items list")
  | `String other -> Error ("unknown evidence access state: " ^ other)
  | _ -> Error "evidence access state is missing"

type skill_evidence_status =
  | Skill_evidence_observed
  | Skill_evidence_not_observed_in_retained_coverage

type skill_evidence_composition_scope =
  | Skill_evidence_exact_reference_latest_completed
  | Skill_evidence_composition_unavailable

type skill_evidence_coverage =
  { sec_composition_scope : skill_evidence_composition_scope
  ; sec_composition_records_read : int
  ; sec_composition_unavailable : string list
  ; sec_activation_scope : string
  ; sec_activation_sessions_inspected : int
  ; sec_activation_ledgers_loaded : int
  ; sec_activation_gap_count : int
  ; sec_activation_owner_gap_count : int
  }

type skill_evidence_owner_claim =
  { seo_keeper : string
  ; seo_source : string
  }

type skill_evidence_activation_item =
  { sea_trace_id : string
  ; sea_owner_status : string
  ; sea_owner_claims : skill_evidence_owner_claim list
  ; sea_owner_gap_count : int
  ; sea_activation : Yojson.Safe.t
  }

type skill_evidence_activation =
  | Skill_evidence_most_recent_observed of skill_evidence_activation_item
  | Skill_evidence_most_recent_observed_timestamp_tie of
      skill_evidence_activation_item list

type skill_evidence =
  { se_status : skill_evidence_status
  ; se_activation : skill_evidence_activation option
  ; se_composition : Yojson.Safe.t option
  ; se_coverage : skill_evidence_coverage
  }

let decode_skill_evidence_optional_object field json =
  match json with
  | `Assoc fields when not (List.mem_assoc field fields) ->
    Error ("Skill evidence " ^ field ^ " is required")
  | `Assoc _ ->
    (match member field json with
     | `Null -> Ok None
     | `Assoc _ as value -> Ok (Some value)
     | _ -> Error ("Skill evidence " ^ field ^ " must be an object or null"))
  | _ -> Error "Skill evidence must be an object"
;;

let decode_skill_evidence_nonnegative_int field json =
  match member field json with
  | `Int value when value >= 0 -> Ok value
  | _ -> Error ("Skill evidence coverage " ^ field ^ " must be nonnegative")
;;

let decode_skill_evidence_string_list field json =
  match member field json with
  | `List values ->
    List.fold_left
      (fun result value ->
         let* reversed = result in
         match value with
         | `String value -> Ok (value :: reversed)
         | _ -> Error ("Skill evidence " ^ field ^ " rows must be strings"))
      (Ok [])
      values
    |> Result.map List.rev
  | _ -> Error ("Skill evidence " ^ field ^ " must be a list")
;;

let skill_evidence_exact_fields expected fields =
  let actual = List.map fst fields in
  List.length actual = List.length expected
  && List.sort_uniq String.compare actual = List.sort String.compare expected
;;

let skill_evidence_string_field field json =
  match member field json with `String _ -> true | _ -> false
;;

let skill_evidence_positive_int_field field json =
  match member field json with `Int value -> value > 0 | _ -> false
;;

let skill_evidence_manifest_cause = function
  | `Assoc fields as cause ->
    (match member "code" cause with
     | `String "manifest_read_failed" ->
       skill_evidence_exact_fields [ "code"; "detail" ] fields
       && skill_evidence_string_field "detail" cause
     | `String "manifest_empty" ->
       skill_evidence_exact_fields [ "code" ] fields
     | `String ("manifest_invalid_json" | "manifest_invalid_row") ->
       skill_evidence_exact_fields [ "code"; "line_number"; "detail" ] fields
       && skill_evidence_positive_int_field "line_number" cause
       && skill_evidence_string_field "detail" cause
     | `String "manifest_identity_mismatch" ->
       skill_evidence_exact_fields
         [ "code"; "line_number"; "observed_keeper"; "observed_trace" ]
         fields
       && skill_evidence_positive_int_field "line_number" cause
       && skill_evidence_string_field "observed_keeper" cause
       && skill_evidence_string_field "observed_trace" cause
     | _ -> false)
  | _ -> false
;;

let skill_evidence_owner_gap = function
  | `Assoc fields as gap ->
    (match member "code" gap with
     | `String "keeper_catalog_unavailable" ->
       skill_evidence_exact_fields [ "code"; "detail" ] fields
       && skill_evidence_string_field "detail" gap
     | `String "keeper_catalog_changed_during_resolution" ->
       skill_evidence_exact_fields [ "code" ] fields
     | `String "invalid_persisted_keeper_name" ->
       skill_evidence_exact_fields [ "code"; "keeper" ] fields
       && skill_evidence_string_field "keeper" gap
     | `String "keeper_meta_name_mismatch" ->
       skill_evidence_exact_fields [ "code"; "keeper"; "metadata_name" ] fields
       && skill_evidence_string_field "keeper" gap
       && skill_evidence_string_field "metadata_name" gap
     | `String "keeper_meta_unavailable" ->
       skill_evidence_exact_fields [ "code"; "keeper"; "detail" ] fields
       && skill_evidence_string_field "keeper" gap
       && skill_evidence_string_field "detail" gap
     | `String "runtime_manifest_unreadable" ->
       skill_evidence_exact_fields [ "code"; "keeper"; "cause" ] fields
       && skill_evidence_string_field "keeper" gap
       && skill_evidence_manifest_cause (member "cause" gap)
     | _ -> false)
  | _ -> false
;;

let skill_evidence_filesystem_gap expected_code = function
  | `Assoc fields as gap ->
    skill_evidence_exact_fields [ "code"; "operation"; "path"; "detail" ] fields
    && member "code" gap = `String expected_code
    && (match member "operation" gap with
        | `String ("open_directory" | "read_directory" | "close_directory" | "stat_entry") -> true
        | _ -> false)
    && skill_evidence_string_field "path" gap
    && skill_evidence_string_field "detail" gap
  | _ -> false
;;

let skill_evidence_file_kind = function
  | `String
      ( "regular"
      | "directory"
      | "character_device"
      | "block_device"
      | "symbolic_link"
      | "fifo"
      | "socket" ) -> true
  | _ -> false
;;

let skill_evidence_activation_gap = function
  | `Assoc fields as gap ->
    (match member "code" gap with
     | `String ("trace_root_unavailable" as code)
     | `String ("trace_entry_unreadable" as code) ->
       skill_evidence_filesystem_gap code gap
     | `String "trace_root_not_directory" ->
       skill_evidence_exact_fields [ "code"; "kind" ] fields
       && skill_evidence_file_kind (member "kind" gap)
     | `String ("invalid_trace_directory" | "symlink_trace_entry") ->
       skill_evidence_exact_fields [ "code"; "entry" ] fields
       && skill_evidence_string_field "entry" gap
     | `String "trace_entry_not_directory" ->
       skill_evidence_exact_fields [ "code"; "trace_id"; "kind" ] fields
       && skill_evidence_string_field "trace_id" gap
       && skill_evidence_file_kind (member "kind" gap)
     | `String
         ( "trace_inventory_changed_during_discovery"
         | "trace_root_changed_during_discovery" ) ->
       skill_evidence_exact_fields [ "code" ] fields
     | `String "ledger_changed_during_discovery" ->
       skill_evidence_exact_fields [ "code"; "trace_id" ] fields
       && skill_evidence_string_field "trace_id" gap
     | `String "ledger_unreadable" ->
       skill_evidence_exact_fields
         [ "code"; "trace_id"; "cause_code"; "detail" ]
         fields
       && skill_evidence_string_field "trace_id" gap
       && skill_evidence_string_field "cause_code" gap
       && skill_evidence_string_field "detail" gap
     | _ -> false)
  | _ -> false
;;

let decode_skill_evidence_activation_item reference = function
  | `Assoc _ as evidence ->
    let* trace_id, sea_trace_id =
      match member "trace_id" evidence with
      | `String value ->
        Keeper_id.Trace_id.of_string value
        |> Result.map (fun trace_id -> trace_id, value)
        |> Result.map_error (fun _ -> "Skill activation trace_id is invalid")
      | _ -> Error "Skill activation trace_id is invalid"
    in
    let* sea_owner_status, sea_owner_claims, sea_owner_gap_count =
      match member "owner" evidence with
      | `Assoc _ as owner ->
        let* status =
          match member "status" owner with
          | `String
              ( "known"
              | "not_claimed_in_retained_catalog"
              | "conflicting"
              | "incomplete"
              | "catalog_unavailable" as value ) ->
            Ok value
          | _ -> Error "Skill activation owner status is invalid"
        in
        let* claims =
          match member "claims" owner with
          | `List claims ->
            List.fold_left
              (fun result claim ->
                 let* reversed = result in
                 match claim with
                 | `Assoc _ as claim ->
                   (match member "keeper" claim, member "source" claim with
                    | ( `String keeper
                      , `String ("current_meta" | "trace_history" | "runtime_manifest" as source) )
                      when String.trim keeper <> "" ->
                      Ok ({ seo_keeper = keeper; seo_source = source } :: reversed)
                    | _ -> Error "Skill activation owner claim is invalid")
                 | _ -> Error "Skill activation owner claim must be an object")
              (Ok [])
              claims
            |> Result.map List.rev
          | _ -> Error "Skill activation owner claims must be a list"
        in
        let* gaps =
          match member "gaps" owner with
          | `List gaps when List.for_all skill_evidence_owner_gap gaps ->
            Ok gaps
          | _ -> Error "Skill activation owner gaps must be objects"
        in
        let owner_agrees =
          match status with
          | "known" -> List.length claims = 1 && gaps = []
          | "not_claimed_in_retained_catalog" -> claims = [] && gaps = []
          | "conflicting" -> List.length claims >= 2 && gaps = []
          | "incomplete" -> gaps <> []
          | "catalog_unavailable" -> claims = [] && gaps <> []
          | _ -> false
        in
        if owner_agrees
        then Ok (status, claims, List.length gaps)
        else Error "Skill activation owner status disagrees with claims or gaps"
      | _ -> Error "Skill activation owner must be an object"
    in
    let* sea_activation =
      match member "activation" evidence with
      | `Assoc _ as activation ->
        (match
           Keeper_skill_activation_ledger.activation_of_yojson
             ~expected_trace_id:trace_id
             activation
         with
         | Ok observed ->
           let observed_reference =
             Skill_reference.make
               ~identity:observed.identity
               ~content_revision:observed.content_revision
           in
           if Skill_reference.equal reference observed_reference
           then Ok activation
           else Error "Skill activation reference disagrees with envelope"
         | Error _ -> Error "Skill activation payload is invalid")
      | _ -> Error "Skill activation payload must be an object"
    in
    Ok
      { sea_trace_id
      ; sea_owner_status
      ; sea_owner_claims
      ; sea_owner_gap_count
      ; sea_activation
      }
  | _ -> Error "Skill activation evidence must be an object"
;;

let decode_skill_evidence_activation reference json =
  match json with
  | `Assoc fields when not (List.mem_assoc "activation" fields) ->
    Error "Skill evidence activation is required"
  | _ ->
  match member "activation" json with
  | `Null -> Ok None
  | `Assoc _ as activation ->
    (match member "selection" activation, member "evidence" activation with
     | `String "most_recent_observed", evidence ->
       decode_skill_evidence_activation_item reference evidence
       |> Result.map (fun evidence ->
            Some (Skill_evidence_most_recent_observed evidence))
     | `String "most_recent_observed_timestamp_tie", `List evidence ->
       let* evidence =
         List.fold_left
           (fun result value ->
              let* reversed = result in
              let* evidence =
                decode_skill_evidence_activation_item reference value
              in
              Ok (evidence :: reversed))
           (Ok [])
           evidence
         |> Result.map List.rev
       in
       let parsed_timestamps =
         evidence
         |> List.filter_map (fun item ->
              match member "activated_at" item.sea_activation with
              | `String value -> Time_codec.parse_rfc3339_opt value
              | _ -> None)
         |> List.sort_uniq Float.compare
       in
       let distinct_traces =
         evidence
         |> List.map (fun item -> item.sea_trace_id)
         |> List.sort_uniq String.compare
       in
       if
         List.length evidence >= 2
         && List.length parsed_timestamps = 1
         && List.length distinct_traces = List.length evidence
       then
         Ok
           (Some
              (Skill_evidence_most_recent_observed_timestamp_tie evidence))
       else Error "Skill activation timestamp tie is inconsistent"
     | _ -> Error "Skill activation selection is invalid")
  | _ -> Error "Skill evidence activation must be an object or null"
;;

let decode_skill_evidence json =
  if member "schema" json <> `String "masc.skill-evidence/v5"
  then Error "Skill evidence schema is unsupported"
  else
    let* reference =
      match Skill_reference.of_yojson (member "reference" json) with
      | Ok reference -> Ok reference
      | Error _ -> Error "Skill evidence reference is invalid"
    in
    let* se_activation = decode_skill_evidence_activation reference json in
    let* se_composition = decode_skill_evidence_optional_object "composition" json in
    let* () =
      match se_composition with
      | None -> Ok ()
      | Some composition ->
        (match Keeper_skill_composition_evidence.of_yojson composition with
         | Ok evidence
           when Skill_reference.equal
                  reference
                  (Keeper_skill_composition_evidence.reference evidence) ->
           Ok ()
         | Ok _ -> Error "Skill composition evidence reference disagrees with envelope"
         | Error _ -> Error "Skill composition evidence record is invalid")
    in
    let observed = Option.is_some se_activation || Option.is_some se_composition in
    let* se_status =
      match member "status" json, observed with
      | `String "observed", true -> Ok Skill_evidence_observed
      | `String "not_observed_in_retained_coverage", false ->
        Ok Skill_evidence_not_observed_in_retained_coverage
      | `String ("observed" | "not_observed_in_retained_coverage"), _ ->
        Error "Skill evidence status disagrees with its observations"
      | _ -> Error "Skill evidence status is unsupported"
    in
    match member "coverage" json with
    | `Assoc _ as coverage ->
      let* () =
        match member "coverage_complete" coverage with
        | `Bool false -> Ok ()
        | _ -> Error "Skill evidence coverage must remain incomplete"
      in
      let* sec_activation_scope =
        match member "activation_scope" coverage with
        | `String
            ( "complete_retained_trace_snapshot"
            | "incomplete_retained_trace_snapshot"
            | "trace_store_unavailable" as value ) ->
          Ok value
        | _ -> Error "Skill evidence activation scope is unsupported"
      in
      let* sec_composition_scope =
        match member "composition_scope" coverage with
        | `String "exact_reference_latest_completed" ->
          Ok Skill_evidence_exact_reference_latest_completed
        | `String "unavailable" -> Ok Skill_evidence_composition_unavailable
        | _ -> Error "Skill evidence composition scope is unsupported"
      in
      let* sec_composition_records_read =
        decode_skill_evidence_nonnegative_int
          "composition_records_read"
          coverage
      in
      let* sec_composition_unavailable =
        decode_skill_evidence_string_list "composition_unavailable" coverage
      in
      let* sec_activation_sessions_inspected =
        decode_skill_evidence_nonnegative_int
          "activation_sessions_inspected"
          coverage
      in
      let* sec_activation_ledgers_loaded =
        decode_skill_evidence_nonnegative_int
          "activation_ledgers_loaded"
          coverage
      in
      let* activation_gaps =
        match member "activation_gaps" coverage with
        | `List gaps when List.for_all skill_evidence_activation_gap gaps ->
          Ok gaps
        | _ -> Error "Skill evidence activation gaps must be objects"
      in
      let sec_activation_gap_count = List.length activation_gaps in
      let* sec_activation_owner_gap_count =
        decode_skill_evidence_nonnegative_int
          "activation_owner_gap_count"
          coverage
      in
      let* () =
        match sec_composition_scope, se_composition, sec_composition_records_read with
        | Skill_evidence_exact_reference_latest_completed, Some _, 1
          when sec_composition_unavailable = [] ->
          Ok ()
        | Skill_evidence_exact_reference_latest_completed, None, 0
          when sec_composition_unavailable = [] ->
          Ok ()
        | Skill_evidence_composition_unavailable, None, 0
          when sec_composition_unavailable <> [] ->
          Ok ()
        | _ -> Error "Skill evidence composition coverage disagrees with its record"
      in
      let owner_gap_count =
        match se_activation with
        | None -> 0
        | Some (Skill_evidence_most_recent_observed evidence) ->
          evidence.sea_owner_gap_count
        | Some (Skill_evidence_most_recent_observed_timestamp_tie evidence) ->
          List.fold_left (fun total row -> total + row.sea_owner_gap_count) 0 evidence
      in
      let activation_count =
        match se_activation with
        | None -> 0
        | Some (Skill_evidence_most_recent_observed _) -> 1
        | Some (Skill_evidence_most_recent_observed_timestamp_tie evidence) ->
          List.length evidence
      in
      let* () =
        if
          sec_activation_ledgers_loaded <= sec_activation_sessions_inspected
          && activation_count <= sec_activation_ledgers_loaded
          && owner_gap_count = sec_activation_owner_gap_count
          &&
          (match sec_activation_scope with
           | "complete_retained_trace_snapshot" -> sec_activation_gap_count = 0
           | "incomplete_retained_trace_snapshot" ->
             sec_activation_gap_count > 0
           | "trace_store_unavailable" ->
             (match activation_gaps with
              | [ gap ] ->
                member "code" gap = `String "trace_root_unavailable"
                || member "code" gap = `String "trace_root_not_directory"
              | _ -> false)
             && Option.is_none se_activation
             && sec_activation_sessions_inspected = 0
             && sec_activation_ledgers_loaded = 0
             && sec_activation_owner_gap_count = 0
           | _ -> false)
        then Ok ()
        else Error "Skill evidence activation coverage disagrees with snapshot"
      in
      Ok
        { se_status
        ; se_activation
        ; se_composition
        ; se_coverage =
            { sec_composition_scope
            ; sec_composition_records_read
            ; sec_composition_unavailable
            ; sec_activation_scope
            ; sec_activation_sessions_inspected
            ; sec_activation_ledgers_loaded
            ; sec_activation_gap_count
            ; sec_activation_owner_gap_count
            }
        }
    | _ -> Error "Skill evidence coverage must be an object"
;;
