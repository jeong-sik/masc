open Result.Syntax
open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_errors
open Keeper_skill_activation_ledger_encode
open Keeper_skill_activation_ledger_decode_parts
open Keeper_skill_activation_ledger_decode_activation

(* ── Durable event log ──────────────────────────────────────────────

   A session's ledger is an append-only JSONL file. Its first row names the
   workspace and the session; every later row is one change -- an activation
   recorded, deliveries observed, an action observed, or a transition
   rejected. The ledger a reader sees is those rows applied in order, and a
   mutation is the event it appends applied to the ledger it read, so what a
   process holds and what a replay of the file rebuilds are one function of
   the same rows.

   A mutation appends one row. This process keeps each session's applied
   ledger with the file cursor it was read to, and the next read under the
   session lock takes only the rows written after that cursor.
   [events_schema] names the row shape of the whole log. A change that makes
   an existing row undecodable bumps it, so a log of another generation is
   refused at its header as [Unsupported_schema] instead of at the first row
   the new decoder cannot read. v2 begins where a composition invocation
   carries its physical [execution_id]; v1 composition rows have none. A log
   of another generation is retired by the operator while the server is
   stopped, and no reader converts it. Rollback to a binary of an earlier
   generation is unsupported for the same reason. *)

let events_schema = "masc.skill-activation-events/v2"
let events_filename = "skill-activation-events.jsonl"
let events_path session_dir = Filename.concat session_dir events_filename

type event =
  | Activation_recorded of activation
  | Deliveries_observed of (string * delivery) list
  | Action_observed of
      { skill_tool_use_ids : string list
      ; action : action
      }
  | Transition_rejected of transition_rejection
  | Async_result_delivered of Keeper_skill_async_delivery.t
  | Async_action_observed of Keeper_skill_async_action.t

let header_to_yojson ~workspace_key ~session_id =
  `Assoc
    [ "schema", `String events_schema
    ; "kind", `String "opened"
    ; "workspace_key", `String workspace_key
    ; "session_id", `String (Keeper_id.Trace_id.to_string session_id)
    ]
;;

let event_to_yojson = function
  | Activation_recorded activation ->
    `Assoc
      [ "kind", `String "activation_recorded"
      ; "activation", activation_to_yojson activation
      ]
  | Deliveries_observed deliveries ->
    `Assoc
      [ "kind", `String "deliveries_observed"
      ; ( "deliveries"
        , `List
            (List.map
               (fun (skill_tool_use_id, delivery) ->
                  `Assoc
                    [ "skill_tool_use_id", `String skill_tool_use_id
                    ; "delivery", delivery_to_yojson delivery
                    ])
               deliveries) )
      ]
  | Action_observed { skill_tool_use_ids; action } ->
    `Assoc
      [ "kind", `String "action_observed"
      ; ( "skill_tool_use_ids"
        , `List (List.map (fun id -> `String id) skill_tool_use_ids) )
      ; "action", action_to_yojson action
      ]
  | Async_action_observed action ->
    `Assoc ["kind",`String "async_action_observed";"action",Keeper_skill_async_action.to_json action]
  | Async_result_delivered delivery ->
    `Assoc ["kind",`String "async_result_delivered";"delivery",Keeper_skill_async_delivery.to_json delivery]
  | Transition_rejected rejection ->
    `Assoc
      [ "kind", `String "transition_rejected"
      ; "rejection", transition_rejection_to_yojson rejection
      ]
;;

let event_row json = Yojson.Safe.to_string json ^ "\n"

let required_field ~field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Expected_object { field })
;;

