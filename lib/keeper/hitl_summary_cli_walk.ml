open Keeper_approval_queue_result
open Keeper_approval_queue_rules_types
open Hitl_summary_flow_outcome
open Hitl_summary_flow_prepare
open Hitl_summary_exact_queue
open Hitl_summary_exact_settlement

let log_cli_slot_failure (entry : pending_approval) failure =
  Log.Keeper.warn
    ~keeper_name:entry.keeper_name
    "HITL exact-output approval_id=%s: %s"
    entry.id
    (Keeper_lane_cli_oneshot.failure_to_string failure)
;;

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
      (* Every cli slot failed or waits for its provider, and the entry was
         settled here: under the last cli identity, under the caller's
         binding when no slot ran, or under a held slot's identity when
         nothing was bound. Nothing left for the caller to settle. *)
  | Cli_fell_back
      (* The walk could not take over (release/bind persistence refused);
         the pre-cli binding state is intact, so the caller settles exactly
         as it would have without cli slots. *)

let cli_prompt ~context_bundle =
  Hitl_judge_original.canonical_output_contract () ^ "\n\n" ^ Yojson.Safe.to_string context_bundle
;;

(* ── Slots whose provider stated a time (RFC-exact-lane-waits-for-a-stated-reset)
   A held slot is a slot refused for its account's rest, minus the call (R5).
   Here a call starts by binding the slot's identity, so a held slot binds
   nothing, and the walk settles as it does after its last call: under the
   last identity it bound, with that slot's failure. When it bound none, a
   quarantine still needs an identity; [settle_held_slot] binds a held slot's
   for that and settles it as the execution failure its refusal would have
   been. *)

let earliest_held = function
  | [] -> None
  | first :: rest ->
    Some
      (List.fold_left
         (fun ((_, earliest_until) as earliest) ((_, until) as held) ->
            if until < earliest_until then held else earliest)
         first
         rest)
;;

let note_slots_held (entry : pending_approval) ~slot_id ~until =
  record_outcome Slots_held;
  Log.Keeper.warn
    ~keeper_name:entry.keeper_name
    "HITL exact-output approval_id=%s: every remaining slot waits for its provider \
     (earliest %s until %s); settled without a call"
    entry.id
    slot_id
    (Masc_domain.iso8601_of_unix_seconds until)
;;

