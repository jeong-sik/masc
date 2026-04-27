(** Keeper_exec_context — facade that re-exports from domain sub-modules.

    Working context types live in {!Keeper_types}.
    Pure context operations are in {!Keeper_context_core}.
    Compaction policy is in {!Keeper_compact_policy}.
    Handoff rollover is in {!Keeper_rollover}.
    Post-turn lifecycle is in {!Keeper_post_turn}.

    This module preserves the original public API so that callers
    do not need updating. *)

open Keeper_types

let contains_ci = String_util.contains_substring_ci

(* ================================================================ *)
(* Re-export from Keeper_context_core                                *)
(* ================================================================ *)

type working_context = Keeper_types.working_context
type checkpoint = Keeper_types.checkpoint
type session_context = Keeper_types.session_context

let text_of_message = Keeper_context_core.text_of_message
let msg_tokens = Keeper_context_core.msg_tokens
let count_tokens = Keeper_context_core.count_tokens
let max_tokens_of_context = Keeper_context_core.max_tokens_of_context
let token_count = Keeper_context_core.token_count
let message_count = Keeper_context_core.message_count
let context_ratio = Keeper_context_core.context_ratio
let checkpoint_of_context = Keeper_context_core.checkpoint_of_context
let oas_context_of_context = Keeper_context_core.oas_context_of_context
let with_max_tokens = Keeper_context_core.with_max_tokens
let system_prompt_of_context = Keeper_context_core.system_prompt_of_context
let messages_of_context = Keeper_context_core.messages_of_context
let create = Keeper_context_core.create
let set_system_prompt = Keeper_context_core.set_system_prompt
let append = Keeper_context_core.append
let append_many = Keeper_context_core.append_many
let sync_oas_context = Keeper_context_core.sync_oas_context
let role_to_string = Keeper_context_core.role_to_string
let role_of_string = Keeper_context_core.role_of_string
let role_of_string_opt = Keeper_context_core.role_of_string_opt
let message_to_json = Keeper_context_core.message_to_json
let message_of_json = Keeper_context_core.message_of_json
let serialize_context = Keeper_context_core.serialize_context
let deserialize_context = Keeper_context_core.deserialize_context
let context_to_json = Keeper_context_core.context_to_json
let create_checkpoint = Keeper_context_core.create_checkpoint
let create_session = Keeper_context_core.create_session
let persist_message = Keeper_context_core.persist_message

let timed = Keeper_context_core.timed
let zero_usage = Keeper_context_core.zero_usage
let usage_of_response = Keeper_context_core.usage_of_response
let total_tokens = Keeper_context_core.total_tokens

let save_session_checkpoint = Keeper_context_core.save_session_checkpoint

let log_keeper_exn = Keeper_context_core.log_keeper_exn
let checkpoint_max_tokens = Keeper_context_core.checkpoint_max_tokens
let context_of_oas_checkpoint = Keeper_context_core.context_of_oas_checkpoint
let checkpoint_model_of_meta = Keeper_context_core.checkpoint_model_of_meta
let save_oas_checkpoint = Keeper_context_core.save_oas_checkpoint
let load_context_from_checkpoint = Keeper_context_core.load_context_from_checkpoint
let save_checkpoint = Keeper_context_core.save_checkpoint

(* ================================================================ *)
(* Re-export from Keeper_rollover                                    *)
(* ================================================================ *)

type handoff_rollover = Keeper_rollover.handoff_rollover = {
  updated_meta : keeper_meta;
  handoff_json : Yojson.Safe.t option;
  attempted : bool;
  failure_reason : string option;
  context_ratio : float;
  context_tokens : int;
  context_max : int;
  message_count : int;
}

let maybe_rollover_oas_handoff = Keeper_rollover.maybe_rollover_oas_handoff

type rollover_gate_decision = Keeper_rollover.rollover_gate_decision =
  | Skip of string
  | Go of string

let blocker_indicates_overflow = Keeper_rollover.blocker_indicates_overflow
let classify_rollover_gate = Keeper_rollover.classify_rollover_gate

(* ================================================================ *)
(* Re-export from Keeper_compact_policy                              *)
(* ================================================================ *)