let decode_header ~expected_workspace_key ~expected_trace_id json =
  let* fields = object_field "events_header" json in
  let* () =
    exact_fields
      ~object_name:"events_header"
      ~allowed:[ "schema"; "kind"; "workspace_key"; "session_id" ]
      fields
  in
  let* observed_schema = string_field "schema" fields in
  let* () =
    if String.equal observed_schema events_schema
    then Ok ()
    else Error (Unsupported_schema observed_schema)
  in
  let* kind = string_field "kind" fields in
  let* () =
    if String.equal kind "opened" then Ok () else Error (Invalid_event_kind kind)
  in
  let* session_id = string_field "session_id" fields in
  let* session_id =
    Keeper_id.Trace_id.of_string session_id
    |> Result.map_error (fun _ -> Invalid_session_id session_id)
  in
  let* () =
    if Keeper_id.Trace_id.equal session_id expected_trace_id
    then Ok ()
    else Error Session_id_mismatch
  in
  let* workspace_key = string_field "workspace_key" fields in
  if String.equal workspace_key expected_workspace_key
  then Ok ()
  else Error Workspace_key_mismatch
;;

let decode_event ~expected_trace_id json =
  let* fields = object_field "event" json in
  let* kind = string_field "kind" fields in
  match kind with
  | "activation_recorded" ->
    let* () =
      exact_fields ~object_name:"event" ~allowed:[ "kind"; "activation" ] fields
    in
    let* activation = required_field ~field:"activation" fields in
    let* activation = decode_activation ~expected_trace_id activation in
    Ok (Activation_recorded activation)
  | "deliveries_observed" ->
    let* () =
      exact_fields ~object_name:"event" ~allowed:[ "kind"; "deliveries" ] fields
    in
    (match List.assoc_opt "deliveries" fields with
     | Some (`List values) ->
       let* reversed =
         List.fold_left
           (fun result value ->
              let* reversed = result in
              let* entry = object_field "delivery_observation" value in
              let* () =
                exact_fields
                  ~object_name:"delivery_observation"
                  ~allowed:[ "skill_tool_use_id"; "delivery" ]
                  entry
              in
              let* skill_tool_use_id = string_field "skill_tool_use_id" entry in
              let* delivery = required_field ~field:"delivery" entry in
              let* delivery = decode_delivery delivery in
              match delivery with
              | Some delivery -> Ok ((skill_tool_use_id, delivery) :: reversed)
              | None -> Error (Expected_object { field = "delivery" }))
           (Ok [])
           values
       in
       Ok (Deliveries_observed (List.rev reversed))
     | Some _ | None -> Error (Expected_object { field = "deliveries" }))
  | "action_observed" ->
    let* () =
      exact_fields
        ~object_name:"event"
        ~allowed:[ "kind"; "skill_tool_use_ids"; "action" ]
        fields
    in
    let* skill_tool_use_ids =
      match List.assoc_opt "skill_tool_use_ids" fields with
      | Some (`List values) ->
        List.fold_left
          (fun result value ->
             let* reversed = result in
             match value with
             | `String id -> Ok (id :: reversed)
             | _ -> Error (Missing_string { field = "skill_tool_use_ids" }))
          (Ok [])
          values
        |> Result.map List.rev
      | Some _ | None -> Error (Expected_object { field = "skill_tool_use_ids" })
    in
    let* action = required_field ~field:"action" fields in
    let* action = decode_action action in
    Ok (Action_observed { skill_tool_use_ids; action })
  | "async_action_observed" ->
    let* () = exact_fields ~object_name:"event" ~allowed:["kind";"action"] fields in
    let* json = required_field ~field:"action" fields in
    let* action = Keeper_skill_async_action.of_json json
      |> Result.map_error (fun detail -> Invalid_async_action_evidence detail) in
    Ok (Async_action_observed action)
  | "async_result_delivered" ->
    let* () = exact_fields ~object_name:"event" ~allowed:["kind";"delivery"] fields in
    let* json = required_field ~field:"delivery" fields in
    let* delivery = Keeper_skill_async_delivery.of_json json
      |> Result.map_error (fun detail -> Invalid_async_result_evidence detail) in
    Ok (Async_result_delivered delivery)
  | "transition_rejected" ->
    let* () =
      exact_fields ~object_name:"event" ~allowed:[ "kind"; "rejection" ] fields
    in
    let* rejection = required_field ~field:"rejection" fields in
    let* rejection = decode_transition_rejection ~expected_trace_id rejection in
    Ok (Transition_rejected rejection)
  | kind -> Error (Invalid_event_kind kind)
;;
