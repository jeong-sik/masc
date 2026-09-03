(** Runtime adapter for LLM-owned current Memory OS selection. *)

module Exact_output = Agent_core.Exact_output

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

let prompt_input_for_librarian ?max_messages (inp : Keeper_librarian.input) =
  let max_messages =
    match max_messages with
    | Some max_messages -> max_messages
    | None -> prompt_max_messages ()
  in
  { inp with
    messages =
      select_recent_messages
        ~max_messages
        inp.messages
  ; counterpart_observations =
      select_recent_messages
        ~max_messages
        inp.counterpart_observations
  }
;;

let message role text =
  Agent_core.Types.make_message ~role [ Agent_core.Types.Text text ]
;;

type exact_setup_error =
  | Exact_registry_unavailable of Runtime_exact_output_registry.publication_error
  | Exact_lane_unavailable of Runtime_exact_output_registry.lane_resolution_error
  | Exact_lane_preference_unavailable of string
  | Exact_candidate_invalid of
      { position : int
      ; slot_id : string
      }
  | Exact_flow_snapshot_failed of Exact_output.flow_snapshot_error
  | Exact_flow_start_failed of Exact_output.flow_start_error
  | Exact_input_over_budget of { slot_id : string }
    (** Even the librarian's fixed material (template, keeper instructions,
        current facts) with zero conversation messages exceeds this admitted
        slot's request-body limit — nothing left to shrink. *)
  | Exact_request_projection_failed of { slot_id : string }
    (** The pre-flight request-body projection itself failed for this slot;
        distinct from over-budget, which is a measured size verdict. *)

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
  | Memory_snapshot_write_failed of
      { detail : string
      ; selected_slot : string
      }

let extraction_error_kind : extraction_error -> Keeper_memory_os_current.librarian_failure_kind
  = function
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
  | Exact_lane_preference_unavailable detail ->
    "exact lane preference unavailable: " ^ detail
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
  | Exact_input_over_budget { slot_id } ->
    Printf.sprintf
      "librarian prompt exceeds slot request-body limit even with zero \
       conversation messages slot=%s"
      slot_id
  | Exact_request_projection_failed { slot_id } ->
    Printf.sprintf
      "librarian request-body projection failed for slot=%s"
      slot_id
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
  | Memory_snapshot_write_failed { detail; selected_slot = _ } ->
    "memory os current snapshot write failed: " ^ detail
;;

let selected_slot_of_extraction_error = function
  | Memory_snapshot_write_failed { selected_slot; _ } -> Some selected_slot
  | Prompt_render_failed _
  | Execution_clock_unavailable
  | Exact_setup_failed _
  | Exact_execution_failed _
  | Domain_output_invalid _ ->
    None
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

let render_librarian_prompt input =
  render_prompt
    Prompt_names.librarian
    (Keeper_librarian.prompt_variables input)
;;

type librarian_prompt_material =
  { resolution : Prompt_registry.prompt_resolution
  ; rendered : string
  }

let resolve_librarian_prompt input =
  let variables = Keeper_librarian.prompt_variables input in
  ( variables
  , Result.map
      (fun (resolution, rendered) -> { resolution; rendered })
      (Prompt_registry.resolve_and_render_prompt_template
         Prompt_names.librarian
         variables) )
;;

let prompt_and_input_for_librarian (inp : Keeper_librarian.input) =
  let input = prompt_input_for_librarian inp in
  let open Result.Syntax in
  (* One asset, one message: the librarian's role statement lives at the top
     of the selection prompt it is rendered with, so there is no second file
     to keep in step. *)
  let+ prompt =
    render_librarian_prompt input
  in
  input, prompt
;;

let messages_and_input_for_librarian inp =
  Result.map
    (fun (input, prompt) -> input, [ message Agent_core.Types.User prompt ])
    (prompt_and_input_for_librarian inp)
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

let librarian_output_requirement =
  Exact_output.make_output_requirement
    ~schema:Keeper_structured_output_schema.librarian_current_output_schema
    ~minimum_guarantee:Exact_output.Json_syntax
;;

