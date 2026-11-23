(** Runtime adapter for the tool-free working-context Librarian pass. *)

module Exact_output = Agent_core.Exact_output
module Failure_evidence = Keeper_exact_walk_failure

let exact_lane_id = Standalone_lane.to_id Standalone_lane.Librarian

let input_trace_id (inp : Keeper_librarian.input) = Ids.Turn_ref.trace_id inp.turn_ref

let message role text =
  Llm_provider.Types.make_message ~role [ Llm_provider.Types.Text text ]
;;

type slot_refusal =
  { slot_id : string
  ; cause : Exact_output.admission_error
  }

let slot_reason_pairs ?(sep = "; ") (refusals : slot_refusal list) : string =
  String.concat sep
    (List.map
       (fun { slot_id; cause } ->
          slot_id ^ ": " ^ Exact_output.admission_error_reason cause)
       refusals)
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
  | Exact_request_projection_failed of slot_refusal list

type outward_effect =
  | No_outward_effect
  | Outward_effect_started

type input_capacity_evidence =
  | No_input_capacity_refusal
  | Input_capacity_refused

type message_descent =
  | No_descent_evidence
  | Smaller_input_may_help
  | Invalid_output_blocks_descent
  | Unsettled_native_blocks_descent

type exact_execution_error =
  { outward_effect : outward_effect
  ; failure_evidence : Failure_evidence.t
  ; detail : string
  }

type served_slot =
  | Api_slot of string
  | Cli_slot of string

let served_slot_id = function
  | Api_slot id | Cli_slot id -> id
;;

type extraction_error =
  | Prompt_render_failed of string
  | Exact_setup_failed of exact_setup_error
  | Exact_execution_failed of exact_execution_error
  | Cli_slots_exhausted of
      { prior_error : extraction_error option
      ; failures : Keeper_lane_cli_oneshot.failure list
      }
  | Cli_prompt_unavailable of { prior_error : extraction_error option }
  | No_transport_declared
  | Slots_held of
      { until : float
      ; after : extraction_error option
      }
  | Domain_output_invalid of string

type failure_kind =
  | Prompt_render_failure
  | Execution_clock_unavailable
  | Exact_setup_failure
  | Exact_execution_failure
  | Domain_output_invalid
  | Runtime_context_unavailable
  | Lane_cancelled
  | Unhandled_exception

let failure_kind_to_string = function
  | Prompt_render_failure -> "prompt_render_failure"
  | Execution_clock_unavailable -> "execution_clock_unavailable"
  | Exact_setup_failure -> "exact_setup_failure"
  | Exact_execution_failure -> "exact_execution_failure"
  | Domain_output_invalid -> "domain_output_invalid"
  | Runtime_context_unavailable -> "runtime_context_unavailable"
  | Lane_cancelled -> "lane_cancelled"
  | Unhandled_exception -> "unhandled_exception"
;;

let rec extraction_error_kind : extraction_error -> failure_kind
  = function
  | Prompt_render_failed _ -> Prompt_render_failure
  | Exact_setup_failed _ -> Exact_setup_failure
  | Exact_execution_failed _ -> Exact_execution_failure
  | Cli_slots_exhausted { prior_error = Some error; _ }
  | Cli_prompt_unavailable { prior_error = Some error } -> extraction_error_kind error
  | Cli_slots_exhausted { prior_error = None; _ }
  | Cli_prompt_unavailable { prior_error = None } -> Exact_execution_failure
  | No_transport_declared -> Exact_setup_failure
  | Slots_held { after = Some error; _ } -> extraction_error_kind error
  | Slots_held { after = None; _ } -> Exact_execution_failure
  | Domain_output_invalid _ -> Domain_output_invalid
;;

let exact_setup_error_to_string = function
  | Exact_registry_unavailable error ->
    "exact registry unavailable: "
    ^ Runtime_exact_output_registry.publication_error_to_string error
  | Exact_lane_unavailable error ->
    Runtime_exact_output_registry.lane_resolution_error_to_string error
  | Exact_candidate_invalid { position; slot_id } ->
    Printf.sprintf "exact lane candidate invalid position=%d slot=%S" position slot_id
  | Exact_flow_snapshot_failed
      (Exact_output.Duplicate_flow_candidate_id
         { candidate_id; first_position; duplicate_position }) ->
    Printf.sprintf
      "exact flow duplicate candidate id=%S first_position=%d duplicate_position=%d"
      candidate_id
      first_position
      duplicate_position
  | Exact_flow_start_failed (Exact_output.Flow_id_generation_failed detail) ->
    "exact flow identity allocation failed: " ^ detail
  | Exact_request_projection_failed refusals ->
    "request projection refused by all API slots: " ^ slot_reason_pairs refusals
;;

