(** Compact raw domain JSON into briefing-ready form. *)

open Briefing_json_helpers

let compact_keeper_json keeper_json =
  let diagnostic = member_assoc "diagnostic" keeper_json in
  `Assoc
    [
      ("name", string_json_opt (member_assoc "name" keeper_json));
      ("status", string_json_opt (member_assoc "status" keeper_json));
      ("generation", int_json (member_assoc "generation" keeper_json));
      ("context_ratio", float_json (member_assoc "context_ratio" keeper_json));
      ("last_turn_ago_s", float_json (member_assoc "last_turn_ago_s" keeper_json));
      ("handoff_count_total", int_json (member_assoc "handoff_count_total" keeper_json));
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
