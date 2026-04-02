(** Meta_cognition — room-level read model derived from existing artifacts.

    This module does not introduce a new source of truth.
    It aggregates signals already present in board/task/agent/governance
    surfaces into a compact snapshot that can be reused by tools,
    dashboard views, and operator digests. *)

open Types

type source = {
  ref_id : string;
  author : string;
  text : string;
  created_at : float;
  hearth : string option;
  target_author : string option;
}

type governance_case = {
  id : string;
  title : string;
  status : string;
}

type belief_rule = {
  id : string;
  claim : string;
  support : source -> bool;
  challenge : source -> bool;
}

type tension_rule = {
  id : string;
  topic : string;
  kind : string;
  matches : source -> bool;
}

type desire_rule = {
  id : string;
  desired_state : string;
  desire_type : string;
  actionability : string;
  matches : source -> bool;
}

type social_edge = {
  from_agent : string;
  to_agent : string;
  edge_type : string;
  weight : int;
  evidence_refs : string list;
  last_seen_at : float;
}

type belief_summary = {
  id : string option;
  claim : string option;
  status : string option;
  confidence : float option;
  support_agent_count : int option;
  challenge_agent_count : int option;
  evidence_refs : string list;
  challenge_refs : string list;
}

type tension_summary = {
  id : string option;
  topic : string option;
  kind : string option;
  severity : string option;
  recurrence_count : int option;
  needs_operator : bool;
  evidence_refs : string list;
}

type desire_summary = {
  id : string option;
  desired_state : string option;
  desire_type : string option;
  actionability : string option;
  strength : float option;
  evidence_refs : string list;
}

type summary_input = {
  stagnation_score : float;
  belief_count : int;
  contested_belief_count : int;
  dominant_belief : belief_summary option;
  top_tension : tension_summary option;
  top_desire : desire_summary option;
}

type salience =
  | Stable
  | Contested_belief
  | Operator_tension
  | Operator_desire
  | Stagnant_room

type interpretation = {
  primary_salience : salience;
  secondary_saliences : salience list;
  reason : string;
  target_id : string option;
  evidence_refs : string list;
}

type digest_ref = {
  post_id : string;
  title : string;
  created_at : string;
  updated_at : string option;
  hearth : string option;
  digest_key : string;
  matches_summary : bool;
}

let take n xs =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: rest -> loop (remaining - 1) (x :: acc) rest
  in
  loop n [] xs

let unique_non_empty values =
  values
  |> List.map String.trim
  |> List.filter (fun value -> value <> "")
  |> List.sort_uniq String.compare

let clamp ~min_v ~max_v value =
  if value < min_v then min_v
  else if value > max_v then max_v
  else value

let salience_to_string = function
  | Stable -> "stable"
  | Contested_belief -> "contested_belief"
  | Operator_tension -> "operator_tension"
  | Operator_desire -> "operator_desire"
  | Stagnant_room -> "stagnant_room"

let preview ?(max_len = 120) text =
  let text =
    text
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun chunk -> chunk <> "")
    |> String.concat " "
  in
  if String.length text <= max_len then text
  else String.sub text 0 (max 0 (max_len - 1)) ^ "…"

let contains_ci haystack needle =
  String_util.contains_substring
    (String.lowercase_ascii haystack)
    (String.lowercase_ascii needle)

let contains_any_ci haystack needles =
  List.exists (fun needle -> contains_ci haystack needle) needles

let load_jsonl_safe path =
  if not (Sys.file_exists path) then []
  else
    try Fs_compat.load_jsonl path
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> []

let load_board_posts config =
  let path = Filename.concat (Room.masc_dir config) "board_posts.jsonl" in
  load_jsonl_safe path
  |> List.filter_map Board.post_of_yojson

let load_board_comments config =
  let path = Filename.concat (Room.masc_dir config) "board_comments.jsonl" in
  load_jsonl_safe path
  |> List.filter_map Board.comment_of_yojson

let load_board_vote_count config =
  let path = Filename.concat (Room.masc_dir config) "board_votes.jsonl" in
  List.length (load_jsonl_safe path)

let load_governance_cases config =
  let dir = Filename.concat (Room.masc_dir config) "governance_v2/cases" in
  match Safe_ops.list_dir_safe dir with
  | Error _ -> []
  | Ok names ->
      names
      |> List.filter (fun name ->
             Filename.check_suffix name ".json"
             && not (String.starts_with ~prefix:"_" name))
      |> List.filter_map (fun name ->
             let path = Filename.concat dir name in
             match Safe_ops.read_json_file_safe path with
             | Error _ -> None
             | Ok json ->
                 let id = Safe_ops.json_string ~default:"" "id" json in
                 let title = Safe_ops.json_string ~default:"" "title" json in
                 let status = Safe_ops.json_string ~default:"" "status" json in
                 if id = "" then None else Some { id; title; status })