let rec extraction_error_to_string = function
  | Prompt_render_failed detail -> detail
  | Exact_setup_failed error -> exact_setup_error_to_string error
  | Exact_execution_failed { outward_effect; detail; _ } ->
    Printf.sprintf
      "exact execution failed outward_effect=%s cause=%s"
      (match outward_effect with
       | No_outward_effect -> "none"
       | Outward_effect_started -> "started")
      detail
  | Cli_slots_exhausted { prior_error; failures } ->
    let cli_detail =
      let summary = "official-client fallback exhausted" in
      match failures with
      | [] -> summary
      | _ :: _ ->
        summary
        ^ ": "
        ^ String.concat "; " (List.map Keeper_lane_cli_oneshot.failure_to_string failures)
    in
    (match prior_error with
     | None -> cli_detail
     | Some error -> extraction_error_to_string error ^ "; " ^ cli_detail)
  | Cli_prompt_unavailable { prior_error } ->
    let cli_detail =
      "official-client fallback skipped: fitted prompt is not one text message"
    in
    (match prior_error with
     | None -> cli_detail
     | Some error -> extraction_error_to_string error ^ "; " ^ cli_detail)
  | No_transport_declared -> "lane declares no API or official-client slots"
  | Slots_held { until; after } ->
    let held_detail =
      "API slots waiting for their provider until "
      ^ Masc_domain.iso8601_of_unix_seconds until
      ^ " were not called"
    in
    (match after with
     | None -> held_detail
     | Some error -> extraction_error_to_string error ^ "; " ^ held_detail)
  | Domain_output_invalid detail -> "domain output invalid: " ^ detail
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

let working_contexts_rule_variable = "working_contexts_rule"

let with_working_contexts_rule variables =
  Result.map
    (fun rule -> (working_contexts_rule_variable, rule) :: variables)
    (render_prompt Prompt_names.librarian_working_contexts_rule [])
;;

type librarian_prompt_material =
  { resolution : Prompt_registry.prompt_resolution
  ; rendered : string
  }

let resolve_working_context_prompt (inp : Keeper_librarian.input) =
  let base_variables = Keeper_librarian.working_context_prompt_variables inp in
  match with_working_contexts_rule base_variables with
  | Error detail -> base_variables, Error detail
  | Ok variables ->
    let material =
      match
        Prompt_registry.resolve_and_render_prompt_template
          Prompt_names.librarian_working_context
          variables
      with
      | Error detail ->
        Error (Printf.sprintf "%s: %s" Prompt_names.librarian_working_context detail)
      | Ok (resolution, text) ->
        let rendered = String.trim text in
        if String.equal rendered ""
        then
          Error (Printf.sprintf "%s rendered empty prompt" Prompt_names.librarian_working_context)
        else Ok { resolution; rendered }
    in
    variables, material
;;

let working_context_messages (inp : Keeper_librarian.input) =
  Result.map
    (fun material -> [ message Agent_core.Types.User material.rendered ])
    (snd (resolve_working_context_prompt inp))
;;

let working_context_requirement =
  Exact_output.make_output_requirement
    ~schema:Keeper_structured_output_schema.librarian_working_context_output_schema
    ~minimum_guarantee:Exact_output.Json_syntax
;;

let flow_candidates selected_slots =
  let rec loop position acc = function
    | [] -> Ok (List.rev acc)
    | (slot : Runtime_exact_output_registry.selected_slot) :: rest ->
      (match
         Exact_output.make_flow_candidate ~id:slot.slot_id ~admitted_target:slot.admitted_target
       with
       | Ok candidate -> loop (position + 1) (candidate :: acc) rest
       | Error Exact_output.Blank_flow_candidate_id ->
         Error (Exact_candidate_invalid { position; slot_id = slot.slot_id }))
  in
  loop 0 [] selected_slots
;;

type slot_projection =
  | Slot_admitted
  | Slot_unusable of Exact_output.admission_error

let project_slot ~requirement ~(slot : Runtime_exact_output_registry.selected_slot) ~messages
  : slot_projection
  =
  match Exact_output.project_request_body ~target:slot.admitted_target ~messages requirement with
  | Error error -> Slot_unusable error
  | Ok (_ : Exact_output.request_body_projection) -> Slot_admitted
;;

type preflight_selection =
  { selected_slots : Runtime_exact_output_registry.selected_slot list
  ; unusable : slot_refusal list
  }

let preflight_slots ~requirement ~selected_slots ~messages =
  match selected_slots with
  | [] -> Ok { selected_slots = []; unusable = [] }
  | _ :: _ ->
    let selected_slots, unusable =
      List.fold_left
        (fun (selected_slots, unusable) (slot : Runtime_exact_output_registry.selected_slot) ->
           match project_slot ~requirement ~slot ~messages with
           | Slot_admitted -> slot :: selected_slots, unusable
           | Slot_unusable cause ->
             selected_slots, { slot_id = slot.slot_id; cause } :: unusable)
        ([], [])
        selected_slots
      |> fun (selected_slots, unusable) -> List.rev selected_slots, List.rev unusable
    in
    (match selected_slots with
     | [] -> Error (Exact_setup_failed (Exact_request_projection_failed unusable))
     | _ :: _ -> Ok { selected_slots; unusable })
;;