let compaction_policy_of_keeper = Keeper_compact_policy.compaction_policy_of_keeper
let compact_if_needed = Keeper_compact_policy.compact_if_needed

(* ================================================================ *)
(* Re-export from Keeper_post_turn                                   *)
(* ================================================================ *)

type compaction_event = Keeper_post_turn.compaction_event = {
  attempted : bool;
  applied : bool;
  failure_reason : string option;
  trigger : string option;
  decision : string;
  before_tokens : int;
  after_tokens : int;
  saved_tokens : int;
}

type post_turn_lifecycle = Keeper_post_turn.post_turn_lifecycle = {
  updated_meta : keeper_meta;
  checkpoint : Oas.Checkpoint.t option;
  handoff_json : Yojson.Safe.t option;
  handoff_attempted : bool;
  handoff_failure_reason : string option;
  compaction : compaction_event;
  turn_generation : int;
  context_ratio : float;
  context_tokens : int;
  context_max : int;
  message_count : int;
}

type overflow_retry_recovery = Keeper_post_turn.overflow_retry_recovery = {
  checkpoint : Oas.Checkpoint.t;
  compaction : compaction_event;
  turn_generation : int;
}

type max_context_resolution = {
  requested_override : int option;
  primary_budget : int;
  cascade_budget : int;
  turn_budget : int;
  effective_budget : int;
}

let apply_post_turn_lifecycle = Keeper_post_turn.apply_post_turn_lifecycle
let recover_latest_checkpoint_for_overflow_retry =
  Keeper_post_turn.recover_latest_checkpoint_for_overflow_retry

let dispatch_keeper_phase_event ~(config : Coord.config) ~keeper_name event =
  match
    Keeper_registry.dispatch_event
      ~base_path:config.base_path
      keeper_name
      event
  with
  | Ok _ -> ()
  | Error err ->
      Prometheus.inc_counter
        Prometheus.metric_keeper_lifecycle_dispatch_rejections
        ~labels:[ ("event", Keeper_state_machine.event_to_string event) ]
        ();
      Log.Keeper.warn
        "%s: post-turn lifecycle dispatch failed event=%s error=%s"
        keeper_name
        (Keeper_state_machine.event_to_string event)
        (Keeper_state_machine.transition_error_to_string err)

