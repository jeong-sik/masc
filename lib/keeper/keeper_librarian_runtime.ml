(** Runtime adapter for LLM-owned current Memory OS selection. *)

module Exact_output = Agent_sdk.Exact_output

let exact_lane_id = "librarian_exact"

let input_trace_id (inp : Keeper_librarian.input) =
  Ids.Turn_ref.trace_id inp.turn_ref
;;

let cadence_turns () =
  Env_config.KeeperMemoryOs.librarian_cadence_turns ()
;;

let cadence_mu = Eio.Mutex.create ()
let cadence_counters : (string, string * int) Hashtbl.t = Hashtbl.create 16
let fresh_counter = -1

let cadence_step ~cadence ~counter =
  if cadence <= 1
  then 0, true
  else if counter < 0
  then cadence, true
  else (
    let next = counter + 1 in
    if next >= cadence then cadence, true else next, false)
;;

let cadence_step_keyed ~cadence ~current_trace ~prior =
  let counter =
    match prior with
    | Some (trace, counter) when String.equal trace current_trace -> counter
    | Some _ | None -> fresh_counter
  in
  let updated, due = cadence_step ~cadence ~counter in
  (current_trace, updated), due
;;

let cadence_due ~keeper_id ~trace_id =
  Eio_guard.with_mutex cadence_mu (fun () ->
    let prior = Hashtbl.find_opt cadence_counters keeper_id in
    let value, due =
      cadence_step_keyed
        ~cadence:(cadence_turns ())
        ~current_trace:trace_id
        ~prior
    in
    Hashtbl.replace cadence_counters keeper_id value;
    due)
;;

let cadence_record_success ~keeper_id ~trace_id =
  Eio_guard.with_mutex cadence_mu (fun () ->
    Hashtbl.replace cadence_counters keeper_id (trace_id, 0))
;;

let cadence_record_attempt ~keeper_id ~trace_id =
  Eio_guard.with_mutex cadence_mu (fun () ->
    Hashtbl.replace cadence_counters keeper_id (trace_id, 0))
;;

let cadence_counter_entries () =
  Eio_guard.with_mutex_ro cadence_mu (fun () ->
    Hashtbl.length cadence_counters)
;;

let max_messages () =
  Env_config.KeeperMemoryOs.librarian_max_messages ()
;;

let prompt_max_messages () =
  max_messages () * cadence_turns ()
;;

let select_recent_messages ~max_messages messages =
  let max_messages = max 0 max_messages in
  let drop_count = max 0 (List.length messages - max_messages) in
  let rec drop remaining = function
    | messages when remaining <= 0 -> messages
    | [] -> []
    | _ :: rest -> drop (remaining - 1) rest
  in
  drop drop_count messages
;;

let message role text =
  Agent_sdk.Types.make_message ~role [ Agent_sdk.Types.Text text ]
;;

type exact_setup_error =
  | Exact_registry_unavailable of Runtime_exact_output_registry.publication_error
  | Exact_lane_unavailable of Runtime_exact_output_registry.lane_resolution_error
  | Exact_candidate_invalid of
      { position : int
      ; slot_id : string
      }
  | Exact_flow_snapshot_failed of Exact_output.flow_snapshot_error
  | Exact_flow_start_failed of Exact_output.flow_start_error

type outward_effect =
  | No_outward_effect
  | Outward_effect_started

type exact_execution_error =
  { outward_effect : outward_effect
  ; detail : string
  }

type extraction_error =
  | Prompt_render_failed of string
  | Execution_clock_unavailable
  | Exact_setup_failed of exact_setup_error
  | Exact_execution_failed of exact_execution_error
  | Domain_output_invalid of string
  | Memory_snapshot_write_failed of string

type extraction_error_kind =
  | Prompt_render_failure
  | Execution_clock_unavailable
  | Exact_setup_failure
  | Exact_execution_failure
  | Domain_output_invalid
  | Memory_snapshot_write_failure

