(** Exact TUI projection for the actor-scoped operator confirmation surface.

    This module lives above [masc.operator] so it can reuse the canonical
    pending-confirm parser without introducing a dependency cycle into the
    core [Masc.Tui_decode] library. *)

type approval_item = {
  ap_token : string;
  ap_trace_id : string;
  ap_actor : string;
  ap_action_type : string;
  ap_target_type : string;
  ap_target_id : string option;
  ap_payload : Yojson.Safe.t;
  ap_delegated_tool : string;
  ap_created_at : string;
  ap_expires_at : string option;
  ap_summary : string;
}

type approval_snapshot = {
  aps_items : approval_item list;
  aps_actor_filter : string option;
  aps_filter_active : bool;
  aps_visible_count : int;
  aps_total_count : int;
  aps_hidden_count : int;
}

type approval_decision =
  | Confirm
  | Deny

type pending_approval_action = {
  paa_token : string;
  paa_decision : approval_decision;
}

type approval_gate_transition =
  | Gate_blocked_inflight
  | Gate_arm of pending_approval_action
  | Gate_submit

type confirm_outcome =
  | Completed of Yojson.Safe.t
  | Deferred of Yojson.Safe.t
  | Execution_failed of Yojson.Safe.t * string

module Flow = struct
  type generation = int

  type t = {
    latest : generation;
    action : generation option;
  }

  let initial = { latest = 0; action = None }
  let action_inflight state = Option.is_some state.action

  let reserve_refresh state =
    match state.action with
    | Some _ -> state, None
    | None ->
        let generation = state.latest + 1 in
        { latest = generation; action = None }, Some generation

  let begin_action state =
    match state.action with
    | Some _ -> Error `Already_inflight
    | None ->
        let generation = state.latest + 1 in
        Ok ({ latest = generation; action = Some generation }, generation)

  let finish_action state generation =
    match state.action with
    | Some current when current = generation ->
        { state with action = None }, true
    | Some _ | None -> state, false

  let is_current state generation = state.latest = generation
end

let ( let* ) = Result.bind

let member key json =
  match Json_util.assoc_member_opt key json with
  | Some value -> value
  | None -> `Null

let approval_of_pending_confirm
    (entry : Operator_pending_confirm.pending_confirm) =
  {
    ap_token = entry.confirm_token;
    ap_trace_id = entry.trace_id;
    ap_actor = entry.actor;
    ap_action_type = entry.action_type;
    ap_target_type = entry.target_type;
    ap_target_id = entry.target_id;
    ap_payload = entry.payload;
    ap_delegated_tool = entry.delegated_tool;
    ap_created_at = entry.created_at;
    ap_expires_at = entry.expires_at;
    ap_summary =
      Printf.sprintf "%s on %s (%s)" entry.action_type entry.target_type
        entry.delegated_tool;
  }

let approval_decision_wire = function
  | Confirm -> "confirm"
  | Deny -> "deny"

let approval_gate_transition ~inflight ~pending ~token ~decision =
  if inflight then Gate_blocked_inflight
  else
    match pending with
    | Some pending
      when String.equal pending.paa_token token
           && pending.paa_decision = decision ->
        Gate_submit
    | Some _ | None -> Gate_arm { paa_token = token; paa_decision = decision }

let fallback_cursor ~cursor items =
  min (max 0 cursor) (max 0 (List.length items - 1))

let reconcile_cursor ~current_items ~cursor ~next_items =
  let selected_token =
    if cursor < 0 then None
    else Option.map (fun item -> item.ap_token) (List.nth_opt current_items cursor)
  in
  match selected_token with
  | Some token ->
      (match
         List.find_index
           (fun item -> String.equal token item.ap_token)
           next_items
       with
       | Some index -> index
       | None -> fallback_cursor ~cursor next_items)
  | None -> fallback_cursor ~cursor next_items

let decode_string_list label values =
  Masc.Tui_decode.decode_list label
    (function
      | `String value when String.trim value <> "" -> Ok ()
      | `String _ -> Error "must not contain blank strings"
      | other ->
          Error
            (Printf.sprintf "must contain strings (received %s)"
               (Json_util.kind_name other)))
    values