(* Pre-flight size discipline for the exact Librarian lane. The librarian's input
   scales linearly with conversation text and previously had no byte bound at
   all (only a 72-message COUNT cap), so an oversized prompt failed at the
   provider, cost a full round-trip, and with a single admitted slot had
   nowhere to advance (lane audit W1/W2, live p50 132s). Message count is the
   shrink axis: dropping older messages only removes prompt bytes, so the
   serialized size is monotone in the count and binary search applies. *)
let prompt_fits_all_slots ~selected_slots messages =
  let rec loop = function
    | [] -> Ok true
    | (slot : Runtime_exact_output_registry.selected_slot) :: rest ->
      (match
         Exact_output.project_request_body
           ~target:slot.admitted_target
           ~messages
           librarian_output_requirement
       with
       | Error _ ->
         Error
           (Exact_setup_failed
              (Exact_request_projection_failed { slot_id = slot.slot_id }))
       | Ok projection ->
         if projection.Exact_output.within_limit then loop rest else Ok false)
  in
  loop selected_slots
;;

(* [render_at k] renders the prompt with both message lists trimmed to the
   newest [k] entries and returns it as the flow's message list. Returns the
   fitted messages plus [Some k] when the full prompt had to shrink, so the
   caller can record that the observed registration input and the dispatched
   prompt differ. *)
let fitted_messages ~selected_slots ~full_messages ~render_at =
  let open Result.Syntax in
  let* full_fits = prompt_fits_all_slots ~selected_slots full_messages in
  if full_fits
  then Ok (full_messages, None)
  else (
    let full = prompt_max_messages () in
    let rec search best low high =
      if low > high
      then
        match best with
        | Some (messages, count) -> Ok (messages, Some count)
        | None ->
          let slot_id =
            match selected_slots with
            | (slot : Runtime_exact_output_registry.selected_slot) :: _ ->
              slot.slot_id
            | [] -> exact_lane_id
          in
          Error (Exact_setup_failed (Exact_input_over_budget { slot_id }))
      else (
        let midpoint = low + ((high - low) / 2) in
        let* messages = render_at midpoint in
        let* fits = prompt_fits_all_slots ~selected_slots messages in
        if fits
        then search (Some (messages, midpoint)) (midpoint + 1) high
        else search best low (midpoint - 1))
    in
    search None 0 (max 0 (full - 1)))
;;

let resolve_librarian_slots ~base_path ~keeper_id =
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
  let* resolved =
    Keeper_exact_lane_preference.apply
      ~base_path
      ~keeper_name:keeper_id
      ~lane_id:exact_lane_id
      resolved
    |> Result.map_error (fun detail ->
      Exact_setup_failed
        (Exact_lane_preference_unavailable detail))
  in
  Ok
    ( resolved.Runtime_exact_output_registry.selected_slots
    , resolved.Runtime_exact_output_registry.cli_slots )
;;

let prepare_attempt ~selected_slots messages =
  let open Result.Syntax in
  let* candidates =
    flow_candidates selected_slots
    |> Result.map_error (fun error -> Exact_setup_failed error)
  in
  match candidates with
  | [] ->
    Error
      (Exact_setup_failed
         (Exact_lane_unavailable
            (No_admitted_lane_slots { lane_id = exact_lane_id })))
  | first :: rest ->
    let* snapshot =
      Exact_output.snapshot_flow ~first ~rest ~messages librarian_output_requirement
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
        "agent_core_execution_failed: %s"
        (Keeper_exact_flow_detail.execution_failure_detail
           ~candidate
           ~cause
           ~evidence)
  in
  { outward_effect; detail }
;;

(* The librarian's whole prompt is one User message; the cli one-shot needs
   that text back out of the fitted list. Anything else is a structural
   drift this lane has never produced, so the walk is skipped with a log
   rather than inventing an input. *)
let cli_prompt_of_messages ~keeper_id (messages : Agent_core.Types.message list) =
  match messages with
  | [ { Agent_core.Types.content = [ Agent_core.Types.Text prompt ]; _ } ] ->
    Some prompt
  | messages ->
    Log.Keeper.warn
      ~keeper_name:keeper_id
      "librarian cli fallback skipped: fitted prompt is not one text message \
       (%d messages)"
      (List.length messages);
    None
