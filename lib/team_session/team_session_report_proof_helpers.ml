(** Team_session_report_proof_helpers — proof criteria, event parsing, and spawn analysis. *)

include Team_session_report_core

let bool_of_criterion evidence =
  match Yojson.Safe.Util.member "passed" evidence with
  | `Bool b -> b
  | _ -> false

let criterion name passed detail =
  `Assoc [ ("name", `String name); ("passed", `Bool passed); ("detail", `String detail) ]

let has_event_type (json : Yojson.Safe.t) expected =
  match Yojson.Safe.Util.member "event_type" json with
  | `String e -> String.equal e expected
  | _ -> false

let count_event_type events expected =
  List.fold_left
    (fun acc json -> if has_event_type json expected then acc + 1 else acc)
    0 events

let turn_actor_of_event (json : Yojson.Safe.t) =
  if has_event_type json "team_turn" then
    match
      detail_member "actor" json
    with
    | `String actor ->
        let actor = String.trim actor in
        if actor = "" then None else Some actor
    | _ -> None
  else
    None

let turn_kind_of_event (json : Yojson.Safe.t) =
  if has_event_type json "team_turn" then
    match
      detail_member "kind" json
    with
    | `String kind -> Some (String.lowercase_ascii (String.trim kind))
    | _ -> None
  else
    None

let turn_message_of_event (json : Yojson.Safe.t) =
  if has_event_type json "team_turn" then
    match
      detail_member "message" json
    with
    | `String message ->
        let message = String.trim message in
        if message = "" then None else Some message
    | _ -> None
  else
    None

let empty_note_turn_actor_of_event (json : Yojson.Safe.t) =
  match (turn_kind_of_event json, turn_actor_of_event json, turn_message_of_event json) with
  | Some "note", Some actor, None -> Some actor
  | _ -> None

let count_empty_note_turns events =
  List.fold_left
    (fun acc json ->
      match empty_note_turn_actor_of_event json with Some _ -> acc + 1 | None -> acc)
    0 events

let empty_note_turn_actors_of_events events =
  events |> List.filter_map empty_note_turn_actor_of_event
  |> Team_session_types.dedup_strings

let team_step_spawn_agent (json : Yojson.Safe.t) =
  if has_event_type json "team_step_spawn" then
    match
      Yojson.Safe.Util.member "detail" json
      |> Yojson.Safe.Util.member "spawn_agent"
    with
    | `String agent ->
        let agent = String.trim agent in
        if agent = "" then None else Some agent
    | _ -> None
  else
    None

let team_step_runtime_actor (json : Yojson.Safe.t) =
  if has_event_type json "team_step_spawn" then
    match
      Yojson.Safe.Util.member "detail" json
      |> Yojson.Safe.Util.member "runtime_actor"
    with
    | `String actor ->
        let actor = String.trim actor in
        if actor = "" then None else Some actor
    | _ -> None
  else
    None

let team_step_spawn_success (json : Yojson.Safe.t) =
  if has_event_type json "team_step_spawn" then
    match
      Yojson.Safe.Util.member "detail" json
      |> Yojson.Safe.Util.member "success"
    with
    | `Bool b -> Some b
    | _ -> None
  else
    None

let count_turn_kind events expected_kind =
  List.fold_left
    (fun acc json ->
      match turn_kind_of_event json with
      | Some kind when String.equal kind expected_kind -> acc + 1
      | _ -> acc)
    0 events

let count_spawn_success events =
  List.fold_left
    (fun acc json ->
      match team_step_spawn_success json with
      | Some true -> acc + 1
      | _ -> acc)
    0 events

let count_spawn_failure events =
  List.fold_left
    (fun acc json ->
      match team_step_spawn_success json with
      | Some false -> acc + 1
      | _ -> acc)
    0 events

let find_criterion criteria name =
  criteria
  |> List.find_opt (fun item ->
         match Yojson.Safe.Util.member "name" item with
         | `String n -> String.equal n name
         | _ -> false)
  |> Option.value ~default:(criterion name false "missing")
  |> bool_of_criterion

let has_criterion criteria name =
  List.exists (fun item ->
    match Yojson.Safe.Util.member "name" item with
    | `String n -> String.equal n name
    | _ -> false
  ) criteria

let all_criteria_pass criteria =
  List.for_all bool_of_criterion criteria

let make_standard_criteria ~event_started ~checkpoints_count ~turn_events
    ~communication_total ~goal_recorded ~participants_count
    ~unique_turn_actors_count ~required_turn_actors
    ~unauthorized_turn_actors ~report_json_exists ~report_md_exists
    ~done_delta_total
    ?(min_turn_events = 1) ?(min_communication = 0) () =
  [
    criterion "session_started_event" event_started "session_started 이벤트 존재";
    criterion "checkpoint_recorded" (checkpoints_count > 0)
      (Printf.sprintf "checkpoints=%d" checkpoints_count);
    criterion "turn_or_communication_recorded"
      (turn_events > 0 || communication_total > 0)
      (Printf.sprintf "turn_events=%d communication_total=%d" turn_events
         communication_total);
    criterion "turn_volume_threshold" (turn_events >= min_turn_events)
      (Printf.sprintf "turn_events=%d min_turn_events=%d" turn_events
         min_turn_events);
    criterion "communication_volume_threshold"
      (communication_total >= min_communication)
      (Printf.sprintf "communication_total=%d min_communication=%d"
         communication_total min_communication);
    criterion "goal_recorded" goal_recorded "goal 문자열 존재";
    criterion "participants_recorded" (participants_count > 0)
      (Printf.sprintf "participants=%d" participants_count);
    criterion "multi_actor_turn_coverage"
      (unique_turn_actors_count >= required_turn_actors)
      (Printf.sprintf "unique_turn_actors=%d required_turn_actors=%d"
         unique_turn_actors_count required_turn_actors);
    criterion "turn_actor_authorized" (unauthorized_turn_actors = [])
      (if unauthorized_turn_actors = [] then
         "all turn actors are session participants"
       else
         Printf.sprintf "unauthorized=%s"
           (String.concat "," unauthorized_turn_actors));
    criterion "report_artifacts" (report_json_exists && report_md_exists)
      (Printf.sprintf "report_json=%b report_md=%b" report_json_exists
         report_md_exists);
    criterion "outcome_traceable" (done_delta_total >= 0)
      (Printf.sprintf "done_delta_total=%d" done_delta_total);
  ]

let make_strong_criteria ~required_spawn_agents ~spawn_events
    ~spawn_success_count ~unique_spawn_agents_count ~required_turn_actors
    ~min_turn_events ~turn_events ~min_communication ~communication_total
    ~vote_events ~run_deliverables ~empty_note_turn_count =
  [
    criterion "spawn_evidence_present" (spawn_events >= required_spawn_agents)
      (Printf.sprintf "spawn_events=%d required_spawn_agents=%d" spawn_events
         required_spawn_agents);
    criterion "spawn_success_observed"
      (spawn_success_count >= required_spawn_agents)
      (Printf.sprintf "spawn_success=%d required_spawn_agents=%d"
         spawn_success_count required_spawn_agents);
    criterion "spawn_actor_diversity"
      (unique_spawn_agents_count >= required_turn_actors)
      (Printf.sprintf "unique_spawn_agents=%d required_turn_actors=%d"
         unique_spawn_agents_count required_turn_actors);
    criterion "turn_volume_threshold" (turn_events >= min_turn_events)
      (Printf.sprintf "turn_events=%d min_turn_events=%d" turn_events
         min_turn_events);
    criterion "communication_volume_threshold"
      (communication_total >= min_communication)
      (Printf.sprintf "communication_total=%d min_communication=%d"
         communication_total min_communication);
    criterion "vote_evidence_present" (vote_events >= 1)
      (Printf.sprintf "vote_events=%d required>=1" vote_events);
    criterion "deliverable_evidence_present" (run_deliverables >= 1)
      (Printf.sprintf "run_deliverables=%d required>=1" run_deliverables);
    criterion "empty_note_turns_absent" (empty_note_turn_count = 0)
      (Printf.sprintf "empty_note_turn_count=%d" empty_note_turn_count);
  ]

let mandatory_ok_for_level ~proof_level criteria =
  match proof_level with
  | Team_session_types.Proof_standard ->
      find_criterion criteria "session_started_event"
      && find_criterion criteria "checkpoint_recorded"
      && find_criterion criteria "turn_or_communication_recorded"
      && find_criterion criteria "multi_actor_turn_coverage"
      && find_criterion criteria "turn_actor_authorized"
      && find_criterion criteria "report_artifacts"
      && (not (has_criterion criteria "turn_volume_threshold") || find_criterion criteria "turn_volume_threshold")
      && (not (has_criterion criteria "communication_volume_threshold") || find_criterion criteria "communication_volume_threshold")
  | Team_session_types.Proof_strong -> all_criteria_pass criteria

let verdict_for_level ~proof_level ~mandatory_ok =
  match proof_level with
  | Team_session_types.Proof_standard ->
      if mandatory_ok then "proved" else "insufficient_evidence"
  | Team_session_types.Proof_strong ->
      if mandatory_ok then "proved_strong" else "insufficient_evidence_strong"

let proof_profile_summary ~proof_level ~required_spawn_agents ~min_turn_events
    ~min_communication =
  `Assoc
    [
      ("proof_level", `String (Team_session_types.proof_level_to_string proof_level));
      ("required_spawn_agents", `Int required_spawn_agents);
      ("min_turn_events", `Int min_turn_events);
      ("min_communication_events", `Int min_communication);
    ]

let required_spawn_agents_for_session (session : Team_session_types.session) =
  let planned_workers = List.length session.planned_workers in
  if planned_workers > 0 then
    max 1 (min 4 planned_workers)
  else
    let participants = max 1 (List.length session.agent_names) in
    max 1 (min 4 participants)

let min_turn_events_for_session required_turn_actors =
  max 4 (required_turn_actors * 3)

let min_communication_for_session required_turn_actors =
  max 1 (required_turn_actors * 3)

let default_proof_level = Team_session_types.Proof_standard

let proof_level_of_optional_string = function
  | None -> default_proof_level
  | Some s -> Team_session_types.proof_level_of_string (String.lowercase_ascii (String.trim s))

let parse_proof_level_json_value (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "proof_level" json with
  | `String s -> proof_level_of_optional_string (Some s)
  | _ -> default_proof_level

let parse_proof_level_arg s = proof_level_of_optional_string (Some s)

let parse_proof_level_opt = function
  | None -> default_proof_level
  | Some s -> parse_proof_level_arg s

let parse_proof_level_default () = default_proof_level

let normalize_proof_level = function
  | Team_session_types.Proof_standard -> Team_session_types.Proof_standard
  | Team_session_types.Proof_strong -> Team_session_types.Proof_strong

let resolve_proof_level ?proof_level () =
  match proof_level with
  | Some p -> normalize_proof_level p
  | None -> default_proof_level

let parse_proof_level ?proof_level () = resolve_proof_level ?proof_level ()

let proof_level_to_string = Team_session_types.proof_level_to_string

let parse_event_bool path json =
  match Yojson.Safe.Util.member path json with
  | `Bool b -> Some b
  | _ -> None

let parse_event_string path json =
  match Yojson.Safe.Util.member path json with
  | `String s ->
      let t = String.trim s in
      if t = "" then None else Some t
  | _ -> None

let parse_event_int path json =
  match Yojson.Safe.Util.member path json with
  | `Int n -> Some n
  | `Intlit s -> int_of_string_opt s
  | _ -> None

let parse_event_string_list path json =
  match Yojson.Safe.Util.member path json with
  | `List xs ->
      xs
      |> List.filter_map (function
             | `String s ->
                 let t = String.trim s in
                 if t = "" then None else Some t
             | _ -> None)
  | _ -> []

let parse_event_detail json = Yojson.Safe.Util.member "detail" json

let parse_spawn_agent json = parse_event_detail json |> parse_event_string "spawn_agent"

let parse_spawn_success json = parse_event_detail json |> parse_event_bool "success"

let parse_spawn_model json = parse_event_detail json |> parse_event_string "spawn_model"

let parse_spawn_execution_scope json =
  parse_event_detail json |> parse_event_string "execution_scope"

let parse_spawn_tool_call_count json =
  parse_event_detail json |> parse_event_int "tool_call_count"

let parse_spawn_tool_names json =
  parse_event_detail json |> parse_event_string_list "tool_names"

let parse_spawn_selection_note json =
  parse_event_detail json |> parse_event_string "spawn_selection_note"

let parse_spawn_role json = parse_event_detail json |> parse_event_string "spawn_role"

let parse_spawn_error json = parse_event_detail json |> parse_event_string "error"

let parse_spawn_elapsed_ms json =
  parse_event_detail json |> parse_event_int "elapsed_ms"

let parse_detached_actor json =
  if has_event_type json "session_agent_detached" then
    parse_event_detail json |> parse_event_string "actor"
  else
    None

let parse_detached_reason json =
  if has_event_type json "session_agent_detached" then
    parse_event_detail json |> parse_event_string "reason"
  else
    None

let parse_ts_iso json = parse_event_string "ts_iso" json

let spawn_agent_of_event json =
  if has_event_type json "team_step_spawn" then parse_spawn_agent json else None

let spawn_runtime_actor_of_event json =
  if has_event_type json "team_step_spawn" then team_step_runtime_actor json
  else None

let spawn_success_of_event json =
  if has_event_type json "team_step_spawn" then parse_spawn_success json else None

let spawn_model_of_event json =
  if has_event_type json "team_step_spawn" then parse_spawn_model json else None

let spawn_selection_note_of_event json =
  if has_event_type json "team_step_spawn" then parse_spawn_selection_note json
  else None

let collect_spawn_agents events =
  events |> List.filter_map spawn_agent_of_event |> Team_session_types.dedup_strings

let collect_spawn_runtime_actors events =
  events |> List.filter_map spawn_runtime_actor_of_event
  |> Team_session_types.dedup_strings

let collect_spawn_models events =
  events |> List.filter_map spawn_model_of_event |> Team_session_types.dedup_strings

let collect_spawn_selection_notes events =
  events |> List.filter_map spawn_selection_note_of_event
  |> Team_session_types.dedup_strings

let collect_spawn_tool_names events =
  events
  |> List.concat_map (fun json ->
         if
           has_event_type json "team_step_spawn"
           || has_event_type json "team_step_delegate"
         then
           parse_spawn_tool_names json
         else [])
  |> Team_session_types.dedup_strings

let sum_spawn_tool_call_count events =
  events
  |> List.fold_left
       (fun acc json ->
         if
           has_event_type json "team_step_spawn"
           || has_event_type json "team_step_delegate"
         then
           acc + Option.value ~default:0 (parse_spawn_tool_call_count json)
         else acc)
       0

let count_write_capable_spawns events =
  events
  |> List.fold_left
       (fun acc json ->
         if
           has_event_type json "team_step_spawn"
           || has_event_type json "team_step_delegate"
         then
           match parse_spawn_execution_scope json with
           | Some "limited_code_change" -> acc + 1
           | _ -> acc
         else acc)
       0

let failed_spawn_roster_of_events events =
  events
  |> List.filter_map (fun json ->
         match team_step_spawn_success json with
         | Some false ->
             Some
               (`Assoc
                 [
                   ( "runtime_actor",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (team_step_runtime_actor json) );
                   ( "spawn_agent",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (parse_spawn_agent json) );
                   ( "spawn_role",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (parse_spawn_role json) );
                   ( "spawn_model",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (parse_spawn_model json) );
                   ( "error",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (parse_spawn_error json) );
                   ( "elapsed_ms",
                     Option.fold ~none:`Null ~some:(fun n -> `Int n)
                       (parse_spawn_elapsed_ms json) );
                   ( "ts_iso",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (parse_ts_iso json) );
                 ])
         | _ -> None)

let detached_actor_roster_of_events events =
  events
  |> List.filter_map (fun json ->
         match parse_detached_actor json with
         | Some actor ->
             Some
               (`Assoc
                 [
                   ("actor", `String actor);
                   ( "reason",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (parse_detached_reason json) );
                   ( "ts_iso",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       (parse_ts_iso json) );
                 ])
         | None -> None)

let proof_level_name proof_level = proof_level_to_string proof_level

let proof_kind_summary proof_level =
  match proof_level with
  | Team_session_types.Proof_standard -> "standard"
  | Team_session_types.Proof_strong -> "strong"

let proof_profile_title proof_level =
  match proof_level with
  | Team_session_types.Proof_standard -> "Standard Proof"
  | Team_session_types.Proof_strong -> "Strong Proof"

let proof_profile_description proof_level =
  match proof_level with
  | Team_session_types.Proof_standard ->
      "Baseline evidence requirements for team session traceability."
  | Team_session_types.Proof_strong ->
      "Strict evidence requirements for multi-agent spawned collaboration."

let proof_profile_meta proof_level =
  `Assoc
    [
      ("name", `String (proof_profile_title proof_level));
      ("level", `String (proof_kind_summary proof_level));
      ("description", `String (proof_profile_description proof_level));
    ]

let proof_profile proof_level = proof_profile_meta proof_level

let proof_metadata ~proof_level ~required_spawn_agents ~min_turn_events
    ~min_communication =
  `Assoc
    [
      ("profile", proof_profile proof_level);
      ("thresholds", proof_profile_summary ~proof_level ~required_spawn_agents ~min_turn_events ~min_communication);
    ]

