(** Meta_cognition_snapshot — Data loading, JSON builders, and snapshot generation.

    Loads board posts/comments/votes/governance cases and produces
    deterministic JSON snapshots of room-level beliefs, tensions, desires,
    and social edges.

    @since God file decomposition — extracted from meta_cognition.ml *)

open Meta_cognition_types

(* ================================================================ *)
(* Data loading                                                     *)
(* ================================================================ *)

let load_jsonl_safe path =
  if not (Sys.file_exists path) then []
  else
    try Fs_compat.load_jsonl path
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Pages.warn "load_jsonl_safe: failed to load %s: %s"
          path (Printexc.to_string exn);
        []

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

(* ================================================================ *)
(* Source extraction                                                *)
(* ================================================================ *)

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

(* ================================================================ *)
(* JSON builders                                                    *)
(* ================================================================ *)

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
      List.exists Meta_cognition_rules.operator_need_support matching
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
      match source.target_author, Meta_cognition_rules.classify_interaction_text source.text with
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

(* ================================================================ *)
(* Snapshot assembly                                                *)
(* ================================================================ *)

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
  let all_beliefs =
    Meta_cognition_rules.belief_rules
    |> List.filter_map (fun rule -> belief_json ~limit rule sources)
    |> List.sort (fun a b ->
           let count_of json key = json |> Yojson.Safe.Util.member key |> Yojson.Safe.Util.to_int in
           compare (count_of b "support_agent_count") (count_of a "support_agent_count"))
  in
  let total_belief_count = List.length all_beliefs in
  let beliefs = take limit all_beliefs in
  let all_contested =
    all_beliefs
    |> List.filter (fun json ->
           (match Yojson.Safe.Util.member "status" json with
            | `String s -> String.equal s "contested"
            | _ -> false))
  in
  let total_contested_belief_count = List.length all_contested in
  let contested_beliefs = take limit all_contested in
  let tensions =
    Meta_cognition_rules.tension_rules
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
    Meta_cognition_rules.desire_rules
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
    sources |> List.filter Meta_cognition_rules.tool_block_support |> List.length
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
      ("total_belief_count", `Int total_belief_count);
      ("contested_beliefs", `List contested_beliefs);
      ("total_contested_belief_count", `Int total_contested_belief_count);
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
            `String "board:posts";
            `String "board:comments";
            `String "board:votes";
            `String "governance:cases";
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

(* ================================================================ *)
(* Summary helpers                                                  *)
(* ================================================================ *)

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

let summary_json ?hearth config =
  let snapshot = snapshot_json ?hearth ~limit:3 config in
  `Assoc
    [
      ( "stagnation_score",
        Yojson.Safe.Util.member "stagnation_score" snapshot );
      ("belief_count", Yojson.Safe.Util.member "total_belief_count" snapshot);
      ("contested_belief_count",
        Yojson.Safe.Util.member "total_contested_belief_count" snapshot);
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
