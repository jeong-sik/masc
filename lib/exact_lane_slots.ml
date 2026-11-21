module Exact = Agent_core.Exact_output
module Oneshot = Keeper_lane_cli_oneshot
module Registry = Runtime_exact_output_registry
module Provider_admission = Llm_provider.Provider_admission

type t =
  | Http_slot of Registry.selected_slot
  | Cli_slot of
      { runtime_id : string
      ; runtime : Runtime_instance.t option
      }

let of_resolved_lane (resolved : Registry.resolved_lane) =
  List.map (fun slot -> Http_slot slot) resolved.selected_slots
  @ List.map
      (fun runtime_id -> Cli_slot { runtime_id; runtime = Runtime.get_runtime_by_id runtime_id })
      resolved.cli_slots
;;

let id = function
  | Http_slot (slot : Registry.selected_slot) -> slot.slot_id
  | Cli_slot { runtime_id; runtime = _ } -> runtime_id
;;

let kind = function
  | Http_slot (_ : Registry.selected_slot) -> Exact_lane_walk.Http
  | Cli_slot { runtime_id = _; runtime = _ } -> Exact_lane_walk.Cli
;;

let quota_scope_of = function
  | Http_slot (slot : Registry.selected_slot) ->
    Option.map
      (fun (observation : Registry.runtime_observation) -> observation.quota_scope)
      slot.runtime_observation
  | Cli_slot { runtime; runtime_id = _ } ->
    Option.map Runtime_instance.quota_scope_of_runtime runtime
;;

(* Both kinds keep their rest on this cell, and the next order reads it
   (RFC section 3.5). An HTTP visit writes it through
   [Runtime_exact_lane_backpressure.observe]; a CLI visit writes it through
   [note_rate_limit] and [note_candidate_success]. A change to one writer
   changes when a slot of the other kind rests, so the two change together. *)
let candidate_backpressure_of = function
  | Http_slot (slot : Registry.selected_slot) ->
    Option.map
      (fun (observation : Registry.runtime_observation) -> observation.candidate)
      slot.runtime_observation
  | Cli_slot { runtime; runtime_id = _ } ->
    Option.map (fun (runtime : Runtime_instance.t) -> runtime.candidate_backpressure) runtime
;;

let is_official_client (runtime : Runtime_instance.t) =
  match Runtime_execution.checkpoint_owner runtime.execution with
  | Runtime_execution.Official_client -> true
  | Runtime_execution.Masc_agent_core -> false
;;

let provider_id (runtime : Runtime_instance.t) = runtime.provider.Runtime_schema.id

let account_scheduler runtime =
  if is_official_client runtime
  then Runtime_official_client_seats.scheduler ~provider_id:(provider_id runtime)
  else None
;;

let seats ~admission_class = function
  | Http_slot (slot : Registry.selected_slot) ->
    (match Exact.target_seats ~admission_class slot.admitted_target with
     | Ok source -> Exact_lane_walk.Seats_of source
     | Error (_ : Exact.target_selection_error) -> Exact_lane_walk.Seatless)
  | Cli_slot { runtime = None; runtime_id = _ } -> Exact_lane_walk.Seatless
  | Cli_slot { runtime = Some runtime; runtime_id = _ } ->
    (match account_scheduler runtime with
     | Some scheduler ->
       Exact_lane_walk.Seats_of (Provider_admission.Scheduler_seats { scheduler; admission_class })
     | None -> Exact_lane_walk.Seatless)
;;

type cli_request =
  { system_prompt : string
  ; prompt : string
  }

type ('accepted, 'rejection) answer =
  | Http_answered of
      { slot_id : string
      ; success : ('accepted, 'rejection) Exact.validated_flow_success
      }
  | Cli_answered of
      { runtime_id : string
      ; accepted : 'accepted
      }

type ('rejection, 'record_error) failure =
  | Http_failed of
      { slot_id : string
      ; error : ('record_error, 'rejection) Exact.validated_flow_error
      }
  | Cli_failed of
      { runtime_id : string
      ; failure : Oneshot.failure
      }
  | Cli_rejected of
      { runtime_id : string
      ; rejection : 'rejection
      }
  | Cli_unfit of { runtime_id : string }
  | Cli_seats_unpublished of
      { runtime_id : string
      ; provider_id : string
      }
  | Http_unfit of
      { slot_id : string
      ; reason : string
      }

