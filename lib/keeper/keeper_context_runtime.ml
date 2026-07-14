(** Keeper_context_runtime — facade that re-exports from domain sub-modules.

    Working context types live in {!Keeper_types}.
    Pure context operations are in {!Keeper_context_core}.
    Compaction policy is in {!Keeper_compact_policy}.
    Post-turn lifecycle is in {!Keeper_post_turn}.

    This module preserves the original public API so that callers
    do not need updating. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile


(* ================================================================ *)
(* Re-export from Keeper_context_core                                *)
(* ================================================================ *)

type working_context = Keeper_types.working_context
type session_context = Keeper_types.session_context

let text_of_message = Keeper_context_core.text_of_message
let max_tokens_of_context = Keeper_context_core.max_tokens_of_context
let message_count = Keeper_context_core.message_count
let checkpoint_of_context = Keeper_context_core.checkpoint_of_context
let resume_checkpoint_of_context =
  Keeper_context_core.resume_checkpoint_of_context
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
let role_of_string_opt = Keeper_context_core.role_of_string_opt
let message_to_json = Keeper_context_core.message_to_json
let message_of_json = Keeper_context_core.message_of_json
let serialize_context = Keeper_context_core.serialize_context
let deserialize_context = Keeper_context_core.deserialize_context
let context_to_json = Keeper_context_core.context_to_json
let create_session = Keeper_context_core.create_session
let persist_message = Keeper_context_core.persist_message

let timed = Keeper_context_core.timed
let zero_usage = Keeper_context_core.zero_usage
let usage_of_response = Keeper_context_core.usage_of_response
let total_tokens = Keeper_context_core.total_tokens

let log_keeper_exn = Keeper_context_core.log_keeper_exn
let checkpoint_max_tokens = Keeper_context_core.checkpoint_max_tokens
let context_of_oas_checkpoint = Keeper_context_core.context_of_oas_checkpoint
let save_oas_checkpoint = Keeper_context_core.save_oas_checkpoint
let load_context_from_checkpoint = Keeper_context_core.load_context_from_checkpoint

(* ================================================================ *)
(* Re-export from Keeper_compact_policy                              *)
(* ================================================================ *)

let compaction_policy_of_keeper = Keeper_compact_policy.compaction_policy_of_keeper

type compaction_decision = Keeper_compact_policy.compaction_decision =
  | Applied of Compaction_trigger.t
  | Prepared of Compaction_trigger.t
  | Rejected of Compaction_trigger.t * Keeper_compact_policy.compaction_rejection
  | Not_requested
  | Skipped_no_checkpoint

let compaction_decision_to_string =
  Keeper_compact_policy.compaction_decision_to_string

let compaction_decision_applied =
  Keeper_compact_policy.compaction_decision_applied

let compaction_decision_prepared =
  Keeper_compact_policy.compaction_decision_prepared


(* ================================================================ *)
(* Re-export from Keeper_post_turn                                   *)
(* ================================================================ *)

type compaction_event = Keeper_post_turn.compaction_event = {
  attempted : bool;
  applied : bool;
  started_dispatched : bool;
  failure_reason : string option;
  trigger : Compaction_trigger.t option;
  decision : Keeper_compact_policy.compaction_decision;
  before_messages : int;
  after_messages : int;
}

type post_turn_lifecycle = Keeper_post_turn.post_turn_lifecycle = {
  updated_meta : keeper_meta;
  checkpoint : Agent_sdk.Checkpoint.t option;
  handoff_json : Yojson.Safe.t option;
  handoff_attempted : bool;
  handoff_failure_reason : string option;
  compaction : compaction_event;
  turn_generation : int;
  context_max : int;
  message_count : int;
}

type overflow_retry_recovery = Keeper_post_turn.overflow_retry_recovery = {
  checkpoint : Agent_sdk.Checkpoint.t;
  compaction : compaction_event;
  turn_generation : int;
}

type max_context_resolution = {
  requested_override : int option;
  primary_budget : int;
  runtime_budget : int;
  requested_context_window : int;
  effective_budget : int;
}

type context_budget_source =
  | Runtime_provider_cap
  | Requested_override
  | Requested_override_clamped_to_provider

let context_budget_source_of_resolution (resolution : max_context_resolution) =
  match resolution.requested_override with
  | Some requested
    when requested > 0
         && resolution.effective_budget < resolution.requested_context_window ->
    Requested_override_clamped_to_provider
  | Some requested when requested > 0 -> Requested_override
  | Some _ | None -> Runtime_provider_cap

let context_budget_source_to_string = function
  | Runtime_provider_cap -> "runtime_provider_cap"
  | Requested_override -> "requested_override"
  | Requested_override_clamped_to_provider ->
    "requested_override_clamped_to_provider"

let context_budget_json_of_resolution
    ~(runtime_id : string)
    (resolution : max_context_resolution) : Yojson.Safe.t =
  let context_budget_source =
    resolution
    |> context_budget_source_of_resolution
    |> context_budget_source_to_string
  in
  `Assoc
    [ ("runtime_id", `String runtime_id)
    ; ("provider_context_window", `Int resolution.primary_budget)
    ; ("budget_source", `String context_budget_source)
    ; ("requested_override", Json_util.int_opt_to_json resolution.requested_override)
    ; ("primary_budget", `Int resolution.primary_budget)
    ; ("runtime_budget", `Int resolution.runtime_budget)
    ; ("requested_context_window", `Int resolution.requested_context_window)
    ; ("effective_budget", `Int resolution.effective_budget)
    ]