let resolve_librarian_slots () =
  let open Result.Syntax in
  let* registry =
    Runtime_exact_output_registry.current ()
    |> Result.map_error (fun error -> Exact_setup_failed (Exact_registry_unavailable error))
  in
  let* resolved =
    Runtime_exact_output_registry.resolve_lane registry ~lane_id:exact_lane_id
    |> Result.map_error (fun error -> Exact_setup_failed (Exact_lane_unavailable error))
  in
  let (ordered : Runtime_exact_lane_backpressure.ordered) =
    Runtime_exact_lane_backpressure.order resolved
  in
  Ok
    ( ordered.lane.Runtime_exact_output_registry.selected_slots
    , ordered.lane.Runtime_exact_output_registry.cli_slots
    , ordered.held_http )
;;

let prepare_attempt ~requirement ~selected_slots messages =
  let open Result.Syntax in
  let* candidates =
    flow_candidates selected_slots |> Result.map_error (fun error -> Exact_setup_failed error)
  in
  match candidates with
  | [] ->
    Error
      (Exact_setup_failed
         (Exact_lane_unavailable (No_admitted_lane_slots { lane_id = exact_lane_id })))
  | first :: rest ->
    let* snapshot =
      Exact_output.snapshot_flow ~first ~rest ~messages requirement
      |> Result.map_error (fun error -> Exact_setup_failed (Exact_flow_snapshot_failed error))
    in
    Exact_output.start_flow
      ~admission_class:(Standalone_lane.admission_class Librarian)
      snapshot
    |> Result.map_error (fun error -> Exact_setup_failed (Exact_flow_start_failed error))
;;

let rec extraction_failure_evidence = function
  | Exact_execution_failed error -> error.failure_evidence
  | Domain_output_invalid _ -> Failure_evidence.invalid_output
  | Cli_slots_exhausted { prior_error; failures } ->
    let prior =
      Option.fold ~none:Failure_evidence.empty ~some:extraction_failure_evidence prior_error
    in
    Failure_evidence.after_cli_fallback ~prior failures
  | Cli_prompt_unavailable { prior_error } ->
    Option.fold
      ~none:Failure_evidence.empty
      ~some:(fun error ->
        Failure_evidence.without_measured_cli_capacity (extraction_failure_evidence error))
      prior_error
  | Slots_held { after; _ } ->
    Failure_evidence.combine
      (Option.fold ~none:Failure_evidence.empty ~some:extraction_failure_evidence after)
      Failure_evidence.held
  | Prompt_render_failed _ | Exact_setup_failed _ | No_transport_declared ->
    Failure_evidence.empty
;;

let input_capacity_of_failure evidence =
  if Failure_evidence.refuses_input_capacity evidence
  then Input_capacity_refused
  else No_input_capacity_refusal
;;

let message_descent_of_failure (evidence : Failure_evidence.t) =
  if evidence.unsettled_native_execution
  then Unsettled_native_blocks_descent
  else if evidence.invalid_output
  then Invalid_output_blocks_descent
  else if evidence.historical_range_size || evidence.named_input_capacity
  then Smaller_input_may_help
  else No_descent_evidence
;;

type not_committed =
  { input_capacity_evidence : input_capacity_evidence
  ; input_capacity_only : bool
  ; message_descent : message_descent
  ; provider_input_refusals : Keeper_exact_input_refusal.t list
  ; detail : string
  ; walk_shows_size : bool
  ; smaller_range_meets_same_failure : bool
  }

let not_committed_of_failure ~detail (evidence : Failure_evidence.t) =
  { detail
  ; walk_shows_size = Failure_evidence.shows_range_size evidence
  ; message_descent = message_descent_of_failure evidence
  ; input_capacity_evidence = input_capacity_of_failure evidence
  ; input_capacity_only = Failure_evidence.input_capacity_only evidence
  ; provider_input_refusals = evidence.provider_input_refusals
  ; smaller_range_meets_same_failure = evidence.size_independent_execution_failure
  }
;;

type no_callback_error = |

let no_callback_error_to_string : no_callback_error -> string = function
  | _ -> .
;;

let exact_execution_error
      ~declared_http
      ~excluded_http
      ~declared_cli
      ~semantic_rejections
      (error : no_callback_error Exact_output.flow_execution_error)
  =
  let http =
    Keeper_exact_walk_receipt.http_failure
      ~callback_error_to_string:no_callback_error_to_string
      ~rejection_to_string:Keeper_librarian.parse_error_to_string
      (Exact_output.Flow_execution_terminal { cause = error; prior_rejections = semantic_rejections })
  in
  let cli =
    Keeper_exact_walk_receipt.cli ~visited:[] ~dispatched:[] ~failures:[] ~result:Not_reached
  in
  let receipt =
    match
      Keeper_exact_walk_receipt.make ~declared_http ~excluded_http ~declared_cli ~http ~cli
    with
    | Ok receipt -> receipt
    | Error detail -> invalid_arg ("invalid Librarian walk: " ^ detail)
  in
  let outward_effect =
    match Keeper_exact_walk_receipt.generation_dispatch receipt with
    | Exact_output.No_generation_dispatch -> No_outward_effect
    | Generation_dispatch_started -> Outward_effect_started
  in
  let detail =
    Exact_output.flow_execution_error_to_string
      ~callback_error_to_string:no_callback_error_to_string
      ~raw_response_to_string:Keeper_exact_flow_detail.raw_response_excerpt
      error
  in
  { outward_effect
  ; failure_evidence = Keeper_exact_walk_receipt.failure_evidence receipt
  ; detail
  }
