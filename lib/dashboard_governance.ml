open Yojson.Safe.Util

type detail_status = [ `OK | `Not_found ]

let option_to_yojson f = function Some value -> f value | None -> `Null
let string_opt_json = option_to_yojson (fun value -> `String value)

let rec take n items =
  match items with
  | [] -> []
  | _ when n <= 0 -> []
  | item :: rest -> item :: take (n - 1) rest

let rec drop n items =
  match items with
  | [] -> []
  | rows when n <= 0 -> rows
  | _ :: rest -> drop (n - 1) rest

let iso_of_unix unix_ts =
  let tm = Unix.gmtime unix_ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour
    tm.Unix.tm_min tm.Unix.tm_sec

let max_opt left right =
  match left, right with
  | None, value | value, None -> value
  | Some a, Some b -> Some (max a b)

let dedup_strings values =
  values
  |> List.filter_map (fun raw ->
         let trimmed = String.trim raw in
         if trimmed = "" then None else Some trimmed)
  |> List.sort_uniq String.compare

let list_string_json values =
  `List (List.map (fun value -> `String value) values)

let debate_context_json (debate : Council.Debate.debate) =
  let context = debate.context in
  `Assoc
    [
      ("board_post_id", string_opt_json context.board_post_id);
      ("task_id", string_opt_json context.task_id);
      ("operation_id", string_opt_json context.operation_id);
      ("team_session_id", string_opt_json context.team_session_id);
    ]

let consensus_context_json (session : Council.Consensus.session) =
  let context = session.context in
  `Assoc
    [
      ("board_post_id", string_opt_json context.board_post_id);
      ("task_id", string_opt_json context.task_id);
      ("operation_id", string_opt_json context.operation_id);
      ("team_session_id", string_opt_json context.team_session_id);
    ]

let action_logs base_path =
  let config = Room.default_config base_path in
  match Operator_control.recent_actions_json config with
  | `List items -> items
  | _ -> []

let pending_confirms base_path =
  let config = Room.default_config base_path in
  match Operator_control.pending_confirms_json config with
  | `List items -> items
  | _ -> []

let judge_runtime_json base_path =
  let runtime = Dashboard_governance_judge.runtime_status base_path in
  `Assoc
    [
      ("judge_online", `Bool runtime.judge_online);
      ("refreshing", `Bool runtime.refreshing);
      ("generated_at", string_opt_json runtime.generated_at);
      ("expires_at", string_opt_json runtime.expires_at);
      ("model_used", string_opt_json runtime.model_used);
      ("keeper_name", `String runtime.keeper_name);
      ("last_error", string_opt_json runtime.last_error);
    ]

let latest_judgment_map base_path =
  Dashboard_governance_judge.latest_judgments base_path
  |> List.fold_left
       (fun acc json ->
         let kind = json |> member "target_kind" |> to_string in
         let id = json |> member "target_id" |> to_string in
         let key = kind ^ ":" ^ id in
         Hashtbl.replace acc key json;
         acc)
       (Hashtbl.create 32)

let judgment_for judgments ~kind ~id =
  Hashtbl.find_opt judgments (kind ^ ":" ^ id)

