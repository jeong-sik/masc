(** Council tools - Governance V2 petition/case/ruling surface. *)

open Tool_args
open Tool_council_json
open Tool_council_helpers
open Tool_council_logic

module GV2 = Council.Governance_v2

type context = Tool_council_helpers.context = {
  base_path : string;
  agent_name : string;
  room_config : Room.config option;
}

type result = Tool_council_helpers.result

let execute_action = Tool_council_logic.execute_action

let handle_petition_submit ctx args =
  let title = get_string args "title" "" in
  if String.trim title = "" then
    (false, "title is required")
  else
    match parse_requested_action args with
    | Error message -> (false, message)
    | Ok requested_action -> (
        match derive_risk_class args requested_action with
        | Error message -> (false, message)
        | Ok risk_class ->
            let origin =
              let value = get_string args "origin" "human" |> String.trim in
              if value = "" then "human" else value
            in
            let subject_type =
              let value = get_string args "subject_type" "task" |> String.trim in
              if value = "" then "task" else value
            in
            let source_refs = get_string_list args "source_refs" in
            match
              GV2.submit_petition ctx.base_path ~title ~origin ~subject_type
                ~risk_class ~requested_action ~source_refs
                ~created_by:ctx.agent_name
            with
            | Error message -> (false, message)
            | Ok result -> (
                match GV2.get_case_bundle ctx.base_path result.case_.id with
                | Error message -> (false, message)
                | Ok bundle ->
                    let ruling = build_ruling bundle in
                    let _ = GV2.save_ruling ctx.base_path ruling in
                    let json =
                      `Assoc
                        [
                          ("petition", petition_json result.petition);
                          ("case", case_json result.case_);
                          ("merged", `Bool result.merged);
                          ("ruling", ruling_json ruling);
                        ]
                    in
                    (true, Yojson.Safe.pretty_to_string json)))

let handle_case_brief_submit ctx args =
  let case_id = get_string args "case_id" "" in
  let summary = get_string args "summary" "" in
  if String.trim case_id = "" || String.trim summary = "" then
    (false, "case_id and summary are required")
  else
    match parse_stance args with
    | Error message -> (false, message)
    | Ok stance ->
        let evidence_refs = get_string_list args "evidence_refs" in
        (match
           GV2.submit_brief ctx.base_path ~case_id ~author:ctx.agent_name ~stance
             ~summary ~evidence_refs
         with
        | Error message -> (false, message)
        | Ok _case -> (
            match GV2.get_case_bundle ctx.base_path case_id with
            | Error message -> (false, message)
            | Ok bundle ->
                let ruling = build_ruling bundle in
                let _ = GV2.save_ruling ctx.base_path ruling in
                let order =
                  match build_execution_order bundle ruling with
                  | None -> None
                  | Some initial_order -> (
                      let _ = GV2.save_execution_order ctx.base_path initial_order in
                      match initial_order.GV2.status with
                      | GV2.Queued_auto -> (
                          match execute_action ctx bundle.GV2.case_ initial_order with
                          | Ok executed_order ->
                              let _ = GV2.update_execution_order ctx.base_path executed_order in
                              Some executed_order
                          | Error message ->
                              let blocked_order =
                                {
                                  initial_order with
                                  status = GV2.Blocked_order;
                                  updated_at = Time_compat.now ();
                                  result_summary = Some message;
                                  actor = Some ctx.agent_name;
                                }
                              in
                              let _ = GV2.update_execution_order ctx.base_path blocked_order in
                              Some blocked_order)
                      | _ -> Some initial_order)
                in
                (match GV2.get_case_bundle ctx.base_path case_id with
                | Error message -> (false, message)
                | Ok fresh_bundle ->
                    let json =
                      `Assoc
                        [
                          ("case", case_json fresh_bundle.case_);
                          ("ruling", ruling_json ruling);
                          ( "execution_order",
                            match order with
                            | Some value -> execution_order_json value
                            | None -> `Null );
                        ]
                    in
                    (true, Yojson.Safe.pretty_to_string json))))

let status_filter_of_string = function
  | "pending_ruling" -> Some GV2.Pending_ruling
  | "ready_auto_execute" -> Some GV2.Ready_auto_execute
  | "needs_human_gate" -> Some GV2.Needs_human_gate
  | "executed" -> Some GV2.Executed
  | "blocked" -> Some GV2.Blocked
  | "closed" -> Some GV2.Closed
  | _ -> None

