(** Council tools - Multi-agent debate and consensus system *)

open Council
open Tool_args

(* Context required by council tools *)
type context = {
  base_path: string;
  agent_name: string;
  room_config: Room.config option;  (* For broadcasting notifications *)
}

type result = bool * string

let ensure_consensus ctx =
  Consensus.init ~base_path:ctx.base_path

(** {1 SSE Event Broadcasting}

    Emits decision-model events to connected viewers via the SSE push pipeline.
    Wire format follows JSON-RPC 2.0 notification (no id field):
    {jsonrpc: "2.0", method: "masc/event", params: {type, agent, data, timestamp}}

    Event types follow the Cross-Session Protocol defined in the viewer plan:
    - decision_issue, decision_option, decision_argument
    - decision_vote, decision_consensus, decision_phase *)

let broadcast_decision_event ~event_type ~agent ?(data=`Null) () =
  let params = `Assoc [
    ("type", `String event_type);
    ("agent", `String agent);
    ("data", data);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  let notification = `Assoc [
    ("jsonrpc", `String "2.0");
    ("method", `String "masc/event");
    ("params", params);
  ] in
  Sse.broadcast notification

(** {1 Debate Handlers} *)

let handle_debate_start ctx args =
  let topic = get_string args "topic" "" in
  if topic = "" then
    (false, "Error: topic is required")
  else
    let config = Council.make_config ~base_path:ctx.base_path in
    let notify_fn = fun ~agent:_ ~message:_ -> () in
    match DebateApi.start ~config ~topic ~notify_fn with
    | Ok debate ->
      (* SSE: decision_issue + decision_phase(proposal) *)
      broadcast_decision_event ~event_type:"decision_issue" ~agent:ctx.agent_name
        ~data:(`Assoc [
          ("id", `String debate.Debate.id);
          ("title", `String topic);
          ("description", `String topic);
          ("urgency", `String "medium");
        ]) ();
      broadcast_decision_event ~event_type:"decision_phase" ~agent:ctx.agent_name
        ~data:(`Assoc [
          ("issue_id", `String debate.Debate.id);
          ("phase", `String "proposal");
        ]) ();
      let json = `Assoc [
        ("id", `String debate.Debate.id);
        ("topic", `String debate.topic);
        ("status", `String (Debate.status_to_string debate.status));
      ] in
      (true, Yojson.Safe.pretty_to_string json)
    | Error e -> (false, Printf.sprintf "Error: %s" e)

let handle_debate_argue ctx args =
  let debate_id = get_string args "debate_id" "" in
  let position_str = get_string args "position" "neutral" in
  let content = get_string args "content" "" in
  let evidence = get_string_list args "evidence" in
  let reply_to = match Yojson.Safe.Util.member "reply_to" args with
    | `Int i -> Some i
    | _ -> None
  in
  let mentions = get_string_list args "mentions" in
  if debate_id = "" || content = "" then
    (false, "Error: debate_id and content are required")
  else
    let config = Council.make_config ~base_path:ctx.base_path in
    let position = match String.lowercase_ascii position_str with
      | "support" -> Debate.Support
      | "oppose" -> Debate.Oppose
      | _ -> Debate.Neutral
    in
    (* Broadcast notifications via MASC Room *)
    let notify_fn = Some (fun ~agent ~message -> 
      Printf.eprintf "[Council] Notify %s: %s\n%!" agent message;
      match ctx.room_config with
      | None -> ()
      | Some room_cfg ->
        (* Send targeted message to the mentioned agent *)
        let _ = Room.broadcast room_cfg 
          ~from_agent:ctx.agent_name 
          ~content:(Printf.sprintf "@%s %s" agent message) in
        ()
    ) in
    match DebateApi.add_argument ~config ~debate_id ~agent:ctx.agent_name 
            ~position ~content ~evidence ~reply_to ~mentions ~notify_fn () with
    | Ok debate ->
      let count = List.length debate.Debate.arguments in
      let reply_info = match reply_to with
        | Some i -> Printf.sprintf " (reply to #%d)" i
        | None -> ""
      in
      (* SSE: decision_argument *)
      broadcast_decision_event ~event_type:"decision_argument" ~agent:ctx.agent_name
        ~data:(`Assoc [
          ("issue_id", `String debate_id);
          ("option_id", `String (Printf.sprintf "arg-%d" (count - 1)));
          ("agent", `String ctx.agent_name);
          ("position", `String (match position with
            | Debate.Support -> "for"
            | Debate.Oppose -> "against"
            | Debate.Neutral -> "neutral"));
          ("reasoning", `String content);
          ("confidence", `Float 0.8);
        ]) ();
      (true, Printf.sprintf "Argument #%d added%s. Total: %d" (count - 1) reply_info count)
    | Error e -> (false, Printf.sprintf "Error: %s" e)

let handle_debate_close ctx args =
  let debate_id = get_string args "debate_id" "" in
  if debate_id = "" then
    (false, "Error: debate_id is required")
  else
    let config = Council.make_config ~base_path:ctx.base_path in
    match DebateApi.close ~config ~debate_id with
    | Ok debate ->
      (* SSE: decision_phase(resolved) *)
      broadcast_decision_event ~event_type:"decision_phase" ~agent:ctx.agent_name
        ~data:(`Assoc [
          ("issue_id", `String debate.Debate.id);
          ("phase", `String "resolved");
        ]) ();
      let json = `Assoc [
        ("id", `String debate.Debate.id);
        ("topic", `String debate.topic);
        ("status", `String (Debate.status_to_string debate.status));
        ("argument_count", `Int (List.length debate.arguments));
      ] in
      (true, Yojson.Safe.pretty_to_string json)
    | Error e -> (false, Printf.sprintf "Error: %s" e)

let handle_debate_status ctx args =
  let debate_id = get_string args "debate_id" "" in
  if debate_id = "" then
    (false, "Error: debate_id is required")
  else
    let config = Council.make_config ~base_path:ctx.base_path in
    match DebateApi.status ~config ~debate_id with
    | Ok summary ->
      (true, Debate.render_summary summary)
    | Error e -> (false, Printf.sprintf "Error: %s" e)

let handle_debates ctx _args =
  let config = Council.make_config ~base_path:ctx.base_path in
  let debates = DebateApi.list_all ~config () in
  let items = List.map (fun (d : Debate.debate) ->
    `Assoc [
      ("id", `String d.id);
      ("topic", `String d.topic);
      ("status", `String (Debate.status_to_string d.status));
      ("argument_count", `Int (List.length d.arguments));
    ]
  ) debates in
  (true, Yojson.Safe.pretty_to_string (`List items))

(** {1 Consensus Handlers} *)

let handle_consensus_start ctx args =
  ensure_consensus ctx;
  let topic = get_string args "topic" "" in
  let quorum = get_int args "quorum" 2 in
  let threshold = get_float args "threshold" 0.5 in
  if topic = "" then
    (false, "Error: topic is required")
  else
    match ConsensusApi.start_vote ~topic ~initiator:ctx.agent_name ~quorum ~threshold () with
    | Ok session ->
      (* SSE: decision_phase(voting) *)
      broadcast_decision_event ~event_type:"decision_phase" ~agent:ctx.agent_name
        ~data:(`Assoc [
          ("issue_id", `String session.Consensus.id);
          ("phase", `String "voting");
        ]) ();
      let json = `Assoc [
        ("id", `String session.Consensus.id);
        ("topic", `String session.topic);
        ("quorum", `Int session.quorum);
        ("threshold", `Float session.threshold);
      ] in
      (true, Yojson.Safe.pretty_to_string json)
    | Error e ->
      let msg = match e with
        | Consensus.Session_not_found id -> Printf.sprintf "Session not found: %s" id
        | Consensus.Session_closed id -> Printf.sprintf "Session closed: %s" id
        | Consensus.Already_voted agent -> Printf.sprintf "Already voted: %s" agent
        | Consensus.Quorum_not_met { required; current } -> 
          Printf.sprintf "Quorum not met: %d/%d" current required
        | Consensus.Invalid_threshold t -> Printf.sprintf "Invalid threshold: %f" t
      in
      (false, Printf.sprintf "Error: %s" msg)

let handle_consensus_vote ctx args =
  ensure_consensus ctx;
  let session_id = get_string args "session_id" "" in
  (* Accept both "decision" and "choice" for user convenience *)
  let decision_str = 
    let d = get_string args "decision" "" in
    if d = "" then get_string args "choice" "abstain" else d
  in
  let reason = get_string args "reason" "" in
  if session_id = "" then
    (false, "Error: session_id is required")
  else
    let decision = match String.lowercase_ascii decision_str with
      | "approve" | "yes" | "agree" -> Consensus.Approve
      | "reject" | "no" | "disagree" -> Consensus.Reject
      | _ -> Consensus.Abstain
    in
    match ConsensusApi.cast ~session_id ~agent:ctx.agent_name ~decision ~reason () with
    | Ok session ->
      (* SSE: decision_vote *)
      broadcast_decision_event ~event_type:"decision_vote" ~agent:ctx.agent_name
        ~data:(`Assoc [
          ("issue_id", `String session_id);
          ("agent", `String ctx.agent_name);
          ("option_id", `String decision_str);
          ("weight", `Float 1.0);
        ]) ();
      (true, Printf.sprintf "Vote cast. Total votes: %d/%d"
        (List.length session.Consensus.votes) session.quorum)
    | Error e ->
      let msg = match e with
        | Consensus.Session_not_found id -> Printf.sprintf "Session not found: %s" id
        | Consensus.Session_closed id -> Printf.sprintf "Session closed: %s" id
        | Consensus.Already_voted agent -> Printf.sprintf "Already voted: %s" agent
        | Consensus.Quorum_not_met { required; current } -> 
          Printf.sprintf "Quorum not met: %d/%d" current required
        | Consensus.Invalid_threshold t -> Printf.sprintf "Invalid threshold: %f" t
      in
      (false, Printf.sprintf "Error: %s" msg)

let handle_consensus_close ctx args =
  ensure_consensus ctx;
  let session_id = get_string args "session_id" "" in
  if session_id = "" then
    (false, "Error: session_id is required")
  else
    match ConsensusApi.close ~session_id with
    | Ok session ->
      let result = match ConsensusApi.result ~session_id with
        | Ok r -> Consensus.show_voting_result r
        | Error _ -> "unknown"
      in
      (* SSE: decision_consensus *)
      broadcast_decision_event ~event_type:"decision_consensus" ~agent:"system"
        ~data:(`Assoc [
          ("issue_id", `String session.Consensus.id);
          ("chosen_option_id", `String result);
          ("method", `String "weighted");
          ("margin", `Float session.threshold);
          ("dissenting", `List []);
        ]) ();
      let json = `Assoc [
        ("id", `String session.Consensus.id);
        ("topic", `String session.topic);
        ("result", `String result);
        ("vote_count", `Int (List.length session.votes));
      ] in
      (true, Yojson.Safe.pretty_to_string json)
    | Error e ->
      let msg = match e with
        | Consensus.Session_not_found id -> Printf.sprintf "Session not found: %s" id
        | Consensus.Session_closed id -> Printf.sprintf "Session closed: %s" id
        | Consensus.Already_voted agent -> Printf.sprintf "Already voted: %s" agent
        | Consensus.Quorum_not_met { required; current } -> 
          Printf.sprintf "Quorum not met: %d/%d" current required
        | Consensus.Invalid_threshold t -> Printf.sprintf "Invalid threshold: %f" t
      in
      (false, Printf.sprintf "Error: %s" msg)

let handle_consensus_result ctx args =
  ensure_consensus ctx;
  let session_id = get_string args "session_id" "" in
  if session_id = "" then
    (false, "Error: session_id is required")
  else
    match ConsensusApi.result ~session_id with
    | Ok result ->
      (true, Consensus.voting_result_to_string result)
    | Error e ->
      let msg = match e with
        | Consensus.Session_not_found id -> Printf.sprintf "Session not found: %s" id
        | Consensus.Session_closed id -> Printf.sprintf "Session closed: %s" id
        | Consensus.Already_voted agent -> Printf.sprintf "Already voted: %s" agent
        | Consensus.Quorum_not_met { required; current } -> 
          Printf.sprintf "Quorum not met: %d/%d" current required
        | Consensus.Invalid_threshold t -> Printf.sprintf "Invalid threshold: %f" t
      in
      (false, Printf.sprintf "Error: %s" msg)

let handle_sessions ctx _args =
  ensure_consensus ctx;
  let sessions = ConsensusApi.list_active () in
  let items = List.map (fun (s : Consensus.session) ->
    `Assoc [
      ("id", `String s.id);
      ("topic", `String s.topic);
      ("initiator", `String s.initiator);
      ("votes", `Int (List.length s.votes));
      ("quorum", `Int s.quorum);
    ]
  ) sessions in
  (true, Yojson.Safe.pretty_to_string (`List items))

(** {1 Router Handler} *)

let handle_route _ctx args =
  let query = get_string args "query" "" in
  let max_agents = get_int args "max_agents" 3 in
  if query = "" then
    (false, "Error: query is required")
  else
    let decision = RouterApi.route ~max_agents query in
    let agents = List.map (fun (a : Router.agent_spec) ->
      `Assoc [
        ("name", `String a.name);
        ("model", `String a.model);
        ("tier", `String (Router.show_model_tier a.tier));
      ]
    ) decision.agents in
    let json = `Assoc [
      ("agents", `List agents);
      ("reason", `String decision.reason);
      ("estimated_cost", `Float decision.estimated_cost);
      ("complexity", `Float decision.complexity_score);
    ] in
    (true, Yojson.Safe.pretty_to_string json)

(** {1 Status Handler} *)

let handle_council_status ctx _args =
  let config = Council.make_config ~base_path:ctx.base_path in
  let json = Council.status ~config in
  (true, Yojson.Safe.pretty_to_string json)

(** Archive a record (requires Eio context - placeholder) *)
let handle_archive_save _ctx args =
  let type_str = get_string args "type" "decision" in
  let content = get_string args "content" "" in
  let agents = get_string_list args "agents" in
  if content = "" then
    (false, "Error: content is required")
  else
    let record_type = match String.lowercase_ascii type_str with
      | "debate" -> Archive.Debate
      | "vote" -> Archive.Vote
      | "post" -> Archive.Post
      | _ -> Archive.Decision
    in
    let record = Archive.create_record ~type_:record_type ~content ~agents () in
    (* Note: Actual save requires Eio context, done via server-side *)
    let json = `Assoc [
      ("id", `String record.Archive.id);
      ("type", `String (Archive.record_type_to_string record.type_));
      ("content", `String record.content);
      ("agents", `List (List.map (fun a -> `String a) record.agents));
      ("timestamp", `String record.timestamp);
      ("note", `String "Record created. Neo4j save requires server context.");
    ] in
    (true, Yojson.Safe.pretty_to_string json)

(** Execute decision after voting *)
let handle_execute _ctx args =
  let topic = get_string args "topic" "" in
  let result_str = get_string args "result" "majority" in
  if topic = "" then
    (false, "Error: topic is required")
  else
    (* Parse result string to Consensus.voting_result *)
    let result = match String.lowercase_ascii result_str with
      | "unanimous" -> Consensus.Unanimous Consensus.Approve
      | "deadlock" -> Consensus.Deadlock
      | _ -> Consensus.Majority 2  (* Default to majority *)
    in
    match Council.ExecutorApi.execute ~topic ~result with
    | None -> (false, "No action matched or threshold not met")
    | Some exec_result ->
      let json = `Assoc [
        ("success", `Bool exec_result.Executor.success);
        ("stdout", `String exec_result.stdout);
        ("stderr", `String exec_result.stderr);
        ("output", `String exec_result.output);
        ("timestamp", `Float exec_result.timestamp);
      ] in
      (exec_result.success, Yojson.Safe.pretty_to_string json)

(** Dry run - show what would happen *)
let handle_execute_dry_run _ctx args =
  let topic = get_string args "topic" "" in
  let result_str = get_string args "result" "majority" in
  if topic = "" then
    (false, "Error: topic is required")
  else
    let result = match String.lowercase_ascii result_str with
      | "unanimous" -> Consensus.Unanimous Consensus.Approve
      | "deadlock" -> Consensus.Deadlock
      | _ -> Consensus.Majority 2
    in
    let output = Council.ExecutorApi.dry_run ~topic ~result in
    (true, output)

(** {1 Dispatch} *)

let dispatch ctx ~name ~args : result option =
  match name with
  (* Debate tools *)
  | "masc_debate_start" -> Some (handle_debate_start ctx args)
  | "masc_debate_argue" -> Some (handle_debate_argue ctx args)
  | "masc_debate_close" -> Some (handle_debate_close ctx args)
  | "masc_debate_status" -> Some (handle_debate_status ctx args)
  | "masc_debates" -> Some (handle_debates ctx args)
  (* Consensus tools *)
  | "masc_consensus_start" -> Some (handle_consensus_start ctx args)
  | "masc_consensus_vote" -> Some (handle_consensus_vote ctx args)
  | "masc_consensus_close" -> Some (handle_consensus_close ctx args)
  | "masc_consensus_result" -> Some (handle_consensus_result ctx args)
  | "masc_sessions" -> Some (handle_sessions ctx args)
  (* Router tool *)
  | "masc_route" -> Some (handle_route ctx args)
  (* Status *)
  | "masc_council_status" -> Some (handle_council_status ctx args)
  (* Executor *)
  | "masc_execute" -> Some (handle_execute ctx args)
  | "masc_execute_dry_run" -> Some (handle_execute_dry_run ctx args)
  (* Archive *)
  | "masc_archive_save" -> Some (handle_archive_save ctx args)
  | _ -> None

(** {1 Tool Definitions} *)

let definitions = [
  (* Debate tools *)
  `Assoc [
    ("name", `String "masc_debate_start");
    ("description", `String "Start a structured debate on a topic");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The topic to debate");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ]);
  ];
  `Assoc [
    ("name", `String "masc_debate_argue");
    ("description", `String "Add an argument to an ongoing debate");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("debate_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The debate ID");
        ]);
        ("position", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "support"; `String "oppose"; `String "neutral"]);
          ("description", `String "Your position on the topic");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "Your argument");
        ]);
        ("evidence", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Supporting evidence");
        ]);
      ]);
      ("required", `List [`String "debate_id"; `String "content"]);
    ]);
  ];
  `Assoc [
    ("name", `String "masc_debate_close");
    ("description", `String "Close a debate");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("debate_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The debate ID to close");
        ]);
      ]);
      ("required", `List [`String "debate_id"]);
    ]);
  ];
  `Assoc [
    ("name", `String "masc_debate_status");
    ("description", `String "Get status of a debate");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("debate_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The debate ID");
        ]);
      ]);
      ("required", `List [`String "debate_id"]);
    ]);
  ];
  `Assoc [
    ("name", `String "masc_debates");
    ("description", `String "List all debates");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ]);
  ];
  (* Consensus tools *)
  `Assoc [
    ("name", `String "masc_consensus_start");
    ("description", `String "Start a voting session for consensus");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The topic to vote on");
        ]);
        ("quorum", `Assoc [
          ("type", `String "integer");
          ("description", `String "Minimum votes required (default: 2)");
        ]);
        ("threshold", `Assoc [
          ("type", `String "number");
          ("description", `String "Majority threshold 0.0-1.0 (default: 0.5)");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ]);
  ];
  `Assoc [
    ("name", `String "masc_consensus_vote");
    ("description", `String "Cast a vote in a consensus session");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The voting session ID");
        ]);
        ("decision", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "approve"; `String "reject"; `String "abstain"]);
          ("description", `String "Your vote");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for your vote");
        ]);
      ]);
      ("required", `List [`String "session_id"; `String "decision"]);
    ]);
  ];
  `Assoc [
    ("name", `String "masc_consensus_close");
    ("description", `String "Close a voting session and get result");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The voting session ID");
        ]);
      ]);
      ("required", `List [`String "session_id"]);
    ]);
  ];
  `Assoc [
    ("name", `String "masc_consensus_result");
    ("description", `String "Get the result of a voting session");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The voting session ID");
        ]);
      ]);
      ("required", `List [`String "session_id"]);
    ]);
  ];
  `Assoc [
    ("name", `String "masc_sessions");
    ("description", `String "List active voting sessions");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ]);
  ];
  (* Router tool *)
  `Assoc [
    ("name", `String "masc_route");
    ("description", `String "Route a query to appropriate agents (MoE-style)");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [
          ("type", `String "string");
          ("description", `String "The query to route");
        ]);
        ("max_agents", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max agents to select (default: 3)");
        ]);
      ]);
      ("required", `List [`String "query"]);
    ]);
  ];
  (* Status *)
  `Assoc [
    ("name", `String "masc_council_status");
    ("description", `String "Get council system status");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ]);
  ];
]
