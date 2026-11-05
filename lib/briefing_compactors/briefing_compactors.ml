(** Compact raw domain JSON into briefing-ready form. *)

open Briefing_json_helpers

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