let extraction_error_kind = function
  | Prompt_render_failed _ -> Prompt_render_failure
  | Execution_clock_unavailable -> Execution_clock_unavailable
  | Exact_setup_failed _ -> Exact_setup_failure
  | Exact_execution_failed _ -> Exact_execution_failure
  | Domain_output_invalid _ -> Domain_output_invalid
  | Memory_snapshot_write_failed _ -> Memory_snapshot_write_failure
;;

let exact_setup_error_to_string = function
  | Exact_registry_unavailable error ->
    "exact registry unavailable: "
    ^ Runtime_exact_output_registry.publication_error_to_string error
  | Exact_lane_unavailable error ->
    Runtime_exact_output_registry.lane_resolution_error_to_string error
  | Exact_candidate_invalid { position; slot_id } ->
    Printf.sprintf
      "exact lane candidate invalid position=%d slot=%S"
      position
      slot_id
  | Exact_flow_snapshot_failed
      (Exact_output.Duplicate_flow_candidate_id
         { candidate_id; first_position; duplicate_position }) ->
    Printf.sprintf
      "exact flow duplicate candidate id=%S first_position=%d duplicate_position=%d"
      candidate_id
      first_position
      duplicate_position
  | Exact_flow_start_failed
      (Exact_output.Flow_id_generation_failed detail) ->
    "exact flow identity allocation failed: " ^ detail
;;

let extraction_error_to_string = function
  | Prompt_render_failed detail -> detail
  | Execution_clock_unavailable ->
    "memory os librarian execution clock unavailable"
  | Exact_setup_failed error -> exact_setup_error_to_string error
  | Exact_execution_failed { outward_effect; detail } ->
    Printf.sprintf
      "librarian exact execution failed outward_effect=%s cause=%s"
      (match outward_effect with
       | No_outward_effect -> "none"
       | Outward_effect_started -> "started")
      detail
  | Domain_output_invalid detail ->
    "librarian domain output invalid: " ^ detail
  | Memory_snapshot_write_failed detail ->
    "memory os current snapshot write failed: " ^ detail
;;

let should_record_cadence_backoff_after_error = function
  | Exact_execution_failed { outward_effect = Outward_effect_started; _ }
  | Domain_output_invalid _ ->
    true
  | Exact_execution_failed { outward_effect = No_outward_effect; _ }
  | Execution_clock_unavailable
  | Prompt_render_failed _
  | Exact_setup_failed _
  | Memory_snapshot_write_failed _ ->
    false
;;

let render_prompt key variables =
  match Prompt_registry.render_prompt_template key variables with
  | Ok text ->
    let text = String.trim text in
    if String.equal text ""
    then Error (Printf.sprintf "%s rendered empty prompt" key)
    else Ok text
  | Error message -> Error (Printf.sprintf "%s: %s" key message)
;;

let messages_and_input_for_librarian (inp : Keeper_librarian.input) =
  let input =
    { inp with
      messages =
        select_recent_messages
          ~max_messages:(prompt_max_messages ())
          inp.messages
    }
  in
  let open Result.Syntax in
  (* One asset, one message: the librarian's role statement lives at the top
     of the selection prompt it is rendered with, so there is no second file
     to keep in step. *)
  let+ user =
    render_prompt
      Keeper_prompt_names.librarian
      (Keeper_librarian.prompt_variables input)
  in
  input, [ message Agent_sdk.Types.User user ]
;;

let messages_for_librarian inp =
  Result.map snd (messages_and_input_for_librarian inp)
;;

let flow_candidates selected_slots =
  let rec loop position acc = function
    | [] -> Ok (List.rev acc)
    | (slot : Runtime_exact_output_registry.selected_slot) :: rest ->
      (match
         Exact_output.make_flow_candidate
           ~id:slot.slot_id
           ~admitted_target:slot.admitted_target
       with
       | Ok candidate -> loop (position + 1) (candidate :: acc) rest
       | Error Exact_output.Blank_flow_candidate_id ->
         Error
           (Exact_candidate_invalid
              { position
              ; slot_id = slot.slot_id
              }))
  in
  loop 0 [] selected_slots
;;