;;

let try_cli_slots
      ~keeper_id
      ~base_path
      ~cli_runner
      ~cli_slots
      ~(selected_input : Keeper_librarian.input)
      ~messages
  =
  match cli_slots with
  | [] -> None
  | cli_slots ->
    (match cli_prompt_of_messages ~keeper_id messages with
     | None -> None
     | Some prompt ->
       (match
          Keeper_lane_cli_oneshot.walk
            ?runner:cli_runner
            ~base_dir:base_path
            ~cli_slots
            ~system_prompt:""
            ~requirement:librarian_output_requirement
            ~prompt
            ()
        with
        | Error failures ->
          List.iter
            (fun failure ->
               Log.Keeper.warn
                 ~keeper_name:keeper_id
                 "librarian cli lane-slot failed: %s"
                 (Keeper_lane_cli_oneshot.failure_to_string failure))
            failures;
          None
        | Ok (runtime_id, output) ->
          (match Keeper_librarian.selection_of_json_result selected_input output with
           | Ok selection -> Some (runtime_id, selection, output)
           | Error error ->
             Log.Keeper.warn
               ~keeper_name:keeper_id
               "librarian cli output invalid slot=%s: %s"
               runtime_id
               (Keeper_librarian.parse_error_to_string error);
             None)))
;;

let execute_exact_output_classified
      ?cli_runner
      ~clock
      ~net
      ~base_path
      ~keeper_id
      ~(selected_input : Keeper_librarian.input)
      ~messages
      ~render_at
      ()
  =
  let open Result.Syntax in
  let* selected_slots, cli_slots = resolve_librarian_slots ~base_path ~keeper_id in
  let* messages, fitted_message_count =
    fitted_messages ~selected_slots ~full_messages:messages ~render_at
  in
  let* attempt = prepare_attempt ~selected_slots messages in
  let validate flow_success =
    let output = Exact_output.flow_success_output flow_success in
    match
      Keeper_librarian.selection_of_json_result
        selected_input
        output.output
    with
    | Ok selection -> Exact_output.Accept (selection, output.output)
    | Error error -> Exact_output.Reject_and_advance error
  in
  match
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
  | Ok success ->
    let selected_slot =
      success.transport_success
      |> Exact_output.flow_success_candidate
      |> fun candidate -> candidate.visit.identity.candidate_id
    in
    Ok (success.accepted, selected_slot, fitted_message_count)
  | Error (Exact_output.Flow_execution_terminal { cause; _ }) ->
    let terminal () = Error (Exact_execution_failed (exact_execution_error cause)) in
    (* Only provider exhaustion may fall back to the cli walk; the
       infrastructure causes keep their terminal (RFC
       cli-runtimes-as-lane-slots, same split as the other lanes). *)
    (match cause with
     | Exact_output.Flow_candidates_exhausted _
     | Exact_output.Flow_exact_execution_failed _ ->
       (match
          try_cli_slots
            ~keeper_id
            ~base_path
            ~cli_runner
            ~cli_slots
            ~selected_input
            ~messages
        with
        | Some (runtime_id, selection, output) ->
          Ok ((selection, output), runtime_id, fitted_message_count)
        | None -> terminal ())
     | Exact_output.Flow_attempt_already_started _
     | Exact_output.Flow_attempt_start_failed _
     | Exact_output.Flow_measurement_start_failed _
     | Exact_output.Flow_before_measurement_dispatch_callback_failed _
     | Exact_output.Flow_measurement_terminal_callback_failed _
     | Exact_output.Flow_before_dispatch_callback_failed _
     | Exact_output.Flow_before_advance_callback_failed _ -> terminal ())
  | Error
      (Exact_output.Flow_semantic_candidates_exhausted
         { rejections; _ }) ->
    let rejection =
      List.fold_left
        (fun _ rejection -> rejection)
        rejections.first
        rejections.rest
    in
    (match
       try_cli_slots
         ~keeper_id
         ~base_path
         ~cli_runner
         ~cli_slots
         ~selected_input
         ~messages
     with
     | Some (runtime_id, selection, output) ->
       Ok ((selection, output), runtime_id, fitted_message_count)
     | None ->
       Error
         (Domain_output_invalid
            (Keeper_librarian.parse_error_to_string rejection.rejection)))
