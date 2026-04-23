(** Section builders for mission briefing (communication, alignment, watch). *)

open Briefing_json_helpers
open Briefing_gaps

let section_id_string = function
  | Communication -> "communication"
  | Alignment -> "alignment"
  | Watch -> "watch"

let section_label = function
  | Communication -> "Communication"
  | Alignment -> "Alignment"
  | Watch -> "Watch Next"

let has_operational_signal ~section ~room_health ~incident_count ~recommended_action_count =
  let room_risky =
    Dashboard_utils.is_health_at_risk (Dashboard_utils.health_level_of_string room_health)
  in
  match section with
  | Watch -> room_risky || incident_count > 0 || recommended_action_count > 0
  | Communication | Alignment -> room_risky || incident_count > 0

let annotate_section ~section ~status ~summary ~evidence ~metadata_gaps
    ~room_health ~incident_count ~recommended_action_count =
  let gap_count = count_metadata_gaps_for_section ~section metadata_gaps in
  let operational =
    has_operational_signal ~section ~room_health ~incident_count
      ~recommended_action_count
  in
  let signal_class, evidence_quality =
    if gap_count > 0 && not operational then
      ("metadata_gap", "missing")
    else if gap_count > 0 && operational then
      ("mixed", "partial")
    else if operational && evidence <> [] then
      ("operational_risk", "strong")
    else if operational then
      ("operational_risk", "partial")
    else if evidence <> [] then
      ("operational_risk", "partial")
    else
      ("operational_risk", "missing")
  in
  `Assoc
    [
      ("id", `String (section_id_string section));
      ("label", `String (section_label section));
      ("status", `String status);
      ("summary", `String summary);
      ("evidence", `List (List.map (fun item -> `String item) evidence));
      ("signal_class", `String signal_class);
      ("evidence_quality", `String evidence_quality);
      ("provenance", `String "narrative");
      ("authoritative", `Bool false);
    ]

let int_field_direct ?(default = 0) key json = int_field ~default key json

let sum_int_field key items =
  List.fold_left (fun acc json -> acc + int_field_direct key json) 0 items

let count_matching_field key ~predicate items =
  List.fold_left
    (fun acc json -> if predicate (string_field key json) then acc + 1 else acc)
    0 items

let status_is_active_agent value =
  List.mem
    (String.lowercase_ascii (String.trim value))
    [ "active"; "busy" ]

let evidence_add_if cond text items =
  if cond && text <> "" then text :: items else items

let build_communication_section ~sessions ~recent_messages ~metadata_gaps
    ~room_health ~incident_count ~recommended_action_count =
  let live_session_count = List.length sessions in
  let recent_message_count = List.length recent_messages in
  let broadcast_total = sum_int_field "broadcast_count" sessions in
  let portal_total = sum_int_field "portal_count" sessions in
  let known_mode_count =
    count_matching_field "communication_mode" sessions ~predicate:(fun value ->
        value <> "" && value <> "unknown")
  in
  let metadata_evidence =
    evidence_of_metadata_gaps ~section_id:"communication" metadata_gaps
  in
  let positive_signal =
    recent_message_count > 0 || broadcast_total > 0 || portal_total > 0
  in
  let positive_evidence =
    []
    |> evidence_add_if (recent_message_count > 0)
         (Printf.sprintf "Recent namespace messages recorded: %d" recent_message_count)
    |> evidence_add_if (broadcast_total > 0)
         (Printf.sprintf "Session broadcasts recorded: %d" broadcast_total)
    |> evidence_add_if (portal_total > 0)
         (Printf.sprintf "Portal messages recorded: %d" portal_total)
  in
  let inactivity_evidence =
    []
    |> evidence_add_if
         (not positive_signal && live_session_count = 0)
         "Active sessions count is zero"
    |> evidence_add_if
         (not positive_signal && live_session_count > 0)
         "No communication activity is recorded for the live sessions"
  in
  let evidence =
    if metadata_evidence <> [] then
      take 2 (metadata_evidence @ positive_evidence @ inactivity_evidence)
    else
      take 2 (positive_evidence @ inactivity_evidence)
  in
  if positive_signal && metadata_evidence = [] then
    ("healthy", "Communication activity is recorded across recent messages and session metrics.", evidence)
  else if positive_signal then
    ("watch", "Communication activity exists, but some communication metadata is still missing.", evidence)
  else if live_session_count = 0 then
    ("unclear", "No live session is present, so communication health cannot be judged.", evidence)
  else if metadata_evidence <> [] then
    ("unclear", "Communication metadata is incomplete and no positive activity signal is recorded.", evidence)
  else if known_mode_count = 0 then
    ("unclear", "Communication mode is not recorded for the live sessions.", evidence)
  else if Dashboard_utils.is_health_at_risk (Dashboard_utils.health_level_of_string room_health)
          || incident_count > 0 || recommended_action_count > 0
  then
    ("watch", "Live sessions exist without recorded communication activity while the namespace still has open operator attention.", evidence)
  else
    ("watch", "Live sessions exist, but no communication activity is recorded yet.", evidence)

let build_alignment_section ~sessions ~agents ~metadata_gaps =
  let active_agent_count =
    List.fold_left
      (fun acc json ->
        if status_is_active_agent (string_field "status" json) then acc + 1 else acc)
      0 agents
  in
  let assigned_active_agent_count =
    List.fold_left
      (fun acc json ->
        if status_is_active_agent (string_field "status" json)
           && String.equal (string_field "assignment_status" json) "assigned"
        then acc + 1
        else acc)
      0 agents
  in
  let bound_goal_count =
    List.fold_left
      (fun acc json ->
        if String.equal (string_field "goal" json) "unassigned" then acc else acc + 1)
      0 sessions
  in
  let metadata_evidence =
    evidence_of_metadata_gaps ~section_id:"alignment" metadata_gaps
  in
  let evidence =
    []
    |> evidence_add_if (active_agent_count = 0) "Active agents count is zero"
    |> evidence_add_if (active_agent_count > 0)
         (Printf.sprintf "Active agents recorded: %d" active_agent_count)
    |> evidence_add_if (bound_goal_count > 0)
         (Printf.sprintf "Session goals bound: %d" bound_goal_count)
    |> evidence_add_if
         (active_agent_count > 0 && assigned_active_agent_count = active_agent_count)
         "All active agents have bound focus"
    |> fun items -> items @ metadata_evidence
    |> take 2
  in
  if active_agent_count = 0 then
    ("unclear", "No active agents are present, so alignment cannot be judged.", evidence)
  else if metadata_evidence <> [] then
    ("unclear", "Goal or focus bindings are incomplete, so alignment cannot be confirmed.", evidence)
  else if bound_goal_count = 0 then
    ("unclear", "Active agents exist, but no bound session goal is recorded.", evidence)
  else if assigned_active_agent_count = active_agent_count then
    ("aligned", "Active agents have bound focus and session goals are recorded.", evidence)
  else
    ("watch", "Some active agents are present without a bound focus.", evidence)

let build_watch_section ~room_health ~incident_count ~recommended_action_count
    ~top_attention_summary =
  let room_health_level = Dashboard_utils.health_level_of_string room_health in
  let risky_room =
    Dashboard_utils.is_health_at_risk room_health_level
  in
  let evidence =
    []
    |> evidence_add_if risky_room (Printf.sprintf "Namespace health is %s" room_health)
    |> evidence_add_if (incident_count > 0)
         (Printf.sprintf "Incident count is %d" incident_count)
    |> evidence_add_if (recommended_action_count > 0)
         (Printf.sprintf "Recommended actions count is %d" recommended_action_count)
    |> evidence_add_if
         (top_attention_summary <> "" && top_attention_summary <> "unknown")
         top_attention_summary
    |> take 2
  in
  if risky_room then
    ( "risk",
      Printf.sprintf
        "Namespace health is %s with %d incidents and %d recommended actions."
        room_health incident_count recommended_action_count,
      evidence )
  else if incident_count > 0 || recommended_action_count > 0 then
    ( "watch",
      Printf.sprintf
        "Operator attention remains open with %d incidents and %d recommended actions."
        incident_count recommended_action_count,
      evidence )
  else
    ("ok", "No immediate operator action is flagged by the namespace summary.", evidence)

let build_briefing_sections ~mission_summary_json ~sessions ~agents ~recent_messages
    ~metadata_gaps =
  let room_health = mission_summary_json |> string_field "room_health" in
  let incident_count = mission_summary_json |> int_field "incident_count" in
  let recommended_action_count =
    mission_summary_json |> int_field "recommended_action_count"
  in
  let top_attention_summary =
    mission_summary_json |> string_field "top_attention_summary"
  in
  let communication_status, communication_summary, communication_evidence =
    build_communication_section ~sessions ~recent_messages ~metadata_gaps
      ~room_health ~incident_count ~recommended_action_count
  in
  let alignment_status, alignment_summary, alignment_evidence =
    build_alignment_section ~sessions ~agents ~metadata_gaps
  in
  let watch_status, watch_summary, watch_evidence =
    build_watch_section ~room_health ~incident_count ~recommended_action_count
      ~top_attention_summary
  in
  ( watch_summary,
    [
      annotate_section ~section:Communication ~status:communication_status
        ~summary:communication_summary ~evidence:communication_evidence
        ~metadata_gaps ~room_health ~incident_count ~recommended_action_count;
      annotate_section ~section:Alignment ~status:alignment_status
        ~summary:alignment_summary ~evidence:alignment_evidence ~metadata_gaps
        ~room_health ~incident_count ~recommended_action_count;
      annotate_section ~section:Watch ~status:watch_status
        ~summary:watch_summary ~evidence:watch_evidence ~metadata_gaps
        ~room_health ~incident_count ~recommended_action_count;
    ] )