let prepare_attempt messages =
  let open Result.Syntax in
  let* registry =
    Runtime_exact_output_registry.current ()
    |> Result.map_error (fun error ->
      Exact_setup_failed (Exact_registry_unavailable error))
  in
  let* resolved =
    Runtime_exact_output_registry.resolve_lane registry ~lane_id:exact_lane_id
    |> Result.map_error (fun error ->
      Exact_setup_failed (Exact_lane_unavailable error))
  in
  let* candidates =
    flow_candidates resolved.selected_slots
    |> Result.map_error (fun error -> Exact_setup_failed error)
  in
  match candidates with
  | [] ->
    Error
      (Exact_setup_failed
         (Exact_lane_unavailable
            (No_admitted_lane_slots { lane_id = exact_lane_id })))
  | first :: rest ->
    let requirement =
      Exact_output.make_output_requirement
        ~schema:Keeper_structured_output_schema.librarian_current_output_schema
        ~minimum_guarantee:Exact_output.Json_syntax
    in
    let* snapshot =
      Exact_output.snapshot_flow ~first ~rest ~messages requirement
      |> Result.map_error (fun error ->
        Exact_setup_failed (Exact_flow_snapshot_failed error))
    in
    Exact_output.start_flow snapshot
    |> Result.map_error (fun error ->
      Exact_setup_failed (Exact_flow_start_failed error))
;;

let exact_execution_error error =
  let outward_effect =
    match Exact_output.flow_execution_error_generation_dispatch error with
    | Exact_output.No_generation_dispatch -> No_outward_effect
    | Exact_output.Generation_dispatch_started -> Outward_effect_started
  in
  (* The static labels stay as prefixes (existing log greps keep working);
     the payload each branch carries — failing slot, typed cause, raw provider
     body, flow journey — is rendered after them instead of being discarded. *)
  let detail =
    match error with
    | Exact_output.Flow_attempt_already_started _ ->
      "attempt_already_started"
    | Flow_attempt_start_failed _ ->
      "attempt_start_failed"
    | Flow_measurement_start_failed _ ->
      "measurement_start_failed"
    | Flow_candidates_exhausted { rejection; evidence } ->
      Printf.sprintf
        "candidates_exhausted: %s"
        (Keeper_exact_flow_detail.candidates_exhausted_detail
           ~rejection
           ~evidence)
    | Flow_before_measurement_dispatch_callback_failed _
    | Flow_measurement_terminal_callback_failed _
    | Flow_before_dispatch_callback_failed _
    | Flow_before_advance_callback_failed _ ->
      "unexpected_callback_failure"
    | Flow_exact_execution_failed { candidate; cause; evidence } ->
      Printf.sprintf
        "oas_execution_failed: %s"
        (Keeper_exact_flow_detail.execution_failure_detail
           ~candidate
           ~cause
           ~evidence)
  in
  { outward_effect; detail }
;;

let extract_with_exact_output_classified
      ?clock
      ~net
      (inp : Keeper_librarian.input)
  : (Keeper_librarian.selection, extraction_error) result
  =
  let open Result.Syntax in
  match clock with
  | None -> Error Execution_clock_unavailable
  | Some clock ->
    let* selected_input, messages =
      messages_and_input_for_librarian inp
      |> Result.map_error (fun detail -> Prompt_render_failed detail)
    in
    let* attempt = prepare_attempt messages in
    let validate flow_success =
      let output = Exact_output.flow_success_output flow_success in
      match
        Keeper_librarian.selection_of_json_result
          selected_input
          output.output
      with
      | Ok selection -> Exact_output.Accept selection
      | Error error -> Exact_output.Reject_and_advance error
    in
    (match
       Exact_output.execute_flow_once
         ~net
         ~clock
         ~before_measurement_dispatch:(fun _ -> Ok ())
         ~on_measurement_terminal:(fun _ -> Ok ())
         ~before_dispatch:(fun _ -> Ok ())
         ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
         ~validate
         attempt
     with
     | Ok success -> Ok success.accepted
     | Error (Exact_output.Flow_execution_terminal { cause; _ }) ->
       Error (Exact_execution_failed (exact_execution_error cause))
     | Error
         (Exact_output.Flow_semantic_candidates_exhausted
            { rejections; _ }) ->
       let rejection =
         List.fold_left
           (fun _ rejection -> rejection)
           rejections.first
           rejections.rest
       in
       Error
         (Domain_output_invalid
            (Keeper_librarian.parse_error_to_string rejection.rejection)))