;;

(* A failure while no current snapshot exists means the keeper is running
   memoryless and cannot leave that state on its own — that is an ERROR,
   not a WARN. With a snapshot present the previous memory keeps serving
   recall and the failure only stales it. Both the classified [Error] path
   and the exception catch in [run_best_effort] route through this rule so
   an exception cannot demote a starving keeper's failure back to WARN. *)
(* A failed pass leaves no snapshot, so the commit journal line never runs and
   the attempt would otherwise exist only as a log line and an in-memory
   counter — neither survives a process restart, which is what made #26729
   undiagnosable from disk afterwards. Every failure path routes here so the
   log severity and the recorded line resolve snapshot presence from the same
   read and cannot disagree about one instant. *)
let record_failure ~keepers_dir ~keeper_id ~trace_id ~kind ~detail ~cadence_deferred =
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
  else Log.Keeper.warn ~keeper_name:keeper_id "%s" message;
  Keeper_memory_os_current.append_librarian_failure
    ~keepers_dir
    ~keeper_id
    ~now:(Time_compat.now ())
    ~trace_id
    ~kind
    ~detail
    ~snapshot_present:(not snapshot_absent)
    ~cadence_deferred
;;

let current_selection_registry_summary = function
  | None -> `Assoc [ "present", `Bool false; "fact_count", `Int 0 ]
  | Some (current : Keeper_librarian.current_selection) ->
    `Assoc
      [ "present", `Bool true
      ; "fact_count", `Int (List.length current.facts)
      ]
;;

let prompt_material_payload = function
  | Ok ({ resolution; rendered } : librarian_prompt_material) ->
    `Assoc
      [ "key", `String Prompt_names.librarian
      ; "source", `String resolution.source
      ; ( "file_path"
        , match resolution.file_path with
          | None -> `Null
          | Some path -> `String path )
      ; "effective_template", `String resolution.effective
      ; "rendered_bytes", `Int (String.length rendered)
      ; ( "rendered_sha256"
        , `String Digestif.SHA256.(digest_string rendered |> to_hex) )
      ]
  | Error detail ->
    `Assoc
      [ "key", `String Prompt_names.librarian
      ]
;;

let exact_input_payload
      (inp : Keeper_librarian.input)
      ~(prompt_variables : (string * string) list)
      (prompt_material : (librarian_prompt_material, string) result)
  =
  `Assoc
    [ "turn_ref", Ids.Turn_ref.to_yojson inp.turn_ref
    ; "keeper_instructions", `String inp.keeper_instructions
    ; "prompt", prompt_material_payload prompt_material
    ; ( "rendered_prompt_variables"
      , `Assoc
          (List.map
             (fun (name, value) -> name, `String value)
             prompt_variables) )
    ]
;;