;;

let cli_prompt_of_messages ~keeper_id (messages : Llm_provider.Types.message list) =
  match messages with
  | [ { Llm_provider.Types.content = [ Llm_provider.Types.Text prompt ]; _ } ] -> Some prompt
  | ( []
    | _ :: _ :: _
    | [ { Llm_provider.Types.content = []; _ } ]
    | [ { Llm_provider.Types.content = _ :: _ :: _; _ } ]
    | [ { Llm_provider.Types.content =
            [ ( Llm_provider.Types.Thinking _
              | Llm_provider.Types.ReasoningDetails _
              | Llm_provider.Types.RedactedThinking _
              | Llm_provider.Types.ToolUse _
              | Llm_provider.Types.ToolReference _
              | Llm_provider.Types.ToolResult _
              | Llm_provider.Types.Image _
              | Llm_provider.Types.Document _
              | Llm_provider.Types.Audio _ ) ]
      ; _
      } ] ) as messages ->
    Log.Keeper.warn
      ~keeper_name:keeper_id
      "librarian cli fallback skipped: fitted prompt is not one text message (%d messages)"
      (List.length messages);
    None
;;

type cli_fallback_failure =
  | No_cli_slots
  | Fitted_prompt_unavailable
  | Slot_failures of Keeper_lane_cli_oneshot.failure list

let try_cli_slots
      ~requirement
      ~validate
      ~keeper_id
      ~base_path
      ~cli_runner
      ~cli_slots
      ~messages
  =
  match cli_slots with
  | [] -> Error No_cli_slots
  | cli_slots ->
    (match cli_prompt_of_messages ~keeper_id messages with
     | None -> Error Fitted_prompt_unavailable
     | Some prompt ->
       (match
          Exact_lane_slot_capture.walk_cli
            ?runner:cli_runner
            ~base_dir:base_path
            ~cli_slots
            ~system_prompt:""
            ~requirement
            ~prompt
            ~validate:(fun output ->
              validate output
              |> Result.map (fun answer -> answer, output)
              |> Result.map_error Keeper_librarian.parse_error_to_string)
            ~on_failure:(fun failure ->
              Log.Keeper.warn
                ~keeper_name:keeper_id
                "librarian fallback: %s"
                (Keeper_lane_cli_oneshot.failure_to_string failure))
            ()
        with
        | Error failures -> Error (Slot_failures failures)
        | Ok (runtime_id, (selection, output)) -> Ok (runtime_id, selection, output)))
;;

let with_cli_failure prior_error = function
  | No_cli_slots -> prior_error
  | Slot_failures failures ->
    Cli_slots_exhausted { prior_error = Some prior_error; failures }
  | Fitted_prompt_unavailable -> Cli_prompt_unavailable { prior_error = Some prior_error }
;;