;;

let extract_and_commit_with_exact_output_classified
      ?clock
      ~net
      ~keepers_dir
      ~keeper_id
      ~expected_revision
      inp
  =
  let open Result.Syntax in
  let* selection =
    extract_with_exact_output_classified ?clock ~net inp
  in
  Keeper_memory_os_current.replace
    ?clock
    ~dropped_statements:selection.dropped
    ~keepers_dir
    ~keeper_id
    ~expected_revision
    ~now:(Time_compat.now ())
    ~source:
      { kind = Keeper_memory_os_current.Librarian
      ; trace_id = input_trace_id inp
      ; generation = inp.generation
      }
    ~facts:selection.facts
    ()
  |> Result.map_error (fun detail ->
    Memory_snapshot_write_failed detail)
;;

(* A failure while no current snapshot exists means the keeper is running
   memoryless and cannot leave that state on its own — that is an ERROR,
   not a WARN. With a snapshot present the previous memory keeps serving
   recall and the failure only stales it. Both the classified [Error] path
   and the exception catch in [run_best_effort] route through this rule so
   an exception cannot demote a starving keeper's failure back to WARN. *)
let log_failure_with_snapshot_severity ~keepers_dir ~keeper_id detail =
  let snapshot_absent =
    match
      Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id
    with
    | Ok (Some _) -> false
    | Ok None | Error _ -> true
  in
  let message =
    Printf.sprintf
      "%s current_snapshot=%s"
      detail
      (if snapshot_absent then "absent" else "present")
  in
  if snapshot_absent
  then Log.Keeper.error ~keeper_name:keeper_id "%s" message
  else Log.Keeper.warn ~keeper_name:keeper_id "%s" message
;;

let run_best_effort
      ~keepers_dir
      ~keeper_id
      ~expected_revision
      (inp : Keeper_librarian.input)
  =
  let trace_id = input_trace_id inp in
  if cadence_due ~keeper_id ~trace_id
  then (
    try
      match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
      | Some net, Some clock ->
        (match
           extract_and_commit_with_exact_output_classified
             ~clock
             ~net
             ~keepers_dir
             ~keeper_id
             ~expected_revision
             inp
         with
         | Ok snapshot ->
           cadence_record_success ~keeper_id ~trace_id;
           Log.Keeper.info
             ~keeper_name:keeper_id
             "memory os librarian committed current snapshot revision=%d facts=%d added=%d removed=%d"
             snapshot.revision
             (List.length snapshot.facts)
             (List.length snapshot.change.added)
             (List.length snapshot.change.removed)
         | Error error ->
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string MemoryOsLibrarianFailures)
             ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
             ();
           let deferred = should_record_cadence_backoff_after_error error in
           if deferred then cadence_record_attempt ~keeper_id ~trace_id;
           log_failure_with_snapshot_severity
             ~keepers_dir
             ~keeper_id
             (Printf.sprintf
                "memory os librarian failed lane=%s: %s; cadence deferred=%b"
                exact_lane_id
                (extraction_error_to_string error)
                deferred))
      | _ ->
        Log.Keeper.warn
          ~keeper_name:keeper_id
          "memory os librarian skipped: Eio net/clock context unavailable lane=%s"
          exact_lane_id
    with
    | Eio.Cancel.Cancelled _ as error -> raise error
    | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string MemoryOsLibrarianFailures)
        ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
        ();
      log_failure_with_snapshot_severity
        ~keepers_dir
        ~keeper_id
        (Printf.sprintf
           "memory os librarian failed lane=%s: %s"
           exact_lane_id
           (Printexc.to_string exn)))
;;