type ('rejection, 'record_error) stop =
  | Http_unstartable of
      { slot_id : string
      ; reason : string
      }
  | Http_stopped of
      { slot_id : string
      ; error : ('record_error, 'rejection) Exact.validated_flow_error
      }
  | Record_failed of 'record_error

let rests = function
  | Http_failed { slot_id = _; error = Exact.Flow_execution_terminal { cause; prior_rejections = _ } }
    ->
    (match Exact.flow_execution_binding_standing cause with
     | Exact.Every_binding_resting -> true
     | Exact.Not_every_binding_resting -> false)
  | Http_failed { slot_id = _; error = Exact.Flow_semantic_candidates_exhausted _ } -> false
  | Cli_failed { runtime_id = _; failure } -> Oneshot.refused_for_binding_rest failure
  | Cli_rejected _ | Cli_unfit _ | Cli_seats_unpublished _ -> false
  | Http_unfit _ -> false
;;

(* What a failed slot says about the request, read as the walk receipt reads
   the same failure of a flow or a one-shot. *)
let evidence_of_failure = function
  | Http_failed { slot_id = _; error = Exact.Flow_semantic_candidates_exhausted _ } ->
    Keeper_exact_walk_failure.invalid_output
  | Http_failed
      { slot_id = _; error = Exact.Flow_execution_terminal { cause; prior_rejections } } ->
    let evidence =
      match cause with
      | Exact.Flow_exact_execution_failed { cause = error; candidate = _; evidence = _ } ->
        Keeper_exact_walk_failure.of_cause error.cause
      | Exact.Flow_candidates_exhausted { rejection; evidence = _ } ->
        Keeper_exact_walk_failure.of_disposition
          (Exact.candidate_rejection_disposition rejection)
      (* masc's own failures stop the walk ([visit_http]). Like the walk
         receipt's local stops, they say nothing about the request. *)
      | Exact.Flow_attempt_already_started _
      | Exact.Flow_attempt_start_failed _
      | Exact.Flow_measurement_start_failed _
      | Exact.Flow_before_measurement_dispatch_callback_failed _
      | Exact.Flow_measurement_terminal_callback_failed _
      | Exact.Flow_before_dispatch_callback_failed _
      | Exact.Flow_before_advance_callback_failed _ -> Keeper_exact_walk_failure.empty
    in
    (match prior_rejections with
     | [] -> evidence
     | _ :: _ -> Keeper_exact_walk_failure.with_invalid_output evidence)
  | Cli_failed { runtime_id = _; failure } -> Keeper_exact_walk_failure.of_cli_failure failure
  | Cli_rejected { runtime_id; rejection = _ } ->
    Keeper_exact_walk_failure.of_cli_observation
      (Keeper_exact_walk_failure.cli_invalid_domain_answer ~runtime_id)
  | Cli_unfit { runtime_id = _ } ->
    Keeper_exact_walk_failure.of_local_rejection Keeper_exact_walk_failure.Input_contract
  | Cli_seats_unpublished { runtime_id = _; provider_id = _ } ->
    Keeper_exact_walk_failure.of_local_rejection Keeper_exact_walk_failure.Runtime_unavailable
  | Http_unfit { slot_id = _; reason = _ } ->
    Keeper_exact_walk_failure.of_local_rejection Keeper_exact_walk_failure.Runtime_contract
;;

let failure_evidence passed =
  List.fold_left
    (fun evidence pass ->
       Keeper_exact_walk_failure.combine
         evidence
         (match pass with
          | Exact_lane_walk.Held { slot = (_ : t); until = _ } -> Keeper_exact_walk_failure.held
          | Exact_lane_walk.Seats_full (_ : t) ->
            Keeper_exact_walk_failure.of_local_rejection Keeper_exact_walk_failure.Seats_full
          | Exact_lane_walk.Failed { slot = (_ : t); failure } -> evidence_of_failure failure))
    Keeper_exact_walk_failure.empty
    passed
;;

type ('accepted, 'rejection, 'record_error) walk_result =
  ( t
    , ('accepted, 'rejection) answer
    , ('rejection, 'record_error) failure
    , ('rejection, 'record_error) stop )
    Exact_lane_walk.walk_result

(* Why one candidate could not become a flow: the slot's own declaration, or
   masc failing to give the flow an identity. The first settles only this slot
   (RFC section 3.3 Q1); the second is masc's own failure and ends the walk. *)
type start_refusal =
  | Slot_unfit of string
  | Identity_unavailable of string
;;

let start_one_candidate_flow ~admission_class ~messages ~requirement (slot : Registry.selected_slot)
  =
  match Exact.make_flow_candidate ~id:slot.slot_id ~admitted_target:slot.admitted_target with
  | Error Exact.Blank_flow_candidate_id -> Error (Slot_unfit "the slot has a blank id")
  | Ok first ->
    (match Exact.snapshot_flow ~first ~rest:[] ~messages requirement with
     | Error
         (Exact.Duplicate_flow_candidate_id
           { candidate_id; first_position = _; duplicate_position = _ }) ->
       Error (Slot_unfit ("the slot is named twice: " ^ candidate_id))
     | Ok snapshot ->
       (match Exact.start_flow ~admission_class snapshot with
        | Ok attempt -> Ok attempt
        | Error (Exact.Flow_id_generation_failed detail) -> Error (Identity_unavailable detail)))
;;

let visit_http
      ~net
      ~clock
      ~admission_class
      ~messages
      ~requirement
      ~before_measurement_dispatch
      ~on_measurement_terminal
      ~before_dispatch
      ~validate
      (slot : Registry.selected_slot)
      seat
  =
  match start_one_candidate_flow ~admission_class ~messages ~requirement slot with
  | Error (Slot_unfit reason) -> Exact_lane_walk.Advance (Http_unfit { slot_id = slot.slot_id; reason })
  | Error (Identity_unavailable reason) ->
    Exact_lane_walk.Stop (Http_unstartable { slot_id = slot.slot_id; reason })
  | Ok attempt ->
    let result =
      Exact_lane_slot_capture.flow attempt (fun () ->
        Exact.execute_flow_once
          ?seat
          ~net
          ~clock
          ~before_measurement_dispatch
          ~on_measurement_terminal
          ~before_dispatch
          (* The flow has no next candidate to move to, so it never calls
             this. The walk records the move to the next slot with its own
             [on_advance]. *)
          ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
          ~validate
          attempt)
    in
    (* Every rejection of a one-candidate flow names this slot, so this
       one-slot lane finds the observation of each. *)
    Runtime_exact_lane_backpressure.observe
      ~resolved:{ Registry.selected_slots = [ slot ]; cli_slots = [] }
      result;
    (match result with
     | Ok success -> Exact_lane_walk.Answer (Http_answered { slot_id = slot.slot_id; success })
     | Error (Exact.Flow_semantic_candidates_exhausted _ as error) ->
       Exact_lane_walk.Advance (Http_failed { slot_id = slot.slot_id; error })
     | Error (Exact.Flow_execution_terminal { cause; prior_rejections = _ } as error) ->
       (match Exact.flow_execution_terminal_kind cause with
        | Exact.Advanceable_candidates_exhausted ->
          Exact_lane_walk.Advance (Http_failed { slot_id = slot.slot_id; error })
        | Exact.Non_advanceable_terminal ->
          Exact_lane_walk.Stop (Http_stopped { slot_id = slot.slot_id; error })))
;;

(* Why a CLI slot the walk reached without a seat runs no client. A slot
   the one-shot would refuse by itself is recorded as that refusal. *)
let unservable ~runtime_id runtime =
  let refused failure =
    Exact_lane_slot_capture.cli_not_run failure;
    Cli_failed { runtime_id; failure }
  in
  match runtime with
  | None -> refused (Oneshot.Unknown_runtime { runtime_id })
  | Some runtime ->
    if is_official_client runtime
    then Cli_seats_unpublished { runtime_id; provider_id = provider_id runtime }
    else refused (Oneshot.Not_an_official_client { runtime_id })
;;

let visit_cli
      ?runner
      ~base_dir
      ~requirement
      ~cli_request
      ~validate
      ~before_cli_visit
      ~runtime_id
      ~runtime
      seat
  =
  match seat, runtime with
  (* No seat: [seats] found no runtime, a runtime that is not an official
     client, or an account that published no seats. A seat with no runtime
     does not occur, because [seats] gives a slot without a runtime no seat
     source; it is matched so that every pair is written. *)
  | None, (Some (_ : Runtime_instance.t) | None) | Some (_ : Provider_admission.seat), None ->
    Exact_lane_walk.Advance (unservable ~runtime_id runtime)
  | Some (_ : Provider_admission.seat), Some (runtime : Runtime_instance.t) ->
    (match cli_request with
     | None -> Exact_lane_walk.Advance (Cli_unfit { runtime_id })
     | Some { system_prompt; prompt } ->
       (match before_cli_visit ~runtime_id with
        | Error record_error -> Exact_lane_walk.Stop (Record_failed record_error)
        | Ok () ->
          (match
             Exact_lane_slot_capture.run_cli
               ?runner
               ~base_dir
               ~runtime_id
               ~system_prompt
               ~requirement
               ~prompt
               ()
           with
           | Error failure ->
             (* RFC section 3.5: the client's refusal for its account's
                standing goes in the same cell an HTTP 429 writes. *)
             if Oneshot.refused_for_binding_rest failure
             then
               Runtime_candidate_backpressure.note_rate_limit
                 ~candidate:runtime.candidate_backpressure
                 ~retry_after:None;
             Exact_lane_walk.Advance (Cli_failed { runtime_id; failure })
           | Ok json ->
             Runtime_candidate_backpressure.note_candidate_success
               ~candidate:runtime.candidate_backpressure;
             (match validate json with
              | Ok accepted ->
                Exact_lane_slot_capture.cli_outcome ~slot_id:runtime_id Exact_lane_slot_observation.Accepted;
                Exact_lane_walk.Answer (Cli_answered { runtime_id; accepted })
              | Error rejection ->
                Exact_lane_slot_capture.cli_outcome
                  ~slot_id:runtime_id
                  (Exact_lane_slot_observation.Cli_failed
                     (Keeper_exact_walk_failure.cli_invalid_domain_answer ~runtime_id));
                Exact_lane_walk.Advance (Cli_rejected { runtime_id; rejection })))))
;;

(* What the run's capture keeps of a slot passed without a visit, as the
   walks before this one kept it: a full HTTP slot as a candidate passed for
   its seats, a held CLI slot as the one-shot's held refusal. A held HTTP
   slot was left out before any flow, and a failed slot was recorded by its
   visit. *)
let record_pass = function
  | Exact_lane_walk.Seats_full (Http_slot slot) ->
    Exact_lane_slot_capture.http_not_sent ~slot_id:slot.slot_id Keeper_exact_walk_failure.Seats_full
  | Exact_lane_walk.Held { slot = Cli_slot { runtime_id; runtime = _ }; until } ->
    Exact_lane_slot_capture.cli_not_run (Oneshot.Held { runtime_id; until })
  | Exact_lane_walk.Seats_full (Cli_slot { runtime_id = _; runtime = _ })
  | Exact_lane_walk.Held { slot = Http_slot _; until = _ }
  | Exact_lane_walk.Failed { slot = _; failure = _ } -> ()
;;

let walk
      ?runner
      ~net
      ~clock
      ~base_dir
      ~admission_class
      ~messages
      ~requirement
      ~cli_request
      ~before_measurement_dispatch
      ~on_measurement_terminal
      ~before_dispatch
      ~validate_http
      ~validate_cli
      ~before_cli_visit
      ~on_advance
      slots
  =
  Exact_lane_walk.walk
    ~now:(fun () -> Eio.Time.now clock)
    ~kind
    ~quota_scope_of
    ~candidate_backpressure_of
    ~seats:(seats ~admission_class)
    ~visit:(fun slot seat ->
      match slot with
      | Http_slot http ->
        visit_http
          ~net
          ~clock
          ~admission_class
          ~messages
          ~requirement
          ~before_measurement_dispatch
          ~on_measurement_terminal
          ~before_dispatch
          ~validate:validate_http
          http
          seat
      | Cli_slot { runtime_id; runtime } ->
        visit_cli
          ?runner
          ~base_dir
          ~requirement
          ~cli_request
          ~validate:validate_cli
          ~before_cli_visit
          ~runtime_id
          ~runtime
          seat)
    ~on_advance:(fun ~failed ~next ->
      Result.map_error (fun record_error -> Record_failed record_error) (on_advance ~failed ~next))
    ~on_pass:record_pass
    ~rests
    slots
;;