;;

let apply_post_turn_lifecycle_with_resilience_handles =
  Keeper_post_turn.apply_post_turn_lifecycle_with_resilience_handles
let recover_latest_checkpoint_for_overflow_retry =
  Keeper_post_turn.recover_latest_checkpoint_for_overflow_retry

let record_lifecycle_dispatch_rejection ~keeper_name ~origin event ~error =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string LifecycleDispatchRejections)
    ~labels:[ ("keeper", keeper_name); ("event", Keeper_state_machine.event_to_string event) ]
    ();
  Log.Keeper.warn
    "%s: keeper lifecycle dispatch rejected origin=%s event=%s error=%s"
    keeper_name
    (Keeper_registry.lifecycle_event_origin_to_string origin)
    (Keeper_state_machine.event_to_string event)
    error

let dispatch_keeper_phase_event
    ~(config : Workspace.config)
    ?(origin = Keeper_registry.Generic_dispatch)
    ~keeper_name
    event =
  match
    Keeper_registry.dispatch_event
      ~base_path:config.base_path
      ~origin
      keeper_name
      event
  with
  | Ok _ -> ()
  | Error err ->
      record_lifecycle_dispatch_rejection
        ~keeper_name
        ~origin
        event
        ~error:(Keeper_state_machine.transition_error_to_string err)
  | exception (Keeper_registry_types.Compaction_transition_violation _ as exn) ->
      record_lifecycle_dispatch_rejection
        ~keeper_name
        ~origin
        event
        ~error:(Printexc.to_string exn)

let dispatch_compaction_completed
    ~(config : Workspace.config)
    ~origin
    ~keeper_name
    ~before_messages
    ~after_messages =
  Otel_metric_store.inc_counter Keeper_metrics.(to_string FsmEdgeTransitions)
    ~labels:[("edge", "kmc_to_ksm_compact_completed")] ();
  dispatch_keeper_phase_event ~config ~origin ~keeper_name
    (Keeper_state_machine.Compaction_completed
       { before_messages; after_messages })

let dispatch_post_turn_lifecycle_events
    ~(config : Workspace.config)
    ~keeper_name
    (lifecycle : post_turn_lifecycle) =
  if lifecycle.compaction.attempted then
    if lifecycle.compaction.applied then begin
      (* FSM boundary: compaction_stage must be Compaction_compacting
         before we dispatch Compaction_completed.  If the
         on_compaction_started callback succeeded (started_dispatched =
         true), the FSM is already in compacting.  If it failed or was
         never called (recovery path), the FSM is still at accumulating
         and we must dispatch Compaction_started first.  The Started
         dispatch is idempotent from compacting, so this is safe in
         both cases. *)
      if not lifecycle.compaction.started_dispatched then begin
        Otel_metric_store.inc_counter Keeper_metrics.(to_string CompactionCallbackRecoveries)
          ~labels:[ ("keeper", keeper_name) ] ();
        Log.Keeper.warn
          "%s: on_compaction_started callback did not fire — \
           dispatching Compaction_started before Completed to recover \
           FSM path.  If this repeats, investigate registry contention \
           or keeper registration timing."
          keeper_name;
        dispatch_keeper_phase_event ~config
          ~origin:Keeper_registry.Post_turn_lifecycle
          ~keeper_name
          Keeper_state_machine.Compaction_started
      end;
      dispatch_compaction_completed
        ~config
        ~origin:Keeper_registry.Post_turn_lifecycle
        ~keeper_name
        ~before_messages:lifecycle.compaction.before_messages
        ~after_messages:lifecycle.compaction.after_messages
    end
    else
      dispatch_keeper_phase_event
        ~config
        ~origin:Keeper_registry.Post_turn_lifecycle
        ~keeper_name
        (Keeper_state_machine.Compaction_failed
           {
             reason =
               Option.value lifecycle.compaction.failure_reason
                 ~default:
                   (compaction_decision_to_string
                      lifecycle.compaction.decision);
           });
  match lifecycle.handoff_attempted, lifecycle.handoff_json with
  | true, Some _json ->
      dispatch_keeper_phase_event
        ~config
        ~origin:Keeper_registry.Post_turn_lifecycle
        ~keeper_name
        (Keeper_state_machine.Handoff_completed
           {
             generation = lifecycle.updated_meta.runtime.generation;
             new_trace_id =
               Keeper_id.Trace_id.to_string
                 lifecycle.updated_meta.runtime.trace_id;
           })
  | true, None ->
      dispatch_keeper_phase_event
        ~config
        ~origin:Keeper_registry.Post_turn_lifecycle
        ~keeper_name
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

