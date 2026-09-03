open Keeper_approval_queue
open Keeper_approval_queue_rules_types

module Exact_output = Agent_core.Exact_output
module Registry = Runtime_exact_output_registry
module Schema = Keeper_structured_output_schema

let summary_version = current_hitl_context_summary_version
let lane_id = "hitl_auto_judge"

let system_prompt () =
  Prompt_registry.render_prompt_template Prompt_names.judge_effect []
;;

let ( let* ) = Result.bind

(* ── Metrics ────────────────────────────────────── *)

let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~help:
      "Total HITL exact-output flow outcomes classified by [outcome]. MASC \
       records domain and durability outcomes only; provider selection, \
       admission, dispatch, and failover remain AGENT_CORE-owned."
    ()
;;

(** Every terminal disposition of the HITL exact-output flow.

    Closed on purpose. These were 27 string literals spread over 37 call
    sites, so a branch added later could reach the metric — and any consumer
    derived from it — without the compiler asking. A variant makes each
    derivation an exhaustive match, so the next branch stops the build
    until it is classified. The metric label text is unchanged: it is
    derived here rather than restated at each site. *)
type flow_outcome =
  | Ok_summary
  | Ok_summary_cli
  | Source_resolved
  | Identity_unbound
  | Identity_unbound_source_changed
  | Terminal_sync_unconfirmed
  | Terminal_persistence_failure
  | Terminal_rejected
  | Provenance_mismatch
  | Domain_invalid_output
  | Attempt_replay
  | Attempt_start_failed
  | Measurement_start_failed
  | Measurement_callback_failed
  | Candidates_exhausted
  | Bind_failed
  | Release_failed
  | Execution_failed
  | Cli_slots_exhausted
  | Cli_released_without_binding
  | Cli_walk_fell_back
  | Cli_release_unconfirmed
  | Cli_bind_unconfirmed
  | Cli_bind_failed
  | Cancellation
  | Cancellation_settlement_failed
  | Crashed

let outcome_label = function
  | Ok_summary -> "ok_summary"
  | Ok_summary_cli -> "ok_summary_cli"
  | Source_resolved -> "exact_source_resolved"
  | Identity_unbound -> "exact_identity_unbound"
  | Identity_unbound_source_changed -> "exact_identity_unbound_source_changed"
  | Terminal_sync_unconfirmed -> "exact_terminal_sync_unconfirmed"
  | Terminal_persistence_failure -> "exact_terminal_persistence_failure"
  | Terminal_rejected -> "exact_terminal_rejected"
  | Provenance_mismatch -> "exact_provenance_mismatch"
  | Domain_invalid_output -> "exact_domain_invalid_output"
  | Attempt_replay -> "exact_attempt_replay"
  | Attempt_start_failed -> "exact_attempt_start_failed"
  | Measurement_start_failed -> "exact_measurement_start_failed"
  | Measurement_callback_failed -> "exact_measurement_callback_failed"
  | Candidates_exhausted -> "exact_candidates_exhausted"
  | Bind_failed -> "exact_bind_failed"
  | Release_failed -> "exact_release_failed"
  | Execution_failed -> "exact_execution_failed"
  | Cli_slots_exhausted -> "exact_cli_slots_exhausted"
  | Cli_released_without_binding -> "exact_cli_released_without_binding"
  | Cli_walk_fell_back -> "exact_cli_walk_fell_back"
  | Cli_release_unconfirmed -> "exact_cli_release_unconfirmed"
  | Cli_bind_unconfirmed -> "exact_cli_bind_unconfirmed"
  | Cli_bind_failed -> "exact_cli_bind_failed"
  | Cancellation -> "exact_cancellation"
  | Cancellation_settlement_failed -> "exact_cancellation_settlement_failed"
  | Crashed -> "crashed"
;;

(* The branch a flow last took, kept per fiber so concurrent workers cannot
   read each other's. A flow that ends without a judgment summary knows only
   that it produced none; this is how the run registry gets to say which
   branch it was standing on when that happened. Fiber-local rather than a
   parameter because [record_outcome] is called from top-level helpers that
   have no flow value to thread. *)
let outcome_sink_key : flow_outcome option ref Eio.Fiber.key = Eio.Fiber.create_key ()

let with_outcome_sink sink f = Eio.Fiber.with_binding outcome_sink_key sink f

let record_outcome outcome =
  (match Eio.Fiber.get outcome_sink_key with
   | Some sink -> sink := Some outcome
   | None -> ());
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~labels:[ "outcome", outcome_label outcome ]
    ()
;;

(* ── Immutable MASC request ─────────────────────── *)

(* The fields that identify a request - keeper, tool, complete input, and
   task/goal linkage - are present on every pending approval. Outer-turn
   context is an accuracy aid that a request raised outside a Keeper turn
   structurally cannot carry, so its absence is reported to the judge as
   [partial_context] instead of ending the attempt. *)
(* The judge is shown what the Keeper did, not what it told itself while
   deciding to. [thinking] blocks are the Keeper's own reasoning, and they are
   dropped here for two reasons.

   Size: measured 2026-08-27 on the live queue, they were 23.2 kB of an 85.6 kB
   bundle for one keeper -- 51% of the message blocks -- while the call actually
   being judged was 2.5 kB. Every pending approval carries its own copy, so one
   Keeper with five of them sent the same reasoning five times.

   Independence: a Keeper's reasoning is where it argues for what it is about
   to do. The live sample carried "I MUST STOP this immediately" as a
   self-instruction, and a judge reading that is being asked to weigh the
   Keeper's account of itself rather than the request. What the Keeper actually
   did is still there in [text], [tool_use] and [tool_result].

   Dropped at the bundle rather than at write time: the durable entry keeps
   what the turn carried, and only the prompt is narrowed. The count is
   reported so a judge reading a thin bundle can tell trimming from a turn that
   never reasoned. *)
let thinking_block = function
  | `Assoc fields -> (
    match List.assoc_opt "type" fields with
    | Some (`String "thinking") -> true
    | Some _ | None -> false)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> false
;;

(* Newest first, because a constraint a Keeper set for itself is the one it
   just wrote down. The messages arrive oldest-first, so the budget is spent
   walking them backwards and the survivors are marked before the forward pass
   rewrites each message. Physical identity is the mark: two thinking blocks
   with the same text are still two blocks, and keeping "the newest one" has to
   mean the one that is newest. *)
let newest_thinking_blocks ~keep messages =
  if keep <= 0
  then []
  else
    List.fold_left
      (fun kept message ->
        if List.length kept >= keep
        then kept
        else
          match message with
          | `Assoc fields -> (
            match List.assoc_opt "content_blocks" fields with
            | Some (`List blocks) ->
              List.fold_left
                (fun kept block ->
                  if List.length kept >= keep || not (thinking_block block)
                  then kept
                  else block :: kept)
                kept (List.rev blocks)
            | Some _ | None -> kept)
          | _ -> kept)
      [] (List.rev messages)
;;

let drop_thinking_blocks ?(keep_newest = 0) context =
  let dropped = ref 0 in
  let survivors =
    match context with
    | `Assoc fields -> (
      match List.assoc_opt "initial" fields with
      | Some (`Assoc initial) -> (
        match List.assoc_opt "history_messages" initial with
        | Some (`List messages) -> newest_thinking_blocks ~keep:keep_newest messages
        | Some _ | None -> [])
      | Some _ | None -> [])
    | _ -> []
  in
  let survives block = List.exists (fun kept -> kept == block) survivors in
  let strip_message = function
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
             match key, value with
             | "content_blocks", `List blocks ->
               let kept =
                 List.filter (fun b -> (not (thinking_block b)) || survives b) blocks
               in
               dropped := !dropped + (List.length blocks - List.length kept);
               key, `List kept
             | _ -> key, value)
           fields)
    | other -> other
  in
  let strip_initial = function
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
             match key, value with
             | "history_messages", `List messages ->
               key, `List (List.map strip_message messages)
             | _ -> key, value)
           fields)
    | other -> other
  in
  let stripped =
    (* Only the one path this shape defines. A context that does not have it is
       carried through unchanged rather than walked for anything that looks
       like a block: guessing at the shape is how a field nobody meant to
       touch gets rewritten. *)
    match context with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
             if String.equal key "initial" then key, strip_initial value
             else key, value)
           fields)
    | other -> other
  in
  stripped, !dropped
;;

let build_context_bundle ~(entry : pending_approval) =
  let request_identity =
    [ "keeper_name", `String entry.keeper_name
    ; "tool_name", `String entry.tool_name
    ; "turn_id", Json_util.int_opt_to_json entry.turn_id
    ; "task_id", Json_util.string_opt_to_json entry.task_id
    ; "goal_id", Json_util.string_opt_to_json entry.goal_id
    ; "input", entry.input
    ]
  in
  let host_context = Keeper_gate_host_context.for_approval entry in
  match entry.request_context with
  | Some request_context ->
    let request_context, thinking_dropped =
      drop_thinking_blocks
        ~keep_newest:(Keeper_config.keeper_hitl_thinking_blocks ())
        request_context
    in
    `Assoc
      (request_identity
       @ [ "partial_context", `Bool false
         ; "thinking_blocks_omitted", `Int thinking_dropped
         ; "host_context", host_context
         ; "request_context", request_context
         ])
  | None ->
    `Assoc
      (request_identity
       @ [ "partial_context", `Bool true
         ; "host_context", host_context
         ])
