(** Runtime adapter for LLM-owned current Memory OS selection. *)

module Exact_output = Agent_core.Exact_output

let exact_lane_id = "librarian_exact"

let input_trace_id (inp : Keeper_librarian.input) =
  Ids.Turn_ref.trace_id inp.turn_ref
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
  | Exact_request_projection_failed of { slot_id : string; reason : string }
    (** The pre-flight request projection failed for every slot; this names
        the first. The reason names the admission refusal (capability,
        serialization) so the failure is diagnosable from the line alone. *)

type outward_effect =
  | No_outward_effect
  | Outward_effect_started

type exact_execution_error =
  { outward_effect : outward_effect
  ; walk_shows_size : bool
  ; detail : string
  }

type extraction_error =
  | Prompt_render_failed of string
  | Execution_clock_unavailable
  | Exact_setup_failed of exact_setup_error
  | Exact_execution_failed of exact_execution_error
  | Cli_slots_exhausted of
      { prior_error : extraction_error option
      ; failures : Keeper_lane_cli_oneshot.failure list
      }
  | Cli_prompt_unavailable of
      { prior_error : extraction_error option
      }
  | No_transport_declared
  | Domain_output_invalid of string
  | Memory_snapshot_write_failed of
      { detail : string
      ; selected_slot : string
      }

let rec extraction_error_kind : extraction_error -> Keeper_memory_os_current.librarian_failure_kind
  = function
  | Prompt_render_failed _ -> Prompt_render_failure
  | Execution_clock_unavailable -> Execution_clock_unavailable
  | Exact_setup_failed _ -> Exact_setup_failure
  | Exact_execution_failed _ ->
    Exact_execution_failure
  | Cli_slots_exhausted { prior_error = Some error; _ }
  | Cli_prompt_unavailable { prior_error = Some error } ->
    extraction_error_kind error
  | Cli_slots_exhausted { prior_error = None; _ }
  | Cli_prompt_unavailable { prior_error = None } ->
    Exact_execution_failure
  | No_transport_declared -> Exact_setup_failure
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
  | Exact_request_projection_failed { slot_id; reason } ->
    Printf.sprintf
      "librarian request projection failed for slot=%s reason=%s"
      slot_id reason
;;

let rec extraction_error_to_string = function
  | Prompt_render_failed detail -> detail
  | Execution_clock_unavailable ->
    "memory os librarian execution clock unavailable"
  | Exact_setup_failed error -> exact_setup_error_to_string error
  | Exact_execution_failed { outward_effect; detail; _ } ->
    Printf.sprintf
      "librarian exact execution failed outward_effect=%s cause=%s"
      (match outward_effect with
       | No_outward_effect -> "none"
       | Outward_effect_started -> "started")
      detail
  | Cli_slots_exhausted { prior_error; failures } ->
    let cli_detail =
      let summary = "librarian official-client slots exhausted" in
      match failures with
      | [] -> summary
      | _ :: _ ->
        summary ^ ": "
        ^ String.concat "; " (List.map Keeper_lane_cli_oneshot.failure_to_string failures)
    in
    (match prior_error with
     | None -> cli_detail
     | Some error ->
       "API failure: " ^ extraction_error_to_string error ^ "; " ^ cli_detail)
  | Cli_prompt_unavailable { prior_error } ->
    let cli_detail =
      "librarian official-client fallback skipped: fitted prompt is not one text message"
    in
    (match prior_error with
     | None -> cli_detail
     | Some error ->
       "API failure: " ^ extraction_error_to_string error ^ "; " ^ cli_detail)
  | No_transport_declared ->
    "librarian lane declares no API or official-client slots"
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
  | Cli_slots_exhausted _
  | Cli_prompt_unavailable _
  | No_transport_declared
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

(* Completed-history synthesis and pending-input organization own different
   sources and stores. A continuity pass must neither organize nor publish the
   live queue; its source is the exact prepared checkpoint interval. *)
let input_for_continuity continuity (input : Keeper_librarian.input) =
  match continuity with
  | None -> input
  | Some _ -> { input with working_context = Keeper_librarian_context.empty }

let resolve_librarian_prompt ?continuity input =
  let input = input_for_continuity continuity input in
  let variables = Keeper_librarian.prompt_variables input in
  let variables = match continuity with None -> variables | Some prepared ->
    ("continuity", Yojson.Safe.to_string (Keeper_librarian_continuity.prompt_json prepared))
    :: List.remove_assoc "continuity" variables in
  ( variables
  , Result.map
      (fun (resolution, rendered) -> { resolution; rendered })
      (Prompt_registry.resolve_and_render_prompt_template
         Prompt_names.librarian
         variables) )
;;

let prompt_and_input_for_librarian (inp : Keeper_librarian.input) =
  let open Result.Syntax in
  (* One asset, one message: the librarian's role statement lives at the top
     of the selection prompt it is rendered with, so there is no second file
     to keep in step. *)
  let+ prompt =
    render_librarian_prompt inp
  in
  inp, prompt
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

let librarian_output_requirement continuity =
  let schema = match continuity with
    | None -> Keeper_structured_output_schema.librarian_current_output_schema
    | Some _ -> Keeper_structured_output_schema.librarian_continuity_output_schema in
  Exact_output.make_output_requirement ~schema
    ~minimum_guarantee:Exact_output.Json_syntax
;;

