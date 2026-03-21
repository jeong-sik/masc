(** Council tools - Governance V2 petition/case/ruling surface.

    Feed/params handlers: {!Tool_council_feed}
    Schemas (MCP protocol): {!Tool_council_schemas}

    @since 0.3.0 *)

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
                    (match GV2.save_ruling ctx.base_path ruling with
                     | Ok _ -> ()
                     | Error msg -> Log.Misc.warn "save_ruling failed for case %s: %s" ruling.case_id msg);
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
                (match GV2.save_ruling ctx.base_path ruling with
                 | Ok _ -> ()
                 | Error msg -> Log.Misc.warn "save_ruling failed for case %s: %s" ruling.case_id msg);
                let order =
                  match build_execution_order bundle ruling with
                  | None -> None
                  | Some initial_order -> (
                      (match GV2.save_execution_order ctx.base_path initial_order with
                       | Ok _ -> ()
                       | Error msg -> Log.Misc.warn "save_execution_order failed for case %s: %s" initial_order.GV2.case_id msg);
                      match initial_order.GV2.status with
                      | GV2.Queued_auto -> (
                          match execute_action ctx bundle.GV2.case_ initial_order with
                          | Ok executed_order ->
                              (match GV2.update_execution_order ctx.base_path executed_order with
                               | Ok _ -> ()
                               | Error msg -> Log.Misc.warn "update_execution_order failed for case %s: %s" executed_order.GV2.case_id msg);
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
                              (match GV2.update_execution_order ctx.base_path blocked_order with
                               | Ok _ -> ()
                               | Error msg -> Log.Misc.warn "update_execution_order failed for blocked case %s: %s" blocked_order.GV2.case_id msg);
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

(** Delegated handlers from {!Tool_council_feed}. *)
let handle_governance_feed = Tool_council_feed.handle_governance_feed
let handle_runtime_params = Tool_council_feed.handle_runtime_params

let handle_set_param ctx args =
  Tool_council_feed.handle_set_param ~submit_petition:handle_petition_submit ctx args

(** Internal schemas for MCP dispatch (Types.tool_schema format). *)
let schemas = Tool_council_internal_schemas.schemas

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