;;

let message role text = Agent_core.Types.text_message role text

(* The contract sentence lives in the keeper.hitl_summary.output_contract
   template; this function only supplies the canonical schema as data. A
   template that does not render is logged and falls back to the bare schema
   JSON, never to instruction prose written here. *)
let canonical_output_contract () =
  let schema_json = Yojson.Safe.to_string Schema.hitl_context_summary_schema in
  match
    Prompt_registry.render_prompt_template
      Prompt_names.keeper_hitl_summary_output_contract
      [ "schema_json", schema_json ]
  with
  | Ok text -> String.trim text
  | Error detail ->
    Log.Keeper.error
      "hitl summary output-contract prompt %s did not render, falling back to the bare \
       schema: %s"
      Prompt_names.keeper_hitl_summary_output_contract
      detail;
    schema_json
;;

let messages_for_summary ~system_prompt ~context_bundle =
  [ message Agent_core.Types.System system_prompt
  ; message Agent_core.Types.User (canonical_output_contract ())
  ; message Agent_core.Types.User (Yojson.Safe.to_string context_bundle)
  ]
;;

let output_requirement =
  Exact_output.make_output_requirement
    ~schema:Schema.hitl_context_summary_schema
    ~minimum_guarantee:Exact_output.Json_syntax
;;

type prepared_flow =
  { entry : pending_approval
  ; generated_at : float
  ; attempt : Exact_output.flow_attempt
  ; cli_slots : string list
        (* Official-client runtime ids the lane walks after every catalog
           slot is exhausted, carried from the resolved lane declaration
           (RFC cli-runtimes-as-lane-slots). *)
  ; system_prompt : string
  ; context_bundle : Yojson.Safe.t
        (* Kept beside the frozen HTTP attempt because a cli one-shot has no
           request body: its input is the rendered prompt, rebuilt from the
           same contract and bundle the HTTP messages carry. *)
  }

let registry_error error =
  "HITL exact-output registry unavailable: " ^ Registry.publication_error_to_string error
;;

let lane_error error =
  "HITL exact-output lane unavailable: " ^ Registry.lane_resolution_error_to_string error
;;

let flow_candidates selected_slots =
  let rec loop candidates = function
    | [] -> Ok (List.rev candidates)
    | (slot : Registry.selected_slot) :: rest ->
      (match
         Exact_output.make_flow_candidate
           ~id:slot.slot_id
           ~admitted_target:slot.admitted_target
       with
       | Ok candidate -> loop (candidate :: candidates) rest
       | Error Exact_output.Blank_flow_candidate_id ->
         Error "HITL exact-output lane contains a blank slot id")
  in
  loop [] selected_slots
;;

let snapshot_resolved_lane ~messages (resolved : Registry.resolved_lane) =
  let* candidates = flow_candidates resolved.selected_slots in
  match candidates with
  | [] -> Error "HITL exact-output lane has no usable candidates"
  | first :: rest ->
    Exact_output.snapshot_flow
      ~first
      ~rest
      ~messages
      output_requirement
    |> Result.map_error (fun _ ->
      "HITL exact-output flow snapshot failed")
;;

let prepare_flow
      ~(entry : pending_approval)
  =
  let context_bundle = build_context_bundle ~entry in
  let* system_prompt =
    system_prompt ()
    |> Result.map_error (fun detail ->
      "HITL Gate judgment prompt unavailable: " ^ detail)
  in
  let* registry =
    Registry.current ()
    |> Result.map_error registry_error
  in
  let* resolved =
    Registry.resolve_lane registry ~lane_id
    |> Result.map_error lane_error
  in
  (* Which admitted exact-output slot this Keeper uses first for this lane.
     Only here: the readiness check below asks whether the lane can run at all,
     which is a workspace question with no Keeper in it. *)
  let* resolved =
    Keeper_exact_lane_preference.apply
      ~base_path:entry.Keeper_approval_queue_rules_types.audit_base_path
      ~keeper_name:entry.Keeper_approval_queue_rules_types.keeper_name
      ~lane_id
      resolved
    |> Result.map_error (fun detail ->
      "HITL exact-lane preference unavailable: " ^ detail)
  in
  let* snapshot =
    snapshot_resolved_lane
      ~messages:(messages_for_summary ~system_prompt ~context_bundle)
      resolved
  in
  let* attempt =
    Exact_output.start_flow snapshot
    |> Result.map_error (fun _ ->
      "HITL exact-output flow attempt allocation failed")
  in
  Ok
    { entry
    ; generated_at = Time_compat.now ()
    ; attempt
    ; cli_slots = resolved.Registry.cli_slots
    ; system_prompt
    ; context_bundle
    }
;;

let snapshot_topology_readiness () =
  let* system_prompt = system_prompt () in
  let* registry = Registry.current () |> Result.map_error registry_error in
  let* resolved =
    Registry.resolve_lane registry ~lane_id
    |> Result.map_error lane_error
  in
  let* candidates = flow_candidates resolved.selected_slots in
  match candidates with
  | [] -> Error "HITL exact-output lane has no usable candidates"
  | first :: rest ->
    Exact_output.snapshot_flow
      ~first
      ~rest
      ~messages:
        (messages_for_summary
           ~system_prompt
           ~context_bundle:(`Assoc []))
      output_requirement
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun _ ->
      "HITL exact-output readiness snapshot failed")
;;

(* ── MASC domain validation ─────────────────────── *)

let parse_summary ~generated_at ~model_run_id json =
  match json with
  | `Assoc fields ->
    hitl_context_summary_of_yojson_with_error
      (`Assoc
         ([ "summary_version", `Int summary_version
          ; "generated_at", `Float generated_at
          ; "model_run_id", `String model_run_id
          ]
          @ fields))
  | _ -> Error "HITL summary model output must be a JSON object"
;;

(* ── Exact queue identity and durability ────────── *)

type exact_identity =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

type exact_transition =
  id:string
  -> input_hash:string
  -> sequence:int
  -> slot_id:string
  -> call_id:string
  -> plan_fingerprint:string
  -> request_body_sha256:string
  -> (exact_attempt_transition, exact_attempt_error) result

type exact_completion_transition =
  id:string
  -> input_hash:string
  -> sequence:int
  -> slot_id:string
  -> call_id:string
  -> plan_fingerprint:string
  -> request_body_sha256:string
  -> summary:hitl_context_summary
  -> (exact_attempt_transition, exact_attempt_error) result

type exact_quarantine_transition =
  id:string
  -> input_hash:string
  -> sequence:int
  -> slot_id:string
  -> call_id:string
  -> plan_fingerprint:string
  -> request_body_sha256:string
  -> cause:exact_attempt_quarantine_cause
  -> (exact_attempt_transition, exact_attempt_error) result

type exact_queue_ops =
  { bind : exact_transition
  ; release_before_dispatch : exact_transition
  ; complete : exact_completion_transition
  ; quarantine : exact_quarantine_transition
  ; after_bind : unit -> unit
  }

let create_exact_queue_ops
      ~bind
      ~release_before_dispatch
      ~complete
      ~quarantine
      ~after_bind
  =
  { bind
  ; release_before_dispatch
  ; complete
  ; quarantine
  ; after_bind
  }
;;