let judgment_recommended_action json =
  match json |> member "recommended_action" with
  | `Assoc _ as value -> Some value
  | _ -> None

let related_agents_of_debate (debate : Council.Debate.debate) =
  debate.arguments
  |> List.concat_map (fun (arg : Council.Debate.argument) -> arg.agent :: arg.mentions)
  |> dedup_strings

let last_activity_of_debate (debate : Council.Debate.debate) =
  let arg_last =
    debate.arguments
    |> List.filter_map (fun (arg : Council.Debate.argument) -> arg.created_at)
    |> List.sort Float.compare |> List.rev |> function
    | latest :: _ -> Some latest
    | [] -> None
  in
  debate.closed_at |> max_opt arg_last |> max_opt (Some debate.created_at)

let truth_summary_of_debate (summary : Council.Debate.debate_summary) =
  Printf.sprintf "support %d · oppose %d · neutral %d · arguments %d"
    summary.support_count summary.oppose_count summary.neutral_count
    summary.total_arguments

let vote_counts (session : Council.Consensus.session) =
  let approves, rejects, abstains = Council.Consensus.tally_votes session in
  (approves, rejects, abstains)

let related_agents_of_session (session : Council.Consensus.session) =
  let vote_agents = session.votes |> List.map (fun (vote : Council.Consensus.vote) -> vote.agent) in
  dedup_strings (session.initiator :: vote_agents)

let last_activity_of_session (session : Council.Consensus.session) =
  let vote_last =
    session.votes
    |> List.map (fun (vote : Council.Consensus.vote) -> vote.timestamp)
    |> List.sort Float.compare |> List.rev |> function
    | latest :: _ -> Some latest
    | [] -> None
  in
  session.closed_at |> max_opt vote_last |> max_opt (Some session.created_at)

let truth_summary_of_session (session : Council.Consensus.session) =
  let approves, rejects, abstains = vote_counts session in
  Printf.sprintf "approve %d · reject %d · abstain %d · quorum %d"
    approves rejects abstains session.quorum

let matching_confirm pending_items action_json =
  let resolved_tool = action_json |> member "resolved_tool" |> to_string_option in
  let target_type = action_json |> member "target_type" |> to_string_option in
  let target_id = action_json |> member "target_id" |> to_string_option in
  match resolved_tool, target_type with
  | Some resolved_tool, Some target_type ->
      List.find_opt
        (fun confirm ->
          confirm |> member "delegated_tool" |> to_string = resolved_tool
          && confirm |> member "target_type" |> to_string = target_type
          &&
          match target_id, confirm |> member "target_id" |> to_string_option with
          | Some left, Some right -> String.equal left right
          | None, None -> true
          | _ -> false)
        pending_items
  | _ -> None

let executed_route_for logs ~target_type ~target_id =
  let matches log =
    log |> member "target_type" |> to_string = target_type
    &&
    match target_id, log |> member "target_id" |> to_string_option with
    | Some left, Some right -> String.equal left right
    | None, None -> true
    | _ -> false
  in
  match List.find_opt matches logs with
  | Some log ->
      Some
        (`Assoc
          [
            ("action_type", log |> member "action_type");
            ("delegated_tool", log |> member "delegated_tool");
            ("confirmation_state", log |> member "confirmation_state");
            ("created_at", log |> member "created_at");
          ])
  | None -> None

let evidence_refs_of_debate (debate : Council.Debate.debate) =
  debate.arguments
  |> List.mapi (fun index (arg : Council.Debate.argument) ->
         Printf.sprintf "debate:%s:arg:%d:%s" debate.id index arg.agent)

let evidence_refs_of_session (session : Council.Consensus.session) =
  session.votes
  |> List.mapi (fun index (vote : Council.Consensus.vote) ->
         Printf.sprintf "consensus:%s:vote:%d:%s" session.id index vote.agent)

let governance_item_of_debate judgments pending_items recent_action_logs
    (summary : Council.Debate.debate_summary) =
  let debate = summary.debate in
  let judgment = judgment_for judgments ~kind:"debate" ~id:debate.id in
  let recommended_action = Option.bind judgment judgment_recommended_action in
  let context = debate_context_json debate in
  let executed_route =
    executed_route_for recent_action_logs ~target_type:"team_session"
      ~target_id:debate.context.team_session_id
  in
  let pending_confirm = Option.bind recommended_action (matching_confirm pending_items) in
  let guardrail_state =
    `Assoc
      [
        ("requires_human_gate", `Bool (Option.is_some pending_confirm));
        ("pending_confirm", option_to_yojson (fun value -> value) pending_confirm);
        ( "ready_to_execute",
          `Bool
            (match judgment with
            | Some row -> (
                match row |> member "guardrail_state" |> member "ready_to_execute" with
                | `Bool value -> value
                | _ -> false)
            | None -> false) );
      ]
  in
  `Assoc
    [
      ("kind", `String "debate");
      ("id", `String debate.id);
      ("topic", `String debate.topic);
      ("status", `String (Council.Debate.status_to_string debate.status));
      ("last_activity_at", string_opt_json (Option.map iso_of_unix (last_activity_of_debate debate)));
      ("truth_summary", `String (truth_summary_of_debate summary));
      ("judgment_summary", option_to_yojson (fun row -> row |> member "summary") judgment);
      ("confidence", option_to_yojson (fun row -> row |> member "confidence") judgment);
      ("related_agents", list_string_json (related_agents_of_debate debate));
      ("context", context);
      ("linked_board_post_id", context |> member "board_post_id");
      ("linked_task_id", context |> member "task_id");
      ("linked_operation_id", context |> member "operation_id");
      ("linked_session_id", context |> member "team_session_id");
      ("recommended_action", option_to_yojson (fun value -> value) recommended_action);
      ("executed_route", option_to_yojson (fun value -> value) executed_route);
      ("guardrail_state", guardrail_state);
      ("evidence_refs", list_string_json (evidence_refs_of_debate debate));
    ]

