type outcome =
  | Not_applicable
  | Applied of string
  | Failed of string

let outcome_to_string = function
  | Not_applicable -> "not_applicable"
  | Applied summary -> Printf.sprintf "applied: %s" summary
  | Failed detail -> Printf.sprintf "failed: %s" detail
;;

(* Replay recognizes exactly the identity its producer submits; every other
   approved operation stays with its own producer. The identity is read from
   that producer so the literal has one definition. *)
let write_operation = Keeper_tool_filesystem_runtime.gate_operation
let execute_operation = Keeper_tool_execute_runtime.gate_operation

(* The producer owns both the argument schema and the effect encoding, so it
   owns the inversion; replay only decides whether to spend the grant. *)
let write_args_of_gate_input =
  Keeper_tool_filesystem_runtime.replay_args_of_gate_input
;;

let execute_args_of_gate_input =
  Keeper_tool_execute_runtime.replay_args_of_gate_input
;;

(* Which approved operations this module can spend without the Keeper
   re-emitting the call. Separated from the replay body so the set is
   assertable: a decode function that exists but is never dispatched to looks
   exactly like a working replay from the outside. *)
type replayable =
  | Replay_write
  | Replay_execute

let replayable_of_operation operation =
  if String.equal operation write_operation
  then Some Replay_write
  else if String.equal operation execute_operation
  then Some Replay_execute
  else None
;;

let summarize_execution ~operation (execution : Keeper_tool_execution.t) =
  match execution.disposition with
  | Tool_result.Completed _ -> Applied execution.raw_output
  | Tool_result.Deferred _ ->
    (* The re-derived canonical input no longer matches the approval — what
       the approval pinned is not what replay would act on now. The effect
       stays unapplied and its new request follows the ordinary Gate. *)
    Failed
      (Printf.sprintf
         "approved %s no longer matches what was approved; not applied"
         operation)
  | Tool_result.Failed _ -> Failed execution.raw_output
;;

let replay_approved_effect
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ?continuation_channel
      ?gate_context
      ~(grant : Keeper_gate.cycle_grant)
      ~approval_id
      ()
  =
  match
    Keeper_approval_queue.approved_resolution_request
      ~base_path:config.base_path
      ~id:approval_id
  with
  | Error error ->
    Failed (Keeper_approval_queue.grant_error_to_string error)
  | Ok None -> Not_applicable
  | Ok (Some request) ->
    let replay_gate_context =
      match request.tool_call_id with
      | None -> gate_context
      | Some tool_call_id ->
        Some
          (fun () ->
            let base_context =
              match gate_context with
              | Some current -> current ()
              | None ->
                { Keeper_gate.turn_id = None
                ; tool_call_id = None
                ; snapshot = `Assoc []
                }
            in
            { base_context with tool_call_id = Some tool_call_id })
    in
    let replay operation decode run =
      match decode request.input with
      | Error detail -> Failed detail
      | Ok args -> summarize_execution ~operation (run args)
    in
    (match replayable_of_operation request.tool_name with
     | None -> Not_applicable
     | Some Replay_write ->
       replay write_operation write_args_of_gate_input (fun args ->
         Keeper_tool_filesystem_runtime.handle_file_write_with_outcome
           ~turn_sandbox_factory
           ~config
           ~meta
           ~publication_recovery
           ?continuation_channel
           ?gate_context:replay_gate_context
           ~gate_grant:grant
           ~args
           ())
     | Some Replay_execute ->
       replay execute_operation execute_args_of_gate_input (fun args ->
         Keeper_tool_execute_runtime.handle_tool_execute_with_outcome
           ~turn_sandbox_factory
           ~config
           ~meta
           ?continuation_channel
           ?gate_context:replay_gate_context
           ~gate_grant:grant
           ~args
           ()))
;;