let production_exact_queue_ops =
  create_exact_queue_ops
    ~bind:Keeper_approval_queue.bind_summary_exact_attempt
    ~release_before_dispatch:
      Keeper_approval_queue.release_summary_exact_attempt_before_dispatch
    ~complete:Keeper_approval_queue.complete_summary_exact_attempt
    ~quarantine:Keeper_approval_queue.quarantine_summary_exact_attempt
    ~after_bind:(fun () -> ())
;;

let exact_identity_of_candidate
      (candidate : Exact_output.flow_attempt_receipt)
  =
  let receipt = candidate.receipt in
  { slot_id = candidate.visit.identity.candidate_id
  ; call_id =
      receipt
      |> Exact_output.receipt_call_id
      |> Exact_output.call_id_to_string
  ; plan_fingerprint = Exact_output.receipt_plan_fingerprint receipt
  ; request_body_sha256 =
      Exact_output.receipt_request_body_sha256 receipt
  }
;;

let exact_identity_of_binding (binding : exact_attempt_binding) =
  { slot_id = binding.slot_id
  ; call_id = binding.call_id
  ; plan_fingerprint = binding.plan_fingerprint
  ; request_body_sha256 = binding.request_body_sha256
  }
;;

let with_exact_identity
      (entry : pending_approval)
      (identity : exact_identity)
      transition
  =
  transition
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
    ~slot_id:identity.slot_id
    ~call_id:identity.call_id
    ~plan_fingerprint:identity.plan_fingerprint
    ~request_body_sha256:identity.request_body_sha256
;;

let bind_exact_attempt
      queue_ops
      (entry : pending_approval)
      (identity : exact_identity)
  =
  with_exact_identity entry identity queue_ops.bind
;;

let release_exact_attempt
      queue_ops
      (entry : pending_approval)
      (identity : exact_identity)
  =
  with_exact_identity entry identity queue_ops.release_before_dispatch
;;

let complete_exact_attempt
      queue_ops
      (entry : pending_approval)
      (identity : exact_identity)
      summary
  =
  with_exact_identity
    entry
    identity
    (fun
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
    ->
      queue_ops.complete
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
        ~summary)
;;

type flow_callback_error =
  | Exact_bind_failed of exact_attempt_error
  | Exact_bind_sync_unconfirmed of string
  | Exact_release_failed of exact_attempt_error
  | Exact_release_sync_unconfirmed of string

let flow_callback_error_to_string = function
  | Exact_bind_failed error ->
    "exact bind failed: "
    ^ Keeper_approval_queue.exact_attempt_error_to_string error
  | Exact_bind_sync_unconfirmed detail ->
    "exact bind sync unconfirmed: " ^ detail
  | Exact_release_failed error ->
    "exact release failed: "
    ^ Keeper_approval_queue.exact_attempt_error_to_string error
  | Exact_release_sync_unconfirmed detail ->
    "exact release sync unconfirmed: " ^ detail
;;

let flow_callback_rejection = function
  | Exact_bind_failed (Exact_attempt_rejected rejection)
  | Exact_release_failed (Exact_attempt_rejected rejection) ->
    Some rejection
  | Exact_bind_failed (Exact_attempt_storage_error _)
  | Exact_release_failed (Exact_attempt_storage_error _)
  | Exact_bind_sync_unconfirmed _
  | Exact_release_sync_unconfirmed _ ->
    None
;;

let before_dispatch ~queue_ops (entry : pending_approval) candidate =
  let identity = exact_identity_of_candidate candidate in
  match bind_exact_attempt queue_ops entry identity with
  | Ok { write_outcome = Fsync_completed; _ } -> Ok ()
  | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
    Error (Exact_bind_sync_unconfirmed detail)
  | Error error ->
    Error (Exact_bind_failed error)
;;

let before_advance
      ~queue_ops
      (entry : pending_approval)
      ~failed
      ~next:_
  =
  match failed with
  | Exact_output.Flow_candidate_rejected _ -> Ok ()
  | Exact_output.Flow_candidate_execution_failed { candidate; cause = _ } ->
    let identity = exact_identity_of_candidate candidate in
    (match release_exact_attempt queue_ops entry identity with
     | Ok { write_outcome = Fsync_completed; _ } -> Ok ()
     | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
       Error (Exact_release_sync_unconfirmed detail)
     | Error error ->
       Error (Exact_release_failed error))
;;

let log_exact_error (entry : pending_approval) operation detail =
  Log.Keeper.warn
    ~keeper_name:entry.keeper_name
    "HITL exact-output %s failed approval_id=%s: %s"
    operation
    entry.id
    detail
;;

(* Five distinct outcomes settle as the same [Exact_flow_execution_failed]
   quarantine cause - attempt-allocation failure, measurement-allocation failure,
   candidate exhaustion, provider execution failure and provenance mismatch - and
   the durable row keeps only that label. An operator therefore reads "Auto Judge
   exact attempt quarantined: flow_execution_failed" with no way to tell a local
   context-capacity refusal from a provider outage, while the evidence payload
   each error carries is discarded at this boundary. Observed 2026-07-28: 25
   approvals quarantined under that one label, zero occurrences of the word in
   the system log, and no metrics endpoint listening to read the per-branch
   counter [record_outcome] already writes. Render the per-attempt provenance so
   the branch and the slot it died on are recoverable. *)
(* The renderers themselves moved to [Keeper_exact_flow_detail] so the
   librarian runtime and this worker print slot provenance identically. *)
let flow_evidence_detail = Keeper_exact_flow_detail.flow_evidence_detail
let candidate_rejection_detail = Keeper_exact_flow_detail.candidate_rejection_detail
let exact_attempt_source_resolved (entry : pending_approval) = function
  | Exact_attempt_rejected (Exact_attempt_not_found approval_id) ->
    String.equal approval_id entry.id
  | Exact_attempt_storage_error _ | Exact_attempt_rejected _ -> false
;;

exception Exact_terminalization_persistence_failed of string
exception Exact_terminalization_rejected of exact_attempt_rejection
exception Cancelled_uncertain of exn * Printexc.raw_backtrace * string
exception Exact_terminalization_identity_unbound of string
exception Cancelled_identity_unbound of exn * Printexc.raw_backtrace
exception Cancelled_exact_rejected of
  exn * Printexc.raw_backtrace * exact_attempt_rejection

type exact_settlement_error =
  | Exact_settlement_identity_unbound of string
  | Exact_settlement_persistence_failed of string
  | Exact_settlement_rejected of exact_attempt_rejection

type cancellation_settlement =
  | Cancellation_settled
  | Cancellation_exact_settlement_failed of exact_settlement_error
  | Cancellation_settlement_raised of string

let mark_identity_unbound (entry : pending_approval) =
  Keeper_approval_queue.mark_summary_attempt_identity_unbound
    ~base_path:entry.audit_base_path
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
;;

let mark_persistence_uncertain (entry : pending_approval) =
  Keeper_approval_queue.mark_summary_attempt_persistence_uncertain
    ~base_path:entry.audit_base_path
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
;;

