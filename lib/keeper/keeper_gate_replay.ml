type outcome =
  | Not_applicable
  | Applied of string
  | Failed of string

let outcome_to_string = function
  | Not_applicable -> "not_applicable"
  | Applied summary -> Printf.sprintf "applied: %s" summary
  | Failed detail -> Printf.sprintf "failed: %s" detail
;;

(* The opaque operation identity the filesystem runtime submits to the Gate.
   Replay only recognizes this one identity; every other approved operation
   stays with its own producer. *)
let write_operation = "filesystem_write"

let payload_fields = [ "content"; "old_string"; "new_string"; "replace_all" ]

let write_args_of_gate_input input =
  match input with
  | `Assoc fields ->
    (match List.assoc_opt "requested_target" fields with
     | Some (`String target) ->
       let carried =
         List.filter_map
           (fun name ->
              Option.map (fun value -> name, value) (List.assoc_opt name fields))
           payload_fields
       in
       Ok (`Assoc (("path", `String target) :: carried))
     | Some _ -> Error "approved Gate input has a non-string requested_target"
     | None -> Error "approved Gate input has no requested_target")
  | _ -> Error "approved Gate input is not a JSON object"
;;

let summarize_execution (execution : Keeper_tool_execution.t) =
  match execution.disposition with
  | Tool_result.Completed _ -> Applied execution.raw_output
  | Tool_result.Deferred _ ->
    (* The re-derived canonical input no longer matches the approval — the
       pinned target changed between approval and replay. The effect stays
       unapplied and its new request follows the ordinary Gate. *)
    Failed "approved write no longer matches its pinned target; not applied"
  | Tool_result.Failed _ -> Failed execution.raw_output
;;

let replay_approved_write
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
    if not (String.equal request.tool_name write_operation)
    then Not_applicable
    else (
      match write_args_of_gate_input request.input with
      | Error detail -> Failed detail
      | Ok args ->
        let execution =
          Keeper_tool_filesystem_runtime.handle_file_write_with_outcome
            ~turn_sandbox_factory
            ~config
            ~meta
            ~publication_recovery
            ?continuation_channel
            ?gate_context
            ~gate_grant:grant
            ~args
            ()
        in
        summarize_execution execution)
;;