let post_sources ?hearth_filter posts =
  let post_by_id : (string, Board.post) Hashtbl.t =
    Hashtbl.create (max 16 (List.length posts))
  in
  List.iter
    (fun (post : Board.post) ->
      Hashtbl.replace post_by_id (Board.Post_id.to_string post.id) post)
    posts;
  let post_matches_hearth (post : Board.post) =
    match hearth_filter with
    | None -> true
    | Some value -> (
        match post.hearth with
        | Some post_hearth ->
            String.equal
              (String.lowercase_ascii (String.trim post_hearth))
              (String.lowercase_ascii (String.trim value))
        | None -> false)
  in
  let sources =
    posts
    |> List.filter post_matches_hearth
    |> List.map (fun (post : Board.post) ->
           let target_author =
             match post.thread_id with
             | Some thread_id -> (
                 match Hashtbl.find_opt post_by_id thread_id with
                 | Some thread_post ->
                     Some (Board.Agent_id.to_string thread_post.author)
                 | None -> None)
             | None -> None
           in
           {
             ref_id = "post:" ^ Board.Post_id.to_string post.id;
             author = Board.Agent_id.to_string post.author;
             text =
               String.concat "\n"
                 (List.filter (fun value -> String.trim value <> "")
                    [ post.title; post.body ]);
             created_at = post.created_at;
             hearth = post.hearth;
             target_author;
           })
  in
  (sources, post_by_id)

let comment_sources ?hearth_filter
    (post_by_id : (string, Board.post) Hashtbl.t) comments =
  comments
  |> List.filter_map (fun (comment : Board.comment) ->
         match
           Hashtbl.find_opt post_by_id (Board.Post_id.to_string comment.post_id)
         with
         | None -> None
         | Some parent_post ->
             let hearth_matches =
               match hearth_filter with
               | None -> true
               | Some value -> (
                   match parent_post.hearth with
                   | Some hearth ->
                       String.equal
                         (String.lowercase_ascii (String.trim hearth))
                         (String.lowercase_ascii (String.trim value))
                   | None -> false)
             in
             if not hearth_matches then None
             else
               Some
                 {
                   ref_id = "comment:" ^ Board.Comment_id.to_string comment.id;
                   author = Board.Agent_id.to_string comment.author;
                   text = comment.content;
                   created_at = comment.created_at;
                   hearth = parent_post.hearth;
                   target_author =
                     Some (Board.Agent_id.to_string parent_post.author);
                 })

let has_any_signal source needles =
  contains_any_ci source.text needles

let has_modal_signal source =
  has_any_signal source
    [
      "should";
      "need";
      "would be good";
      "could be a good window";
      "request";
      "좋겠";
      "필요";
      "해줬으면";
      "요청";
      "추가";
    ]

let tool_block_challenge_signals =
  [
    "having access";
    "contradict";
    "contradicts the uniform block hypothesis";
    "contradicts the \"uniform block\" hypothesis";
    "per-agent or per-soul-profile differentiated";
    "per-agent";
    "access may be";
    "differentiat";
    "per-agent differentiation";
    "outlier";
    "different tool manifest";
  ]

let tool_block_support_signals =
  [
    "unregistered_masc_tool";
    "masc_* tools";
    "masc_* tool";
    "all masc_* tools tested return";
    "admin tools unavailable";
    "blocked from the same tools";
    "uniform block";
    "policy restriction";
    "policy boundary";
    "keeper_* tools function normally";
    "keeper_* namespace";
  ]

let tool_block_challenge source =
  has_any_signal source tool_block_challenge_signals

let tool_block_support source =
  has_any_signal source tool_block_support_signals
  && not (tool_block_challenge source)

let idle_backlog_support source =
  has_any_signal source
    [
      "backlog empty";
      "no active tasks";
      "no new tasks";
      "idle and available";
      "ready for work";
      "standing by";
      "all 8 backlog tasks are complete";
      "대기 중인 태스크: 0";
      "새로운 태스크가 시딩되지";
      "idle status observation";
      "backlog remains empty";
    ]

let operator_need_support source =
  has_any_signal source
    [
      "operator intervention";
      "operator guidance";
      "requires operator";
      "needs escalation";
      "cannot self-service";
      "not something we can self-service";
      "grant fs permissions";
      "explicit task assignment";
      "tool registration";
      "ops should";
    ]

let operator_need_challenge source =
  has_any_signal source
    [
      "no action needed";
      "no operator action is required";
      "no further keeper-side verification is needed";
    ]

let belief_rules =
  [
    {
      id = "belief:masc_tools_blocked";
      claim =
        "keeper-class agents believe `masc_*` introspection/admin tools are blocked or unavailable";
      support = tool_block_support;
      challenge = tool_block_challenge;
    };
    {
      id = "belief:idle_backlog_empty";
      claim =
        "the room believes backlog is empty and multiple agents are idle or waiting for work";
      support = idle_backlog_support;
      challenge = (fun _ -> false);
    };
    {
      id = "belief:operator_needed";
      claim =
        "the room believes operator intervention or a new privileged surface is needed";
      support = operator_need_support;
      challenge = operator_need_challenge;
    };
  ]