let persist_identity_unbound (entry : pending_approval) =
  match mark_identity_unbound entry with
  | Ok true -> Ok ()
  | Ok false ->
    Error `Transition_not_applied
  | Error (Exact_attempt_storage_error error) ->
    Error (`Storage_failed (Keeper_approval_queue.storage_error_to_string error))
  | Error (Exact_attempt_rejected rejection) ->
    Error (`Rejected rejection)
;;

let signal_terminalization_persistence_failure
      (entry : pending_approval)
      operation
      detail
  =
  (match mark_persistence_uncertain entry with
   | Ok _ -> ()
   | Error marker_error ->
     log_exact_error
       entry
       "persistence uncertainty observation"
       (Keeper_approval_queue.exact_attempt_error_to_string marker_error));
  record_outcome Terminal_persistence_failure;
  log_exact_error entry operation detail;
  raise
    (Exact_terminalization_persistence_failed
       (Printf.sprintf
          "HITL exact-output %s failed approval_id=%s: %s"
          operation
          entry.id
          detail))
;;

type exact_queue_terminalization_error =
  | Exact_queue_persistence_failed of string
  | Exact_queue_rejected of exact_attempt_rejection

let quarantine_identity_result
      ~queue_ops
      (entry : pending_approval)
      (identity : exact_identity)
      cause
  =
  match
    with_exact_identity
      entry
      identity
      (fun
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
      ->
        queue_ops.quarantine
          ~id
          ~input_hash
          ~sequence
          ~slot_id
        ~call_id
        ~plan_fingerprint
          ~request_body_sha256
          ~cause)
  with
  | Ok { write_outcome = Fsync_completed; _ } -> Ok ()
  | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
    Error
      (Exact_queue_persistence_failed
         ("quarantine durability confirmation failed: " ^ detail))
  | Error error when exact_attempt_source_resolved entry error ->
    record_outcome Source_resolved;
    Ok ()
  | Error (Exact_attempt_storage_error error) ->
    Error
      (Exact_queue_persistence_failed
         (Keeper_approval_queue.storage_error_to_string error))
  | Error (Exact_attempt_rejected rejection) ->
    Error (Exact_queue_rejected rejection)
;;

let quarantine_identity
      ~queue_ops
      (entry : pending_approval)
      (identity : exact_identity)
      cause
  =
  match quarantine_identity_result ~queue_ops entry identity cause with
  | Ok () -> ()
  | Error (Exact_queue_persistence_failed detail) ->
    signal_terminalization_persistence_failure
      entry
      "quarantine persistence"
      detail
  | Error (Exact_queue_rejected rejection) ->
    raise (Exact_terminalization_rejected rejection)
;;

let quarantine_candidate ~queue_ops (entry : pending_approval) candidate cause =
  quarantine_identity
    ~queue_ops
    entry
    (exact_identity_of_candidate candidate)
    cause
;;

let settle_current ~queue_ops (entry : pending_approval) ~reason ~cause =
  match
    Keeper_approval_queue.get_pending_entry_for_workspace
      ~base_path:entry.audit_base_path
      ~id:entry.id
  with
  | Error error ->
    Error
      (Exact_settlement_persistence_failed
         (Keeper_approval_queue.storage_error_to_string error))
  | Ok None ->
    record_outcome Source_resolved;
    Ok ()
  | Ok (Some { exact_attempt = Exact_unbound; _ }) ->
    Error
      (Exact_settlement_identity_unbound
         (Printf.sprintf
            "HITL exact-output terminalization requires a bound attempt identity approval_id=%s: %s"
            entry.id
            reason))
  | Ok
      (Some
      { exact_attempt =
          Exact_bound { status = (Exact_completed | Exact_quarantined _); _ }
      ; _
      }) ->
    record_outcome Source_resolved;
    Ok ()
  | Ok (Some { exact_attempt = Exact_bound binding; _ }) ->
    quarantine_identity_result
      ~queue_ops
      entry
      (exact_identity_of_binding binding)
      cause
    |> Result.map_error (function
      | Exact_queue_persistence_failed detail ->
        Exact_settlement_persistence_failed detail
      | Exact_queue_rejected rejection ->
        Exact_settlement_rejected rejection)
;;

let signal_settlement_error (entry : pending_approval) = function
  | Exact_settlement_identity_unbound detail ->
    (match persist_identity_unbound entry with
     | Ok () ->
       record_outcome Identity_unbound;
       log_exact_error entry "terminalization blocked" detail;
       raise (Exact_terminalization_identity_unbound detail)
     | Error `Transition_not_applied ->
       record_outcome Identity_unbound_source_changed;
       raise (Exact_terminalization_identity_unbound detail)
     | Error (`Rejected rejection) ->
       raise (Exact_terminalization_rejected rejection)
     | Error (`Storage_failed marker_detail) ->
       signal_terminalization_persistence_failure
         entry
         "identity-unbound observation"
         marker_detail)
  | Exact_settlement_persistence_failed detail ->
    signal_terminalization_persistence_failure
      entry
      "terminalization persistence"
      detail
  | Exact_settlement_rejected rejection ->
    raise (Exact_terminalization_rejected rejection)
;;

let settle_current_or_signal ~queue_ops (entry : pending_approval) ~reason ~cause =
  match settle_current ~queue_ops entry ~reason ~cause with
  | Ok () -> ()
  | Error error -> signal_settlement_error entry error
;;

let same_catalog_generation left right =
  String.equal
    (Exact_output.catalog_generation_fingerprint left)
    (Exact_output.catalog_generation_fingerprint right)
;;

let same_catalog_evidence left right =
  String.equal
    (Exact_output.catalog_evidence_sha256 left)
    (Exact_output.catalog_evidence_sha256 right)
;;

let same_target_identity left right =
  String.equal
    (Exact_output.target_identity_fingerprint left)
    (Exact_output.target_identity_fingerprint right)
;;

let receipt_matches
      (left : Exact_output.receipt)
      (right : Exact_output.receipt)
  =
  String.equal
    (left |> Exact_output.receipt_call_id |> Exact_output.call_id_to_string)
    (right |> Exact_output.receipt_call_id |> Exact_output.call_id_to_string)
  && String.equal
       (Exact_output.receipt_plan_fingerprint left)
       (Exact_output.receipt_plan_fingerprint right)
  && String.equal
       (Exact_output.receipt_request_body_sha256 left)
       (Exact_output.receipt_request_body_sha256 right)
  && same_catalog_generation
       (Exact_output.receipt_catalog_generation left)
       (Exact_output.receipt_catalog_generation right)
  && same_catalog_evidence
       (Exact_output.receipt_catalog_evidence left)
       (Exact_output.receipt_catalog_evidence right)
  && same_target_identity
       (Exact_output.receipt_target_identity left)
       (Exact_output.receipt_target_identity right)
;;

let success_provenance_matches (flow_success : Exact_output.flow_success) =
  let candidate = Exact_output.flow_success_candidate flow_success in
  let identity = candidate.visit.identity in
  let success = Exact_output.flow_success_output flow_success in
  let provenance = success.provenance in
  String.equal
    (Exact_output.call_id_to_string success.call_id)
    (candidate.receipt
     |> Exact_output.receipt_call_id
     |> Exact_output.call_id_to_string)
  && receipt_matches candidate.receipt success.receipt
  && same_catalog_generation
       identity.catalog_generation
       (Exact_output.receipt_catalog_generation candidate.receipt)
  && same_catalog_evidence
       identity.catalog_evidence
       (Exact_output.receipt_catalog_evidence candidate.receipt)
  && same_target_identity
       identity.target_identity
       (Exact_output.receipt_target_identity candidate.receipt)
  && same_catalog_generation
       identity.catalog_generation
       (Exact_output.plan_provenance_catalog_generation provenance)
  && same_catalog_evidence
       identity.catalog_evidence
       (Exact_output.plan_provenance_catalog_evidence provenance)
  && same_target_identity
       identity.target_identity
       (Exact_output.plan_provenance_target_identity provenance)
;;

(* ── Flow terminalization ───────────────────────── *)

type semantic_rejection =
  | Semantic_provenance_mismatch
  | Semantic_domain_invalid of string

let validate_success (prepared : prepared_flow) flow_success =
  if not (success_provenance_matches flow_success)
  then Exact_output.Reject_and_advance Semantic_provenance_mismatch
  else
    let call_id =
      flow_success
      |> Exact_output.flow_success_candidate
      |> fun candidate -> candidate.receipt
      |> Exact_output.receipt_call_id
      |> Exact_output.call_id_to_string
    in
    let success = Exact_output.flow_success_output flow_success in
    match
      parse_summary
        ~generated_at:prepared.generated_at
        ~model_run_id:call_id
        success.output
    with
    | Error detail ->
      Exact_output.Reject_and_advance (Semantic_domain_invalid detail)
    | Ok summary -> Exact_output.Accept summary
;;

let handle_validated_success
      ~queue_ops
      (prepared : prepared_flow)
      ~on_summary
      (flow_success : Exact_output.flow_success)
      summary
  =
  let entry = prepared.entry in
  let candidate = Exact_output.flow_success_candidate flow_success in
  let identity = exact_identity_of_candidate candidate in
  match complete_exact_attempt queue_ops entry identity summary with
  | Ok { write_outcome = Fsync_completed; _ } ->
    record_outcome Ok_summary;
    on_summary summary
  | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
    record_outcome Terminal_sync_unconfirmed;
    signal_terminalization_persistence_failure
      entry
      "completion sync"
      detail
  | Error error when exact_attempt_source_resolved entry error ->
    record_outcome Source_resolved
  | Error (Exact_attempt_rejected rejection) ->
    raise (Exact_terminalization_rejected rejection)
  | Error (Exact_attempt_storage_error error) ->
    record_outcome Terminal_persistence_failure;
    log_exact_error
      entry
      "completion"
      (Keeper_approval_queue.storage_error_to_string error);
    quarantine_identity
      ~queue_ops
      entry
      identity
      Exact_terminal_persistence_failure