let settle_held_slot ~queue_ops (prepared : prepared_flow) ~slot_id ~until =
  let entry = prepared.entry in
  note_slots_held entry ~slot_id ~until;
  (* Nothing is bound, and a quarantine needs an identity. A held slot sends
     no request, so like a cli one-shot the prompt's sha256 fills both
     fingerprints; the [held:] fingerprint and [held-hitl-] call id keep it
     apart from an identity that dispatched. *)
  let prompt_sha =
    Agent_core_sha256.(
      digest_string (cli_prompt ~context_bundle:prepared.context_bundle) |> to_hex)
  in
  let identity : exact_identity =
    { slot_id
    ; call_id = Random_id.prefixed ~prefix:"held-hitl-" ~bytes:16
    ; plan_fingerprint = "held:" ^ prompt_sha
    ; request_body_sha256 = prompt_sha
    }
  in
  let settle_unbound detail =
    log_exact_error entry "held slot bind" detail;
    settle_current_or_signal
      ~queue_ops
      entry
      ~reason:"HITL held slot could not bind its identity"
      ~cause:Exact_flow_execution_failed
  in
  match bind_exact_attempt queue_ops entry identity with
  | Ok { write_outcome = Fsync_completed; _ } ->
    quarantine_identity ~queue_ops entry identity Exact_flow_execution_failed
  | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } -> settle_unbound detail
  | Error error ->
    settle_unbound (Keeper_approval_queue_result.exact_attempt_error_to_string error)
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
    let prompt_sha = Agent_core_sha256.(digest_string prompt |> to_hex) in
    let quarantine_cause_of_failure = function
      | Keeper_lane_cli_oneshot.Invalid_json_output _
      | Keeper_lane_cli_oneshot.Invalid_domain_output _ -> Exact_domain_invalid_output
      | Keeper_lane_cli_oneshot.Unknown_runtime _
      | Keeper_lane_cli_oneshot.Not_an_official_client _
      | Keeper_lane_cli_oneshot.Execution_failed _
      | Keeper_lane_cli_oneshot.Held _ -> Exact_flow_execution_failed
    in
    let release identity =
      match release_exact_attempt queue_ops entry identity with
      | Ok { write_outcome = Fsync_completed; _ } -> Ok ()
      | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } -> Error detail
      | Error error ->
        Error (Keeper_approval_queue_result.exact_attempt_error_to_string error)
    in
    let rec walk ~bound ~released_entry_binding ~last_cli_failure ~held slots =
      (* A slot whose provider stated a time is set aside by the read that
         finds it and never called; [held] keeps every slot set aside so far
         for the end of the walk. *)
      let { Runtime_candidate_standing.walk = callable; held = held_now } =
        Keeper_lane_cli_oneshot.order_slots slots
      in
      let held = held @ held_now in
      match callable with
      | [] ->
        (match bound, last_cli_failure with
         | Some identity, Some failure ->
           (* The last failed cli slot is still Exact_dispatch_uncertain, so
              the entry settles through the ordinary quarantine transition
              under the identity that actually failed. *)
           record_outcome Cli_slots_exhausted;
           Log.Keeper.warn
             ~keeper_name:entry.keeper_name
             "HITL exact-output CLI candidates exhausted approval_id=%s last_slot=%s"
             entry.id
             identity.slot_id;
           quarantine_identity
             ~queue_ops
             entry
             identity
             (quarantine_cause_of_failure failure);
           Cli_settled
         | Some identity, None ->
           (* No cli slot ran: [bound] becomes a cli identity only together
              with that identity's failure, so this is still the caller's
              binding. The first read set every slot aside as held, and
              their refusals would have quarantined the entry as an execution
              failure; the caller's binding settles that way. With nothing
              held this cannot be reached, and it settles as an exhausted
              walk rather than hiding under a wildcard. *)
           (match earliest_held held with
            | Some (slot_id, until) -> note_slots_held entry ~slot_id ~until
            | None -> record_outcome Cli_slots_exhausted);
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
             match earliest_held held with
             | Some (slot_id, until) ->
               (* Nothing was released and nothing bound, and the slots the
                  walk could not bind or set aside include held ones. Those,
                  called, would have bound and been refused, so the entry
                  settles under a held slot's identity. *)
               settle_held_slot ~queue_ops prepared ~slot_id ~until;
               Cli_settled
             | None ->
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
                (Keeper_approval_queue_result.exact_attempt_error_to_string error);
              (* This slot never bound; the previous binding was already
                 released, so continue the walk with nothing bound. *)
              walk ~bound:None ~released_entry_binding ~last_cli_failure ~held rest
            | Ok { write_outcome = Fsync_completed; _ } ->
              queue_ops.after_bind ();
              (match
                 Exact_lane_slot_capture.run_cli
                   ?runner:cli_runner
                   ~base_dir
                   ~runtime_id
                   ~system_prompt:prepared.system_prompt
                   ~requirement:output_requirement
                   ~prompt
                   ()
               with
               | Error failure ->
                 log_cli_slot_failure entry failure;
                 walk
                   ~bound:(Some identity)
                   ~released_entry_binding
                   ~last_cli_failure:(Some failure)
                   ~held
                   rest
               | Ok output ->
                 (match
                    Hitl_summary_request.parse_summary
                      ~generated_at:prepared.generated_at
                      ~model_run_id:identity.call_id
                      output
                  with
                  | Error detail ->
                    let failure =
                      Keeper_lane_cli_oneshot.Invalid_domain_output
                        { runtime_id; detail }
                    in
                    Exact_lane_slot_capture.cli_outcome ~slot_id:runtime_id
                      (Exact_lane_slot_observation.Cli_failed
                         (Keeper_exact_walk_failure.cli_observation failure));
                    log_cli_slot_failure entry failure;
                    walk
                      ~bound:(Some identity)
                      ~released_entry_binding
                      ~last_cli_failure:(Some failure)
                      ~held
                      rest
                  | Ok summary ->
                    Exact_lane_slot_capture.cli_outcome ~slot_id:runtime_id Accepted;
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
                         (Keeper_approval_queue_result.storage_error_to_string error);
                       quarantine_identity
                         ~queue_ops
                         entry
                         identity
                         Exact_terminal_persistence_failure;
                       Cli_settled)))))
    in
    walk ~bound ~released_entry_binding:false ~last_cli_failure:None ~held:[] slots
;;
