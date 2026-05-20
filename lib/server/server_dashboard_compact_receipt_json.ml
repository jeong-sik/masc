(* Compact-receipt JSON builders for the dashboard composite endpoint.

   The dashboard composite surface ships a *summary* of the most recent
   keeper receipt (error / cascade / tool-surface blocks) rather than
   the raw receipt JSON.  These helpers do the field projection +
   truncation so the wire payload stays bounded.

   Extracted from [Server_dashboard_http] (godfile decomp). Pure JSON
   mapping over receipt-shaped [Yojson.Safe.t] values.  No shared
   state, no I/O. *)

let compact_preview ~max_chars text =
  let text = String.trim text in
  if String.length text <= max_chars
  then text, false
  else String.sub text 0 max_chars ^ "...", true
;;

(* Local member-lookup helper.  The parent's [json_member] returns
   `Null on miss; matching that shape lets the caller pattern-match
   on `Assoc / `Null without options. *)
let json_member key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some v -> v
     | None -> `Null)
  | _ -> `Null
;;

let json_string key json = Json_util.get_string json key
let json_int key json = Json_util.get_int json key
let json_bool key json = Json_util.get_bool json key

let compact_receipt_error_json receipt =
  match json_member "error" receipt with
  | `Assoc _ as error ->
    let kind = json_string "kind" error in
    let message = json_string "message" error in
    let message_preview, message_truncated =
      match message with
      | Some value -> compact_preview ~max_chars:900 value
      | None -> "", false
    in
    `Assoc
      [ "kind", Json_util.string_opt_to_json kind
      ; ( "message_preview"
        , match message with
          | Some _ -> `String message_preview
          | None -> `Null )
      ; "message_truncated", `Bool message_truncated
      ]
  | _ -> `Null
;;

let compact_receipt_cascade_json receipt =
  match json_member "cascade" receipt with
  | `Assoc _ as cascade ->
    `Assoc
      [ "name", Json_util.string_opt_to_json (json_string "name" cascade)
      ; "selected_model", `Null
      ; "attempt_count", Json_util.int_opt_to_json (json_int "attempt_count" cascade)
      ; ( "fallback_applied"
        , Json_util.bool_opt_to_json (json_bool "fallback_applied" cascade) )
      ; "outcome", Json_util.string_opt_to_json (json_string "outcome" cascade)
      ; ( "degraded_retry_applied"
        , Json_util.bool_opt_to_json (json_bool "degraded_retry_applied" cascade) )
      ; ( "degraded_retry_cascade"
        , Json_util.string_opt_to_json (json_string "degraded_retry_cascade" cascade) )
      ; ( "fallback_reason"
        , Json_util.string_opt_to_json (json_string "fallback_reason" cascade) )
      ]
  | _ -> `Null
;;

let compact_receipt_tool_surface_json receipt =
  let surface =
    match json_member "tool_surface" receipt with
    | `Assoc _ as surface -> surface
    | _ -> json_member "tool_contract" receipt
  in
  match surface with
  | `Assoc _ as surface ->
    let tool_requirement = json_string "tool_requirement" surface in
    let unexpected_tools = Json_util.get_string_list receipt "unexpected_tools" in
    let turn_lane =
      (* Wire values come from [Keeper_agent_tool_surface.tool_requirement_to_yojson]
         (lib/keeper/keeper_agent_tool_surface.ml): "required", "optional", "none".
         The earlier "no_tools" literal never fired because [No_tools] serializes
         to "none" — leaving turn_lane=null on no-tool receipts that omit an
         explicit turn_lane. *)
      match json_string "turn_lane" surface, tool_requirement with
      | Some value, _ -> Some value
      | None, Some "required" -> Some "tool_required"
      | None, Some "optional" -> Some "tool_optional"
      | None, Some "none" -> Some "text_only"
      | None, _ -> None
    in
    `Assoc
      [ "tool_requirement", Json_util.string_opt_to_json tool_requirement
      ; "turn_lane", Json_util.string_opt_to_json turn_lane
      ; ( "tool_surface_class"
        , Json_util.string_opt_to_json (json_string "tool_surface_class" surface) )
      ; ( "visible_tool_count"
        , Json_util.int_opt_to_json (json_int "visible_tool_count" surface) )
      ; ( "tool_gate_enabled"
        , Json_util.bool_opt_to_json (json_bool "tool_gate_enabled" surface) )
      ; ( "tool_surface_fallback_used"
        , Json_util.bool_opt_to_json
            (json_bool "tool_surface_fallback_used" surface) )
      ; ( "missing_required_tools"
        , Json_util.json_string_list
            (Json_util.get_string_list surface "missing_required_tools") )
      ; ( "required_tools"
        , Json_util.json_string_list (Json_util.get_string_list surface "required_tools")
        )
      ; ( "required_tool_candidates"
        , Json_util.json_string_list
            (Json_util.get_string_list surface "required_tool_candidates") )
      ; "unexpected_tools", Json_util.json_string_list unexpected_tools
      ; "unexpected_tool_count", `Int (List.length unexpected_tools)
      ]
  | _ -> `Null
;;