;;

let last_semantic_rejection
      (trace : semantic_rejection Exact_output.semantic_rejection_trace)
  =
  List.fold_left
    (fun _ rejection -> rejection)
    trace.first
    trace.rest
;;

(* The outcome a finished exact run earns, decided by whether a summary was
   observed. Named rather than inline because both arms are load-bearing: a
   summary reaches [on_summary] only after domain validation, provenance
   verification and fsync (see the .mli), so its absence is the failure, not a
   shape to synthesise an output for. *)
let run_outcome_of_observed_summary ~last_outcome = function
  | Some summary ->
    Exact_lane_run_registry.Succeeded, hitl_context_summary_to_yojson summary
  | None ->
    let code, detail =
      match last_outcome with
      | Some outcome ->
        ( outcome_label outcome
        , Printf.sprintf
            "exact flow terminalized without a judgment summary; the candidate \
             was quarantined on %s"
            (outcome_label outcome) )
      | None ->
        ( "no_branch_recorded"
        , "exact flow terminalized without a judgment summary and without \
           recording a branch" )
    in
    Exact_lane_run_registry.Failed { code; detail }, `Null
;;

let handle_semantic_exhaustion ~queue_ops (prepared : prepared_flow) trace =
  let rejection = last_semantic_rejection trace in
  let flow_success = rejection.transport_success in
  let candidate = Exact_output.flow_success_candidate flow_success in
  match rejection.rejection with
  | Semantic_provenance_mismatch ->
    record_outcome Provenance_mismatch;
    quarantine_candidate
      ~queue_ops
      prepared.entry
      candidate
      Exact_flow_execution_failed
  | Semantic_domain_invalid detail ->
    record_outcome Domain_invalid_output;
    log_exact_error prepared.entry "domain validation" detail;
    quarantine_candidate
      ~queue_ops
      prepared.entry
      candidate
      Exact_domain_invalid_output
;;

let handle_flow_error ~queue_ops (prepared : prepared_flow) = function
  | Exact_output.Flow_attempt_already_started evidence ->
    record_outcome Attempt_replay;
    log_exact_error prepared.entry "attempt replay" (flow_evidence_detail evidence);
    settle_current_or_signal
      ~queue_ops
      prepared.entry
      ~reason:"HITL exact-output flow attempt was replayed"
      ~cause:Exact_attempt_replay
  | Exact_output.Flow_attempt_start_failed { cause; evidence; _ } ->
    record_outcome Attempt_start_failed;
    let cause_detail =
      match cause with
      | Exact_output.Call_id_generation_failed detail -> detail
    in
    log_exact_error
      prepared.entry
      "candidate attempt allocation"
      (Printf.sprintf "%s (%s)" cause_detail (flow_evidence_detail evidence));
    settle_current_or_signal
      ~queue_ops
      prepared.entry
      ~reason:"HITL exact-output candidate attempt allocation failed"
      ~cause:Exact_flow_execution_failed
  | Exact_output.Flow_measurement_start_failed { evidence; _ } ->
    record_outcome Measurement_start_failed;
    log_exact_error
      prepared.entry
      "measurement allocation"
      (flow_evidence_detail evidence);
    settle_current_or_signal
      ~queue_ops
      prepared.entry
      ~reason:"HITL exact-output measurement allocation failed"
      ~cause:Exact_flow_execution_failed
  | Exact_output.Flow_candidates_exhausted { rejection; evidence } ->
    record_outcome Candidates_exhausted;
    log_exact_error
      prepared.entry
      "candidate exhaustion before dispatch"
      (Printf.sprintf
         "%s (%s)"
         (candidate_rejection_detail rejection)
         (flow_evidence_detail evidence));
    settle_current_or_signal
      ~queue_ops
      prepared.entry
      ~reason:"HITL exact-output candidates exhausted before dispatch"
      ~cause:Exact_flow_execution_failed
  | Exact_output.Flow_before_measurement_dispatch_callback_failed
      { cause; _ }
  | Exact_output.Flow_measurement_terminal_callback_failed
      { cause; _ } ->
    record_outcome Measurement_callback_failed;
    (match flow_callback_rejection cause with
     | Some rejection -> raise (Exact_terminalization_rejected rejection)
     | None ->
       settle_current_or_signal
         ~queue_ops
         prepared.entry
         ~reason:(flow_callback_error_to_string cause)
         ~cause:Exact_terminal_persistence_failure)
  | Exact_output.Flow_before_dispatch_callback_failed { cause; _ } ->
    record_outcome Bind_failed;
    (match flow_callback_rejection cause with
     | Some rejection -> raise (Exact_terminalization_rejected rejection)
     | None ->
       settle_current_or_signal
         ~queue_ops
         prepared.entry
         ~reason:(flow_callback_error_to_string cause)
         ~cause:Exact_terminal_persistence_failure)
  | Exact_output.Flow_before_advance_callback_failed { cause; _ } ->
    record_outcome Release_failed;
    (match flow_callback_rejection cause with
     | Some rejection -> raise (Exact_terminalization_rejected rejection)
     | None ->
       settle_current_or_signal
         ~queue_ops
         prepared.entry
         ~reason:(flow_callback_error_to_string cause)
         ~cause:Exact_terminal_persistence_failure)
  | Exact_output.Flow_exact_execution_failed { candidate; cause; evidence } ->
    record_outcome Execution_failed;
    log_exact_error
      prepared.entry
      "exact execution"
      (Keeper_exact_flow_detail.execution_failure_detail ~candidate ~cause ~evidence);
    quarantine_candidate
      ~queue_ops
      prepared.entry
      candidate
      Exact_flow_execution_failed
;;

type execution_boundary =
  | Executed
  | Identity_unbound_blocked
  | Exact_rejection_blocked of exact_attempt_rejection

(* ── CLI lane-slot fallback (RFC cli-runtimes-as-lane-slots) ─────────
   Walked only after the HTTP flow reports candidate exhaustion. Every queue
   transition stays inside the exact-attempt contract proven above:
   [release -> bind(new identity)] is the same rebind the HTTP walk uses, a
   summary completes the bound cli identity exactly like an HTTP success,
   and a failed walk leaves its last cli binding Exact_dispatch_uncertain so
   the ordinary quarantine transition can settle the entry. A cli one-shot
   has no request body; its input is the rendered prompt, so the prompt's
   sha256 fills both exactness fingerprints of the durable identity. *)

type cli_walk_outcome =
  | Cli_no_slots
      (* Nothing declared — the caller keeps its pre-cli behaviour. *)
  | Cli_summary
      (* A cli slot answered; the summary is completed and delivered. *)
  | Cli_settled
      (* Every cli slot failed and the entry was quarantined under the last
         cli identity. Nothing left for the caller to settle. *)
  | Cli_fell_back
      (* The walk could not take over (release/bind persistence refused);
         the pre-cli binding state is intact, so the caller settles exactly
         as it would have without cli slots. *)

let cli_prompt ~context_bundle =
  canonical_output_contract () ^ "\n\n" ^ Yojson.Safe.to_string context_bundle
;;

let try_cli_slots
      ~queue_ops
      ~cli_runner
      ~(bound : exact_identity option)
      (prepared : prepared_flow)
      ~on_summary
  =
  match prepared.cli_slots with
  | [] -> Cli_no_slots
  | slots ->
    let entry = prepared.entry in
    let base_dir = entry.Keeper_approval_queue_rules_types.audit_base_path in
    let prompt = cli_prompt ~context_bundle:prepared.context_bundle in
    let prompt_sha = Digestif.SHA256.(digest_string prompt |> to_hex) in
    let quarantine_cause_of_failure = function
      | Keeper_lane_cli_oneshot.Invalid_json_output _ -> Exact_domain_invalid_output
      | Keeper_lane_cli_oneshot.Not_an_official_client _
      | Keeper_lane_cli_oneshot.Execution_failed _ -> Exact_flow_execution_failed
    in
    let release identity =
      match release_exact_attempt queue_ops entry identity with
      | Ok { write_outcome = Fsync_completed; _ } -> Ok ()
      | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } -> Error detail
      | Error error ->
        Error (Keeper_approval_queue.exact_attempt_error_to_string error)
    in
    let rec walk ~bound ~released_entry_binding ~last_cli_failure = function
      | [] ->
        (match bound, last_cli_failure with
         | Some identity, Some failure ->
           (* The last failed cli slot is still Exact_dispatch_uncertain, so
              the entry settles through the ordinary quarantine transition
              under the identity that actually failed. *)
           record_outcome Cli_slots_exhausted;
           log_exact_error
             entry
             "cli lane-slot walk"
             (Keeper_lane_cli_oneshot.failure_to_string failure);
           quarantine_identity
             ~queue_ops
             entry
             identity
             (quarantine_cause_of_failure failure);
           Cli_settled
         | Some identity, None ->
           (* Unreachable by construction: [bound] becomes [Some] only for a
              cli identity whose run already recorded a failure, and a
              success returns before the walk recurses. Treat it as the
              exhausted case with an execution cause rather than hiding it
              under a wildcard. *)
           record_outcome Cli_slots_exhausted;
           quarantine_identity ~queue_ops entry identity Exact_flow_execution_failed;
           Cli_settled
         | None, (Some _ | None) ->
           if released_entry_binding
           then (
             (* The walk released the caller's exhausted binding and then no
                cli slot managed to bind: the pre-cli state is gone, so the
                caller's quarantine (which requires that binding) would be
                rejected. Settle the entry here instead. *)
             record_outcome Cli_released_without_binding;
             settle_current_or_signal
               ~queue_ops
               entry
               ~reason:
                 "HITL cli lane-slot walk released the exhausted binding but \
                  no cli slot bound"
               ~cause:Exact_flow_execution_failed;
             Cli_settled)
           else (
             (* Nothing was released and nothing bound: the pre-cli state is
                intact and the caller's ordinary settlement still applies. *)
             record_outcome Cli_walk_fell_back;
             Cli_fell_back))
      | runtime_id :: rest ->
        (* Rebind discipline: whatever is bound (the exhausted HTTP candidate
           or the previous cli slot) is released before the next identity
           binds — the same release-then-bind step the HTTP walk performs. *)
        let released_entry_binding = released_entry_binding || Option.is_some bound in
        (match
           match bound with
           | None -> Ok ()
           | Some identity -> release identity
         with
         | Error detail ->
           record_outcome Cli_release_unconfirmed;
           log_exact_error entry "cli slot release" detail;
           (* The release did not confirm, so the caller's binding may or may
              not remain; the caller's own settlement copes with either (its
              quarantine raises a typed rejection at worst on a state it can
              no longer see). Nothing cli-owned exists yet. *)
           Cli_fell_back
         | Ok () ->
           let identity =
             { slot_id = runtime_id
             ; call_id = Random_id.prefixed ~prefix:"cli-hitl-" ~bytes:16
             ; plan_fingerprint = "cli-oneshot:" ^ prompt_sha
             ; request_body_sha256 = prompt_sha
             }
           in
           (match bind_exact_attempt queue_ops entry identity with
            | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
              record_outcome Cli_bind_unconfirmed;
              log_exact_error entry "cli slot bind" detail;
              (* The binding may not be durable; walking on without a durable
                 identity would detach the dispatch from the queue record. *)
              Cli_fell_back
            | Error error ->
              record_outcome Cli_bind_failed;
              log_exact_error
                entry
                "cli slot bind"
                (Keeper_approval_queue.exact_attempt_error_to_string error);
              (* This slot never bound; the previous binding was already
                 released, so continue the walk with nothing bound. *)
              walk ~bound:None ~released_entry_binding ~last_cli_failure rest
            | Ok { write_outcome = Fsync_completed; _ } ->
              queue_ops.after_bind ();
              (match
                 Keeper_lane_cli_oneshot.run
                   ?runner:cli_runner
                   ~base_dir
                   ~runtime_id
                   ~system_prompt:prepared.system_prompt
                   ~requirement:output_requirement
                   ~prompt
                   ()
               with
               | Error failure ->
                 log_exact_error
                   entry
                   "cli slot execution"
                   (Keeper_lane_cli_oneshot.failure_to_string failure);
                 walk
                   ~bound:(Some identity)
                   ~released_entry_binding
                   ~last_cli_failure:(Some failure)
                   rest
               | Ok output ->
                 (match
                    parse_summary
                      ~generated_at:prepared.generated_at
                      ~model_run_id:identity.call_id
                      output
                  with
                  | Error detail ->
                    log_exact_error entry "cli domain validation" detail;
                    walk
                      ~bound:(Some identity)
                      ~released_entry_binding
                      ~last_cli_failure:
                        (Some
                           (Keeper_lane_cli_oneshot.Invalid_json_output
                              { runtime_id; detail }))
                      rest
                  | Ok summary ->
                    (match complete_exact_attempt queue_ops entry identity summary with
                     | Ok { write_outcome = Fsync_completed; _ } ->
                       record_outcome Ok_summary_cli;
                       on_summary summary;
                       Cli_summary
                     | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
                       record_outcome Terminal_sync_unconfirmed;
                       (* Raises: the surrounding execution boundary treats an
                          unconfirmed terminal write as persistence
                          uncertainty, same as the HTTP completion path. *)
                       signal_terminalization_persistence_failure
                         entry
                         "cli completion sync"
                         detail
                     | Error error when exact_attempt_source_resolved entry error ->
                       record_outcome Source_resolved;
                       Cli_settled
                     | Error (Exact_attempt_rejected rejection) ->
                       raise (Exact_terminalization_rejected rejection)
                     | Error (Exact_attempt_storage_error error) ->
                       record_outcome Terminal_persistence_failure;
                       log_exact_error
                         entry
                         "cli completion"
                         (Keeper_approval_queue.storage_error_to_string error);
                       quarantine_identity
                         ~queue_ops
                         entry
                         identity
                         Exact_terminal_persistence_failure;
                       Cli_settled)))))
    in
    walk ~bound ~released_entry_binding:false ~last_cli_failure:None slots
;;

let execute_prepared_flow_with_queue_ops_current
      ~queue_ops
      ?cli_runner
      ~net
      ?clock
      ~on_summary
      (prepared : prepared_flow)
  =
  let bound_candidate = ref None in
  let guarded_before_dispatch candidate =
    let* () =
      match !bound_candidate with
      | None -> Ok ()
      | Some previous ->
        let identity = exact_identity_of_candidate previous in
        (match release_exact_attempt queue_ops prepared.entry identity with
         | Ok { write_outcome = Fsync_completed; _ } ->
           bound_candidate := None;
           Ok ()
         | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
           Error (Exact_release_sync_unconfirmed detail)
         | Error error ->
           Error (Exact_release_failed error))
    in
    let* () = before_dispatch ~queue_ops prepared.entry candidate in
    bound_candidate := Some candidate;
    queue_ops.after_bind ();
    Ok ()
  in
  let guarded_before_advance ~failed ~next =
    let* () = before_advance ~queue_ops prepared.entry ~failed ~next in
    (match failed with
     | Exact_output.Flow_candidate_rejected _ -> ()
     | Exact_output.Flow_candidate_execution_failed _ ->
       bound_candidate := None);
    Ok ()
  in
  try
    match
      Exact_output.execute_flow_once
        ~net
        ?clock
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_dispatch:guarded_before_dispatch
        ~before_advance:guarded_before_advance
        ~validate:(validate_success prepared)
        prepared.attempt
    with
    | Ok success ->
      handle_validated_success
        ~queue_ops
        prepared
        ~on_summary
        success.transport_success
        success.accepted;
      Executed
    | Error
        (Exact_output.Flow_execution_terminal
           { cause = (Exact_output.Flow_candidates_exhausted _ as cause); _ }) ->
      (match !bound_candidate with
       | Some candidate ->
         (match
            try_cli_slots
              ~queue_ops
              ~cli_runner
              ~bound:(Some (exact_identity_of_candidate candidate))
              prepared
              ~on_summary
          with
          | Cli_summary | Cli_settled -> ()
          | Cli_no_slots | Cli_fell_back ->
            record_outcome Domain_invalid_output;
            quarantine_candidate
              ~queue_ops
              prepared.entry
              candidate
              Exact_domain_invalid_output)
       | None ->
         (match
            try_cli_slots ~queue_ops ~cli_runner ~bound:None prepared ~on_summary
          with
          | Cli_summary | Cli_settled -> ()
          | Cli_no_slots | Cli_fell_back ->
            handle_flow_error ~queue_ops prepared cause));
      Executed
    | Error
        (Exact_output.Flow_execution_terminal
           { cause =
               Exact_output.Flow_exact_execution_failed { candidate; _ } as cause
           ; _
           }) ->
      (* The last candidate failed post-dispatch with no successor left —
         provider exhaustion in a different coat (a single-slot lane lands
         here, never in Flow_candidates_exhausted). Infrastructure causes
         (callback/measurement failures) stay below: a cli slot answers for
         missing providers, not for a broken flow. *)
      (match
         try_cli_slots
           ~queue_ops
           ~cli_runner
           ~bound:(Some (exact_identity_of_candidate candidate))
           prepared
           ~on_summary
       with
       | Cli_summary | Cli_settled -> ()
       | Cli_no_slots | Cli_fell_back ->
         handle_flow_error ~queue_ops prepared cause);
      Executed
    | Error (Exact_output.Flow_execution_terminal { cause; _ }) ->
      handle_flow_error ~queue_ops prepared cause;
      Executed
    | Error
        (Exact_output.Flow_semantic_candidates_exhausted
           { rejections; _ }) ->
      (* The rejected candidate is still bound Exact_dispatch_uncertain (the
         semantic reject happens after dispatch, before any advance), which
         is exactly the state the cli walk's release-then-bind step expects. *)
      let bound =
        rejections
        |> last_semantic_rejection
        |> fun rejection ->
        rejection.transport_success
        |> Exact_output.flow_success_candidate
        |> exact_identity_of_candidate
      in
      (match
         try_cli_slots ~queue_ops ~cli_runner ~bound:(Some bound) prepared ~on_summary
       with
       | Cli_summary | Cli_settled -> ()
       | Cli_no_slots | Cli_fell_back ->
         handle_semantic_exhaustion ~queue_ops prepared rejections);
      Executed
  with
  | Eio.Cancel.Cancelled _ as cancellation ->
    let cancellation_backtrace = Printexc.get_raw_backtrace () in
    let cancelled_uncertain detail =
      (match mark_persistence_uncertain prepared.entry with
       | Ok _ -> ()
       | Error marker_error ->
         log_exact_error
           prepared.entry
           "cancellation uncertainty observation"
           (Keeper_approval_queue.exact_attempt_error_to_string marker_error));
      raise
        (Cancelled_uncertain
           (cancellation, cancellation_backtrace, detail))
    in
    let settlement =
      try
        Eio.Cancel.protect
        @@ fun () ->
        record_outcome Cancellation;
        (match
           settle_current
             ~queue_ops
             prepared.entry
             ~reason:"HITL exact-output flow was cancelled"
             ~cause:Exact_cancellation
         with
        | Ok () ->
          Cancellation_settled
        | Error error ->
          Cancellation_exact_settlement_failed error)
      with
      | exn ->
        Cancellation_settlement_raised
          ("cancellation settlement raised: " ^ Printexc.to_string exn)
    in
    (match settlement with
     | Cancellation_settled ->
       Printexc.raise_with_backtrace cancellation cancellation_backtrace
     | Cancellation_exact_settlement_failed
         (Exact_settlement_identity_unbound _) ->
       (match persist_identity_unbound prepared.entry with
        | Ok () ->
          raise
            (Cancelled_identity_unbound
               (cancellation, cancellation_backtrace))
        | Error `Transition_not_applied ->
          raise
            (Cancelled_identity_unbound
               (cancellation, cancellation_backtrace))
        | Error (`Rejected rejection) ->
          raise
            (Cancelled_exact_rejected
               (cancellation, cancellation_backtrace, rejection))
        | Error (`Storage_failed marker_detail) ->
          cancelled_uncertain marker_detail)
     | Cancellation_exact_settlement_failed
         (Exact_settlement_persistence_failed detail)
     | Cancellation_settlement_raised detail ->
       record_outcome Cancellation_settlement_failed;
       log_exact_error
         prepared.entry
         "cancellation terminalization persistence"
         detail;
       cancelled_uncertain detail
     | Cancellation_exact_settlement_failed
         (Exact_settlement_rejected rejection) ->
       raise
         (Cancelled_exact_rejected
            (cancellation, cancellation_backtrace, rejection)))
  | Exact_terminalization_persistence_failed _ as persistence_failure ->
    raise persistence_failure
  | Exact_terminalization_rejected rejection ->
    record_outcome Terminal_rejected;
    log_exact_error
      prepared.entry
      "terminalization rejected"
      (Keeper_approval_queue.exact_attempt_error_to_string
         (Exact_attempt_rejected rejection));
    Exact_rejection_blocked rejection
  | Exact_terminalization_identity_unbound _ ->
    Identity_unbound_blocked
  | exn ->
    let detail = Printexc.to_string exn in
    record_outcome Crashed;
    log_exact_error prepared.entry "worker crash" detail;
    let settlement =
      Eio.Cancel.protect
      @@ fun () ->
      settle_current
        ~queue_ops
        prepared.entry
        ~reason:("HITL exact-output worker crashed: " ^ detail)
        ~cause:Exact_terminal_persistence_failure
    in
    (match settlement with
     | Ok () -> Executed
     | Error (Exact_settlement_identity_unbound detail) ->
       (match persist_identity_unbound prepared.entry with
        | Ok () ->
          record_outcome Identity_unbound;
          log_exact_error prepared.entry "terminalization blocked" detail;
          Identity_unbound_blocked
        | Error `Transition_not_applied ->
          Identity_unbound_blocked
        | Error (`Rejected rejection) ->
          raise (Exact_terminalization_rejected rejection)
        | Error (`Storage_failed marker_detail) ->
          signal_terminalization_persistence_failure
            prepared.entry
            "identity-unbound observation"
            marker_detail)
     | Error (Exact_settlement_persistence_failed detail) ->
       signal_terminalization_persistence_failure
         prepared.entry
         "crash terminalization persistence"
         detail
     | Error (Exact_settlement_rejected rejection) ->
       raise (Exact_terminalization_rejected rejection))
;;

let execute_prepared_flow_with_queue_ops
      ~queue_ops
      ?cli_runner
      ~net
      ?clock
      ~on_summary
      (prepared : prepared_flow)
  =
  execute_prepared_flow_with_queue_ops_current
    ~queue_ops
    ?cli_runner
    ~net
    ?clock
    ~on_summary
    prepared
;;

let execute_prepared_flow ~net ?clock ~on_summary prepared =
  execute_prepared_flow_with_queue_ops
    ~queue_ops:production_exact_queue_ops
    ~net
    ?clock
    ~on_summary
    prepared
;;

type finish_outcome =
  | Conclusive_terminalization
  | Terminalization_persistence_uncertain
  | Terminalization_identity_unbound
  | Terminalization_rejected

type spawn_outcome =
  | Worker_forked

let spawn_with
      ~queue_ops
      ?cli_runner
      ~prepare_flow
      ~sw
      ~(entry : pending_approval)
      ~on_summary
      ~on_finish
      ()
  =
  let* net =
    Eio_context.get_net_opt ()
    |> Option.to_result
         ~none:"HITL exact-output flow: Eio net is unavailable"
  in
  match prepare_flow ~entry with
  | Error detail -> Error detail
  | Ok prepared ->
    let clock = Eio_context.get_clock_opt () in
    let registry = Exact_lane_run_registry.global () in
    let run_id = Random_id.prefixed ~prefix:"exact-hitl-judge-" ~bytes:16 in
    let started_at = Time_compat.now () in
    let observed_summary = ref None in
    let observed_outcome = ref None in
    let selected_slot = ref None in
    let bind
          ~id
          ~input_hash
          ~sequence
          ~slot_id
          ~call_id
          ~plan_fingerprint
          ~request_body_sha256
      =
      let result =
        queue_ops.bind
          ~id
          ~input_hash
          ~sequence
          ~slot_id
          ~call_id
          ~plan_fingerprint
          ~request_body_sha256
      in
      (match result with
       | Ok { write_outcome = Fsync_completed; _ } ->
         selected_slot := Some slot_id
       | Ok { write_outcome = Visible_sync_unconfirmed _; _ } | Error _ -> ());
      result
    in
    let release_before_dispatch
          ~id
          ~input_hash
          ~sequence
          ~slot_id
          ~call_id
          ~plan_fingerprint
          ~request_body_sha256
      =
      let result =
        queue_ops.release_before_dispatch
          ~id
          ~input_hash
          ~sequence
          ~slot_id
          ~call_id
          ~plan_fingerprint
          ~request_body_sha256
      in
      (match result with
       | Ok { write_outcome = Fsync_completed; _ } -> selected_slot := None
       | Ok { write_outcome = Visible_sync_unconfirmed _; _ } | Error _ -> ());
      result
    in
    (* These wrappers only retain the durable binding selected by the existing
       queue authority. They do not choose a candidate or alter settlement. *)
    let observed_queue_ops = { queue_ops with bind; release_before_dispatch } in
    let on_summary summary =
      observed_summary := Some summary;
      on_summary summary
    in
    Exact_lane_run_registry.register_running
      registry
      ~run_id
      ~lane:Exact_lane_run_registry.Hitl_auto_judge
      ~actor:entry.keeper_name
      ~started_at
      ~input:
        (Exact_lane_run_registry.Exact_input
           (`Assoc
           [ "tool_name", `String entry.tool_name
           ; "tool_input", entry.input
           ; ( "request_context"
             , match entry.request_context with
               | Some context -> context
               | None -> `Null )
           ; "turn_id", Json_util.int_opt_to_json entry.turn_id
           ; "task_id", Json_util.string_opt_to_json entry.task_id
           ; "goal_id", Json_util.string_opt_to_json entry.goal_id
                  ; "partial_context", `Bool (Option.is_none entry.request_context)
           ]));
    let complete outcome output =
      match
        Exact_lane_run_registry.mark_completed
          registry
          ~run_id
          ~outcome
          ~elapsed_s:(Time_compat.now () -. started_at)
          ~selected_slot:!selected_slot
          ~output
      with
      | Ok () -> ()
      | Error error ->
        Log.Keeper.error
          ~keeper_name:entry.keeper_name
          "HITL exact-run observation completion failed run_id=%s: %s"
          run_id
          (Exact_lane_run_registry.completion_error_to_string error)
    in
    Eio.Fiber.fork ~sw (fun () ->
    let execution_outcome =
      with_outcome_sink observed_outcome
      @@ fun () ->
      try
        match
          execute_prepared_flow_with_queue_ops
            ~queue_ops:observed_queue_ops
            ?cli_runner
            ~net
            ?clock
            ~on_summary
            prepared
        with
        | Executed -> `Completed
        | Identity_unbound_blocked -> `Identity_unbound
        | Exact_rejection_blocked rejection -> `Rejected rejection
      with
      | Cancelled_identity_unbound
          (cancellation, cancellation_backtrace) ->
        `Cancelled_identity_unbound
          (cancellation, cancellation_backtrace)
      | Cancelled_exact_rejected
          (cancellation, cancellation_backtrace, rejection) ->
        `Cancelled_rejected
          (cancellation, cancellation_backtrace, rejection)
      | Cancelled_uncertain (cancellation, cancellation_backtrace, detail) ->
        `Cancelled_uncertain
          (cancellation, cancellation_backtrace, detail)
      | Eio.Cancel.Cancelled _ as cancellation ->
        `Cancelled (cancellation, Printexc.get_raw_backtrace ())
      | Exact_terminalization_persistence_failed _ as uncertainty ->
        `Uncertain uncertainty
      | Exact_terminalization_rejected rejection ->
        `Rejected rejection
      | exn -> `Uncertain exn
    in
    match execution_outcome with
    | `Completed ->
      (* The flow can reach here without ever producing a summary: when every
         candidate is rejected, [Flow_semantic_candidates_exhausted] routes to
         [handle_semantic_exhaustion], which quarantines the candidate and
         returns [Executed] like a judged run. Recording [Succeeded] with a
         synthesised output made a run that judged nothing indistinguishable
         from one that did, and the .mli already says a summary reaches
         [on_summary] only after validation, provenance and fsync. So the
         absence of one is the failure, and the outcome type has a variant for
         it.

         [on_finish] is unchanged: whether an exhausted flow should still
         permit draining later owner work is a separate contract question. *)
      let outcome, output = run_outcome_of_observed_summary
          ~last_outcome:!observed_outcome
          !observed_summary in
      complete outcome output;
      on_finish Conclusive_terminalization
    | `Cancelled (cancellation, cancellation_backtrace) ->
      complete Exact_lane_run_registry.Cancelled `Null;
      on_finish Terminalization_persistence_uncertain;
      Printexc.raise_with_backtrace cancellation cancellation_backtrace
    | `Cancelled_uncertain
        (cancellation, cancellation_backtrace, _detail) ->
      complete Exact_lane_run_registry.Cancelled `Null;
      on_finish Terminalization_persistence_uncertain;
      Printexc.raise_with_backtrace cancellation cancellation_backtrace
    | `Cancelled_identity_unbound
        (cancellation, cancellation_backtrace) ->
      complete Exact_lane_run_registry.Cancelled `Null;
      on_finish Terminalization_identity_unbound;
      Printexc.raise_with_backtrace cancellation cancellation_backtrace
    | `Cancelled_rejected
        (cancellation, cancellation_backtrace, _rejection) ->
      complete Exact_lane_run_registry.Cancelled `Null;
      on_finish Terminalization_rejected;
      Printexc.raise_with_backtrace cancellation cancellation_backtrace
    | `Identity_unbound ->
      complete
        (Exact_lane_run_registry.Failed
           { code = "terminalization_identity_unbound"
           ; detail = "exact attempt identity was not durably bound"
           })
        `Null;
      on_finish Terminalization_identity_unbound
    | `Rejected rejection ->
      let detail =
        Keeper_approval_queue.exact_attempt_error_to_string
          (Exact_attempt_rejected rejection)
      in
      complete
        (Exact_lane_run_registry.Failed
           { code = "terminalization_rejected"; detail })
        `Null;
      on_finish Terminalization_rejected
    | `Uncertain uncertainty ->
      complete
        (Exact_lane_run_registry.Failed
           { code = "terminalization_persistence_uncertain"
           ; detail = Printexc.to_string uncertainty
           })
        `Null;
      on_finish Terminalization_persistence_uncertain;
      raise uncertainty);
    Ok Worker_forked
;;

let spawn ~sw ~entry ~on_summary ~on_finish () =
  (* Eta-expanded so the cli-runner injection stays a test-surface knob:
     production always spawns the real official client. *)
  spawn_with
    ~queue_ops:production_exact_queue_ops
    ~prepare_flow
    ~sw
    ~entry
    ~on_summary
    ~on_finish
    ()
;;

module For_testing = struct
  let with_outcome_sink = with_outcome_sink
  let run_outcome_of_observed_summary = run_outcome_of_observed_summary

  type nonrec prepared_flow = prepared_flow
  type nonrec exact_transition = exact_transition
  type nonrec exact_completion_transition = exact_completion_transition
  type nonrec exact_quarantine_transition = exact_quarantine_transition
  type nonrec exact_queue_ops = exact_queue_ops

  let build_context_bundle = build_context_bundle
  let parse_summary = parse_summary
  let prepare_flow = prepare_flow
  let execute_prepared_flow = execute_prepared_flow

  let make_exact_queue_ops
        ?(bind = production_exact_queue_ops.bind)
        ?(release_before_dispatch =
          production_exact_queue_ops.release_before_dispatch)
        ?(complete = production_exact_queue_ops.complete)
        ?(quarantine = production_exact_queue_ops.quarantine)
        ?(after_bind = production_exact_queue_ops.after_bind)
        ()
    =
    create_exact_queue_ops
      ~bind
      ~release_before_dispatch
      ~complete
      ~quarantine
      ~after_bind
  ;;

  let execute_prepared_flow_with_queue_ops
        ~queue_ops
        ?cli_runner
        ~net
        ?clock
        ~on_summary
        prepared
    =
    execute_prepared_flow_with_queue_ops
      ~queue_ops
      ?cli_runner
      ~net
      ?clock
      ~on_summary
      prepared
  ;;

  let spawn_with_queue_ops
        ~queue_ops
        ?cli_runner
        ~sw
        ~entry
        ~on_summary
        ~on_finish
        ()
    =
    spawn_with
      ~queue_ops
      ?cli_runner
      ~prepare_flow
      ~sw
      ~entry
      ~on_summary
      ~on_finish
      ()
  ;;

  let flow_evidence prepared = Exact_output.flow_attempt_evidence prepared.attempt
  let system_prompt = system_prompt
  let summary_version = summary_version
  let lane_id = lane_id
end
;;
