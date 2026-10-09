(** Host registry and telemetry boundary for shared input validation. *)
include Tool_input_contract

let emit_validation_telemetry ~tool ~result ~reason =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_tool_input_validation
    ~labels:[ "tool", tool; "result", result; "reason", reason ]
    ();
  Otel_spans.add_event
    ~name:"tool.param.validation"
    ~attrs:
      [ "tool.name", `String tool
      ; "tool.param.validation.result", `String result
      ; "tool.param.validation.reason", `String reason
      ]
    ()
;;

let validate ?schema ~name ~args () =
  let checked =
    try
      let schema =
        match schema with
        | Some _ as schema -> schema
        | None -> Tool_dispatch.lookup_schema name
      in
      check_arguments ~schema ~name ~args
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      let exception_text = Printexc.to_string exn in
      Error
        { tool_name = name
        ; schema = None
        ; violation = Validation_raised { exception_text }
        ; message =
            Printf.sprintf
              "Tool '%s' parameter validation failed before dispatch: %s"
              name
              exception_text
        }
  in
  match checked with
  | Ok (prepared_args, accepted) ->
    emit_validation_telemetry ~tool:name ~result:"pass" ~reason:(accepted_reason accepted);
    (match accepted with
     | Accepted_normalized ->
       Log.Tool_validation.debug "tool_input_validation normalized args for %s" name
     | Accepted_empty_schema | Accepted_valid -> ());
    Ok prepared_args
  | Error rejection ->
    emit_validation_telemetry
      ~tool:name
      ~result:"fail"
      ~reason:(violation_reason rejection.violation);
    (match rejection.violation with
     | Validation_raised _ -> Log.Tool_validation.error "%s" rejection.message
     | Schema_not_registered
     | Schema_declares_required_without_properties
     | Schema_unusable _
     | Schema_bound_malformed _
     | Arguments_for_fieldless_schema
     | Retired_transition_alias _
     | Arguments_did_not_arrive
     | Unsupported_fields _
     | No_one_of_branch_matches
     | Several_one_of_branches_match
     | Field_errors _
     | Argument_out_of_range _ ->
       Log.Tool_validation.info
         "tool_input_validation rejected %s: %s"
         name
         rejection.message);
    Error rejection
;;

let validate_args ?schema ~name ~args () =
  match validate ?schema ~name ~args () with
  | Ok prepared_args -> Ok prepared_args
  | Error rejection -> Error (rejection_result rejection)
;;

let validation_action ~name ~args : Tool_dispatch.pre_hook_action =
  match validate ~name ~args () with
  | Ok prepared_args when Yojson.Safe.equal prepared_args args -> Tool_dispatch.Pass
  | Ok prepared_args -> Tool_dispatch.Proceed prepared_args
  | Error rejection -> Tool_dispatch.Reject (rejection_result rejection)
;;

let register_pre_hook () =
  Tool_dispatch.register_pre_hook (fun ~name ~args -> validation_action ~name ~args)
;;