let keeper_board_write_tool_names =
  [ "keeper_board_post"
  ; "keeper_board_comment"
  ; "keeper_board_vote"
  ; "keeper_board_curation_submit"
  ]

let canonical_tool_name name = Keeper_tool_resolution.canonical_tool_name name

let keeper_tool_name_matches tool name =
  String.equal (canonical_tool_name name) tool

let keeper_action_kind_of_tool_names tool_names =
  [ "keeper_board_post", "post"
  ; "keeper_board_comment", "comment"
  ; "keeper_board_vote", "vote"
  ; "keeper_board_curation_submit", "curation"
  ]
  |> List.find_map (fun (tool, action_kind) ->
    if List.exists (keeper_tool_name_matches tool) tool_names then Some action_kind
    else None)
  |> Option.value ~default:"none"

let effective_model_labels_for_turn (m : keeper_meta) : string list =
  (* Provider selection is runtime.toml SSOT; the former ~provider_filter
     plumbing was dead and deleted (audit F8). *)
  let configured = Keeper_model_labels.configured_model_labels_of_meta m in
  match String.trim (Keeper_status_runtime.active_model_of_meta m) with
  | "" -> configured
  | model ->
      let model_allowed =
        List.mem model configured
        || List.exists
             (fun label ->
               Runtime_provider_binding.label_matches_runtime_id
                 ~label
                 ~runtime_id:model)
             configured
      in
      if model_allowed
      then dedupe_keep_order (model :: configured)
      else configured

let resolve_max_context_resolution ~requested_override (labels : string list)
    : max_context_resolution =
  let min_keeper_context = Keeper_config.min_keeper_context_tokens in
  let clamp resolved =
    let local_clamped = resolved in
    max min_keeper_context local_clamped
  in
  let default_budget = Runtime.default_max_context () |> clamp in
  let runtime_budget =
    labels
    |> List.find_map (fun label ->
           String.trim label
           |> Runtime.max_context_of_runtime_id
           |> Option.map clamp)
    (* Labels are an ordered runtime-budget preference list. If none resolve,
       the precomputed default runtime budget preserves config-less tests.
       DET-OK: dispatch still fail-fast validates the selected runtime id before
       provider execution. *)
    |> Option.value ~default:default_budget
  in
  (* RFC-0207: budget against the same per-keeper runtime id that dispatch uses. *)
  let primary_budget = runtime_budget in
  let requested_context_window =
    match requested_override with
    | Some requested when requested > 0 ->
      max min_keeper_context requested
    | _ -> primary_budget
  in
  let effective_budget = min requested_context_window primary_budget in
  { requested_override
  ; primary_budget
  ; runtime_budget
  ; requested_context_window
  ; effective_budget
  }

let resolve_max_context_resolution_of_meta (m : keeper_meta)
    : max_context_resolution =
  (* RFC-0207: the per-keeper routed runtime ([runtime_id_of_meta] — the same id
     [keeper_turn_driver] dispatches to) is the authoritative budget source.
     [effective_model_labels_for_turn] projects through
     [Provider_runtime_projection.default_execution_model_strings], which ignores
     the runtime id and returns the GLOBAL preferred labels (an RFC-0206
     single-binding artifact), so on its own the budget would size against
     [runtime].default and could admit prompts exceeding a smaller per-keeper
     model's window.  Prepend the routed id so [resolve_max_context_resolution]'s
     [find_map] sizes against it first; the projection labels remain as
     fallback. *)
  let labels = runtime_id_of_meta m :: effective_model_labels_for_turn m in
  resolve_max_context_resolution
    ~requested_override:m.max_context_override labels

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
  else if String_util.contains_substring_ci b c then b
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