(* #9988 Option B follow-up: centralize [Compaction_completed] dispatch
   so both emit paths (manual recovery in [tool_keeper] and automatic
   post-turn lifecycle) share the same outcome counter + warn log.

   [masc_keeper_compaction_outcome_total{keeper,outcome}] splits into
   [outcome=ok] (real savings) and [outcome=noop] (before==after or
   after>before).  The FSM (#9993) already refuses to clear
   [context_overflow] in the noop branch; the counter exposes the
   surface so dashboards/Grafana can alert on rising noop rate —
   the operational signal for "reducer has nothing to strip, switch
   profile or hand off". *)
let compaction_outcome_metric = "masc_keeper_compaction_outcome_total"

(* Observability-only: bump the outcome counter and log the warn
   when saved_tokens <= 0.  Split from [dispatch_compaction_completed]
   so unit tests can verify classification without needing a full
   [Coord.config] / [Keeper_registry] setup. *)
let record_compaction_outcome ~keeper_name ~before_tokens ~after_tokens =
  let saved_tokens = before_tokens - after_tokens in
  let outcome = if saved_tokens > 0 then "ok" else "noop" in
  Prometheus.inc_counter compaction_outcome_metric
    ~labels:[ ("keeper", keeper_name); ("outcome", outcome) ] ();
  if saved_tokens <= 0 then
    Log.Keeper.warn
      "#9988 compaction_completed but saved_tokens=%d \
       (before=%d after=%d) keeper=%s — context_overflow will stay set \
       (FSM noop branch).  If this repeats, switch to a stronger \
       compaction profile or escalate to operator."
      saved_tokens before_tokens after_tokens keeper_name

let dispatch_compaction_completed
    ~(config : Coord.config) ~keeper_name ~before_tokens ~after_tokens =
  record_compaction_outcome ~keeper_name ~before_tokens ~after_tokens;
  Prometheus.inc_counter Prometheus.metric_keeper_fsm_edge_transitions
    ~labels:[("edge", "kmc_to_ksm_compact_completed")] ();
  dispatch_keeper_phase_event ~config ~keeper_name
    (Keeper_state_machine.Compaction_completed
       { before_tokens; after_tokens })

let dispatch_post_turn_lifecycle_events
    ~(config : Coord.config)
    ~keeper_name
    (lifecycle : post_turn_lifecycle) =
  if lifecycle.compaction.attempted then
    if lifecycle.compaction.applied then
      dispatch_compaction_completed ~config ~keeper_name
        ~before_tokens:lifecycle.compaction.before_tokens
        ~after_tokens:lifecycle.compaction.after_tokens
    else
      dispatch_keeper_phase_event ~config ~keeper_name
        (Keeper_state_machine.Compaction_failed
           {
             reason =
               Option.value lifecycle.compaction.failure_reason
                 ~default:lifecycle.compaction.decision;
           });
  match lifecycle.handoff_attempted, lifecycle.handoff_json with
  | true, Some _json ->
      dispatch_keeper_phase_event ~config ~keeper_name
        (Keeper_state_machine.Handoff_completed
           {
             generation = lifecycle.updated_meta.runtime.generation;
             new_trace_id =
               Keeper_id.Trace_id.to_string
                 lifecycle.updated_meta.runtime.trace_id;
           })
  | true, None ->
      dispatch_keeper_phase_event ~config ~keeper_name
        (Keeper_state_machine.Handoff_failed
           {
             reason =
               Option.value lifecycle.handoff_failure_reason
                 ~default:"handoff_aborted";
           })
  | false, _ -> ()

(* ================================================================ *)
(* Remaining functions (not extracted — small utilities)              *)
(* ================================================================ *)

let generate_trace_id = Keeper_identity.generate_trace_id

let keeper_board_write_tool_names = Tool_name.Keeper.board_write_tool_names

let keeper_tool_name_matches tool name =
  match Tool_name.Keeper.of_string name with
  | Some parsed -> parsed = tool
  | None -> false

let keeper_write_done tool_names =
  List.exists
    (fun name ->
       match Tool_name.Keeper.of_string name with
       | Some tool -> Tool_name.Keeper.is_board_write tool
       | None -> false)
    tool_names

let keeper_action_kind_of_tool_names tool_names =
  Tool_name.Keeper.board_write_tools
  |> List.find_map (fun tool ->
    if List.exists (keeper_tool_name_matches tool) tool_names then
      Tool_name.Keeper.board_write_action_kind tool
    else None)
  |> Option.value ~default:"none"

let effective_model_labels_for_turn (m : keeper_meta) : string list =
  (* provider filtering now handled by OAS cascade via ~provider_filter *)
  let configured = Keeper_model_labels.configured_model_labels_of_meta m in
  let configured_ids =
    try
      Cascade_config.parse_model_strings configured
      |> List.map (fun (c : Llm_provider.Provider_config.t) -> String.trim c.model_id)
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> []
  in
  match String.trim (Keeper_exec_status.active_model_of_meta m) with
  | "" -> configured
  | model ->
      let model_allowed =
        List.mem model configured
        || List.mem model configured_ids
      in
      if model_allowed
      then dedupe_keep_order (model :: configured)
      else configured

let resolve_max_context_resolution ~requested_override (labels : string list)
    : max_context_resolution =
  let min_keeper_context = Keeper_config.min_keeper_context_tokens in
  let clamp resolved =
    let local_clamped =
      Cascade_runtime.clamp_context_for_pure_local_labels
        ~labels ~max_context:resolved
    in
    max min_keeper_context local_clamped
  in
  let primary_budget =
    Cascade_runtime.resolve_primary_max_context labels
    |> clamp
  in
  let cascade_budget =
    Cascade_runtime.resolve_max_cascade_context labels
    |> clamp
  in
  let turn_budget =
    match requested_override with
    | Some requested when requested > 0 ->
      max min_keeper_context requested
    | _ -> primary_budget
  in
  let effective_budget = min turn_budget primary_budget in
  { requested_override; primary_budget; cascade_budget; turn_budget; effective_budget }

let resolve_max_context_resolution_of_meta (m : keeper_meta)
    : max_context_resolution =
  let labels = effective_model_labels_for_turn m in
  resolve_max_context_resolution
    ~requested_override:m.max_context_override labels

let room_cursor_for meta room_id =
  meta.last_seen_seq_by_room
  |> List.find_map (fun (rid, seq) -> if rid = room_id then Some seq else None)
  |> Option.value ~default:0

let set_room_cursor meta room_id seq =
  let kept =
    meta.last_seen_seq_by_room
    |> List.filter (fun (rid, _) -> rid <> room_id)
  in
  {
    meta with
    last_seen_seq_by_room = dedupe_keep_order ((room_id, seq) :: kept);
  }

let room_ids_for_meta _config (_meta : keeper_meta) : string list =
  [ "default" ]

let keeper_room_capabilities (meta : keeper_meta) =
  let preset_cap =
    match Keeper_types.tool_access_preset meta.tool_access with
    | Some p -> [ "preset:" ^ Keeper_types.tool_preset_to_string p ]
    | None -> []
  in
  [ "keeper" ] @ preset_cap

let keeper_room_capabilities_need_sync config (meta : keeper_meta) capabilities =
  let agent_file =
    Filename.concat (Coord.agents_dir config)
      (Coord.safe_filename meta.agent_name ^ ".json")
  in
  (* Use backend-aware read_json_opt instead of Sys.file_exists which
     returns false for non-filesystem backends (PG, Memory). *)
  match Coord.read_json_opt config agent_file with
  | None -> true
  | Some json -> (
      match Types.agent_of_yojson json with
      | Ok agent -> agent.capabilities <> capabilities
      | Error _ -> true)

let ensure_keeper_room_presence config (meta : keeper_meta) : keeper_meta =
  let room_ids = room_ids_for_meta config meta in
  let capabilities = keeper_room_capabilities meta in
  let successful_rooms =
    List.fold_left
      (fun acc room_id ->
        try
          let joined =
            Coord.is_agent_joined config ~agent_name:meta.agent_name
          in
          if not joined
          then begin
            Coord.ensure_room_bootstrap config;
            ignore
              (Coord.join config ~agent_name:meta.agent_name
                 ~capabilities ())
          end;
          if joined && keeper_room_capabilities_need_sync config meta capabilities
          then
            ignore
              (Coord.update_agent_r config ~agent_name:meta.agent_name
                 ~capabilities ());
          ignore
            (Coord.heartbeat config ~agent_name:meta.agent_name);
          room_id :: acc
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Keeper_context_core.log_keeper_exn ~label:(Printf.sprintf "room presence sync failed for %s in %s" meta.name room_id) exn;
          acc)
      [] room_ids
  in
  { meta with joined_room_ids = List.rev successful_rooms }

let exact_direct_mention_present ~(targets : string list) (content : string) :
    bool =
  Mention.any_mentioned ~targets content

(* Delegate to Keeper_prompt — single source of truth for keeper prompts. *)
let keeper_constitution = Keeper_prompt.keeper_constitution

let build_keeper_system_prompt = Keeper_prompt.build_keeper_system_prompt

let append_trait_clause ~(base : string) ~(clause : string) : string =
  let b = String.trim base in
  let c = String.trim clause in
  if c = "" then b
  else if b = "" then c
  else if contains_ci b c then b
  else Printf.sprintf "%s; %s" b c


include Keeper_text_processing

let memory_check_default_json () : Yojson.Safe.t =
  `Assoc [
    ("performed", `Bool false);
    ("query_kind", `String "none");
    ("expected_topic", `Null);
    ("candidate_count", `Int 0);
    ("initial_score", `Float 0.0);
    ("final_score", `Float 0.0);
    ("threshold", `Float 0.18);
    ("passed", `Bool true);
    ("best_match", `Null);
    ("correction_applied", `Bool false);
    ("correction_success", `Bool false);
    ("prompt_fallback_applied", `Bool false);
    ("prompt_fallback_success", `Bool false);
    ("deterministic_fallback_applied", `Bool false);
    ("recall_fallback_applied", `Bool false);
  ]