let handle_cases ctx args =
  let include_test = get_bool args "include_test" false in
  let status_filter =
    get_string args "status" "" |> String.lowercase_ascii |> status_filter_of_string
  in
  let cases = GV2.list_cases ~include_test ?status_filter ctx.base_path in
  let items = `List (List.map case_json cases) in
  (true, Yojson.Safe.pretty_to_string items)

let handle_case_status ctx args =
  let case_id = get_string args "case_id" "" in
  if String.trim case_id = "" then
    (false, "case_id is required")
  else
    match GV2.get_case_bundle ctx.base_path case_id with
    | Error message -> (false, message)
    | Ok bundle -> (true, Yojson.Safe.pretty_to_string (case_bundle_json bundle))

let handle_ruling_status ctx args =
  let case_id = get_string args "case_id" "" in
  if String.trim case_id = "" then
    (false, "case_id is required")
  else
    match GV2.get_case_bundle ctx.base_path case_id with
    | Error message -> (false, message)
    | Ok bundle -> (
        match bundle.GV2.ruling with
        | Some ruling -> (true, Yojson.Safe.pretty_to_string (ruling_json ruling))
        | None -> (false, "ruling not found"))

let handle_execution_orders ctx args =
  let case_id = get_string args "case_id" "" |> String.trim in
  let decision = get_string args "decision" "" |> String.lowercase_ascii |> String.trim in
  match (case_id, decision) with
  | "", "" ->
      let orders = GV2.list_execution_orders ctx.base_path in
      let json = `List (List.map execution_order_json orders) in
      (true, Yojson.Safe.pretty_to_string json)
  | "", _ -> (false, "case_id is required when decision is provided")
  | _, "" -> (
      match GV2.get_case_bundle ctx.base_path case_id with
      | Error message -> (false, message)
      | Ok bundle -> (
          match bundle.GV2.execution_order with
          | Some order ->
              (true, Yojson.Safe.pretty_to_string (execution_order_json order))
          | None -> (false, "execution order not found")))
  | _, "deny" -> (
      match GV2.get_case_bundle ctx.base_path case_id with
      | Error message -> (false, message)
      | Ok bundle -> (
          match bundle.GV2.execution_order with
          | None -> (false, "execution order not found")
          | Some order ->
              let denied =
                {
                  order with
                  status = GV2.Denied;
                  updated_at = Time_compat.now ();
                  result_summary = Some "Denied by human gate";
                  actor = Some ctx.agent_name;
                }
              in
              let _ = GV2.update_execution_order ctx.base_path denied in
              let _ = GV2.set_case_status ctx.base_path ~case_id ~status:GV2.Closed in
              (true, Yojson.Safe.pretty_to_string (execution_order_json denied))))
  | _, "confirm" -> (
      match GV2.get_case_bundle ctx.base_path case_id with
      | Error message -> (false, message)
      | Ok bundle -> (
          match bundle.GV2.execution_order with
          | None -> (false, "execution order not found")
          | Some order when order.GV2.status <> GV2.Needs_human_gate_order ->
              (false, "execution order is not waiting for human confirmation")
          | Some order -> (
              match execute_action ctx bundle.GV2.case_ order with
              | Error message ->
                  let blocked =
                    {
                      order with
                      status = GV2.Blocked_order;
                      updated_at = Time_compat.now ();
                      result_summary = Some message;
                      actor = Some ctx.agent_name;
                    }
                  in
                  let _ = GV2.update_execution_order ctx.base_path blocked in
                  (false, message)
              | Ok executed ->
                  let _ = GV2.update_execution_order ctx.base_path executed in
                  (true, Yojson.Safe.pretty_to_string (execution_order_json executed)))))
  | _, other ->
      (false, Printf.sprintf "unsupported decision: %s" other)

