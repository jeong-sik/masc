(** Compact raw domain JSON into briefing-ready form. *)

open Briefing_json_helpers

let compact_keeper_json keeper_json =
  let diagnostic = member_assoc "diagnostic" keeper_json in
  `Assoc
    [
      ("name", string_json_opt (member_assoc "name" keeper_json));
      ("status", string_json_opt (member_assoc "status" keeper_json));
      ("context_ratio", float_json (member_assoc "context_ratio" keeper_json));
      ("last_turn_ago_s", float_json (member_assoc "last_turn_ago_s" keeper_json));
      ( "current_task"
      , string_json_opt ~max_len:160 (member_assoc "current_task_id" keeper_json) );
      ("last_reply_status", string_json_opt (member_assoc "last_reply_status" diagnostic));
      ("last_reply_preview", string_json_opt ~max_len:160 (member_assoc "last_reply_preview" diagnostic));
    ]

let compact_agent_json (agent : Masc_domain.agent) =
  let current_focus =
    match agent.current_task with
    | Some task when String.trim task <> "" -> compact_text ~max_len:120 task
    | _ -> ""
  in
  let current_focus_json = Json_util.string_opt_to_json (String_util.trim_nonempty current_focus) in
  `Assoc
    [
      ("name", `String agent.name);
      ("agent_type", `String agent.agent_type);
      ("status", `String (Masc_domain.string_of_agent_status agent.status));
      ("assignment_status", `String (if current_focus = "" then "unassigned" else "assigned"));
      ("current_focus", current_focus_json);
      ("goal_hint", current_focus_json);
      ("session_bound_at", `String agent.session_bound_at);
      ("last_seen", `String agent.last_seen);
      ("capabilities", `List (List.map (fun item -> `String item) (take 2 agent.capabilities)));
    ]

(* ECMAScript WhiteSpace and LineTerminator code points: the browser's
   asString uses String.trim before deciding whether an action is displayable.
   https://tc39.es/ecma262/multipage/ecmascript-language-lexical-grammar.html#sec-white-space *)
let action_string_is_displayable value =
  let rec has_content offset =
    if offset >= String.length value then false
    else
      let decoded = String.get_utf_8_uchar value offset in
      match Uchar.to_int (Uchar.utf_decode_uchar decoded) with
      | 0x0009 | 0x000A | 0x000B | 0x000C | 0x000D | 0x0020 | 0x00A0
      | 0x1680 | 0x2000 | 0x2001 | 0x2002 | 0x2003 | 0x2004 | 0x2005
      | 0x2006 | 0x2007 | 0x2008 | 0x2009 | 0x200A | 0x2028 | 0x2029
      | 0x202F | 0x205F | 0x3000 | 0xFEFF ->
          has_content (offset + Uchar.utf_decode_length decoded)
      | _ -> true
  in
  has_content 0

let compact_briefing_summary_json briefing =
  let ( let* ) = Result.bind in
  let field name =
    match briefing with
    | `Assoc fields ->
        (match List.assoc_opt name fields with
        | Some value -> Ok value
        | None -> Error ("briefing missing " ^ name))
    | _ -> Error "briefing must be an object"
  in
  let* read_error = field "attention_read_error" in
  let* () =
    match read_error with
    | `Null -> Ok ()
    | `String detail -> Error ("briefing attention unavailable: " ^ detail)
    | _ -> Error "briefing attention_read_error must be null or a string"
  in
  let list name =
    let* value = field name in
    match value with
    | `List items -> Ok items
    | _ -> Error ("briefing " ^ name ^ " must be a list")
  in
  let* incidents = list "incidents" in
  let* actions = list "recommended_actions" in
  let* () =
    List.fold_left
      (fun result action ->
        let* () = result in
        match action with
        | `Assoc fields ->
            let* () =
              Json_util.reject_unknown_fields ~surface:"briefing recommended action"
                ~allowed:(List.map fst fields) fields
            in
            List.fold_left
              (fun result name ->
                let* () = result in
                match List.assoc_opt name fields with
                | Some (`String value) when action_string_is_displayable value -> Ok ()
                | _ ->
                    Error ("briefing recommended action." ^ name
                           ^ " must be a nonempty string"))
              (Ok ()) [ "action_type"; "target_type"; "reason" ]
        | _ -> Error "briefing recommended action must be an object")
      (Ok ()) actions
  in
  let* summary = field "summary" in
  let* health =
    match member_assoc "workspace_health" summary with
    | `String _ as value -> Ok value
    | _ -> Error "briefing summary.workspace_health must be a string"
  in
  let* top_attention_summary =
    match incidents with
    | [] -> Ok `Null
    | first :: _ ->
        (match member_assoc "summary" first with
        | `String value -> Ok (`String (compact_text value))
        | _ -> Error "briefing incident.summary must be a string")
  in
  Ok
    (`Assoc
      [ "workspace_health", health;
        "incident_count", `Int (List.length incidents);
        "recommended_action_count", `Int (List.length actions);
        "top_attention_summary", top_attention_summary ])