let completed_output
      ~(inp : Keeper_librarian.input)
      ~exact_output
      (snapshot : Keeper_memory_os_current.t)
  =
  `Assoc
    [ "exact_output", exact_output
    ; "before", current_selection_registry_summary inp.current
    ; ( "after"
      , `Assoc
          [ "revision", `Int snapshot.revision
          ; "updated_at", `Float snapshot.updated_at
          ; "fact_count", `Int (List.length snapshot.facts)
          ; ( "change"
            , `Assoc
                [ "added_count", `Int (List.length snapshot.change.added)
                ; "removed_count", `Int (List.length snapshot.change.removed)
                ; "retained", `Int snapshot.change.retained
                ] )
          ] )
    ]
;;

let failed_output = `Assoc []
;;

let run_best_effort
      ?cli_runner
      ~base_path
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
        let registry = Exact_lane_run_registry.global () in
        let run_id = Random_id.prefixed ~prefix:"librarian-exact-" ~bytes:16 in
        let started_at = Time_compat.now () in
        let started_at_monotonic = Eio.Time.now clock in
        let current_fact_count =
          match inp.current with
          | None -> 0
          | Some current -> List.length current.facts
        in
        let prompt_input = prompt_input_for_librarian inp in
        let prompt_variables, prompt_material =
          resolve_librarian_prompt prompt_input
        in
        Exact_lane_run_registry.register_running
          registry
          ~run_id
          ~lane:Exact_lane_run_registry.Librarian
          ~actor:keeper_id
          ~started_at
          ~input:
            (Exact_lane_run_registry.Exact_input
               (`Assoc
                  [ "actual_input", exact_input_payload prompt_input ~prompt_variables
                      prompt_material
                  ; "message_count", `Int (List.length prompt_input.messages)
                  ; "current_fact_count", `Int current_fact_count
                  ]));
        let complete ?selected_slot outcome output =
          let elapsed_s = Eio.Time.now clock -. started_at_monotonic in
          let completion =
            Exact_lane_run_registry.mark_completed
              registry
              ~run_id
              ~outcome
              ~elapsed_s
              ~selected_slot
              ~output
          in
          match completion with
          | Ok () -> ()
          | Error error ->
            Log.Keeper.error
              ~keeper_name:keeper_id
              "librarian exact-run observation completion failed run_id=%s: %s"
              run_id
              (Exact_lane_run_registry.completion_error_to_string error)
        in
        (try
           let result =
             let open Result.Syntax in
             let* prompt =
               prompt_material
               |> Result.map (fun material -> material.rendered)
               |> Result.map_error (fun detail -> Prompt_render_failed detail)
             in
             let render_at max_messages =
               let shrunk = prompt_input_for_librarian ~max_messages inp in
               match render_librarian_prompt shrunk with
               | Ok rendered ->
                 Ok [ message Agent_core.Types.User rendered ]
               | Error detail -> Error (Prompt_render_failed detail)
             in
             let* (selection, exact_output), selected_slot, fitted_message_count
               =
               execute_exact_output_classified
                 ?cli_runner
                 ~clock
                 ~net
                 ~base_path
                 ~keeper_id
                 ~selected_input:prompt_input
                 ~messages:[ message Agent_core.Types.User prompt ]
                 ~render_at
                 ()
             in
             (match fitted_message_count with
              | None -> ()
              | Some count ->
                Log.Keeper.info
                  ~keeper_name:keeper_id
                  "librarian prompt shrunk to fit slot request-body limits \
                   messages=%d (registered input shows the full material)"
                  count);

             (* The decision goes to the store, not the whole set it projects
                to. [selection.facts] is that projection, taken against the
                snapshot this pass read before its provider turn; writing it
                required nothing to have changed since, and a keeper recording
                one fact of its own in that window ended the pass (masc
                #32859). The decision itself has no such requirement: a fact it
                never mentions is one it never saw. *)
             let+ snapshot =
               Keeper_memory_os_current.apply_disposition
               ~clock
               ~dropped_statements:selection.dropped
               ~keepers_dir
               ~keeper_id
               ~now:(Time_compat.now ())
               ~source:
                 { kind = Keeper_memory_os_current.Librarian
                 ; trace_id = input_trace_id inp
                 }
               ~retained_memory_ids:selection.retained_memory_ids
               ~new_claims:selection.new_claims
               ()
             |> Result.map_error (fun detail ->
               Memory_snapshot_write_failed { detail; selected_slot })
             in
             snapshot, exact_output, selected_slot
           in
           match result with
           | Ok (snapshot, exact_output, selected_slot) ->
             complete
               ~selected_slot
               Exact_lane_run_registry.Succeeded
               (completed_output ~inp ~exact_output snapshot);
             cadence_record_success ~keeper_id ~trace_id;
             Log.Keeper.info
               ~keeper_name:keeper_id
               "memory os librarian committed current snapshot revision=%d facts=%d added=%d removed=%d"
               snapshot.revision
               (List.length snapshot.facts)
               (List.length snapshot.change.added)
               (List.length snapshot.change.removed)
           | Error error ->
             let detail = extraction_error_to_string error in
             complete
               ?selected_slot:(selected_slot_of_extraction_error error)
               (Exact_lane_run_registry.Failed
                  { code = "librarian_failed"
                  ; (* The registry row is what the standalone-lanes dashboard
                       and the TUI surface, so it carries the same typed cause
                       the operator log line does. The fixed "inspect the
                       operator logs" sentence here made all 138 live failures
                       on 2026-08-27..28 indistinguishable while the causes
                       (domain-contract violations vs provider execution
                       failures) sat one WARN line away. *)
                    detail
                  })
               failed_output;
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string MemoryOsLibrarianFailures)
               ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
               ();
             (* Every failure defers the next pass by the full cadence. The
                old split re-ran the "safe to retry" classes (setup, prompt
                render, no-outward-effect execution, snapshot write) on EVERY
                subsequent turn, because a due pass leaves the counter at the
                cadence value — but those classes are exactly the ones that
                tend to persist (an unpublished registry, a broken template),
                so the lane burned its heaviest prompt each turn for as long
                as the condition lasted. A three-turn delay on recovery is
                the cheaper side of that trade. *)
             cadence_record_attempt ~keeper_id ~trace_id;
             record_failure
               ~keepers_dir
               ~keeper_id
               ~trace_id
               ~kind:(extraction_error_kind error)
               ~detail:
                 (Printf.sprintf
                    "memory os librarian failed lane=%s: %s"
                    exact_lane_id
                    detail)
               ~cadence_deferred:true
         with
         (* A cancelled pass reached the lane registry and stopped there, so the
            journal — the record of what the librarian did on this keeper —
            showed the same silence for a pass killed mid-flight as for a turn
            on which the librarian never ran. Measured live on 2026-08-07: 11
            of 23 completed librarian lane runs cancelled, none of them
            represented in the journal.

            The write runs under [Eio.Cancel.protect] because the surrounding
            context is already cancelled; without it the append would be
            cancelled in turn and record nothing, which is the failure it
            exists to close. *)
         | Eio.Cancel.Cancelled _ as exn ->
           complete
             Exact_lane_run_registry.Cancelled
             failed_output;
           Eio.Cancel.protect (fun () ->
             record_failure
               ~keepers_dir
               ~keeper_id
               ~trace_id
               ~kind:Keeper_memory_os_current.Lane_cancelled
               ~detail:
                 (Printf.sprintf
                    "memory os librarian cancelled lane=%s before commit"
                    exact_lane_id)
                 (* Cancellation is not the pass declining its own turn, so the
                    cadence counter remains due. A later turn can schedule a
                    new pass, but it does not replay this immutable input;
                    graceful lifecycle boundaries therefore drain accepted
                    work instead of cancelling it. *)
               ~cadence_deferred:false);
           raise exn
         | exn ->
           complete
             (Exact_lane_run_registry.Failed
                { code = "librarian_raised"
                ; detail =
                    "Librarian raised; inspect the operator logs and Memory journal"
                })
             failed_output;
           raise exn)
      (* Missing Eio context is a failed pass like any other: the keeper's
         memory does not advance. It was previously a bare WARN with no record,
         which hid a restart-shaped outage behind the same silence as a healthy
         idle turn. *)
      | _ ->
        record_failure
          ~keepers_dir
          ~keeper_id
          ~trace_id
          ~kind:Keeper_memory_os_current.Runtime_context_unavailable
          ~detail:
            (Printf.sprintf
               "memory os librarian skipped: Eio net/clock context unavailable lane=%s"
               exact_lane_id)
          ~cadence_deferred:false
    with
    | Eio.Cancel.Cancelled _ as error -> raise error
    | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string MemoryOsLibrarianFailures)
        ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
        ();
      record_failure
        ~keepers_dir
        ~keeper_id
        ~trace_id
        ~kind:Keeper_memory_os_current.Unhandled_exception
        ~detail:
          (Printf.sprintf
             "memory os librarian failed lane=%s: %s"
             exact_lane_id
             (Printexc.to_string exn))
        ~cadence_deferred:false)
;;

module For_testing = struct
  type classified_error = extraction_error

  let classified_error_detail = extraction_error_to_string
  let execute_exact_output_classified = execute_exact_output_classified
end