let governance_item_of_session judgments pending_items recent_action_logs
    (session : Council.Consensus.session) =
  let judgment = judgment_for judgments ~kind:"consensus" ~id:session.id in
  let recommended_action = Option.bind judgment judgment_recommended_action in
  let context = consensus_context_json session in
  let executed_route =
    executed_route_for recent_action_logs ~target_type:"team_session"
      ~target_id:session.context.team_session_id
  in
  let pending_confirm = Option.bind recommended_action (matching_confirm pending_items) in
  let guardrail_state =
    `Assoc
      [
        ("requires_human_gate", `Bool (Option.is_some pending_confirm));
        ("pending_confirm", option_to_yojson (fun value -> value) pending_confirm);
        ( "ready_to_execute",
          `Bool
            (match judgment with
            | Some row -> (
                match row |> member "guardrail_state" |> member "ready_to_execute" with
                | `Bool value -> value
                | _ -> false)
            | None -> false) );
      ]
  in
  let approves, rejects, abstains = vote_counts session in
  `Assoc
    [
      ("kind", `String "consensus");
      ("id", `String session.id);
      ("topic", `String session.topic);
      ("status", Council.Consensus.voting_state_to_yojson session.state);
      ("last_activity_at", string_opt_json (Option.map iso_of_unix (last_activity_of_session session)));
      ("truth_summary", `String (truth_summary_of_session session));
      ("judgment_summary", option_to_yojson (fun row -> row |> member "summary") judgment);
      ("confidence", option_to_yojson (fun row -> row |> member "confidence") judgment);
      ("related_agents", list_string_json (related_agents_of_session session));
      ("context", context);
      ("linked_board_post_id", context |> member "board_post_id");
      ("linked_task_id", context |> member "task_id");
      ("linked_operation_id", context |> member "operation_id");
      ("linked_session_id", context |> member "team_session_id");
      ("recommended_action", option_to_yojson (fun value -> value) recommended_action);
      ("executed_route", option_to_yojson (fun value -> value) executed_route);
      ("guardrail_state", guardrail_state);
      ("approve_count", `Int approves);
      ("reject_count", `Int rejects);
      ("abstain_count", `Int abstains);
      ("votes", `Int (List.length session.votes));
      ("quorum", `Int session.quorum);
      ("threshold", `Float session.threshold);
      ("evidence_refs", list_string_json (evidence_refs_of_session session));
    ]

let compare_activity left right =
  let left_ts =
    left |> member "created_at" |> to_string_option |> function
    | Some iso -> (try Types.parse_iso8601 iso with _ -> 0.0)
    | None -> 0.0
  in
  let right_ts =
    right |> member "created_at" |> to_string_option |> function
    | Some iso -> (try Types.parse_iso8601 iso with _ -> 0.0)
    | None -> 0.0
  in
  Float.compare right_ts left_ts

let activity_of_debate (debate : Council.Debate.debate) =
  let started =
    `Assoc
      [
        ("kind", `String "debate_started");
        ("item_kind", `String "debate");
        ("item_id", `String debate.id);
        ("topic", `String debate.topic);
        ("created_at", `String (iso_of_unix debate.created_at));
        ("summary", `String "Debate started");
      ]
  in
  let arguments =
    debate.arguments
    |> List.mapi (fun index (arg : Council.Debate.argument) ->
           match arg.created_at with
           | None -> None
           | Some ts ->
               Some
                 (`Assoc
                   [
                     ("kind", `String "argument_added");
                     ("item_kind", `String "debate");
                     ("item_id", `String debate.id);
                     ("created_at", `String (iso_of_unix ts));
                     ("summary", `String arg.content);
                     ("actor", `String arg.agent);
                     ("index", `Int index);
                   ]))
    |> List.filter_map (fun item -> item)
  in
  let closed =
    match debate.closed_at with
    | None -> []
    | Some ts ->
        [
          `Assoc
            [
              ("kind", `String "debate_closed");
              ("item_kind", `String "debate");
              ("item_id", `String debate.id);
              ("created_at", `String (iso_of_unix ts));
              ("summary", `String "Debate closed");
            ];
        ]
  in
  started :: arguments @ closed