let execute_callable
      ~selected_slots
      ~held_ids
      ~cli_slots
      ~requirement
      ~validate
      ?cli_runner
      ~clock
      ~net
      ~base_path
      ~keeper_id
      ~messages
      ?usage_observer
      ()
  =
  let open Result.Syntax in
  match selected_slots with
  | [] ->
    (match
       try_cli_slots ~requirement ~validate ~keeper_id ~base_path ~cli_runner ~cli_slots ~messages
     with
     | Ok (runtime_id, selection, output) -> Ok ((selection, output), Cli_slot runtime_id)
     | Error No_cli_slots -> Error No_transport_declared
     | Error (Slot_failures failures) ->
       Error (Cli_slots_exhausted { prior_error = None; failures })
     | Error Fitted_prompt_unavailable -> Error (Cli_prompt_unavailable { prior_error = None }))
  | _ :: _ ->
    (match preflight_slots ~requirement ~selected_slots ~messages with
     | Error error ->
       (match
          try_cli_slots ~requirement ~validate ~keeper_id ~base_path ~cli_runner ~cli_slots
            ~messages
        with
        | Ok (runtime_id, selection, output) ->
          Log.Keeper.warn
            ~keeper_name:keeper_id
            "librarian lane=%s every API slot refused projection; answered by cli slot=%s: %s"
            exact_lane_id
            runtime_id
            (extraction_error_to_string error);
          Ok ((selection, output), Cli_slot runtime_id)
        | Error cli_failure -> Error (with_cli_failure error cli_failure))
     | Ok preflight ->
       if preflight.unusable <> []
       then
         Log.Keeper.warn
           ~keeper_name:keeper_id
           "librarian lane=%s pre-flight excluded slot(s) from this run: %s"
           exact_lane_id
           (slot_reason_pairs ~sep:", " preflight.unusable);
       let* attempt = prepare_attempt ~requirement ~selected_slots:preflight.selected_slots messages in
       let validate_flow flow_success =
         let output = Exact_output.flow_success_output flow_success in
         match validate output.output with
         | Ok answer -> Exact_output.Accept (answer, output.output)
         | Error error -> Exact_output.Reject_and_advance error
       in
       let flow =
         Exact_lane_slot_capture.flow attempt (fun () ->
           Exact_output.execute_flow_once
             ~net
             ~clock
             ~before_measurement_dispatch:(fun _ -> Ok ())
             ~on_measurement_terminal:(fun _ -> Ok ())
             ~before_dispatch:(fun _ -> Ok ())
             ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
             ~validate:validate_flow
             attempt)
       in
       Runtime_exact_lane_backpressure.observe
         ~resolved:Runtime_exact_output_registry.{ selected_slots; cli_slots }
         flow;
       (match flow with
        | Ok success ->
          let selected_slot =
            success.transport_success
            |> Exact_output.flow_success_candidate
            |> fun candidate -> candidate.visit.identity.candidate_id
          in
          (match usage_observer with
           | Some observe ->
             observe (Exact_output.flow_success_output success.transport_success).usage
           | None -> ());
          Ok (success.accepted, Api_slot selected_slot)
        | Error (Exact_output.Flow_execution_terminal { cause; prior_rejections }) ->
          let declared_http =
            List.map
              (fun (slot : Runtime_exact_output_registry.selected_slot) -> slot.slot_id)
              selected_slots
            @ held_ids
          in
          let excluded_http =
            List.map (fun (slot : slot_refusal) -> slot.slot_id) preflight.unusable @ held_ids
          in
          let terminal () =
            Error
              (Exact_execution_failed
                 (exact_execution_error
                    ~declared_http
                    ~excluded_http
                    ~declared_cli:cli_slots
                    ~semantic_rejections:prior_rejections
                    cause))
          in
          (match Exact_output.flow_execution_terminal_kind cause with
           | Exact_output.Advanceable_candidates_exhausted ->
             (match
                try_cli_slots ~requirement ~validate ~keeper_id ~base_path ~cli_runner ~cli_slots
                  ~messages
              with
              | Ok (runtime_id, selection, output) ->
                Ok ((selection, output), Cli_slot runtime_id)
              | Error cli_failure ->
                Error
                  (with_cli_failure
                     (Exact_execution_failed
                        (exact_execution_error
                           ~declared_http
                           ~excluded_http
                           ~declared_cli:cli_slots
                           ~semantic_rejections:prior_rejections
                           cause))
                     cli_failure))
           | Exact_output.Non_advanceable_terminal -> terminal ())
        | Error (Exact_output.Flow_semantic_candidates_exhausted { rejections; _ }) ->
          let rejection =
            List.fold_left (fun _ rejection -> rejection) rejections.first rejections.rest
          in
          (match
             try_cli_slots ~requirement ~validate ~keeper_id ~base_path ~cli_runner ~cli_slots
               ~messages
           with
           | Ok (runtime_id, selection, output) ->
             Ok ((selection, output), Cli_slot runtime_id)
           | Error cli_failure ->
             Error
               (with_cli_failure
                  (Domain_output_invalid (Keeper_librarian.parse_error_to_string rejection.rejection))
                  cli_failure))))
;;

let execute_answer
      ~selected_slots
      ~held_http
      ~cli_slots
      ~requirement
      ~validate
      ?cli_runner
      ~clock
      ~net
      ~base_path
      ~keeper_id
      ~messages
      ?usage_observer
      ()
  =
  let held_ids =
    List.map (fun (held : Runtime_exact_lane_backpressure.held_slot) -> held.slot_id) held_http
  in
  let callable () =
    execute_callable ~selected_slots ~held_ids ~cli_slots ~requirement ~validate ?cli_runner ~clock
      ~net ~base_path ~keeper_id ~messages ?usage_observer ()
  in
  match held_http with
  | [] -> callable ()
  | (first : Runtime_exact_lane_backpressure.held_slot) :: rest ->
    let until =
      List.fold_left
        (fun until (held : Runtime_exact_lane_backpressure.held_slot) -> Float.min until held.until)
        first.until
        rest
    in
    (match selected_slots, cli_slots with
     | [], [] -> Error (Slots_held { until; after = None })
     | _ :: _, _ | [], _ :: _ ->
       callable () |> Result.map_error (fun error -> Slots_held { until; after = Some error }))
;;

let execute_working_context_classified
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
  let* selected_slots, cli_slots, held_http = resolve_librarian_slots () in
  execute_answer
    ~selected_slots
    ~held_http
    ~cli_slots
    ~requirement:working_context_requirement
    ~validate:(Keeper_librarian.working_contexts_of_json_result selected_input)
    ?cli_runner
    ~clock
    ~net
    ~base_path
    ~keeper_id
    ~messages
    ()
;;

