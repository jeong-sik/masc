(** Section builders for briefing (communication, alignment, watch). *)

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

let has_operational_signal ~section ~workspace_health ~incident_count ~recommended_action_count =
  let workspace_risky =
    Dashboard_utils.is_health_at_risk (Dashboard_utils.health_level_of_string workspace_health)
  in
  match section with
  | Watch -> workspace_risky || incident_count > 0 || recommended_action_count > 0
  | Communication | Alignment -> workspace_risky || incident_count > 0

let annotate_section ~section ~status ~summary ~evidence ~metadata_gaps
    ~workspace_health ~incident_count ~recommended_action_count =
  let gap_count = count_metadata_gaps_for_section ~section metadata_gaps in
  let operational =
    has_operational_signal ~section ~workspace_health ~incident_count
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

let status_is_active_agent value =
  List.mem
    (String.lowercase_ascii (String.trim value))
    [ "active"; "busy" ]

let evidence_add_if cond text items =
  if cond && text <> "" then text :: items else items

let build_communication_section ~recent_messages ~metadata_gaps ~workspace_health
    ~incident_count ~recommended_action_count =
  let recent_message_count = List.length recent_messages in
  let metadata_evidence = evidence_of_metadata_gaps ~section:Communication metadata_gaps in
  let positive_signal = recent_message_count > 0 in
  let evidence =
    []
    |> evidence_add_if positive_signal
         (Printf.sprintf "Recent namespace messages recorded: %d" recent_message_count)
    |> evidence_add_if (not positive_signal) "Recent namespace message count is zero"
    |> fun activity_evidence -> take 2 (metadata_evidence @ activity_evidence)
  in
  if positive_signal && metadata_evidence = [] then
    ("healthy", "Communication activity is recorded across recent namespace messages.", evidence)
  else if positive_signal then
    ("watch", "Communication activity exists, but some communication metadata is still missing.", evidence)
  else if metadata_evidence <> [] then
    ("unclear", "Communication metadata is incomplete and no message activity is recorded.", evidence)
  else if Dashboard_utils.is_health_at_risk (Dashboard_utils.health_level_of_string workspace_health)
          || incident_count > 0 || recommended_action_count > 0
  then
    ("watch", "No communication activity is recorded while the namespace still has open operator attention.", evidence)
  else
    ("watch", "No communication activity is recorded yet.", evidence)

let build_alignment_section ~agents ~metadata_gaps =
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
  let metadata_evidence = evidence_of_metadata_gaps ~section:Alignment metadata_gaps in
  let evidence =
    []
    |> evidence_add_if (active_agent_count = 0) "Active agents count is zero"
    |> evidence_add_if (active_agent_count > 0)
         (Printf.sprintf "Active agents recorded: %d" active_agent_count)
    |> evidence_add_if
         (active_agent_count > 0 && assigned_active_agent_count = active_agent_count)
         "All active agents have bound focus"
    |> fun items -> items @ metadata_evidence
    |> take 2
  in
  if active_agent_count = 0 then
    ("unclear", "No active agents are present, so alignment cannot be judged.", evidence)
  else if metadata_evidence <> [] then
    ("unclear", "Focus bindings are incomplete, so alignment cannot be confirmed.", evidence)
  else if assigned_active_agent_count = active_agent_count then
    ("aligned", "Every active agent has a bound focus.", evidence)
  else
    ("watch", "Some active agents are present without a bound focus.", evidence)

let build_watch_section ~workspace_health ~incident_count ~recommended_action_count
    ~top_attention_summary =
  let workspace_health_level = Dashboard_utils.health_level_of_string workspace_health in
  let risky_workspace =
    Dashboard_utils.is_health_at_risk workspace_health_level
  in
  let evidence =
    []
    |> evidence_add_if risky_workspace (Printf.sprintf "Namespace health is %s" workspace_health)
    |> evidence_add_if (incident_count > 0)
         (Printf.sprintf "Incident count is %d" incident_count)
    |> evidence_add_if (recommended_action_count > 0)
         (Printf.sprintf "Recommended actions count is %d" recommended_action_count)
    |> evidence_add_if
         (top_attention_summary <> "" && top_attention_summary <> "unknown")
         top_attention_summary
    |> take 2
  in
  if risky_workspace then
    ( "risk",
      Printf.sprintf
        "Namespace health is %s with %d incidents and %d recommended actions."
        workspace_health incident_count recommended_action_count,
      evidence )
  else if incident_count > 0 || recommended_action_count > 0 then
    ( "watch",
      Printf.sprintf
        "Operator attention remains open with %d incidents and %d recommended actions."
        incident_count recommended_action_count,
      evidence )
  else
    ("ok", "No immediate operator action is flagged by the namespace summary.", evidence)

let build_briefing_sections ~briefing_summary_json ~agents ~recent_messages
    ~metadata_gaps =
  let workspace_health = briefing_summary_json |> string_field "workspace_health" in
  let incident_count = Option.value ~default:0 (Json_util.assoc_int_opt "incident_count" briefing_summary_json) in
  let recommended_action_count =
    Option.value ~default:0 (Json_util.assoc_int_opt "recommended_action_count" briefing_summary_json)
  in
  let top_attention_summary =
    briefing_summary_json |> string_field "top_attention_summary"
  in
  let communication_status, communication_summary, communication_evidence =
    build_communication_section ~recent_messages ~metadata_gaps ~workspace_health
      ~incident_count ~recommended_action_count
  in
  let alignment_status, alignment_summary, alignment_evidence =
    build_alignment_section ~agents ~metadata_gaps
  in
  let watch_status, watch_summary, watch_evidence =
    build_watch_section ~workspace_health ~incident_count ~recommended_action_count
      ~top_attention_summary
  in
  ( watch_summary,
    [
      annotate_section ~section:Communication ~status:communication_status
        ~summary:communication_summary ~evidence:communication_evidence
        ~metadata_gaps ~workspace_health ~incident_count ~recommended_action_count;
      annotate_section ~section:Alignment ~status:alignment_status
        ~summary:alignment_summary ~evidence:alignment_evidence ~metadata_gaps
        ~workspace_health ~incident_count ~recommended_action_count;
      annotate_section ~section:Watch ~status:watch_status
        ~summary:watch_summary ~evidence:watch_evidence ~metadata_gaps
        ~workspace_health ~incident_count ~recommended_action_count;
    ] )