let handle_governance_status ctx _args =
  let cases : GV2.case_record list = GV2.list_cases ctx.base_path in
  let counts =
    List.fold_left
      (fun (pending, ready, human_gate, executed, blocked)
           (case_ : GV2.case_record) ->
        match case_.GV2.status with
        | GV2.Pending_ruling -> (pending + 1, ready, human_gate, executed, blocked)
        | GV2.Ready_auto_execute -> (pending, ready + 1, human_gate, executed, blocked)
        | GV2.Needs_human_gate -> (pending, ready, human_gate + 1, executed, blocked)
        | GV2.Executed -> (pending, ready, human_gate, executed + 1, blocked)
        | GV2.Blocked | GV2.Closed -> (pending, ready, human_gate, executed, blocked + 1))
      (0, 0, 0, 0, 0) cases
  in
  let pending, ready, human_gate, executed, blocked = counts in
  let json =
    `Assoc
      [
        ("cases_open", `Int (List.length cases));
        ("pending_ruling", `Int pending);
        ("ready_auto_execute", `Int ready);
        ("needs_human_gate", `Int human_gate);
        ("executed", `Int executed);
        ("blocked", `Int blocked);
      ]
  in
  (true, Yojson.Safe.pretty_to_string json)

let handle_route _ctx args =
  let query = get_string args "query" "" in
  if String.trim query = "" then (false, "query is required")
  else
    let decision = Council.RouterApi.route query in
    let json =
      `Assoc
        [
          ("reason", `String decision.reason);
          ("agents", json_string_list (List.map (fun agent -> agent.Council.Router.name) decision.agents));
        ]
    in
    (true, Yojson.Safe.pretty_to_string json)

let handle_execute _ctx args =
  let topic = get_string args "topic" "" in
  let result_str = get_string args "result" "majority" in
  if String.trim topic = "" then
    (false, "topic is required")
  else
    let result =
      match String.lowercase_ascii result_str with
      | "unanimous" -> Council.Consensus.Unanimous Council.Consensus.Approve
      | "deadlock" -> Council.Consensus.Deadlock
      | _ -> Council.Consensus.Majority 2
    in
    match Council.ExecutorApi.execute ~topic ~result with
    | Some output ->
        let json =
          `Assoc
            [
              ("topic", `String topic);
              ("result", `String result_str);
              ("output", `String output.output);
              ("stdout", `String output.stdout);
              ("stderr", `String output.stderr);
            ]
        in
        (true, Yojson.Safe.pretty_to_string json)
    | None -> (false, "no executor matched the topic")

let handle_execute_dry_run _ctx args =
  let topic = get_string args "topic" "" in
  let result_str = get_string args "result" "majority" in
  if String.trim topic = "" then
    (false, "topic is required")
  else
    let result =
      match String.lowercase_ascii result_str with
      | "unanimous" -> Council.Consensus.Unanimous Council.Consensus.Approve
      | "deadlock" -> Council.Consensus.Deadlock
      | _ -> Council.Consensus.Majority 2
    in
    (true, Council.ExecutorApi.dry_run ~topic ~result)

let schemas : Types.tool_schema list = [
  {
    name = "masc_petition_submit";
    description = "Submit a Governance V2 petition. Creates or merges a case, records requested action metadata, and files the item into the petition inbox.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("title", `Assoc [
          ("type", `String "string");
          ("description", `String "Petition title or agenda item");
        ]);
        ("origin", `Assoc [
          ("type", `String "string");
          ("description", `String "Origin tag such as human, automation, test, or harness");
        ]);
        ("subject_type", `Assoc [
          ("type", `String "string");
          ("description", `String "Subject classification such as task, operation, policy, or dispute");
        ]);
        ("risk_class", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "low"; `String "high"]);
          ("description", `String "Explicit risk classification. If omitted, the runtime derives it from the requested action.");
        ]);
        ("requested_action", `Assoc [
          ("type", `String "object");
          ("description", `String "Action metadata to execute when the case is adopted");
          ("properties", `Assoc [
            ("action_type", `Assoc [("type", `String "string")]);
            ("target_type", `Assoc [("type", `String "string")]);
            ("target_id", `Assoc [("type", `String "string")]);
            ("payload", `Assoc [("type", `String "object")]);
          ]);
        ]);
        ("source_refs", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Evidence or source references attached to the petition");
        ]);
      ]);
      ("required", `List [`String "title"]);
    ];
  };
  {
    name = "masc_case_brief_submit";
    description = "Add a support/oppose/neutral brief to a Governance V2 case. Brief submission can trigger a ruling and execution order.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
        ("stance", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "support"; `String "oppose"; `String "neutral"]);
          ("description", `String "Brief stance for the case");
        ]);
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Short brief text");
        ]);
        ("evidence_refs", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Evidence references supporting the brief");
        ]);
      ]);
      ("required", `List [`String "case_id"; `String "summary"]);
    ];
  };
  {
    name = "masc_cases";
    description = "List Governance V2 cases. Use this instead of the legacy debate/session listing tools.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("status", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional case status filter");
        ]);
        ("include_test", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include test/harness cases that are hidden by default");
        ]);
      ]);
    ];
  };
  {
    name = "masc_case_status";
    description = "Read a single Governance V2 case bundle including petitions, briefs, ruling, and execution order.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
      ]);
      ("required", `List [`String "case_id"]);
    ];
  };
  {
    name = "masc_ruling_status";
    description = "Read the latest Governance V2 ruling (approved, denied, pending) for a case. Use when checking whether a governance petition has been decided before proceeding with the action.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
      ]);
      ("required", `List [`String "case_id"]);
    ];
  };
  {
    name = "masc_execution_orders";
    description = "List Governance V2 execution orders, inspect one case order, or confirm/deny a human gate.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
        ("decision", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "confirm"; `String "deny"]);
          ("description", `String "Optional human-gate decision for a high-risk execution order");
        ]);
      ]);
    ];
  };
  {
    name = "masc_governance_status";
    description = "Get Governance V2 status (pending rulings, auto-executable cases, human-gated orders, executed cases).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* masc_route *)
  {
    name = "masc_route";
    description = "Route a query to the best-fit agents using MoE-style selection, returning selected agents and estimated cost. \
Use when you have a task and need to identify which agents should handle it. \
Pair with masc_dispatch_assign to actually assign work to the selected agents.";
    input_schema = `Assoc [
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
    ];
  };

  (* masc_execute *)
  {
    name = "masc_execute";
    description = "Execute an action based on a governance decision by matching the topic pattern to a handler. \
Use when a governance ruling has been made and the resulting action needs to run (e.g., 'Merge PR #123'). \
Call masc_execute_dry_run first to preview. Pair with masc_execution_orders for the order context.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The decision topic (e.g., 'Merge PR #456')");
        ]);
        ("result", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "unanimous"; `String "majority"; `String "deadlock"]);
          ("description", `String "Voting result (default: majority)");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };

  (* masc_execute_dry_run *)
  {
    name = "masc_execute_dry_run";
    description = "Preview what action a governance execution would take without actually running it. \
Use when you want to verify the matched handler and parameters before committing to masc_execute. \
Pair with masc_execute to run the action after confirming the dry-run output.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The decision topic");
        ]);
        ("result", `Assoc [
          ("type", `String "string");
          ("description", `String "Voting result");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };

]

let handle_governance_feed ctx args =
  let filter = get_string args "filter" "decisions" |> String.lowercase_ascii in
  let limit = get_int args "limit" 20 in
  let items = ref [] in
  (* Parameter change audit trail *)
  if filter = "decisions" || filter = "all" then begin
    let audit = Runtime_params.recent_audit ~base_path:ctx.base_path limit in
    List.iter (fun entry ->
      items := `Assoc [ ("kind", `String "param_change"); ("data", entry) ] :: !items
    ) audit
  end;
  (* Active governance cases *)
  if filter = "decisions" || filter = "all" then begin
    let cases = GV2.list_cases ctx.base_path in
    let active = List.filter (fun (c : GV2.case_record) ->
      match c.status with GV2.Closed -> false | _ -> true) cases in
    List.iter (fun c ->
      items := `Assoc [ ("kind", `String "case"); ("data", case_json c) ] :: !items
    ) active
  end;
  (* Human board posts *)
  if filter = "human_only" || filter = "all" then begin
    let posts = Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent ~limit () in
    let human = List.filter (fun (p : Board.post) ->
      p.post_kind = Board.Human_post) posts in
    List.iter (fun p ->
      items := `Assoc [
        ("kind", `String "human_post");
        ("data", Board.post_to_yojson p);
      ] :: !items
    ) human
  end;
  (* Reverse to restore source order (cons reverses each batch) then take *)
  let all = List.rev !items in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: rest -> x :: take (n - 1) rest
  in
  let result = take limit all in
  (true, Yojson.Safe.pretty_to_string (`List result))

let handle_runtime_params _ctx _args =
  let params = Runtime_params.registry () in
  let items =
    List.map
      (fun (key, current, default, has_override) ->
        `Assoc
          [
            ("key", `String key);
            ("current", current);
            ("default", default);
            ("has_override", `Bool has_override);
          ])
      params
  in
  let surfaces = Governance_registry.surfaces_json () in
  let json =
    `Assoc
      [
        ("parameters", `List items);
        ("surfaces", surfaces);
      ]
  in
  (true, Yojson.Safe.pretty_to_string json)

let handle_set_param ctx args =
  let param_key = get_string args "param_key" "" |> String.trim in
  let value_json =
    match Yojson.Safe.Util.member "value" args with
    | `Null -> None
    | v -> Some v
  in
  let reason = get_string args "reason" "" in
  if param_key = "" then (false, "param_key is required")
  else
    match value_json with
    | None -> (false, "value is required")
    | Some value ->
        let risk =
          Governance_registry.surfaces
          |> List.find_opt (fun (s : Governance_registry.surface) ->
               List.mem param_key s.param_keys)
          |> Option.map (fun (s : Governance_registry.surface) -> s.risk)
          |> Option.value ~default:"low"
        in
        if risk = "high" then
          let title =
            Printf.sprintf "Set %s = %s%s" param_key
              (Yojson.Safe.to_string value)
              (if reason <> "" then " (" ^ reason ^ ")" else "")
          in
          let petition_args =
            `Assoc
              [
                ("title", `String title);
                ("origin", `String "agent");
                ("subject_type", `String "param_change");
                ("risk_class", `String "high");
                ( "requested_action",
                  `Assoc
                    [
                      ("action_type", `String "set_param");
                      ( "payload",
                        `Assoc
                          [
                            ("param_key", `String param_key);
                            ("value", value);
                          ] );
                    ] );
                ("source_refs", `List [ `String param_key ]);
              ]
          in
          let (ok, msg) = handle_petition_submit ctx petition_args in
          if ok then
            (true, Printf.sprintf "High-risk parameter. Governance petition created.\n%s" msg)
          else
            (false, Printf.sprintf "Failed to create governance petition: %s" msg)
        else begin
          let old_value =
            match Runtime_params.registry ()
                  |> List.find_opt (fun (k, _, _, _) -> k = param_key) with
            | Some (_, current, _, _) -> current
            | None -> `Null
          in
          match Runtime_params.set_by_key param_key value with
          | Error msg -> (false, Printf.sprintf "set_param failed: %s" msg)
          | Ok () ->
              Runtime_params.persist ~base_path:ctx.base_path;
              Runtime_params.record_audit ~base_path:ctx.base_path
                ~key:param_key ~old_value ~new_value:value
                ~actor:ctx.agent_name ();
              Sse.broadcast
                (`Assoc
                   [
                     ("type", `String "governance_param_changed");
                     ("param_key", `String param_key);
                     ("old_value", old_value);
                     ("new_value", value);
                     ("actor", `String ctx.agent_name);
                   ]);
              (true,
               Printf.sprintf "Set %s = %s (low-risk, applied immediately)"
                 param_key (Yojson.Safe.to_string value))
        end

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_petition_submit" -> Some (handle_petition_submit ctx args)
  | "masc_case_brief_submit" -> Some (handle_case_brief_submit ctx args)
  | "masc_cases" -> Some (handle_cases ctx args)
  | "masc_case_status" -> Some (handle_case_status ctx args)
  | "masc_ruling_status" -> Some (handle_ruling_status ctx args)
  | "masc_execution_orders" -> Some (handle_execution_orders ctx args)
  | "masc_governance_status" -> Some (handle_governance_status ctx args)
  | "masc_governance_feed" -> Some (handle_governance_feed ctx args)
  | "masc_runtime_params" -> Some (handle_runtime_params ctx args)
  | "masc_set_param" -> Some (handle_set_param ctx args)
  | "masc_route" -> Some (handle_route ctx args)
  | "masc_execute" -> Some (handle_execute ctx args)
  | "masc_execute_dry_run" -> Some (handle_execute_dry_run ctx args)
  | _ -> None

let definitions = Tool_council_schemas.definitions