(* Pre-flight projection for the exact Librarian lane: each slot's request
   either projects (a capability and serialization admission) or is refused
   outright. Size is not judged here — the provider decides whether it takes
   the body, and the flow's own advance handles a slot failing at dispatch. *)
type slot_projection =
  | Slot_admitted
  | Slot_unusable of string
        (** The projection refused the request outright -- a capability or
            serialization refusal. *)

let slot_reason_pairs ?(sep = "; ") (unusable : (string * string) list) : string =
  String.concat sep
    (List.map (fun (slot_id, reason) -> slot_id ^ ": " ^ reason) unusable)
;;

let project_slot ~requirement ~(slot : Runtime_exact_output_registry.selected_slot) ~messages :
  slot_projection =
  match
    Exact_output.project_request_body
      ~target:slot.admitted_target
      ~messages
      requirement
  with
  | Error error -> Slot_unusable (Exact_output.admission_error_reason error)
  | Ok (_ : Exact_output.request_body_projection) -> Slot_admitted
;;

type preflight_selection =
  { selected_slots : Runtime_exact_output_registry.selected_slot list
  ; unusable : (string * string) list
  }

(* The pre-flight over the ladder: the exact slots this run can use and the
   slots it is without, or the error naming every refusal when no slot
   projects. An empty ladder reports nothing -- the production caller routes
   an empty slot list to the cli lane before it gets here. *)
let preflight_slots ~requirement ~selected_slots ~messages =
  match selected_slots with
  | [] -> Ok { selected_slots = []; unusable = [] }
  | (first : Runtime_exact_output_registry.selected_slot) :: _ ->
    let selected_slots, unusable =
      List.fold_left
        (fun (selected_slots, unusable)
             (slot : Runtime_exact_output_registry.selected_slot) ->
           match project_slot ~requirement ~slot ~messages with
           | Slot_admitted -> slot :: selected_slots, unusable
           | Slot_unusable reason ->
             selected_slots, (slot.slot_id, reason) :: unusable)
        ([], [])
        selected_slots
      |> fun (selected_slots, unusable) ->
      List.rev selected_slots, List.rev unusable
    in
    (match selected_slots with
     | [] ->
       Error
         (Exact_setup_failed
            (Exact_request_projection_failed
               { slot_id = first.slot_id
               ; reason = slot_reason_pairs unusable
               }))
     | _ :: _ -> Ok { selected_slots; unusable })
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

let prepare_attempt ~requirement ~selected_slots messages =
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
      Exact_output.snapshot_flow ~first ~rest ~messages requirement
      |> Result.map_error (fun error ->
        Exact_setup_failed (Exact_flow_snapshot_failed error))
    in
    Exact_output.start_flow snapshot
    |> Result.map_error (fun error ->
      Exact_setup_failed (Exact_flow_start_failed error))
;;

module Http_client = Llm_provider.Http_client

(* A provider error that is not an HTTP refusal, read by its typed kind. Only a
   provider that named the size, an answer the size used up, or a deadline
   (§4.3 counts timeouts among the size failures) moves the width. A transport
   that could not carry the request, a quota, a provider that stopped for a
   reason of its own, or a wiring error meets a smaller range the same way.
   An empty completion counts only when its stop reason names the context
   window or the output budget. *)
let transport_error_shows_size (error : Http_client.http_error) =
  match error with
  (* Exact_output routes every HTTP refusal to [Provider_response_refused],
     whose table is above; this constructor never carries one. *)
  | HttpError _ -> false
  | NetworkError
      { kind =
          ( Connection_refused | Dns_failure | Tls_error | Timeout
          | Local_resource_exhaustion | End_of_file | Unknown )
      ; _
      } -> false
  | TimeoutError { phase; _ } ->
    (match phase with
     | First_token | Wall_clock | Http_operation | Non_streaming_body | Stream_body
     | Stream_idle _ | Provider_step | Cli_stdout_idle | Unknown_timeout -> true
     (* Waiting for a slot or for capacity happens before the request runs. *)
     | Queue | Capacity_backpressure -> false)
  | AcceptRejected _ | ProviderTerminal _ -> false
  | ProviderFailure { kind; _ } ->
    (match kind with
     | Context_overflow _ | Response_body_too_large _ -> true
     | Empty_completion { stop_reason } ->
       (match stop_reason with
        | ContextWindowExceeded | MaxTokens -> true
        | EndTurn | StopToolUse | StopSequence | Refusal | ContentFilter
        | RepetitionTruncation | PauseTurn | Compaction | UnmatchedToolCalls
        | Unknown _ -> false)
     | Capacity_exhausted _ | Hard_quota _ | Capability_mismatch _
     | Cli_policy_invalid _ | Cli_startup_failed _ | Provider_parse_error _
     | Provider_wire_error _ | Provider_reported_error _ | Provider_interrupted
     | Repeating_generation _ | Unknown_provider_failure _ -> false)
;;

(* Whether a failure is evidence that the range's size is what stopped the
   pass. Only such evidence moves the width: a pass that saw none keeps what
   it had, because reading less answers nothing it met.

   Every constructor is listed. A new provider failure kind has to be placed
   here rather than fall into a default. *)
let cause_shows_size (cause : Exact_output.execution_error_cause) =
  match cause with
  | Provider_response_refused { refusal; _ } ->
    (match refusal with
     (* The provider judged the size. Timeout is counted with them by
        RFC-librarian-lifecycle §4.3, and the two that do not say why are read
        toward progress, which is reading less. *)
     | Context_overflow | Input_capacity | Request_body_refused | Timeout
     | Invalid_request | Refusal_body_not_received -> true
     (* The request was taken and the provider could not serve it, or only an
        operator can lift the refusal. A smaller one meets the same wall. *)
     | Rate_limited | Overloaded | Server_error | Network_error
     | Auth_failed | Authorization_refused | Payment_required | Not_found -> false)
  (* An answer that came back unusable is a refused output, which §4.3 counts
     among the failures reading less answers. *)
  | Incomplete_output | Missing_output | Ambiguous_output _
  | Unexpected_output_content | Invalid_json_output | Internal_non_json_output
  | Response_body_deadline_exceeded -> true
  | Completion_failed error -> transport_error_shows_size error
  (* Nothing was judged: this process could not start, time, or match the
     attempt it held. *)
  | Attempt_already_started | Clock_required_for_timeout | Frozen_request_mismatch -> false
;;

(* A candidate the flow turned away before dispatch. One reason is about the
   request's size: the projection did not fit the slot's declared window. The
   rest name the slot or this process -- it is unavailable, its contract
   cannot carry the input or the output, the request could not be prepared --
   and a smaller range gets the same answer, so they are evidence neither way.
   Counting them would make a lane whose one candidate refuses every request
   read less on every quota storm until the width reached one atom. *)
let disposition_shows_size (disposition : Exact_output.candidate_rejection_disposition) =
  match disposition with
  | Input_capacity _ -> true
  | Runtime_slot_unavailable | Runtime_contract_rejected | Input_contract_rejected
  | Output_requirement_rejected | Request_preparation_failed -> false

let rejection_shows_size rejection =
  disposition_shows_size (Exact_output.candidate_rejection_disposition rejection)
;;

let advance_shows_size (receipt : Exact_output.flow_advance_receipt) =
  match receipt.failed with
  | Exact_output.Flow_advance_execution_failed { cause; _ } -> cause_shows_size cause
  | Exact_output.Flow_advance_candidate_rejected rejection ->
    rejection_shows_size rejection
;;

(* The evidence every constructor carries, and the verdict on the failure that
   ended the walk: an exhausted ladder ends on a rejection, a failed execution
   on a provider cause, and the rest end before either exists. *)
let flow_evidence_and_final_verdict = function
  | Exact_output.Flow_attempt_already_started evidence -> evidence, false
  | Exact_output.Flow_attempt_start_failed { evidence; _ }
  | Exact_output.Flow_measurement_start_failed { evidence; _ }
  | Exact_output.Flow_before_measurement_dispatch_callback_failed { evidence; _ }
  | Exact_output.Flow_measurement_terminal_callback_failed { evidence; _ }
  | Exact_output.Flow_before_dispatch_callback_failed { evidence; _ }
  | Exact_output.Flow_before_advance_callback_failed { evidence; _ } -> evidence, false
  | Exact_output.Flow_candidates_exhausted { evidence; rejection } ->
    evidence, rejection_shows_size rejection
  | Exact_output.Flow_exact_execution_failed { evidence; cause; _ } ->
    evidence, cause_shows_size cause.Exact_output.cause
;;

(* Asked of every failed visit of the walk and of the failure that ended it,
   so the same set of causes answers the same way whatever order the slots
   were tried in. A semantic rejection the validator raised never reaches the
   walk's advances, so the caller adds it. *)
let walk_shows_size_flow error =
  let evidence, final = flow_evidence_and_final_verdict error in
  final || List.exists advance_shows_size evidence.Exact_output.advances
;;

(* What a pass that did not commit hands back: the cause for its caller's
   log, and whether anything it met says the range's size stopped it. *)
type not_committed =
  { detail : string
  ; walk_shows_size : bool
  }

(* One official-client slot's failure. A slot that names the limit it refused
   at is answered by [fit_continuity], not here. Of the rest, an answer that
   came back unusable is a refused output, which RFC-librarian-lifecycle §4.3
   counts among the failures reading less answers; an id this module cannot
   run is a configuration error; and a client that simply failed does not say
   why -- its quota and its input limit arrive in the same constructor -- so it
   is no evidence either way. Reading less on it would let a CLI quota storm
   walk the width down to one atom. *)
let cli_failure_shows_size (failure : Keeper_lane_cli_oneshot.failure) =
  match failure with
  | Keeper_lane_cli_oneshot.Invalid_json_output _
  | Keeper_lane_cli_oneshot.Invalid_domain_output _ -> true
  | Keeper_lane_cli_oneshot.Not_an_official_client _
  | Keeper_lane_cli_oneshot.Execution_failed _ -> false
;;

(* Whether anything this pass met says the range's size stopped it. A failure
   that never involved a provider judging the request cannot: the prompt did
   not render, no transport was declared, the lane would not resolve, the
   clock was missing, or the model answered and the snapshot write failed.
   Reading less on those walks the source down over an outage a smaller range
   meets identically, and only an emptied backlog widens it again, so it would
   stay there.

   The official-client tail keeps the API failure that sent the walk to it, and
   both are asked: reading only the tail would answer a size refusal one way
   when CLI slots were declared and the other way when they were not. *)
let rec extraction_shows_size = function
  | Exact_execution_failed error -> error.walk_shows_size
  | Domain_output_invalid _ -> true
  | Cli_slots_exhausted { prior_error; failures } ->
    List.exists cli_failure_shows_size failures
    || (match prior_error with
        | Some error -> extraction_shows_size error
        | None -> false)
  | Cli_prompt_unavailable { prior_error = Some error } -> extraction_shows_size error
  | Cli_prompt_unavailable { prior_error = None } -> false
  | Prompt_render_failed _ | Execution_clock_unavailable | Exact_setup_failed _
  | No_transport_declared | Memory_snapshot_write_failed _ -> false
;;

(* Only a CLI slot reports a limit this process can fit against: its refusal
   carries the server's own character count. An API slot states its limit in
   tokens inside provider prose, which this process cannot read back into a
   number, so no fitting is possible from it -- a walk of API slots answers
   its caller with the size verdict above instead. *)
let extraction_cli_input_limit = function
  | Cli_slots_exhausted { failures; _ } ->
    (match List.rev failures with
     | final :: _ -> Keeper_lane_cli_oneshot.input_capacity final
     | [] -> None)
  | Exact_execution_failed _
  | Prompt_render_failed _ | Execution_clock_unavailable | Exact_setup_failed _
  | Cli_prompt_unavailable _ | No_transport_declared
  | Domain_output_invalid _ | Memory_snapshot_write_failed _ -> None
;;

let fit_continuity ~capacity ~base_path ~keeper_id ~input prepared =
  let open Result.Syntax in
  let* _, cli_slots = resolve_librarian_slots ~base_path ~keeper_id
    |> Result.map_error extraction_error_to_string in
  if not (List.mem capacity.Keeper_lane_cli_oneshot.runtime_id cli_slots)
  then Ok (Some prepared)
  else Keeper_librarian_continuity.fit prepared ~fits:(fun continuity ->
    let input = {input with Keeper_librarian.messages =
      Keeper_librarian_continuity.messages continuity} in
    let* material = snd (resolve_librarian_prompt ~continuity input) in
    let prompt = Keeper_lane_cli_oneshot.prompt_with_schema
      ~requirement:(librarian_output_requirement (Some continuity)) ~prompt:material.rendered in
    let* actual_chars = Runtime_codex_app_server.prompt_char_count prompt in
    Ok (actual_chars <= capacity.capacity.max_chars))
;;

let exact_execution_error ~semantic_rejections error =
  let outward_effect =
    match Exact_output.flow_execution_error_generation_dispatch error with
    | Exact_output.No_generation_dispatch -> No_outward_effect
    | Exact_output.Generation_dispatch_started -> Outward_effect_started
  in
  let detail = Keeper_exact_flow_detail.flow_execution_error_detail error in
  { outward_effect
  ; walk_shows_size =
      walk_shows_size_flow error
      || (match semantic_rejections with [] -> false | _ :: _ -> true)
  ; detail
  }
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

type cli_fallback_failure =
  | No_cli_slots
  | Fitted_prompt_unavailable
  | Slot_failures of Keeper_lane_cli_oneshot.failure list

type continuity_answer =
  | Memory_only
  | Continuity of
      { prepared : Keeper_librarian_continuity.prepared
      ; working_state : string
      }

type accepted =
  { selection : Keeper_librarian.selection
  ; continuity_answer : continuity_answer
  }

(* A continuity pass must produce both Memory disposition and its saved
   working state before either may be published. Ordinary Memory extraction
   has no continuity obligation and still accepts an absent working state.
   The accepted answer carries the pair, so publication has no case for a
   continuity pass without one. *)
let validate_selection ?continuity selected_input output =
  let open Result.Syntax in
  let* selection = Keeper_librarian.selection_of_json_result selected_input output in
  match continuity, selection.Keeper_librarian.working_state with
  | None, _ -> Ok { selection; continuity_answer = Memory_only }
  | Some prepared, Some working_state ->
    Ok { selection; continuity_answer = Continuity { prepared; working_state } }
  | Some _, None ->
    Error (Keeper_librarian.Working_state_invalid
      "continuity requires a nonblank working_state")
;;

let try_cli_slots
      ~requirement
      ~continuity
      ~keeper_id
      ~base_path
      ~cli_runner
      ~cli_slots
      ~(selected_input : Keeper_librarian.input)
      ~messages
  =
  match cli_slots with
  | [] -> Error No_cli_slots
  | cli_slots ->
    (match cli_prompt_of_messages ~keeper_id messages with
     | None -> Error Fitted_prompt_unavailable
     | Some prompt ->
       (match
          Keeper_lane_cli_oneshot.walk
            ?runner:cli_runner
            ~base_dir:base_path
            ~cli_slots
            ~system_prompt:""
            ~requirement
            ~prompt
            ~validate:(fun output ->
              validate_selection ?continuity selected_input output
              |> Result.map (fun selection -> selection, output)
              |> Result.map_error Keeper_librarian.parse_error_to_string)
            ~on_failure:(fun failure ->
              Log.Keeper.warn ~keeper_name:keeper_id
                "librarian cli lane-slot failed: %s"
                (Keeper_lane_cli_oneshot.failure_to_string failure))
            ()
        with
        | Error failures -> Error (Slot_failures failures)
        | Ok (runtime_id, (selection, output)) ->
          Ok (runtime_id, selection, output)))
;;

(* An API refusal says nothing about the CLI walk that followed it. Keep the
   walk's typed failures with that refusal so the run record and Memory
   journal cannot describe an answered CLI request as only API pre-flight. *)
let with_cli_failure prior_error = function
  | No_cli_slots -> prior_error
  | Slot_failures failures ->
    Cli_slots_exhausted { prior_error = Some prior_error; failures }
  | Fitted_prompt_unavailable ->
    Cli_prompt_unavailable { prior_error = Some prior_error }
;;

let execute_exact_output_classified
      ~continuity
      ?cli_runner
      ~clock
      ~net
      ~base_path
      ~keeper_id
      ~(selected_input : Keeper_librarian.input)
      ~messages
      ()
  =
  let open Result.Syntax in
  let* selected_slots, cli_slots = resolve_librarian_slots ~base_path ~keeper_id in
  let requirement = librarian_output_requirement continuity in
  match selected_slots with
  | [] ->
    (* Registry publication rejects a lane with neither transport, and lane
       resolution rejects a lane with no admitted transport. Keep this final
       classification defensive in case either upstream contract changes. *)
    (match try_cli_slots ~requirement ~continuity ~keeper_id ~base_path ~cli_runner ~cli_slots
       ~selected_input ~messages with
     | Ok (runtime_id, selection, output) -> Ok ((selection, output), runtime_id)
     | Error No_cli_slots -> Error No_transport_declared
     | Error (Slot_failures failures) ->
       Error (Cli_slots_exhausted { prior_error = None; failures })
     | Error Fitted_prompt_unavailable ->
       Error (Cli_prompt_unavailable { prior_error = None }))
  | _ :: _ ->
  match preflight_slots ~requirement ~selected_slots ~messages with
  | Error error ->
    (* No API slot can project this request. The independently admitted CLI
       slots still own a chance to answer, just as after API exhaustion. *)
    (match try_cli_slots ~requirement ~continuity ~keeper_id ~base_path ~cli_runner ~cli_slots
       ~selected_input ~messages with
     | Ok (runtime_id, selection, output) ->
       Log.Keeper.warn ~keeper_name:keeper_id
         "librarian lane=%s every API slot refused projection; answered by cli slot=%s: %s"
         exact_lane_id runtime_id (extraction_error_to_string error);
       Ok ((selection, output), runtime_id)
     | Error cli_failure -> Error (with_cli_failure error cli_failure))
  | Ok preflight ->
  (if preflight.unusable <> [] then
     Log.Keeper.warn ~keeper_name:keeper_id
       "librarian lane=%s pre-flight excluded slot(s) from this run: %s"
       exact_lane_id
       (slot_reason_pairs ~sep:", " preflight.unusable));
  let* attempt = prepare_attempt ~requirement ~selected_slots:preflight.selected_slots messages in
  let validate flow_success =
    let output = Exact_output.flow_success_output flow_success in
    match
      validate_selection ?continuity
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
    Ok (success.accepted, selected_slot)
  | Error (Exact_output.Flow_execution_terminal { cause; prior_rejections }) ->
    (* A rejection the validator raised on an answer that arrived never enters
       the walk's advances, so the walk alone would answer differently
       depending on where in the order that answer came. A refused output is
       what RFC-librarian-lifecycle §4.3 counts as a size cause, so one is
       enough. *)
    let terminal () =
      Error
        (Exact_execution_failed
           (exact_execution_error ~semantic_rejections:prior_rejections cause))
    in
    (* The CLI tail follows the same advancement rule as HTTP successors;
       input-specific and infrastructure failures keep their terminal. *)
    (match Exact_output.flow_execution_terminal_kind cause with
     | Exact_output.Advanceable_candidates_exhausted ->
       (match
          try_cli_slots
            ~requirement
            ~continuity
            ~keeper_id
            ~base_path
            ~cli_runner
            ~cli_slots
            ~selected_input
            ~messages
        with
        | Ok (runtime_id, selection, output) ->
          Ok ((selection, output), runtime_id)
        | Error cli_failure ->
          Error
            (with_cli_failure
               (Exact_execution_failed
                  (exact_execution_error ~semantic_rejections:prior_rejections cause))
               cli_failure))
     | Exact_output.Non_advanceable_terminal -> terminal ())
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
         ~requirement
         ~continuity
         ~keeper_id
         ~base_path
         ~cli_runner
         ~cli_slots
         ~selected_input
         ~messages
     with
     | Ok (runtime_id, selection, output) ->
       Ok ((selection, output), runtime_id)
     | Error cli_failure ->
       Error
         (with_cli_failure
            (Domain_output_invalid
               (Keeper_librarian.parse_error_to_string rejection.rejection))
            cli_failure))
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
let record_failure ~keepers_dir ~keeper_id ~trace_id ~kind ~detail =
  let snapshot_absent =
    match
      Domain_pool_ref.submit_io_or_inline (fun () ->
        Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id)
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
  Domain_pool_ref.submit_io_or_inline (fun () ->
    Keeper_memory_os_current.append_librarian_failure
      ~keepers_dir
      ~keeper_id
      ~now:(Time_compat.now ())
      ~trace_id
      ~kind
      ~detail
      ~snapshot_present:(not snapshot_absent))
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
      ; ( "source"
        , `String
            (Prompt_registry.prompt_source_to_string resolution.source) )
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
    ; "goal_context", Keeper_librarian.goal_context_to_json inp.goal_context
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
      ~absorb_gate
      (snapshot : Keeper_memory_os_current.t)
  =
  `Assoc
    [ "absorb_gate", Keeper_librarian_absorb_gate.run_result_to_yojson absorb_gate
    ; "exact_output", exact_output
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

let failed_output = function
  | None -> `Assoc []
  | Some absorb_gate ->
    `Assoc [ "absorb_gate", Keeper_librarian_absorb_gate.observation_to_yojson absorb_gate ]
;;

type context_write =
  | Not_attempted
  | Withheld
  | Outcome_unconfirmed
  | Committed of Keeper_librarian_context.version
  | Write_failed of string

let context_write_json = function
  | Not_attempted -> `Assoc ["status", `String "not_attempted"]
  | Withheld -> `Assoc ["status", `String "withheld"]
  | Outcome_unconfirmed -> `Assoc ["status", `String "outcome_unconfirmed"]
  | Committed (generation, revision) -> `Assoc ["status", `String "committed";
      "generation", `String generation; "revision", `Int revision]
  | Write_failed detail -> `Assoc ["status", `String "failed"; "detail", `String detail]
;;

type write_scope = Context_only | Context_and_memory

let commit_continuity ~commit ~observe =
  (* The executor job has its own cancellation scope. Keep its caller alive
     until all disk effects and their observation finish; shutdown/purge must
     not run past a detached writer after cancellation of the await. *)
  Eio.Cancel.protect (fun () ->
    observe (Domain_pool_ref.submit_io_or_inline commit));
  Eio.Fiber.check ()
;;

let run_best_effort
      ?(write_scope = Context_and_memory)
      ?continuity
      ?(on_memory_committed = fun () -> ())
      ?(on_cli_input_limit = fun _ -> ())
      ?(on_not_committed = fun _ -> ())
      ?(on_continuity_committed = fun _ -> ())
      ?durable_range_id
      ?official_range_id
      ?cli_runner
      ~base_path
      ~keepers_dir
      ~keeper_id
      ~expected_revision
      (inp : Keeper_librarian.input)
  =
  let trace_id = input_trace_id inp in
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
        let prompt_input = input_for_continuity continuity inp in
        let prompt_variables, prompt_material =
          resolve_librarian_prompt ?continuity prompt_input
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
        let observed_context_review = ref None in
        let context_write = ref Not_attempted in
        let continuity_write = ref (`Assoc ["status", `String "not_attempted"]) in
        let complete ?selected_slot outcome output =
          let output = match continuity, output with
            | Some _, `Assoc fields -> `Assoc (("continuity_write", !continuity_write) :: fields)
            | _ -> output in
          let output = match !observed_context_review, output with
            | None, _ -> output
            | Some review, `Assoc fields ->
              let context = [
                "context_write", context_write_json !context_write;
                "context_review", Keeper_librarian_context_review.observation_to_yojson review] in
              (* Keep the existing absorption report first; both derived-context
                 evidence and Memory's receipt survive any later cancellation. *)
              (match fields with
               | (("absorb_gate", _) as gate) :: rest -> `Assoc (gate :: context @ rest)
               | _ -> `Assoc (context @ fields))
            | Some _, _ -> output
          in
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
        (* The gate's received evidence survives later storage exceptions or
           cancellation without changing either the Memory decision or the
           existing failure classification. *)
        let observed_absorb_gate = ref None in
        let committed_memory = ref None in
        (try
           let result =
             let open Result.Syntax in
             let* prompt =
               prompt_material
               |> Result.map (fun material -> material.rendered)
               |> Result.map_error (fun detail -> Prompt_render_failed detail)
             in
             let* ({ selection; continuity_answer }, exact_output), selected_slot =
               execute_exact_output_classified
                 ~continuity
                 ?cli_runner
                 ~clock
                 ~net
                 ~base_path
                 ~keeper_id
                 ~selected_input:prompt_input
                 ~messages:[ message Agent_core.Types.User prompt ]
                 ()
             in

             (* Working context is advisory and has its own revision. A stale
                or failed context write cannot roll back memory or block the
                Keeper; original sources remain pending throughout. *)
             (match continuity with
             | Some _ -> ()
             | None ->
             let context_review = Keeper_librarian_context_review.run
               ~observe:(fun observation -> observed_context_review := Some observation)
               ~clock ~keeper_id ~input:inp.working_context
               ~proposed:selection.working_contexts () in
             if not (Keeper_librarian_context_review.permits_publication context_review) then (
               context_write := Withheld;
               Log.Keeper.info ~keeper_name:keeper_id
                 "working context withheld by review: pockets=%d"
                 (List.length selection.working_contexts))
             else (
             context_write := Outcome_unconfirmed;
             (try match Domain_pool_ref.submit_io_or_inline (fun () ->
                Keeper_librarian_context.commit ~keepers_dir ~keeper_id
                  ~expected_version:(Option.map Keeper_librarian_context.version inp.working_context.previous)
                  ?execution_basis:inp.working_context.execution_basis
                  ?observed_sources:(if inp.working_context.unavailable = []
                    then Some inp.working_context.sources else None)
                  ~sources:(let references = List.concat_map
                    (fun (p : Keeper_librarian_context.pocket) -> p.sources) selection.working_contexts in
                    List.filter (fun (s : Keeper_librarian_context.source) ->
                      List.mem s.reference references) inp.working_context.sources)
                  selection.working_contexts) with
              | Ok working ->
                context_write := Committed (Keeper_librarian_context.version working);
                (match Domain_pool_ref.submit_io_or_inline (fun () ->
                   Keeper_librarian_context_recall.publish ~base_path ~keepers_dir ~keeper_name:keeper_id working) with
                 | Ok () -> ()
                 | Error detail -> Log.Keeper.warn ~keeper_name:keeper_id
                     "working context reference publication failed: %s" detail);
                let covered = Keeper_librarian_context.current_references working in
                let prior = match inp.working_context.previous with None -> [] | Some previous ->
                  Keeper_librarian_context.current_references previous in
                let made_progress = List.exists (fun reference -> not (List.mem reference prior)) covered in
                let remaining = List.exists (fun (source : Keeper_librarian_context.source) ->
                  not (List.mem source.reference covered)) inp.working_context.sources in
                (* Continue incremental organization only after measured source
                   coverage advances. An unfit source or model failure cannot
                   create a private retry loop. *)
                if made_progress && remaining then
                  Keeper_librarian_queue_signal.changed ~base_path ~keeper_name:keeper_id
              | Error detail ->
                context_write := Write_failed detail;
                Log.Keeper.warn ~keeper_name:keeper_id
                  "working context not committed; original intake continues: %s" detail
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn -> Log.Keeper.warn ~keeper_name:keeper_id
                  "working context commit failed independently of memory: %s" (Printexc.to_string exn))));
             let publish_continuity () =
               match continuity_answer with
              | Memory_only -> ()
              | Continuity { prepared; working_state } ->
                continuity_write := `Assoc ["status", `String "outcome_unconfirmed"];
                commit_continuity
                  ~commit:(fun () ->
                   Keeper_librarian_continuity.commit
                     ~config:(Workspace.default_config base_path) ~keeper_name:keeper_id
                     ~prepared ~working_state)
                  ~observe:(function
                 | Ok snapshot ->
                   continuity_write := `Assoc
                     ["status", `String "committed"; "end_atom", `Int snapshot.end_atom;
                      "prefix_sha256", `String snapshot.prefix_sha256];
                   on_continuity_committed snapshot
                 | Error detail ->
                   continuity_write := `Assoc ["status", `String "failed"; "detail", `String detail];
                   (* A snapshot that did not commit -- a CAS the history moved
                      under, a disk error -- is not the range's size, so the
                      caller keeps the width and logs this cause. *)
                   on_not_committed
                     { detail = "continuity state not committed: " ^ detail
                     ; walk_shows_size = false
                     };
                   Log.Keeper.warn ~keeper_name:keeper_id "continuity state not committed: %s" detail)
             in
             match write_scope with
             | Context_only ->
               publish_continuity ();
               Ok (`Context_organized (exact_output, selected_slot))
             | Context_and_memory ->
             (* The decision goes to the store, not the whole set it projects
                to. [selection.facts] is that projection, taken against the
                snapshot this pass read before its provider turn; writing it
                required nothing to have changed since, and a keeper recording
                one fact of its own in that window ended the pass (masc
                #32859). The decision itself has no such requirement: a fact it
                never mentions is one it never saw. *)
             (* An absorption the merged claim does not convey is not applied:
                that memory stays current (RFC-librarian-absorb-gate). The
                gate only narrows the list. A gate switched off, or an
                excluded Keeper, leaves the answer unchanged; a gate that is
                on but cannot be asked absorbs nothing; a failed judgment
                retains unconfirmed originals. *)
             let absorb_gate =
               Keeper_librarian_absorb_gate.run
                 ~observe:(fun observation -> observed_absorb_gate := Some observation)
                 ~clock
                 ~keeper_id
                 ~facts:(match prompt_input.current with
                   | None -> []
                   | Some current -> current.facts)
                 ~new_claims:selection.new_claims
                 ~absorbed:selection.absorbed
                 ()
             in
             let+ snapshot =
               Keeper_memory_os_current.apply_disposition
                 ~on_committed:(fun snapshot ->
                   committed_memory := Some (snapshot, exact_output, selected_slot, absorb_gate);
                   on_memory_committed ())
                 ~clock
                 ~dropped_statements:selection.dropped
                 ?durable_range_id
                 ?official_range_id
                 ~absorbed:(Keeper_librarian_absorb_gate.absorbed_of_run absorb_gate)
               ~keepers_dir
               ~keeper_id
               ~now:(Time_compat.now ())
               ~source:
                 { kind = Keeper_memory_os_current.Librarian
                 ; trace_id = input_trace_id inp
                 }
               ~new_claims:selection.new_claims
               ()
             |> Result.map_error (fun detail ->
               Memory_snapshot_write_failed { detail; selected_slot })
             in
             (* Only saved Memory authorizes publishing the corresponding
                continuity frontier. A failed disposition leaves input intact. *)
             publish_continuity ();
             (* The snapshot is committed; each supersede the answer stated is
                now a Revised event on the old id (RFC-0418). A sidecar that
                cannot be written is said here and does not undo the pass. *)
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Keeper_memory_os_events.append_all
                 ~keepers_dir
                 ~keeper_id
                 (List.map
                    (fun (revision : Keeper_librarian.revision) : Keeper_memory_os_events.event ->
                       { recorded_at = snapshot.updated_at
                       ; memory_id = revision.superseded
                       ; trace_id = input_trace_id inp
                       ; kind =
                           Keeper_memory_os_events.Revised
                             { superseded_by = revision.superseded_by }
                       })
                    selection.revisions))
             |> List.iter (fun error ->
               Log.Keeper.warn
                 ~keeper_name:keeper_id
                 "%s"
                 (Keeper_memory_os_events.append_error_to_string error));
             `Memory_committed (snapshot, exact_output, selected_slot, absorb_gate)
           in
           match result with
           | Ok (`Context_organized (exact_output, selected_slot)) ->
             complete ~selected_slot Exact_lane_run_registry.Succeeded
               (`Assoc [ "memory_write", `String "skipped_context_only"
                       ; "exact_output", exact_output ]);
             Eio.Fiber.check ()
           | Ok (`Memory_committed (snapshot, exact_output, selected_slot, absorb_gate)) ->
             complete
               ~selected_slot
               Exact_lane_run_registry.Succeeded
               (completed_output ~inp ~exact_output ~absorb_gate snapshot);
             Log.Keeper.info
               ~keeper_name:keeper_id
               "memory os librarian committed current snapshot revision=%d facts=%d added=%d removed=%d"
               snapshot.revision
               (List.length snapshot.facts)
               (List.length snapshot.change.added)
               (List.length snapshot.change.removed);
             (* A completion observer may request cancellation and return
                normally. Propagate it here even when no later I/O yields. *)
             Eio.Fiber.check ()
           | Error error ->
             Option.iter on_cli_input_limit (extraction_cli_input_limit error);
             let detail = extraction_error_to_string error in
             (* The caller reads less after this pass unless the whole walk
                was transient, and it names the cause in its log: without the
                cause an authorization outage and an oversized range leave
                the same line. *)
             on_not_committed
               { detail
               ; walk_shows_size = extraction_shows_size error
               };
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
               (failed_output !observed_absorb_gate);
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string MemoryOsLibrarianFailures)
               ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
               ();
             (* A failed pass leaves the read position where it was. What the
                next signal reads from it is the caller's to decide, from the
                verdict handed to [on_not_committed] above; nothing here
                schedules that read or holds it back. *)
             record_failure
               ~keepers_dir
               ~keeper_id
               ~trace_id
               ~kind:(extraction_error_kind error)
               ~detail:
                 (Printf.sprintf
                    "memory os librarian failed lane=%s: %s"
                    exact_lane_id
                    detail);
             Eio.Fiber.check ()
         with
         (* A cancelled pass reached the lane registry and stopped there, so the
            journal — the record of what the librarian did on this keeper —
            showed the same silence for a pass killed mid-flight as for a turn
            on which the librarian never ran. Measured live on 2026-08-07: 11
            of 23 completed librarian lane runs cancelled, none of them
            represented in the journal.

            In this cancellation branch, completion and failure-journal writes
            run under [Eio.Cancel.protect]:
            payload persistence and lock acquisition can yield before the
            registry's transaction protection begins. The surrounding context
            is already cancelled, so protecting only the journal loses both
            records before reaching it. *)
         | Eio.Cancel.Cancelled _ as exn ->
           Eio.Cancel.protect (fun () ->
             (* Notifications run after the registry commit. A cancellation
                from that observer must not overwrite a completed outcome. *)
             let run_completed =
               List.exists
                 (fun (run : Exact_lane_run_registry.run) ->
                    String.equal run.run_id run_id
                    && match run.status with
                       | Exact_lane_run_registry.Completed _ -> true
                       | Running | Completion_persistence_failed _ -> false)
                 (Exact_lane_run_registry.list_runs registry)
             in
             match !committed_memory with
             | Some (snapshot, exact_output, selected_slot, absorb_gate) ->
               if not run_completed then
                 complete ~selected_slot Exact_lane_run_registry.Cancelled
                   (completed_output ~inp ~exact_output ~absorb_gate snapshot);
               Log.Keeper.warn
                 ~keeper_name:keeper_id
                 "memory os librarian cancelled after snapshot commit revision=%d; post-commit work may be incomplete"
                 snapshot.revision
             | None ->
               if not run_completed then
                 complete
                   Exact_lane_run_registry.Cancelled
                   (failed_output !observed_absorb_gate);
               record_failure
                 ~keepers_dir
                 ~keeper_id
                 ~trace_id
                 ~kind:Keeper_memory_os_current.Lane_cancelled
                 ~detail:
                   (Printf.sprintf
                      "memory os librarian cancelled lane=%s"
                      exact_lane_id));
           (* A later signal reads the same position again, but it does not
              replay this immutable input; graceful lifecycle boundaries
              therefore drain accepted work instead of cancelling it. *)
           raise exn
         | exn ->
           complete
             (Exact_lane_run_registry.Failed
                { code = "librarian_raised"
                ; detail = "Librarian raised: " ^ Printexc.to_string exn
                })
             (failed_output !observed_absorb_gate);
           raise exn)
      (* Missing Eio context is a failed pass like any other: the keeper's
         memory does not advance. It was previously a bare WARN with no record,
         which hid a restart-shaped outage behind the same silence as a healthy
         idle turn. *)
      | _ ->
        let detail =
          Printf.sprintf
            "memory os librarian skipped: Eio net/clock context unavailable lane=%s"
            exact_lane_id
        in
        (* No request was composed, so nothing here says the range's size
           stopped the pass. *)
        on_not_committed { detail; walk_shows_size = false };
        record_failure
          ~keepers_dir
          ~keeper_id
          ~trace_id
          ~kind:Keeper_memory_os_current.Runtime_context_unavailable
          ~detail
    with
    | Eio.Cancel.Cancelled _ as error -> raise error
    | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string MemoryOsLibrarianFailures)
        ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
        ();
      (* A raise is this process failing, not a provider judging the request,
         so the caller keeps the width it had. *)
      on_not_committed
        { detail = "librarian raised: " ^ Printexc.to_string exn
        ; walk_shows_size = false
        };
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
;;

module For_testing = struct
  type classified_error = extraction_error

  let classified_error_detail = extraction_error_to_string
  let classified_error_kind = extraction_error_kind
  let execute_exact_output_classified = execute_exact_output_classified
  let record_failure = record_failure
  let commit_continuity = commit_continuity
  let cause_shows_size = cause_shows_size
  let cli_failure_shows_size = cli_failure_shows_size
  let disposition_shows_size = disposition_shows_size
end