let activity_of_session (session : Council.Consensus.session) =
  let started =
    `Assoc
      [
        ("kind", `String "consensus_started");
        ("item_kind", `String "consensus");
        ("item_id", `String session.id);
        ("topic", `String session.topic);
        ("created_at", `String (iso_of_unix session.created_at));
        ("summary", `String "Consensus session started");
      ]
  in
  let votes =
    session.votes
    |> List.map (fun (vote : Council.Consensus.vote) ->
           `Assoc
             [
               ("kind", `String "vote_cast");
               ("item_kind", `String "consensus");
               ("item_id", `String session.id);
               ("created_at", `String (iso_of_unix vote.timestamp));
               ("summary", `String vote.reason);
               ("actor", `String vote.agent);
               ("decision", Council.Consensus.decision_to_yojson vote.decision);
             ])
  in
  let closed =
    match session.closed_at with
    | None -> []
    | Some ts ->
        [
          `Assoc
            [
              ("kind", `String "consensus_closed");
              ("item_kind", `String "consensus");
              ("item_id", `String session.id);
              ("created_at", `String (iso_of_unix ts));
              ("summary", `String "Consensus session closed");
            ];
        ]
  in
  started :: votes @ closed

let factual_snapshot_json ~base_path =
  let config = Council.make_config ~base_path in
  let debates = Council.DebateApi.list_all ~config ~limit:100 () in
  let debate_summaries =
    debates
    |> List.filter_map (fun (debate : Council.Debate.debate) ->
           Council.DebateApi.status ~config ~debate_id:debate.id |> Result.to_option)
  in
  let sessions = Council.ConsensusApi.list_all () in
  let pending_confirms = pending_confirms base_path in
  let recent_action_logs = action_logs base_path in
  let items =
    let debate_items =
      debate_summaries
      |> List.map (fun (summary : Council.Debate.debate_summary) ->
             let debate = summary.debate in
             `Assoc
               [
                 ("kind", `String "debate");
                 ("id", `String debate.id);
                 ("topic", `String debate.topic);
                 ("status", `String (Council.Debate.status_to_string debate.status));
                 ("truth_summary", `String (truth_summary_of_debate summary));
                 ("context", debate_context_json debate);
                 ("related_agents", list_string_json (related_agents_of_debate debate));
                 ("evidence_refs", list_string_json (evidence_refs_of_debate debate));
                 ("pending_confirms", `List pending_confirms);
                 ("recent_actions", `List recent_action_logs);
               ])
    in
    let session_items =
      sessions
      |> List.map (fun (session : Council.Consensus.session) ->
             `Assoc
               [
                 ("kind", `String "consensus");
                 ("id", `String session.id);
                 ("topic", `String session.topic);
                 ("status", Council.Consensus.voting_state_to_yojson session.state);
                 ("truth_summary", `String (truth_summary_of_session session));
                 ("context", consensus_context_json session);
                 ("related_agents", list_string_json (related_agents_of_session session));
                 ("evidence_refs", list_string_json (evidence_refs_of_session session));
                 ("pending_confirms", `List pending_confirms);
                 ("recent_actions", `List recent_action_logs);
               ])
    in
    debate_items @ session_items
  in
  let activity =
    (List.concat_map activity_of_debate debates)
    @ (List.concat_map activity_of_session sessions)
    |> List.sort compare_activity |> fun events -> take 50 events
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("items", `List items);
      ("activity", `List activity);
    ]

let dashboard_json ~base_path ~limit ~offset ~status_filter =
  let config = Council.make_config ~base_path in
  let debates =
    Council.DebateApi.list_all ~config ~status_filter ~limit:(limit + offset) ()
    |> drop offset |> take limit
  in
  let debate_summaries =
    debates
    |> List.filter_map (fun (debate : Council.Debate.debate) ->
           Council.DebateApi.status ~config ~debate_id:debate.id |> Result.to_option)
  in
  let sessions = Council.ConsensusApi.list_all () |> drop offset |> take limit in
  let judgments = latest_judgment_map base_path in
  let pending_items = pending_confirms base_path in
  let recent_action_logs = action_logs base_path in
  let items =
    (debate_summaries
    |> List.map (governance_item_of_debate judgments pending_items recent_action_logs))
    @ (sessions |> List.map (governance_item_of_session judgments pending_items recent_action_logs))
  in
  let items =
    List.sort compare_activity
      (List.map
         (fun item -> `Assoc [ ("created_at", item |> member "last_activity_at"); ("payload", item) ])
         items)
    |> List.map (fun row -> row |> member "payload")
  in
  let judge = judge_runtime_json base_path in
  let ready_to_execute =
    items
    |> List.fold_left
         (fun acc item ->
           match item |> member "guardrail_state" |> member "ready_to_execute" with
           | `Bool true -> acc + 1
           | _ -> acc)
         0
  in
  let sessions_without_quorum =
    sessions
    |> List.fold_left
         (fun acc (session : Council.Consensus.session) ->
           if List.length session.votes < session.quorum then acc + 1 else acc)
         0
  in
  let oldest_open_debate_age_s =
    match debate_summaries with
    | [] -> `Null
    | summaries ->
        let oldest =
          summaries
          |> List.map (fun (summary : Council.Debate.debate_summary) -> summary.debate.created_at)
          |> List.sort Float.compare |> function
          | first :: _ -> Some first
          | [] -> None
        in
        option_to_yojson (fun ts -> `Float (Unix.gettimeofday () -. ts)) oldest
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("debates_open", `Int (List.length debate_summaries));
            ("sessions_active", `Int (List.length sessions));
            ("sessions_without_quorum", `Int sessions_without_quorum);
            ("ready_to_execute", `Int ready_to_execute);
            ("oldest_open_debate_age_s", oldest_open_debate_age_s);
            ("last_activity_age_s", `Null);
            ("judge_online", judge |> member "judge_online");
            ("judge_last_seen_at", judge |> member "generated_at");
          ] );
      ("items", `List items);
      ("activity", factual_snapshot_json ~base_path |> member "activity");
      ("judge", judge);
      ( "pending_actions",
        `List
          (List.map
             (fun item ->
               `Assoc
                 [
                   ("confirm_token", item |> member "confirm_token");
                   ("action_type", item |> member "action_type");
                   ("target_type", item |> member "target_type");
                   ("target_id", item |> member "target_id");
                   ("reason", item |> member "delegated_tool");
                   ("created_at", item |> member "created_at");
                 ])
             pending_items) );
      ( "debates",
        `List
          (List.map
             (fun (summary : Council.Debate.debate_summary) ->
               governance_item_of_debate judgments pending_items recent_action_logs summary)
             debate_summaries) );
      ( "sessions",
        `List
          (List.map
             (governance_item_of_session judgments pending_items recent_action_logs)
             sessions) );
    ]

let debate_detail_json ~base_path ~debate_id : detail_status * Yojson.Safe.t =
  let config = Council.make_config ~base_path in
  match Council.DebateApi.status ~config ~debate_id with
  | Error _ -> (`Not_found, `Assoc [ ("error", `String "Debate not found") ])
  | Ok (summary : Council.Debate.debate_summary) ->
      let debate = summary.debate in
      let judgments = latest_judgment_map base_path in
      let judgment = judgment_for judgments ~kind:"debate" ~id:debate.id in
      let arguments =
        debate.arguments
        |> List.mapi (fun index (arg : Council.Debate.argument) ->
               `Assoc
                 [
                   ("index", `Int index);
                   ("agent", `String arg.agent);
                   ("position", `String (Council.Debate.position_to_string arg.position));
                   ("content", `String arg.content);
                   ("evidence", list_string_json arg.evidence);
                   ("reply_to", option_to_yojson (fun value -> `Int value) arg.reply_to);
                   ("mentions", list_string_json arg.mentions);
                   ("archetype", string_opt_json arg.archetype);
                   ("created_at", option_to_yojson (fun ts -> `String (iso_of_unix ts)) arg.created_at);
                 ])
      in
      ( `OK,
        `Assoc
          [
            ( "debate",
              `Assoc
                [
                  ("id", `String debate.id);
                  ("topic", `String debate.topic);
                  ("status", `String (Council.Debate.status_to_string debate.status));
                  ("created_at", `String (iso_of_unix debate.created_at));
                  ("closed_at", option_to_yojson (fun ts -> `String (iso_of_unix ts)) debate.closed_at);
                ] );
            ("arguments", `List arguments);
            ( "summary",
              `Assoc
                [
                  ("support_count", `Int summary.support_count);
                  ("oppose_count", `Int summary.oppose_count);
                  ("neutral_count", `Int summary.neutral_count);
                  ("total_arguments", `Int summary.total_arguments);
                  ("summary_text", `String (Council.Debate.render_summary summary));
                ] );
            ("context", debate_context_json debate);
            ("judgment", option_to_yojson (fun value -> value) judgment);
          ] )