let tension_rules =
  [
    {
      id = "tension:masc_tool_blockage";
      topic = "keeper-facing masc_* tool blockage";
      kind = "policy_gap";
      matches = tool_block_support;
    };
    {
      id = "tension:idle_backlog_empty";
      topic = "idle room with empty backlog";
      kind = "boredom";
      matches = idle_backlog_support;
    };
    {
      id = "tension:path_validator_bug";
      topic = "allowed path validator mismatch";
      kind = "blocker";
      matches =
        (fun source ->
          has_any_signal source
            [
              "path validator";
              "path_not_in_allowed_paths";
              "path-matching function";
              "allowed paths actually match";
              "allowed path string is identical";
            ]);
    };
  ]

let desire_rules =
  [
    {
      id = "desire:task_seeding";
      desired_state = "seed new tasks or otherwise create meaningful work for idle keepers";
      desire_type = "workflow_preference";
      actionability = "operator_or_scheduler";
      matches =
        (fun source ->
          (has_any_signal source [ "task seeding"; "새 태스크"; "new task"; "new work" ]
           && has_modal_signal source)
          || has_any_signal source
               [
                 "request new tasks";
                 "새 태스크 추가";
                 "task availability";
               ]);
    };
    {
      id = "desire:audit_surface";
      desired_state = "provide a read-only audit surface or audit-specific tool path";
      desire_type = "request";
      actionability = "operator_or_platform";
      matches =
        (fun source ->
          has_any_signal source
            [
              "audit api";
              "audit role";
              "audit reader";
              "read-only role";
              "register audit tools";
              "dedicated audit api endpoint";
              "keeper_governance_read";
              "read-only audit tool";
              "audit surface";
            ]);
    };
    {
      id = "desire:operator_guidance";
      desired_state = "get operator guidance or permission changes that unblock current work";
      desire_type = "operator_ask";
      actionability = "operator";
      matches = operator_need_support;
    };
    {
      id = "desire:synthetic_exercise";
      desired_state = "start a synthetic exercise, cleanup pass, or retrospective during idle time";
      desire_type = "aspiration";
      actionability = "room_or_operator";
      matches =
        (fun source ->
          has_any_signal source
            [
              "synthetic multi-agent exercise";
              "housekeeping";
              "stress-testing keeper coordination";
              "reviewing completed task quality";
              "documenting patterns observed";
            ]);
    };
  ]

let classify_interaction_text text =
  if
    contains_any_ci text
      [
        "correction";
        "corrected";
        "retracted";
        "withdrawn";
        "withdrew";
        "amendment";
        "정정";
        "철회";
      ]
  then
    Some "corrects"
  else if
    contains_any_ci text
      [
        "contradicts";
        "however";
        "disagree";
        "incomplete";
        "not wrong";
        "ambiguity";
        "question";
        "반대";
        "불일치";
      ]
  then
    Some "challenges"
  else if
    contains_any_ci text
      [
        "corroborated";
        "confirmed";
        "consistent with";
        "aligns with";
        "agreed";
        "agree";
        "endorsed";
        "support";
        "accept the findings";
        "confirms";
      ]
  then
    Some "corroborates"
  else if contains_any_ci text [ "acknowledged"; "reviewed"; "accepted" ] then
    Some "acknowledges"
  else
    None