let record_failure_io ~keepers_dir ~keeper_id ~trace_id ~kind ~detail =
  let snapshot_absent =
    match Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id with
    | Ok (Some _) -> false
    | Ok None | Error _ -> true
  in
  let message =
    Printf.sprintf
      "%s kind=%s trace_id=%s current_snapshot=%s"
      detail
      (failure_kind_to_string kind)
      trace_id
      (if snapshot_absent then "absent" else "present")
  in
  if snapshot_absent
  then Log.Keeper.error ~keeper_name:keeper_id "%s" message
  else Log.Keeper.warn ~keeper_name:keeper_id "%s" message
;;

let record_failure ~keepers_dir ~keeper_id ~trace_id ~kind ~detail =
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    record_failure_io ~keepers_dir ~keeper_id ~trace_id ~kind ~detail)
;;

let prompt_material_payload ~key = function
  | Ok ({ resolution; rendered } : librarian_prompt_material) ->
    `Assoc
      [ "key", `String key
      ; "source", `String (Prompt_registry.prompt_source_to_string resolution.source)
      ; ( "file_path"
        , match resolution.file_path with
          | None -> `Null
          | Some path -> `String path )
      ; "effective_template", `String resolution.effective
      ; "rendered_bytes", `Int (String.length rendered)
      ; "rendered_sha256", `String Agent_core_sha256.(digest_string rendered |> to_hex)
      ]
  | Error _detail -> `Assoc [ "key", `String key ]
;;

let exact_input_payload
      (inp : Keeper_librarian.input)
      ~prompt_key
      ~(prompt_variables : (string * string) list)
      (prompt_material : (librarian_prompt_material, string) result)
  =
  `Assoc
    [ "turn_ref", Ids.Turn_ref.to_yojson inp.turn_ref
    ; "goal_context", Keeper_librarian.goal_context_to_json inp.goal_context
    ; "keeper_instructions", `String inp.keeper_instructions
    ; "prompt", prompt_material_payload ~key:prompt_key prompt_material
    ; ( "rendered_prompt_variables"
      , `Assoc (List.map (fun (name, value) -> name, `String value) prompt_variables) )
    ]
;;

type context_write =
  | Not_attempted
  | Withheld
  | Outcome_unconfirmed
  | Committed of Keeper_librarian_context.version
  | Write_failed of string