let decode_object_list label values =
  Masc.Tui_decode.decode_list label
    (function
      | `Assoc _ -> Ok ()
      | other ->
          Error
            (Printf.sprintf "must contain objects (received %s)"
               (Json_util.kind_name other)))
    values

let duplicate_token items =
  let module Tokens = Set.Make (String) in
  let rec loop seen = function
    | [] -> None
    | item :: rest ->
        if Tokens.mem item.ap_token seen then Some item.ap_token
        else loop (Tokens.add item.ap_token seen) rest
  in
  loop Tokens.empty items

let decode_snapshot json =
  let* envelope =
    Masc.Tui_decode.required_object_field json "pending_confirm_envelope"
  in
  let* items = Masc.Tui_decode.required_list_field envelope "items" in
  let* aps_items =
    Masc.Tui_decode.decode_list "pending_confirm_envelope.items"
      (fun item ->
        let* pending = Operator_pending_confirm.pending_confirm_of_yojson item in
        Ok (approval_of_pending_confirm pending))
      items
  in
  let* summary = Masc.Tui_decode.required_object_field envelope "summary" in
  let* aps_actor_filter =
    Masc.Tui_decode.optional_string_field summary "actor_filter"
  in
  let* aps_filter_active =
    match member "filter_active" summary with
    | `Bool value -> Ok value
    | `Null -> Error "missing required field 'filter_active'"
    | other ->
        Error
          (Printf.sprintf
             "field 'filter_active' must be a bool (received %s)"
             (Json_util.kind_name other))
  in
  let* aps_visible_count =
    Masc.Tui_decode.required_int_field summary "visible_count"
  in
  let* aps_total_count =
    Masc.Tui_decode.required_int_field summary "total_count"
  in
  let* aps_hidden_count =
    Masc.Tui_decode.required_int_field summary "hidden_count"
  in
  let* hidden_actors =
    Masc.Tui_decode.required_list_field summary "hidden_actors"
  in
  let* _ = decode_string_list "pending_confirm_envelope.summary.hidden_actors" hidden_actors in
  let* confirm_required_actions =
    Masc.Tui_decode.required_list_field summary "confirm_required_actions"
  in
  let* _ =
    decode_object_list
      "pending_confirm_envelope.summary.confirm_required_actions"
      confirm_required_actions
  in
  let actual_visible = List.length aps_items in
  let duplicate_token = duplicate_token aps_items in
  let actor_filter = Option.bind aps_actor_filter (fun actor ->
      let trimmed = String.trim actor in
      if trimmed = "" || not (String.equal trimmed actor) then None
      else Some trimmed)
  in
  if not aps_filter_active then
    Error "pending confirmation snapshot must be actor-scoped"
  else if Option.is_none actor_filter then
    Error "pending confirmation actor_filter must be a non-blank string"
  else if aps_visible_count < 0 || aps_total_count < 0 || aps_hidden_count < 0 then
    Error "pending confirmation counts must be nonnegative"
  else if
    not
      (List.for_all
         (fun item -> Option.equal String.equal actor_filter (Some item.ap_actor))
         aps_items)
  then
    Error "pending confirmation item actor does not match actor_filter"
  else
    match duplicate_token with
    | Some token ->
        Error (Printf.sprintf "duplicate pending confirmation token %S" token)
    | None when aps_visible_count <> actual_visible ->
        Error
          (Printf.sprintf
             "pending confirmation visible_count mismatch: summary=%d items=%d"
             aps_visible_count actual_visible)
    | None when aps_total_count <> aps_visible_count + aps_hidden_count ->
        Error
          (Printf.sprintf
             "pending confirmation count mismatch: total=%d visible=%d hidden=%d"
             aps_total_count aps_visible_count aps_hidden_count)
    | None ->
        Ok
          {
            aps_items;
            aps_actor_filter = actor_filter;
            aps_filter_active;
            aps_visible_count;
            aps_total_count;
            aps_hidden_count;
          }

let bounded_json json =
  let rendered = Yojson.Safe.to_string json in
  if String.length rendered <= 240 then rendered
  else String.sub rendered 0 240 ^ "..."

let required_nonempty_string json field =
  let* value = Masc.Tui_decode.required_string_field json field in
  if String.trim value = "" then
    Error (Printf.sprintf "field '%s' must not be blank" field)
  else Ok value

let has_field json field =
  match json with
  | `Assoc fields -> List.mem_assoc field fields
  | _ -> false

let failure_detail json =
  match member "message" json with
  | `String message when String.trim message <> "" -> message
  | _ -> (
      match member "result" json with
      | `Null -> bounded_json json
      | result -> bounded_json result)

let decode_confirm_envelope ~expected_token ~expected_decision ~status json =
  let expected_decision_wire = approval_decision_wire expected_decision in
  let* trace_id = required_nonempty_string json "trace_id" in
  let* decision = required_nonempty_string json "decision" in
  let* tool_name = required_nonempty_string json "tool_name" in
  let* executed_action =
    Masc.Tui_decode.required_object_field json "executed_action"
  in
  let* executed_action =
    Operator_pending_confirm.pending_confirm_of_yojson executed_action
  in
  if not (String.equal decision expected_decision_wire) then
    Error
      (Printf.sprintf
         "operator action decision mismatch: expected %S, received %S"
         expected_decision_wire decision)
  else if not (String.equal executed_action.confirm_token expected_token) then
    Error "operator action confirm_token does not match the submitted token"
  else if not (String.equal executed_action.trace_id trace_id) then
    Error "operator action trace_id does not match executed_action"
  else if not (String.equal executed_action.delegated_tool tool_name) then
    Error "operator action tool_name does not match executed_action"
  else
    match expected_decision with
    | Deny ->
        if not (String.equal status "ok") then
          Error "denied operator action must complete with status 'ok'"
        else
          let* result_status = required_nonempty_string json "result_status" in
          if String.equal result_status "not_executed" then Ok (Completed json)
          else
            Error
              (Printf.sprintf
                 "denied operator action must have result_status 'not_executed' (received %S)"
                 result_status)
    | Confirm ->
        if not (has_field json "result") then
          Error "confirmed operator action response missing result"
        else if String.equal status "deferred" then Ok (Deferred json)
        else if String.equal status "error" then
          Ok (Execution_failed (json, failure_detail json))
        else Ok (Completed json)

let decode_confirm_response ~expected_token ~expected_decision json =
  match member "status" json with
  | `String ("ok" | "deferred" | "error" as status) ->
      decode_confirm_envelope ~expected_token ~expected_decision ~status json
  | `String status ->
      Error (Printf.sprintf "unknown operator action status %S" status)
  | `Null -> Error "operator action response missing status"
  | other ->
      Error
        (Printf.sprintf
           "operator action status must be a string (received %s)"
           (Json_util.kind_name other))