let belief_json ~limit (rule : belief_rule) sources =
  let support_sources = List.filter rule.support sources in
  if support_sources = [] then
    None
  else
    let challenge_sources = List.filter rule.challenge sources in
    let support_agents =
      support_sources |> List.map (fun source -> source.author) |> unique_non_empty
    in
    let challenge_agents =
      challenge_sources |> List.map (fun source -> source.author) |> unique_non_empty
    in
    let last_support_at =
      support_sources
      |> List.fold_left
           (fun best (source : source) -> max best source.created_at)
           0.0
    in
    let last_challenge_at =
      challenge_sources
      |> List.fold_left
           (fun best (source : source) -> max best source.created_at)
           0.0
    in
    let status =
      if challenge_agents <> [] && last_challenge_at > last_support_at then
        "contested"
      else if List.length support_agents >= 3 then
        "corroborated"
      else
        "emerging"
    in
    let confidence =
      let support_strength =
        (float_of_int (List.length support_agents) /. 4.0)
        +. (float_of_int (List.length support_sources) /. 12.0)
      in
      let challenge_penalty =
        float_of_int (List.length challenge_agents) /. 6.0
      in
      clamp ~min_v:0.05 ~max_v:0.99 (support_strength -. (0.25 *. challenge_penalty))
    in
    let hearths =
      support_sources
      |> List.filter_map (fun (source : source) -> source.hearth)
      |> unique_non_empty
    in
    Some
      (`Assoc
         [
           ("id", `String rule.id);
           ("claim", `String rule.claim);
           ("status", `String status);
           ("confidence", `Float confidence);
           ("support_agent_count", `Int (List.length support_agents));
           ("challenge_agent_count", `Int (List.length challenge_agents));
           ("support_count", `Int (List.length support_sources));
           ("challenge_count", `Int (List.length challenge_sources));
           ("agents", `List (List.map (fun agent -> `String agent) support_agents));
           ("hearths", `List (List.map (fun hearth -> `String hearth) hearths));
           ( "evidence_refs",
             `List
               (support_sources
               |> List.sort
                    (fun (a : source) (b : source) ->
                      compare b.created_at a.created_at)
               |> take limit
               |> List.map (fun source -> `String source.ref_id)) );
           ( "challenge_refs",
             `List
               (challenge_sources
               |> List.sort
                    (fun (a : source) (b : source) ->
                      compare b.created_at a.created_at)
               |> take limit
               |> List.map (fun source -> `String source.ref_id)) );
         ])

let tension_json ~limit governance_cases (rule : tension_rule) sources =
  let matching = List.filter rule.matches sources in
  if matching = [] then
    None
  else
    let affected_agents =
      matching |> List.map (fun source -> source.author) |> unique_non_empty
    in
    let recurrence_count = List.length matching in
    let needs_operator =
      List.exists operator_need_support matching
      || String.equal rule.id "tension:masc_tool_blockage"
    in
    let severity =
      if recurrence_count >= 6 || List.length affected_agents >= 4 then
        "high"
      else if recurrence_count >= 3 || List.length affected_agents >= 2 then
        "medium"
      else
        "low"
    in
    let linked_governance_cases =
      governance_cases
      |> List.filter (fun (case : governance_case) ->
             contains_any_ci
               (case.title ^ " " ^ case.id ^ " " ^ case.status)
               [ "tool"; "review_tool_usage"; "high-risk tool" ])
      |> take limit
    in
    Some
      (`Assoc
         [
           ("id", `String rule.id);
           ("topic", `String rule.topic);
           ("kind", `String rule.kind);
           ("severity", `String severity);
           ("recurrence_count", `Int recurrence_count);
           ("affected_agent_count", `Int (List.length affected_agents));
           ( "affected_agents",
             `List (List.map (fun agent -> `String agent) affected_agents) );
           ("needs_operator", `Bool needs_operator);
           ( "linked_governance_cases",
             `List
               (List.map
                  (fun (case : governance_case) ->
                    `Assoc
                      [
                        ("id", `String case.id);
                        ("title", `String case.title);
                        ("status", `String case.status);
                      ])
                  linked_governance_cases) );
           ( "evidence_refs",
             `List
               (matching
               |> List.sort
                    (fun (a : source) (b : source) ->
                      compare b.created_at a.created_at)
               |> take limit
               |> List.map (fun source -> `String source.ref_id)) );
         ])

let desire_json ~limit (rule : desire_rule) sources =
  let matching = List.filter rule.matches sources in
  if matching = [] then
    None
  else
    let source_agents =
      matching |> List.map (fun source -> source.author) |> unique_non_empty
    in
    let strength =
      clamp ~min_v:0.05 ~max_v:0.99
        ((float_of_int (List.length source_agents) /. 4.0)
        +. (float_of_int (List.length matching) /. 12.0))
    in
    Some
      (`Assoc
         [
           ("id", `String rule.id);
           ("desired_state", `String rule.desired_state);
           ("type", `String rule.desire_type);
           ("actionability", `String rule.actionability);
           ("strength", `Float strength);
           ("source_agent_count", `Int (List.length source_agents));
           ( "source_agents",
             `List (List.map (fun agent -> `String agent) source_agents) );
           ( "evidence_refs",
             `List
               (matching
               |> List.sort
                    (fun (a : source) (b : source) ->
                      compare b.created_at a.created_at)
               |> take limit
               |> List.map (fun source -> `String source.ref_id)) );
         ])

let social_edges_json ~limit sources =
  let table : (string, social_edge) Hashtbl.t = Hashtbl.create 32 in
  let record_edge (source : source) edge_type target_author =
    let key = source.author ^ "|" ^ target_author ^ "|" ^ edge_type in
    match Hashtbl.find_opt table key with
    | Some edge ->
        Hashtbl.replace table key
          {
            edge with
            weight = edge.weight + 1;
            evidence_refs =
              unique_non_empty (source.ref_id :: edge.evidence_refs);
            last_seen_at = max edge.last_seen_at source.created_at;
          }
    | None ->
        Hashtbl.add table key
          {
            from_agent = source.author;
            to_agent = target_author;
            edge_type;
            weight = 1;
            evidence_refs = [ source.ref_id ];
            last_seen_at = source.created_at;
          }
  in
  List.iter
    (fun (source : source) ->
      match source.target_author, classify_interaction_text source.text with
      | Some target_author, Some edge_type
        when String.trim target_author <> ""
             && not (String.equal source.author target_author) ->
          record_edge source edge_type target_author
      | _ -> ())
    sources;
  Hashtbl.to_seq_values table
  |> List.of_seq
  |> List.sort (fun a b ->
         let by_weight = compare b.weight a.weight in
         if by_weight <> 0 then by_weight
         else compare b.last_seen_at a.last_seen_at)
  |> take limit
  |> List.map (fun edge ->
         `Assoc
           [
             ("from_agent", `String edge.from_agent);
             ("to_agent", `String edge.to_agent);
             ("edge_type", `String edge.edge_type);
             ("weight", `Int edge.weight);
             ("last_seen_at", `Float edge.last_seen_at);
             ( "evidence_refs",
               `List
                 (edge.evidence_refs
                 |> take limit
                 |> List.map (fun ref_id -> `String ref_id)) );
           ])

let active_task_count tasks =
  tasks
  |> List.fold_left
       (fun acc (task : Types.task) ->
         match task.task_status with
         | Types.Done _ | Types.Cancelled _ -> acc
         | Types.Todo | Types.Claimed _ | Types.InProgress _ -> acc + 1)
       0

let stagnation_score ~active_agents ~active_tasks ~idle_signal_count
    ~heartbeat_count ~blocker_count =
  let score =
    (if active_agents > 0 && active_tasks = 0 then 0.35 else 0.0)
    +. min 0.25 (float_of_int idle_signal_count /. 8.0)
    +. min 0.20 (float_of_int heartbeat_count /. 10.0)
    +. min 0.20 (float_of_int blocker_count /. 12.0)
    +. min 0.10 (float_of_int active_agents /. 10.0)
  in
  clamp ~min_v:0.0 ~max_v:1.0 score

let snapshot_json ?hearth ~limit config =
  let limit = max 1 (min 20 limit) in
  let posts = load_board_posts config in
  let comments = load_board_comments config in
  let vote_count = load_board_vote_count config in
  let governance_cases = load_governance_cases config in
  let post_sources, post_by_id = post_sources ?hearth_filter:hearth posts in
  let comment_sources =
    comment_sources ?hearth_filter:hearth post_by_id comments
  in
  let sources = post_sources @ comment_sources in
  let beliefs =
    belief_rules
    |> List.filter_map (fun rule -> belief_json ~limit rule sources)
    |> List.sort (fun a b ->
           let count_of json key = json |> Yojson.Safe.Util.member key |> Yojson.Safe.Util.to_int in
           compare (count_of b "support_agent_count") (count_of a "support_agent_count"))
    |> take limit
  in
  let contested_beliefs =
    beliefs
    |> List.filter (fun json ->
           json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string
           |> String.equal "contested")
  in
  let tensions =
    tension_rules
    |> List.filter_map (fun rule -> tension_json ~limit governance_cases rule sources)
    |> List.sort (fun a b ->
           let count_of json =
             json |> Yojson.Safe.Util.member "recurrence_count"
             |> Yojson.Safe.Util.to_int
           in
           compare (count_of b) (count_of a))
    |> take limit
  in
  let collective_desires =
    desire_rules
    |> List.filter_map (fun rule -> desire_json ~limit rule sources)
    |> List.sort (fun a b ->
           let count_of json =
             json |> Yojson.Safe.Util.member "source_agent_count"
             |> Yojson.Safe.Util.to_int
           in
           compare (count_of b) (count_of a))
    |> take limit
  in
  let social_edges = social_edges_json ~limit sources in
  let tasks = Room.get_tasks_raw config in
  let agents = Room.get_agents_raw config in
  let idle_signal_count =
    sources
    |> List.filter (fun source ->
           contains_any_ci source.text [ "idle"; "ready for work"; "standing by" ])
    |> List.length
  in
  let heartbeat_count =
    sources
    |> List.filter (fun source -> contains_any_ci source.text [ "heartbeat" ])
    |> List.length
  in
  let blocker_count =
    sources |> List.filter tool_block_support |> List.length
  in
  let active_tasks = active_task_count tasks in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ( "room_state",
        `Assoc
          [
            ("active_agent_count", `Int (List.length agents));
            ("active_task_count", `Int active_tasks);
            ("total_task_count", `Int (List.length tasks));
            ("board_post_count", `Int (List.length posts));
            ("board_comment_count", `Int (List.length comments));
            ("board_vote_count", `Int vote_count);
            ("governance_case_count", `Int (List.length governance_cases));
          ] );
      ("beliefs", `List beliefs);
      ("contested_beliefs", `List contested_beliefs);
      ("tensions", `List tensions);
      ("collective_desires", `List collective_desires);
      ("social_edges", `List social_edges);
      ( "stagnation_score",
        `Float
          (stagnation_score ~active_agents:(List.length agents)
             ~active_tasks ~idle_signal_count ~heartbeat_count ~blocker_count) );
      ( "evidence_refs",
        `List
          [
            `String (Filename.concat (Room.masc_dir config) "board_posts.jsonl");
            `String (Filename.concat (Room.masc_dir config) "board_comments.jsonl");
            `String
              (Filename.concat (Room.masc_dir config) "governance_v2/cases");
          ] );
      ( "notes",
        `List
          [
            `String
              "Votes are treated as secondary evidence. The current snapshot weights posts, comments, and thread-linked corroboration more heavily.";
            `String
              "This is a deterministic heuristic snapshot, not an LLM judgment layer.";
          ] );
      ( "highlights",
        `List
          (take limit sources
          |> List.map (fun source ->
                 `Assoc
                   [
                     ("ref", `String source.ref_id);
                     ("author", `String source.author);
                     ("preview", `String (preview source.text));
                   ])) );
    ]

let assoc_subset json fields =
  match json with
  | `Assoc pairs ->
      `Assoc
        (fields
        |> List.filter_map (fun field ->
               match List.assoc_opt field pairs with
               | Some value -> Some (field, value)
               | None -> None))
  | _ -> `Assoc []

let assoc_subset_or_null json fields =
  match assoc_subset json fields with
  | `Assoc [] -> `Null
  | value -> value

let first_item_or_null json key =
  match Yojson.Safe.Util.member key json with
  | `List (item :: _) -> item
  | _ -> `Null

let list_length json key =
  match Yojson.Safe.Util.member key json with
  | `List items -> List.length items
  | _ -> 0

let summary_json ?hearth config =
  let snapshot = snapshot_json ?hearth ~limit:3 config in
  `Assoc
    [
      ( "stagnation_score",
        Yojson.Safe.Util.member "stagnation_score" snapshot );
      ("belief_count", `Int (list_length snapshot "beliefs"));
      ("contested_belief_count", `Int (list_length snapshot "contested_beliefs"));
      ( "dominant_belief",
        assoc_subset_or_null
          (first_item_or_null snapshot "beliefs")
          [ "id"; "claim"; "status"; "confidence"; "support_agent_count";
            "challenge_agent_count"; "evidence_refs"; "challenge_refs" ] );
      ( "top_tension",
        assoc_subset_or_null
          (first_item_or_null snapshot "tensions")
          [ "id"; "topic"; "kind"; "severity"; "recurrence_count";
            "needs_operator"; "evidence_refs" ] );
      ( "top_desire",
        assoc_subset_or_null
          (first_item_or_null snapshot "collective_desires")
          [ "id"; "desired_state"; "type"; "actionability"; "strength";
            "evidence_refs" ] );
    ]

let json_string_opt = function
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let json_int_opt = function
  | `Int value -> Some value
  | `Intlit raw -> (
      try Some (int_of_string raw) with Failure _ -> None)
  | _ -> None

let json_float_opt = function
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit raw -> (
      try Some (float_of_string raw) with Failure _ -> None)
  | _ -> None

let json_bool_opt = function
  | `Bool value -> Some value
  | _ -> None

let json_string_list_opt = function
  | `List items ->
      Some (items |> List.filter_map json_string_opt |> unique_non_empty)
  | `Null -> Some []
  | _ -> None

let parse_belief_summary = function
  | `Assoc _ as json ->
      Ok
        {
          id = Yojson.Safe.Util.member "id" json |> json_string_opt;
          claim = Yojson.Safe.Util.member "claim" json |> json_string_opt;
          status = Yojson.Safe.Util.member "status" json |> json_string_opt;
          confidence = Yojson.Safe.Util.member "confidence" json |> json_float_opt;
          support_agent_count =
            Yojson.Safe.Util.member "support_agent_count" json |> json_int_opt;
          challenge_agent_count =
            Yojson.Safe.Util.member "challenge_agent_count" json |> json_int_opt;
          evidence_refs =
            Yojson.Safe.Util.member "evidence_refs" json
            |> json_string_list_opt |> Option.value ~default:[];
          challenge_refs =
            Yojson.Safe.Util.member "challenge_refs" json
            |> json_string_list_opt |> Option.value ~default:[];
        }
  | `Null -> Ok { id = None; claim = None; status = None; confidence = None;
                  support_agent_count = None; challenge_agent_count = None;
                  evidence_refs = []; challenge_refs = [] }
  | _ -> Error "dominant_belief must be an object"

let parse_tension_summary = function
  | `Assoc _ as json ->
      Ok
        {
          id = Yojson.Safe.Util.member "id" json |> json_string_opt;
          topic = Yojson.Safe.Util.member "topic" json |> json_string_opt;
          kind = Yojson.Safe.Util.member "kind" json |> json_string_opt;
          severity = Yojson.Safe.Util.member "severity" json |> json_string_opt;
          recurrence_count =
            Yojson.Safe.Util.member "recurrence_count" json |> json_int_opt;
          needs_operator =
            Yojson.Safe.Util.member "needs_operator" json |> json_bool_opt
            |> Option.value ~default:false;
          evidence_refs =
            Yojson.Safe.Util.member "evidence_refs" json
            |> json_string_list_opt |> Option.value ~default:[];
        }
  | `Null ->
      Ok
        {
          id = None;
          topic = None;
          kind = None;
          severity = None;
          recurrence_count = None;
          needs_operator = false;
          evidence_refs = [];
        }
  | _ -> Error "top_tension must be an object"

let parse_desire_summary = function
  | `Assoc _ as json ->
      Ok
        {
          id = Yojson.Safe.Util.member "id" json |> json_string_opt;
          desired_state = Yojson.Safe.Util.member "desired_state" json |> json_string_opt;
          desire_type = Yojson.Safe.Util.member "type" json |> json_string_opt;
          actionability = Yojson.Safe.Util.member "actionability" json |> json_string_opt;
          strength = Yojson.Safe.Util.member "strength" json |> json_float_opt;
          evidence_refs =
            Yojson.Safe.Util.member "evidence_refs" json
            |> json_string_list_opt |> Option.value ~default:[];
        }
  | `Null ->
      Ok
        {
          id = None;
          desired_state = None;
          desire_type = None;
          actionability = None;
          strength = None;
          evidence_refs = [];
        }
  | _ -> Error "top_desire must be an object"

let parse_optional_summary parse value =
  match value with
  | `Null -> Ok None
  | other ->
      Result.map
        (fun parsed ->
          match other with
          | `Assoc _ -> Some parsed
          | _ -> None)
        (parse other)

let parse_summary json =
  let open Yojson.Safe.Util in
  match json_float_opt (member "stagnation_score" json) with
  | None -> Error "summary.stagnation_score missing or invalid"
  | Some stagnation_score -> (
      match json_int_opt (member "belief_count" json),
            json_int_opt (member "contested_belief_count" json),
            parse_optional_summary parse_belief_summary (member "dominant_belief" json),
            parse_optional_summary parse_tension_summary (member "top_tension" json),
            parse_optional_summary parse_desire_summary (member "top_desire" json)
      with
      | Some belief_count, Some contested_belief_count,
        Ok dominant_belief, Ok top_tension, Ok top_desire ->
          Ok
            {
              stagnation_score;
              belief_count;
              contested_belief_count;
              dominant_belief;
              top_tension;
              top_desire;
            }
      | None, _, _, _, _ -> Error "summary.belief_count missing or invalid"
      | _, None, _, _, _ -> Error "summary.contested_belief_count missing or invalid"
      | _, _, Error err, _, _ -> Error err
      | _, _, _, Error err, _ -> Error err
      | _, _, _, _, Error err -> Error err)

let operator_actionability = function
  | Some ("operator" | "operator_or_platform" | "operator_or_scheduler"
         | "room_or_operator") -> true
  | _ -> false

let evidence_refs_of_belief (belief : belief_summary) =
  unique_non_empty (belief.evidence_refs @ belief.challenge_refs)

let evidence_refs_of_salience (summary : summary_input) = function
  | Contested_belief -> (
      match summary.dominant_belief with
      | Some belief -> evidence_refs_of_belief belief
      | None -> [])
  | Operator_tension -> (
      match summary.top_tension with
      | Some tension -> tension.evidence_refs
      | None -> [])
  | Operator_desire -> (
      match summary.top_desire with
      | Some desire -> desire.evidence_refs
      | None -> [])
  | Stagnant_room -> (
      match summary.top_tension, summary.dominant_belief, summary.top_desire with
      | Some tension, _, _ when tension.evidence_refs <> [] -> tension.evidence_refs
      | _, Some belief, _ when evidence_refs_of_belief belief <> [] ->
          evidence_refs_of_belief belief
      | _, _, Some desire -> desire.evidence_refs
      | _ -> [])
  | Stable -> []

let reason_of_salience (summary : summary_input) = function
  | Contested_belief -> (
      match Option.bind summary.dominant_belief (fun belief -> belief.claim) with
      | Some claim -> Printf.sprintf "집단 인식에 이견이 있습니다: %s" claim
      | None -> "집단 인식에 이견이 있습니다.")
  | Operator_tension -> (
      match Option.bind summary.top_tension (fun tension -> tension.topic) with
      | Some topic -> Printf.sprintf "운영자 개입이 필요한 집단 긴장: %s" topic
      | None -> "운영자 개입이 필요한 집단 긴장이 감지되었습니다.")
  | Operator_desire -> (
      match Option.bind summary.top_desire (fun desire -> desire.desired_state) with
      | Some desired_state ->
          Printf.sprintf "room이 운영자 액션을 원합니다: %s" desired_state
      | None -> "room-level desire가 운영자 액션을 요청합니다.")
  | Stagnant_room ->
      Printf.sprintf "room stagnation이 %.0f%%로 높습니다. 메타인지 snapshot을 확인하세요."
        (summary.stagnation_score *. 100.0)
  | Stable -> "room-level signal is currently stable."

let target_id_of_salience (summary : summary_input) = function
  | Contested_belief ->
      Option.bind summary.dominant_belief (fun belief -> belief.id)
  | Operator_tension ->
      Option.bind summary.top_tension (fun tension -> tension.id)
  | Operator_desire ->
      Option.bind summary.top_desire (fun desire -> desire.id)
  | Stagnant_room | Stable -> None

let interpret (summary : summary_input) =
  let signals =
    [
      (Contested_belief, summary.contested_belief_count > 0);
      ( Operator_tension,
        match summary.top_tension with
        | Some tension -> tension.needs_operator || tension.severity = Some "high"
        | None -> false );
      ( Operator_desire,
        match summary.top_desire with
        | Some desire -> operator_actionability desire.actionability
        | None -> false );
      (Stagnant_room, summary.stagnation_score >= 0.65);
    ]
    |> List.filter_map (fun (salience, active) -> if active then Some salience else None)
  in
  let primary_salience =
    match signals with
    | salience :: _ -> salience
    | [] -> Stable
  in
  let secondary_saliences =
    match signals with
    | [] -> []
    | _primary :: rest -> rest
  in
  {
    primary_salience;
    secondary_saliences;
    reason = reason_of_salience summary primary_salience;
    target_id = target_id_of_salience summary primary_salience;
    evidence_refs =
      evidence_refs_of_salience summary primary_salience |> unique_non_empty;
  }

let salience_list_to_json saliences =
  `List (List.map (fun salience -> `String (salience_to_string salience)) saliences)

let interpretation_to_json interpretation =
  `Assoc
    [
      ("primary_salience", `String (salience_to_string interpretation.primary_salience));
      ("secondary_saliences", salience_list_to_json interpretation.secondary_saliences);
      ("reason", `String interpretation.reason);
      ( "target_id",
        match interpretation.target_id with
        | Some value -> `String value
        | None -> `Null );
      ("evidence_refs", `List (List.map (fun ref_id -> `String ref_id) interpretation.evidence_refs));
    ]

let summary_signature summary =
  let dominant_belief = summary.dominant_belief in
  let top_tension = summary.top_tension in
  let top_desire = summary.top_desire in
  let stagnation_bucket =
    int_of_float (summary.stagnation_score *. 10.0)
  in
  let parts =
    [
      Option.value ~default:"none" (Option.bind dominant_belief (fun belief -> belief.id));
      Option.value ~default:"none" (Option.bind dominant_belief (fun belief -> belief.status));
      Option.value ~default:"none" (Option.bind top_tension (fun tension -> tension.id));
      Option.value ~default:"none" (Option.bind top_tension (fun tension -> tension.severity));
      Option.value ~default:"none" (Option.bind top_desire (fun desire -> desire.id));
      Option.value ~default:"none"
        (Option.bind top_desire (fun desire -> desire.actionability));
      string_of_int summary.contested_belief_count;
      string_of_int stagnation_bucket;
    ]
  in
  Digest.string (String.concat "|" parts) |> Digest.to_hex

let digest_hearth = "meta-cognition"
let digest_source = "meta_cognition_digest"

let post_digest_key post =
  match post.Board.meta_json with
  | Some (`Assoc fields) -> (
      match List.assoc_opt "source" fields, List.assoc_opt "digest_key" fields with
      | Some (`String source), Some (`String digest_key)
        when String.equal (String.lowercase_ascii (String.trim source)) digest_source ->
          Some digest_key
      | _ -> None)
  | _ -> None

let latest_digest_post () =
  Board_dispatch.list_posts ~hearth:digest_hearth
    ~post_kind_filter:Board.Automation_post ~sort_by:Board_dispatch.Recent
    ~limit:20 ()
  |> List.find_map (fun post ->
         Option.map (fun digest_key -> (post, digest_key)) (post_digest_key post))

let latest_digest_ref ?summary () =
  match latest_digest_post () with
  | None -> None
  | Some (post, digest_key) ->
      let matches_summary =
        match summary with
        | Some current_summary ->
            String.equal digest_key (summary_signature current_summary)
        | None -> false
      in
      Some
        {
          post_id = Board.Post_id.to_string post.id;
          title = post.title;
          created_at = Server_utils.iso8601_of_unix post.created_at;
          updated_at = Some (Server_utils.iso8601_of_unix post.updated_at);
          hearth = post.hearth;
          digest_key;
          matches_summary;
        }

let latest_digest_json ?summary () =
  match latest_digest_ref ?summary () with
  | None -> `Null
  | Some digest ->
      `Assoc
        [
          ("post_id", `String digest.post_id);
          ("title", `String digest.title);
          ("created_at", `String digest.created_at);
          ( "updated_at",
            match digest.updated_at with
            | Some value -> `String value
            | None -> `Null );
          ( "hearth",
            match digest.hearth with
            | Some value -> `String value
            | None -> `Null );
          ("digest_key", `String digest.digest_key);
          ("matches_summary", `Bool digest.matches_summary);
          ("provenance", `String "board");
        ]
