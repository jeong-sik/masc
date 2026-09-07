module P = Keeper_recovery_projection
module Checkpoint = Keeper_checkpoint_store

let ( let* ) = Result.bind

type t =
  { source : Keeper_checkpoint_ref.t
  ; original : Agent_core.Types.message list
  ; transmitted : Agent_core.Types.message list
  }

type error =
  | Projection_source_rejected of P.error
  | Source_prefix_missing of
      { expected_messages : int
      ; actual_messages : int
      }
  | Source_prefix_changed of { message_index : int }
  | Incomplete_transmission of Keeper_transcript_unit.provider_transcript_error
  | Client_projection_not_integrated of { runtime_id : string }
  | Source_reader_unavailable

type Agent_core.Error.carrier += Recovery_transmission_failure of error

let error_to_string = function
  | Projection_source_rejected e -> P.error_to_string e
  | Source_prefix_missing { expected_messages; actual_messages } ->
    Printf.sprintf
      "recovery canonical prefix needs %d messages, received %d"
      expected_messages
      actual_messages
  | Source_prefix_changed { message_index } ->
    Printf.sprintf "recovery canonical message %d changed" message_index
  | Incomplete_transmission e -> Keeper_transcript_unit.show_provider_transcript_error e
  | Client_projection_not_integrated { runtime_id } ->
    Printf.sprintf
      "recovery transmission for client-owned runtime %s is not integrated; this is not \
       a provider capability failure"
      runtime_id
  | Source_reader_unavailable ->
    "canonical workspace artifact reader is absent from the offered Tool surface"
;;

let to_core_error error =
  Agent_core.Error.Internal_carried
    { message = error_to_string error; carrier = Recovery_transmission_failure error }
;;

let of_core_error = function
  | Agent_core.Error.Internal_carried { carrier = Recovery_transmission_failure e; _ } ->
    Some e
  | _ -> None
;;

let should_try_next error =
  match of_core_error error with
  | Some (Client_projection_not_integrated _) -> true
  | _ -> false
;;

let derived_message (d : P.derived) =
  let provenance =
    `Assoc
      [ "source_sha256", `String d.source_sha256
      ; "first_message", `Int d.first_message
      ; "last_message", `Int d.last_message
      ]
  in
  let read_args =
    Yojson.Safe.to_string (`Assoc [ "sha256", `String d.source_sha256; "offset", `Int 0 ])
  in
  let text =
    Printf.sprintf
      "Derived recovery context, not an original Assistant message or Tool result.\n\
       Source artifact SHA256: %s\n\
       Original message range: %d..%d (inclusive, zero-based).\n\
       Read the original with keeper_artifact_read %s; follow its next_offset and \
       referenced artifact IDs for source details.\n\n\
       %s"
      d.source_sha256
      d.first_message
      d.last_message
      read_args
      d.text
  in
  Agent_core.Types.
    { role = User
    ; content = [ Text text ]
    ; name = None
    ; tool_call_id = None
    ; metadata = [ "masc.recovery_derived_context", provenance ]
    }
;;

let create ~source ~validated =
  let* segments =
    P.bind_exact ~current_source:source validated
    |> Result.map_error (fun e -> Projection_source_rejected e)
  in
  let transmitted =
    List.concat_map
      (function
        | P.Original messages -> messages
        | P.Derived d -> [ derived_message d ])
      segments
  in
  Ok
    { source = Checkpoint.exact_snapshot_reference source
    ; original = Checkpoint.exact_snapshot_messages source
    ; transmitted
    }
;;

let source_reference t = t.source

let validate messages =
  Keeper_transcript_unit.validate_provider_transcript messages
  |> Result.map_error (fun e -> Incomplete_transmission e)
;;

let project t incoming =
  let rec suffix index original current =
    match original, current with
    | [], rest -> Ok rest
    | _ :: _, [] ->
      Error
        (Source_prefix_missing
           { expected_messages = List.length t.original; actual_messages = index })
    | old :: olds, actual :: rest ->
      if old == actual || old = actual
      then suffix (index + 1) olds rest
      else Error (Source_prefix_changed { message_index = index })
  in
  let* appended = suffix 0 t.original incoming in
  let* () = validate incoming in
  let projected = t.transmitted @ appended in
  let* () = validate projected in
  Ok projected
;;

let model_input_projection t ?after messages =
  let* projected =
    Domain_pool_ref.submit_cpu_or_inline (fun () -> project t messages)
    |> Result.map_error to_core_error
  in
  match after with
  | None -> Ok projected
  | Some project -> project projected
;;

let require_reader tools =
  let schema = Keeper_runtime_schemas_toml.artifact_read in
  match
    Agent_core.Types.tool_schema_of_input_schema
      ~name:schema.name
      ~description:schema.description
      ~input_schema:schema.input_schema
      ()
  with
  | Error _ -> Error Source_reader_unavailable
  | Ok schema ->
    let expected_wire = Agent_core.Tool.wire_json_of_schema schema in
    let expected_descriptor =
      Agent_core.Tool.descriptor_to_yojson
        (Some (Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent))
    in
    if
      List.exists
        (fun tool ->
           Agent_core.Tool.schema_to_json tool = expected_wire
           && Agent_core.Tool.descriptor_to_yojson (Agent_core.Tool.descriptor tool)
              = expected_descriptor)
        tools
    then Ok ()
    else Error Source_reader_unavailable
;;