let consensus_detail_json ~base_path ~session_id : detail_status * Yojson.Safe.t =
  match Council.ConsensusApi.get ~session_id with
  | None -> (`Not_found, `Assoc [ ("error", `String "Consensus session not found") ])
  | Some session ->
      let judgments = latest_judgment_map base_path in
      let judgment = judgment_for judgments ~kind:"consensus" ~id:session.id in
      let approves, rejects, abstains = vote_counts session in
      let result =
        match Council.ConsensusApi.result ~session_id with
        | Ok value -> Some (Council.Consensus.voting_result_to_string value)
        | Error _ -> None
      in
      let votes =
        session.votes
        |> List.map (fun (vote : Council.Consensus.vote) ->
               `Assoc
                 [
                   ("agent", `String vote.agent);
                   ("decision", Council.Consensus.decision_to_yojson vote.decision);
                   ("reason", `String vote.reason);
                   ("timestamp", `String (iso_of_unix vote.timestamp));
                   ("weight", `Float vote.weight);
                   ("archetype", string_opt_json vote.archetype);
                 ])
      in
      ( `OK,
        `Assoc
          [
            ( "session",
              `Assoc
                [
                  ("id", `String session.id);
                  ("topic", `String session.topic);
                  ("state", Council.Consensus.voting_state_to_yojson session.state);
                  ("initiator", `String session.initiator);
                  ("quorum", `Int session.quorum);
                  ("threshold", `Float session.threshold);
                  ("created_at", `String (iso_of_unix session.created_at));
                  ("closed_at", option_to_yojson (fun ts -> `String (iso_of_unix ts)) session.closed_at);
                ] );
            ("votes", `List votes);
            ( "summary",
              `Assoc
                [
                  ("approve_count", `Int approves);
                  ("reject_count", `Int rejects);
                  ("abstain_count", `Int abstains);
                  ("quorum_met", `Bool (List.length session.votes >= session.quorum));
                  ("result", option_to_yojson (fun value -> `String value) result);
                ] );
            ("context", consensus_context_json session);
            ("judgment", option_to_yojson (fun value -> value) judgment);
          ] )
