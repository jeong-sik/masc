(** Keeper_context_runtime — facade that re-exports from domain sub-modules.

    Working context types live in {!Keeper_types}.
    Pure context operations are in {!Keeper_context_core}.
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
let message_count = Keeper_context_core.message_count
let serialized_bytes = Keeper_context_core.serialized_bytes
let checkpoint_of_context = Keeper_context_core.checkpoint_of_context
let resume_checkpoint_of_context =
  Keeper_context_core.resume_checkpoint_of_context
let agent_core_context_of_context = Keeper_context_core.agent_core_context_of_context
let system_prompt_of_context = Keeper_context_core.system_prompt_of_context
let messages_of_context = Keeper_context_core.messages_of_context
let create = Keeper_context_core.create
let set_system_prompt = Keeper_context_core.set_system_prompt
let append = Keeper_context_core.append
let append_many = Keeper_context_core.append_many
let sync_agent_core_context = Keeper_context_core.sync_agent_core_context
let role_to_string = Keeper_context_core.role_to_string
let role_of_string_opt = Keeper_context_core.role_of_string_opt
let message_to_json = Keeper_context_core.message_to_json
let message_of_json = Keeper_context_core.message_of_json
let serialize_context = Keeper_context_core.serialize_context
let create_session = Keeper_context_core.create_session
let persist_message = Keeper_context_core.persist_message

let log_keeper_exn = Keeper_context_core.log_keeper_exn
let context_of_agent_core_checkpoint = Keeper_context_core.context_of_agent_core_checkpoint
let save_agent_core_checkpoint = Keeper_context_core.save_agent_core_checkpoint
let load_context_from_checkpoint = Keeper_context_core.load_context_from_checkpoint

(* ================================================================ *)


(* ================================================================ *)
(* Re-export from Keeper_post_turn                                   *)
(* ================================================================ *)

type post_turn_lifecycle = Keeper_post_turn.post_turn_lifecycle = {
  updated_meta : keeper_meta;
  checkpoint : Agent_core.Checkpoint.t option;
  checkpoint_bytes : int;
  message_count : int;
}

type max_context_resolution = {
  requested_override : int option;
  primary_budget : int;
  runtime_budget : int;
  (* Where [runtime_budget] came from: the AGENT_CORE capability catalog, a
     runtime.toml override, or that override clamped by the capability.
     [None] only on the legacy ordered-label path when no label resolved and
     the precomputed default budget filled in. Dropping this rendered a
     runtime.toml override as "runtime_provider_cap" in keeper status JSON,
     disguising the #25463 config drift as a provider fact. *)
  runtime_budget_source : Runtime.max_context_source option;
  requested_context_window : int;
  effective_budget : int;
}

type max_context_resolution_error =
  | Invalid_requested_context_override of int
  | Runtime_context_window_unavailable of { runtime_id : string }

let max_context_resolution_error_to_string = function
  | Invalid_requested_context_override requested ->
    Printf.sprintf "requested context override must be positive, got %d" requested
  | Runtime_context_window_unavailable { runtime_id } ->
    Printf.sprintf
      "no configured runtime context window resolved for runtime id %S"
      runtime_id

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
  (* [budget_source] states which side won (runtime budget vs keeper-meta
     requested override); [runtime_budget_source] states where the runtime
     budget itself came from. Without the second field a runtime.toml
     override rendered as budget_source=runtime_provider_cap under the JSON
     key provider_context_window, which disguised the #25463 262144 config
     drift as a provider fact for weeks. *)
  let runtime_budget_source =
    match resolution.runtime_budget_source with
    | Some source -> Runtime.max_context_source_to_string source
    | None -> "default_fallback"
  in
  `Assoc
    [ ("runtime_id", `String runtime_id)
    ; ("provider_context_window", `Int resolution.primary_budget)
    ; ("budget_source", `String context_budget_source)
    ; ("runtime_budget_source", `String runtime_budget_source)
    ; ("requested_override", Json_util.int_opt_to_json resolution.requested_override)
    ; ("primary_budget", `Int resolution.primary_budget)
    ; ("runtime_budget", `Int resolution.runtime_budget)
    ; ("requested_context_window", `Int resolution.requested_context_window)
    ; ("effective_budget", `Int resolution.effective_budget)
    ]
;;

let apply_post_turn_lifecycle = Keeper_post_turn.apply_post_turn_lifecycle

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

type lifecycle_dispatch_error =
  | Transition_rejected of Keeper_state_machine.transition_error

let dispatch_keeper_phase_event_result
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
  | Ok _ -> Ok ()
  | Error err ->
      record_lifecycle_dispatch_rejection
        ~keeper_name
        ~origin
        event
        ~error:(Keeper_state_machine.transition_error_to_string err);
      Error (Transition_rejected err)

let dispatch_keeper_phase_event ~config ?origin ~keeper_name event =
  dispatch_keeper_phase_event_result ~config ?origin ~keeper_name event
  |> ignore

(* ================================================================ *)
(* Remaining functions (not extracted — small utilities)              *)
(* ================================================================ *)

let generate_trace_id = Keeper_identity.generate_trace_id

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
  let default_budget = Runtime.default_max_context () in
  let runtime_budget, runtime_budget_source =
    match
      labels
      |> List.find_map (fun label ->
             String.trim label
             |> Runtime.resolve_max_context_of_runtime_id)
    with
    | Some (budget, source) -> budget, Some source
    (* Labels are an ordered runtime-budget preference list. If none resolve,
       the precomputed default runtime budget preserves config-less tests.
       DET-OK: dispatch still fail-fast validates the selected runtime id before
       provider execution. *)
    | None -> default_budget, None
  in
  (* RFC-0207: budget against the same per-keeper runtime id that dispatch uses. *)
  let primary_budget = runtime_budget in
  let requested_context_window =
    match requested_override with
    | Some requested when requested > 0 -> requested
    | _ -> primary_budget
  in
  let effective_budget = min requested_context_window primary_budget in
  { requested_override
  ; primary_budget
  ; runtime_budget
  ; runtime_budget_source
  ; requested_context_window
  ; effective_budget
  }

let resolve_max_context_resolution_for_runtime
      ~requested_override
      (runtime : Runtime.t)
  =
  match requested_override with
  | Some requested when requested <= 0 ->
    Error (Invalid_requested_context_override requested)
  | Some _ | None ->
    (match Runtime.resolve_max_context_of_runtime runtime with
     | None ->
       Error (Runtime_context_window_unavailable { runtime_id = runtime.id })
     | Some (runtime_budget, runtime_budget_source) ->
       let requested_context_window =
         match requested_override with
         | None -> runtime_budget
         | Some requested -> requested
       in
       let effective_budget = min requested_context_window runtime_budget in
       Ok
         { requested_override
         ; primary_budget = runtime_budget
         ; runtime_budget
         ; runtime_budget_source = Some runtime_budget_source
         ; requested_context_window
         ; effective_budget
         })
;;

let resolve_max_context_resolution_for_runtime_id
      ~requested_override
      ~runtime_id
  =
  match Runtime.get_runtime_by_id runtime_id with
  | None -> Error (Runtime_context_window_unavailable { runtime_id })
  | Some runtime ->
    resolve_max_context_resolution_for_runtime ~requested_override runtime

let exact_direct_mention_present ~(targets : string list) (content : string) :
    bool =
  Mention.any_mentioned ~targets content

(* Delegate to Keeper_prompt — single source of truth for keeper prompts. *)
let build_keeper_system_prompt = Keeper_prompt.build_keeper_system_prompt



include Keeper_text_processing