let context_write_json = function
  | Not_attempted -> `Assoc [ "status", `String "not_attempted" ]
  | Withheld -> `Assoc [ "status", `String "withheld" ]
  | Outcome_unconfirmed -> `Assoc [ "status", `String "outcome_unconfirmed" ]
  | Committed (generation, revision) ->
    `Assoc
      [ "status", `String "committed"
      ; "generation", `String generation
      ; "revision", `Int revision
      ]
  | Write_failed detail -> `Assoc [ "status", `String "failed"; "detail", `String detail ]
;;

let run_best_effort
      ?(on_cli_input_limit = fun _ -> ())
      ?(on_not_committed = fun _ -> ())
      ?(on_context_committed = fun _ -> ())
      ?cli_runner
      ~base_path
      ~keepers_dir
      ~keeper_id
      (inp : Keeper_librarian.input)
  =
  let trace_id = input_trace_id inp in
  try
    match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
    | Some net, Some clock ->
      let acquired = resolve_librarian_slots () in
      (match acquired with
       | Error (Exact_setup_failed (Exact_lane_unavailable (Exact_lane_off _))) ->
         let detail = "Librarian is off; pending input remains unconsumed" in
         on_not_committed
           { detail
           ; walk_shows_size = false
           ; message_descent = No_descent_evidence
           ; input_capacity_evidence = No_input_capacity_refusal
           ; input_capacity_only = false
           ; provider_input_refusals = []
           ; smaller_range_meets_same_failure = false
           };
         Log.Keeper.info ~keeper_name:keeper_id "%s" detail
       | Ok _
       | Error (Prompt_render_failed _)
       | Error
           (Exact_setup_failed
              ( Exact_registry_unavailable _
              | Exact_lane_unavailable (Exact_lane_unconfigured _ | No_admitted_lane_slots _)
              | Exact_candidate_invalid _
              | Exact_flow_snapshot_failed _
              | Exact_flow_start_failed _
              | Exact_request_projection_failed _ ))
       | Error (Exact_execution_failed _)
       | Error (Cli_slots_exhausted _)
       | Error (Cli_prompt_unavailable _)
       | Error No_transport_declared
       | Error (Slots_held _)
       | Error (Domain_output_invalid _) ->
         let registry = Exact_lane_run_registry.global () in
         let run_id = Random_id.prefixed ~prefix:"librarian-exact-" ~bytes:16 in
         let started_at = Time_compat.now () in
         let started_at_monotonic = Eio.Time.now clock in
         let prompt_variables, prompt_material = resolve_working_context_prompt inp in
         Exact_lane_run_registry.register_running
           registry
           ~run_id
           ~lane:Exact_lane_run_registry.Librarian
           ~actor:keeper_id
           ~started_at
           ~input:
             (Exact_lane_run_registry.Exact_input
                (`Assoc
                   [ ( "actual_input"
                     , exact_input_payload
                         inp
                         ~prompt_key:Prompt_names.librarian_working_context
                         ~prompt_variables
                         prompt_material )
                   ; "message_count", `Int 0
                   ; "current_fact_count", `Int 0
                   ]));
         let observed_context_review = ref None in
         let context_write = ref Not_attempted in
         let observed_usage = ref None in
         let slot_capture =
           Exact_lane_slot_capture.create ~owner:(Runtime_schema.Builtin Standalone_lane.Librarian) ()
         in
         let complete ?selected_slot ?usage outcome output =
           let context =
             match !observed_context_review, !context_write with
             | ( Some review
               , ((Not_attempted | Withheld | Outcome_unconfirmed | Committed _ | Write_failed _) as
                  write) ) ->
               [ "context_write", context_write_json write
               ; "context_review", Keeper_librarian_context_review.observation_to_yojson review
               ]
             | ( None
               , (Not_attempted | Withheld | Outcome_unconfirmed | Committed _ | Write_failed _) ) ->
               []
           in
           let output =
             match context, output with
             | [], _ -> output
             | context, `Assoc fields -> `Assoc (context @ fields)
             | _ :: _, _ -> output
           in
           let elapsed_s = Eio.Time.now clock -. started_at_monotonic in
           match
             Exact_lane_run_registry.mark_completed
               registry
               ~run_id
               ~outcome
               ~elapsed_s
               ~selected_slot
               ?usage
               ?slot_observations:(Exact_lane_slot_capture.observations slot_capture)
               ~output
               ()
           with
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
              let* selected_slots, cli_slots, held_http = acquired in
              let* prompt =
                prompt_material
                |> Result.map (fun material -> material.rendered)
                |> Result.map_error (fun detail -> Prompt_render_failed detail)
              in
              let* (proposed, exact_output), served_slot =
                Exact_lane_slot_capture.with_capture slot_capture (fun () ->
                  execute_answer
                    ~selected_slots
                    ~held_http
                    ~cli_slots
                    ~requirement:working_context_requirement
                    ~validate:(Keeper_librarian.working_contexts_of_json_result inp)
                    ?cli_runner
                    ~clock
                    ~net
                    ~base_path
                    ~keeper_id
                    ~messages:[ message Agent_core.Types.User prompt ]
                    ~usage_observer:(fun usage -> observed_usage := usage)
                    ())
              in
              let selected_slot = served_slot_id served_slot in
              let context_review =
                Keeper_librarian_context_review.run
                  ~observe:(fun observation -> observed_context_review := Some observation)
                  ~clock
                  ~keeper_id
                  ~input:inp.working_context
                  ~proposed
                  ()
              in
              (match Keeper_librarian_context_review.withholding_kind context_review with
               | Needs_revision ->
                 context_write := Withheld;
                 Log.Keeper.info
                   ~keeper_name:keeper_id
                   "working context withheld by review: pockets=%d"
                   (List.length proposed)
               | Review_failed reason ->
                 context_write := Withheld;
                 Log.Keeper.warn
                   ~keeper_name:keeper_id
                   "working context withheld fail-closed (%s): pockets=%d"
                   reason
                   (List.length proposed)
               | Not_withheld ->
                 context_write := Outcome_unconfirmed;
                 (try
                    match
                      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                        Keeper_librarian_context.commit
                          ~keepers_dir
                          ~keeper_id
                          ~expected_version:
                            (Option.map Keeper_librarian_context.version inp.working_context.previous)
                          ?execution_basis:inp.working_context.execution_basis
                          ?observed_sources:
                            (if inp.working_context.unavailable = []
                             then Some inp.working_context.sources
                             else None)
                          ~sources:
                            (let references =
                               List.concat_map
                                 (fun (p : Keeper_librarian_context.pocket) -> p.sources)
                                 proposed
                             in
                             List.filter
                               (fun (s : Keeper_librarian_context.source) ->
                                  List.mem s.reference references)
                               inp.working_context.sources)
                          proposed)
                    with
                    | Ok working ->
                      context_write := Committed (Keeper_librarian_context.version working);
                      on_context_committed (Keeper_librarian_context.version working);
                      (match
                         Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                           Keeper_librarian_context_recall.publish
                             ~base_path
                             ~keepers_dir
                             ~keeper_name:keeper_id
                             working)
                       with
                       | Ok () -> ()
                       | Error detail ->
                         Log.Keeper.warn
                           ~keeper_name:keeper_id
                           "working context reference publication failed: %s"
                           detail);
                      let covered = Keeper_librarian_context.current_references working in
                      let prior =
                        match inp.working_context.previous with
                        | None -> []
                        | Some previous -> Keeper_librarian_context.current_references previous
                      in
                      let made_progress =
                        List.exists (fun reference -> not (List.mem reference prior)) covered
                      in
                      let remaining =
                        List.exists
                          (fun (source : Keeper_librarian_context.source) ->
                             not (List.mem source.reference covered))
                          inp.working_context.sources
                      in
                      if made_progress && remaining
                      then Keeper_working_context_signal.changed ~base_path ~keeper_name:keeper_id
                    | Error detail ->
                      context_write := Write_failed detail;
                      Log.Keeper.warn
                        ~keeper_name:keeper_id
                        "working context not committed; original intake continues: %s"
                        detail
                  with
                  | Eio.Cancel.Cancelled _ as exn -> raise exn
                  | exn ->
                    Log.Keeper.warn
                      ~keeper_name:keeper_id
                      "working context commit failed independently of memory: %s"
                      (Printexc.to_string exn)));
              Ok (exact_output, selected_slot)
            in
            match result with
            | Ok (exact_output, selected_slot) ->
              complete
                ~selected_slot
                ?usage:!observed_usage
                Exact_lane_run_registry.Succeeded
                (`Assoc
                   [ "memory_write", `String "skipped_context_only"
                   ; "exact_output", exact_output
                   ]);
              Eio.Fiber.check ()
            | Error error ->
              let evidence = extraction_failure_evidence error in
              Option.iter on_cli_input_limit evidence.measured_cli_capacity;
              let detail = extraction_error_to_string error in
              on_not_committed (not_committed_of_failure ~detail evidence);
              complete
                (Exact_lane_run_registry.Failed { code = "librarian_failed"; detail })
                (`Assoc []);
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string MemoryOsLibrarianFailures)
                ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
                ();
              Keeper_memory_health_input.written ~keepers_dir ~keeper_id;
              record_failure
                ~keepers_dir
                ~keeper_id
                ~trace_id
                ~kind:(extraction_error_kind error)
                ~detail:(Printf.sprintf "memory os librarian lane=%s: %s" exact_lane_id detail);
              Eio.Fiber.check ()
          with
          | Eio.Cancel.Cancelled _ as exn ->
            Eio.Cancel.protect (fun () ->
              let run_completed =
                List.exists
                  (fun (run : Exact_lane_run_registry.run) ->
                     String.equal run.run_id run_id
                     &&
                     match run.status with
                     | Exact_lane_run_registry.Completed _ -> true
                     | Running | Completion_persistence_failed _ -> false)
                  (Exact_lane_run_registry.list_runs registry)
              in
              if not run_completed then complete Exact_lane_run_registry.Cancelled (`Assoc []);
              Eio_unix.run_in_systhread ~label:"librarian-cancellation-journal" (fun () ->
                record_failure_io
                  ~keepers_dir
                  ~keeper_id
                  ~trace_id
                  ~kind:Lane_cancelled
                  ~detail:(Printf.sprintf "memory os librarian cancelled lane=%s" exact_lane_id)));
            raise exn
          | exn ->
            complete
              (Exact_lane_run_registry.Failed
                 { code = "librarian_raised"; detail = "Librarian raised: " ^ Printexc.to_string exn })
              (`Assoc []);
            raise exn))
    | _ ->
      let detail =
        Printf.sprintf
          "memory os librarian skipped: Eio net/clock context unavailable lane=%s"
          exact_lane_id
      in
      on_not_committed
        { detail
        ; walk_shows_size = false
        ; message_descent = No_descent_evidence
        ; input_capacity_evidence = No_input_capacity_refusal
        ; input_capacity_only = false
        ; provider_input_refusals = []
        ; smaller_range_meets_same_failure = false
        };
      record_failure
        ~keepers_dir
        ~keeper_id
        ~trace_id
        ~kind:Runtime_context_unavailable
        ~detail
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string MemoryOsLibrarianFailures)
      ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
      ();
    Keeper_memory_health_input.written ~keepers_dir ~keeper_id;
    on_not_committed
      { detail = "librarian raised: " ^ Printexc.to_string exn
      ; walk_shows_size = false
      ; message_descent = No_descent_evidence
      ; input_capacity_evidence = No_input_capacity_refusal
      ; input_capacity_only = false
      ; provider_input_refusals = []
      ; smaller_range_meets_same_failure = false
      };
    record_failure
      ~keepers_dir
      ~keeper_id
      ~trace_id
      ~kind:Unhandled_exception
      ~detail:
        (Printf.sprintf
           "memory os librarian lane=%s: %s"
           exact_lane_id
           (Printexc.to_string exn))
;;

module For_testing = struct
  let cause_input_refusals cause = (Failure_evidence.of_cause cause).provider_input_refusals

  type classified_error = extraction_error

  let classified_error_detail = extraction_error_to_string
  let classified_error_kind = extraction_error_kind
  let execute_working_context_classified = execute_working_context_classified
  let record_failure = record_failure

  let cause_shows_size cause = Failure_evidence.shows_range_size (Failure_evidence.of_cause cause)

  let cli_failure_shows_size failure =
    Failure_evidence.shows_range_size (Failure_evidence.of_cli_failure failure)
  ;;

  let disposition_shows_size disposition =
    Failure_evidence.shows_range_size (Failure_evidence.of_disposition disposition)
  ;;
end
