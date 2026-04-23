(** Metadata gap detection for mission briefing sections. *)

open Briefing_json_helpers

let metadata_gap_json ~kind ~summary ~scope_type ~scope_id ~severity =
  `Assoc
    [
      ("kind", `String kind);
      ("summary", `String summary);
      ("scope_type", `String scope_type);
      ("scope_id", option_string_json scope_id);
      ("severity", `String severity);
    ]

let collect_metadata_gaps ~sessions ~keepers ~agents =
  let agent_needs_focus json =
    List.mem
      (String.lowercase_ascii (String.trim (string_field "status" json)))
      [ "active"; "busy" ]
  in
  let session_gaps =
    sessions
    |> List.concat_map (fun json ->
           let session_id = string_field "session_id" json |> fun value -> if value = "" then None else Some value in
           let items = ref [] in
           if string_field "goal" json = "unassigned" then
             items :=
               metadata_gap_json ~kind:"session_goal_missing"
                 ~summary:"Session goal is unassigned in briefing facts."
                 ~scope_type:"session" ~scope_id:session_id ~severity:"watch"
               :: !items;
           if string_field "communication_mode" json = "unknown" then
             items :=
               metadata_gap_json ~kind:"session_communication_mode_missing"
                 ~summary:"Session communication mode is not recorded."
                 ~scope_type:"session" ~scope_id:session_id ~severity:"watch"
               :: !items;
           List.rev !items)
  in
  let keeper_gaps =
    keepers
    |> List.filter_map (fun json ->
           let status = string_field "last_reply_status" json in
           if status = "not_recorded" then
             Some
               (metadata_gap_json ~kind:"keeper_last_reply_missing"
                  ~summary:"Keeper last reply status is not recorded."
                  ~scope_type:"keeper"
                  ~scope_id:(Some (string_field "name" json))
                  ~severity:"info")
           else None)
  in
  let agent_gaps =
    agents
    |> List.filter_map (fun json ->
           if string_field "assignment_status" json = "unassigned"
              && agent_needs_focus json
           then
             Some
               (metadata_gap_json ~kind:"agent_focus_missing"
                  ~summary:"Active agent has no current focus bound."
                  ~scope_type:"agent"
                  ~scope_id:(Some (string_field "name" json))
                  ~severity:"watch")
           else None)
  in
  take 8 (session_gaps @ keeper_gaps @ agent_gaps)

type section =
  | Communication
  | Alignment
  | Watch

let gap_kinds_for_section = function
  | Communication ->
      [ "session_communication_mode_missing"; "keeper_last_reply_missing" ]
  | Alignment ->
      [ "session_goal_missing"; "agent_focus_missing" ]
  | Watch -> []

let count_metadata_gaps_for_section ~section gaps =
  let allowed = gap_kinds_for_section section in
  gaps
  |> List.fold_left
       (fun acc json ->
         let kind = string_field "kind" json in
         if List.mem kind allowed then acc + 1 else acc)
       0

let evidence_of_metadata_gaps ~section metadata_gaps =
  let allowed = gap_kinds_for_section section in
  metadata_gaps
  |> List.filter_map (fun json ->
         let kind = string_field "kind" json in
         if List.mem kind allowed then Some (string_field "summary" json) else None)
  |> take 2
