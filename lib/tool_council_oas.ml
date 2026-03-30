(** Tool_council_oas — governance handlers using the OAS-aligned tool surface.

    Governance persistence and lifecycle live in [Council.Governance_v2].
    This module keeps the OAS-facing tool endpoints but does not create
    decorative [Collaboration.t] records for petitions.

    @since Phase 1 — MASC->OAS migration *)

module Oas = Agent_sdk
module GV2 = Council.Governance_v2

open Yojson.Safe.Util
open Tool_args

(* ================================================================ *)
(* Types                                                             *)
(* ================================================================ *)

type context = {
  base_path : string;
  agent_name : string;
  room_config : Room_utils.config option;
  policy : Oas.Policy.t option;
  audit : Oas.Audit.t option;
}

type result = bool * string

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let json_ok json = (true, Yojson.Safe.pretty_to_string json)
let json_err msg = (false, Yojson.Safe.pretty_to_string
  (`Assoc [("error", `String msg)]))

let room_config_of_ctx (ctx : context) =
  match ctx.room_config with
  | Some config -> config
  | None -> Room.default_config ctx.base_path |> Room.config_with_resolved_scope

let ensure_room_ready (ctx : context) =
  let config = room_config_of_ctx ctx in
  (if not (Room.is_initialized config) then
    let (_init_msg : string) = Room.init config ~agent_name:(Some ctx.agent_name) in
    ());
  config

let petition_phase_compat (_status : GV2.case_status) = "active"

let petition_collaboration_id_compat (case_id : string) = case_id

(* ================================================================ *)
(* Petition — persist directly via GV2                               *)
(* ================================================================ *)

let handle_petition_submit ctx args =
  let title = get_string args "title" "" in
  let subject =
    let by_schema = get_string args "subject_type" "" in
    if by_schema <> "" then by_schema else get_string args "subject" ""
  in
  let risk = get_string args "risk_class" "low" in
  let _config = ensure_room_ready ctx in
  if title = "" then json_err "title is required"
  else begin
    match GV2.risk_class_of_string risk with
    | Error msg -> json_err msg
    | Ok risk_class ->
      match GV2.submit_petition ctx.base_path
        ~title ~origin:ctx.agent_name
        ~subject_type:subject
        ~risk_class
        ~requested_action:None
        ~source_refs:[]
        ~created_by:ctx.agent_name
      with
      | Error msg -> json_err msg
      | Ok submit_result ->
        let status = submit_result.case_.status in
        json_ok (`Assoc [
          ("case_id", `String submit_result.case_.id);
          (* Legacy response shape stays populated during the compatibility
             window, but the values are derived from Governance_v2 only. *)
          ( "collaboration_id",
            `String
              (petition_collaboration_id_compat submit_result.case_.id) );
          ("status", `String (GV2.case_status_to_string status));
          ("phase", `String (petition_phase_compat status));
          ("merged", `Bool submit_result.merged);
        ])
  end

(* ================================================================ *)
(* Brief — submit evidence to a case                                 *)
(* ================================================================ *)

let handle_case_brief_submit ctx args =
  let case_id = get_string args "case_id" "" in
  let stance = get_string args "stance" "neutral" in
  let summary = get_string args "summary" "" in
  let evidence_refs =
    match member "evidence_refs" args with
    | `List items ->
        items
        |> List.filter_map (function
             | `String value when String.trim value <> "" -> Some value
             | _ -> None)
    | `String value when String.trim value <> "" -> [ value ]
    | _ -> []
  in
  if case_id = "" then json_err "case_id is required"
  else begin
    match GV2.brief_stance_of_string stance with
    | Error msg -> json_err msg
    | Ok stance_val ->
      let brief_result = GV2.submit_brief ctx.base_path
        ~case_id ~author:ctx.agent_name
        ~stance:stance_val
        ~summary
        ~evidence_refs
      in
      match brief_result with
      | Error msg -> json_err msg
      | Ok _updated_case ->
        json_ok (`Assoc [
          ("case_id", `String case_id);
          ("stance", `String stance);
          ("submitted", `Bool true);
        ])
  end

(* ================================================================ *)
(* Query handlers — thin wrappers over GV2                           *)
(* ================================================================ *)

let handle_cases ctx args =
  let status_filter = match member "status" args with
    | `String s -> (
        match GV2.case_status_of_string s with
        | Ok v -> Some v
        | Error _ -> None)
    | _ -> None in
  let cases = GV2.list_cases ?status_filter ctx.base_path in
  json_ok (`List (List.map (fun (c : GV2.case_record) ->
    `Assoc [
      ("case_id", `String c.id);
      ("title", `String c.title);
      ("status", `String (GV2.case_status_to_string c.status));
    ]) cases))

let handle_case_status ctx args =
  let case_id = get_string args "case_id" "" in
  match GV2.get_case_bundle ctx.base_path case_id with
  | Error msg -> json_err msg
  | Ok bundle ->
    let ruling_json = match bundle.ruling with
      | None -> `Null
      | Some r -> GV2.ruling_to_yojson r
    in
    let order_json = match bundle.execution_order with
      | None -> `Null
      | Some o -> GV2.execution_order_to_yojson o
    in
    json_ok (`Assoc [
      ("case", GV2.case_to_yojson bundle.case_);
      ("petitions", `List (List.map GV2.petition_to_yojson bundle.petitions));
      ("ruling", ruling_json);
      ("execution_order", order_json);
    ])

let handle_ruling_status ctx args =
  let case_id = get_string args "case_id" "" in
  match GV2.get_case_bundle ctx.base_path case_id with
  | Error msg -> json_err msg
  | Ok bundle ->
    match bundle.ruling with
    | None -> json_ok (`Assoc [("ruling", `Null); ("case_id", `String case_id)])
    | Some ruling -> json_ok (GV2.ruling_to_yojson ruling)

(* ================================================================ *)
(* Execution orders                                                  *)
(* ================================================================ *)

let handle_execution_orders ctx args =
  let status_filter = match member "status" args with
    | `String s -> (
        match GV2.order_status_of_string s with
        | Ok v -> Some v
        | Error _ -> None)
    | _ -> None in
  let orders = GV2.list_execution_orders ?status_filter ctx.base_path in
  json_ok (`List (List.map (fun (o : GV2.execution_order) ->
    `Assoc [
      ("case_id", `String o.case_id);
      ("status", `String (GV2.order_status_to_string o.status));
      ("has_action", `Bool (Option.is_some o.action_request));
    ]) orders))

(* ================================================================ *)
(* Governance status — aggregate overview                            *)
(* ================================================================ *)

let handle_governance_status ctx _args =
  let cases = GV2.list_cases ctx.base_path in
  let orders = GV2.list_execution_orders ctx.base_path in
  let open_cases = List.filter (fun (c : GV2.case_record) ->
    not (GV2.is_terminal_case_status c.status)) cases in
  json_ok (`Assoc [
    ("total_cases", `Int (List.length cases));
    ("open_cases", `Int (List.length open_cases));
    ("cases_open", `Int (List.length open_cases));
    ("execution_orders", `Int (List.length orders));
    ("runtime", `String "oas");
  ])

(* ================================================================ *)
(* Governance feed — recent activity                                 *)
(* ================================================================ *)

let handle_governance_feed ctx args =
  let limit = int_of_float (get_float args "limit" 10.0) in
  let cases = GV2.list_cases ctx.base_path in
  let recent = List.filteri (fun i _ -> i < limit) cases in
  json_ok (`List (List.map (fun (c : GV2.case_record) ->
    `Assoc [
      ("case_id", `String c.id);
      ("title", `String c.title);
      ("status", `String (GV2.case_status_to_string c.status));
      ("created_at", `Float c.created_at);
    ]) recent))

(* ================================================================ *)
(* Runtime params                                                    *)
(* ================================================================ *)

let handle_runtime_params _ctx _args =
  json_ok (`Assoc [
    ("governance_version", `String "v2");
    ("runtime", `String "oas");
    ("collaboration_enabled", `Bool true);
  ])

let handle_set_param ctx args =
  let key = get_string args "key" "" in
  let value = get_string args "value" "" in
  if key = "" then json_err "key is required"
  else begin
    let _config = ensure_room_ready ctx in
    json_ok (`Assoc [
      ("set", `Bool true);
      ("key", `String key);
      ("value", `String value);
    ])
  end

(* ================================================================ *)
(* Chain route/execute — delegate to Council.Router/Executor         *)
(* ================================================================ *)

let handle_route _ctx args =
  let query =
    let by_schema = get_string args "query" "" in
    if by_schema <> "" then by_schema else get_string args "input" ""
  in
  let decision = Council.Router.route query in
  json_ok (`Assoc [
    ("reason", `String decision.reason);
    ("estimated_cost", `Float decision.estimated_cost);
    ("complexity_score", `Float decision.complexity_score);
    ("agents", `List (List.map (fun (a : Council.Router.agent_spec) ->
      `Assoc [
        ("name", `String a.name);
        ("model", `String a.model);
        ("tier", `String (Council.Router.show_model_tier a.tier));
      ]) decision.agents));
  ])

let voting_result_of_args args =
  let raw =
    get_string args "result" "majority" |> String.trim |> String.lowercase_ascii
  in
  match raw with
  | "" | "majority" -> Ok (Council.Consensus.Majority 3)
  | "unanimous" ->
      Ok (Council.Consensus.Unanimous Council.Consensus.Approve)
  | "deadlock" -> Ok Council.Consensus.Deadlock
  | "escalate" -> Ok Council.Consensus.Escalate
  | value ->
      Error
        (Printf.sprintf
           "invalid result %S (expected unanimous, majority, deadlock, or escalate)"
           value)

let handle_execute _ctx args =
  let topic = get_string args "topic" "" in
  if topic = "" then json_err "topic is required"
  else
    match voting_result_of_args args with
    | Error msg -> json_err msg
    | Ok result ->
        let preview = Council.ExecutorApi.dry_run ~topic ~result in
        let outcome = Council.ExecutorApi.execute ~topic ~result in
        let matched = Option.is_some outcome in
        let executed =
          match outcome with
          | Some exec -> exec.success
          | None -> false
        in
        let output =
          match outcome with
          | Some exec when String.trim exec.output <> "" -> exec.output
          | _ -> preview
        in
        let stdout =
          match outcome with
          | Some exec when String.trim exec.stdout <> "" -> `String exec.stdout
          | _ -> `Null
        in
        let stderr =
          match outcome with
          | Some exec when String.trim exec.stderr <> "" -> `String exec.stderr
          | _ -> `Null
        in
        json_ok
          (`Assoc
            [
              ("topic", `String topic);
              ("matched", `Bool matched);
              ("executed", `Bool executed);
              ("preview", `String preview);
              ("output", `String output);
              ("stdout", stdout);
              ("stderr", stderr);
              ("runtime", `String "executor");
            ])

let handle_execute_dry_run _ctx args =
  let topic = get_string args "topic" "" in
  if topic = "" then json_err "topic is required"
  else
    match voting_result_of_args args with
    | Error msg -> json_err msg
    | Ok result ->
        let analysis = Council.ExecutorApi.dry_run ~topic ~result in
        json_ok
          (`Assoc
            [
              ("topic", `String topic);
              ("analysis", `String analysis);
              ("dry_run", `Bool true);
              ("runtime", `String "executor");
            ])

(* ================================================================ *)
(* Schemas — reuse from legacy Tool_council                          *)
(* ================================================================ *)

let schemas : Types.tool_schema list = Tool_council_internal_schemas.schemas

(* ================================================================ *)
(* Dispatch                                                          *)
(* ================================================================ *)

let audit_record (ctx : context) ~action ~detail ?verdict () =
  match ctx.audit with
  | None -> ()
  | Some audit ->
    Oas.Audit.record audit {
      id = Printf.sprintf "gov-%d" (int_of_float (Unix.gettimeofday () *. 1000.0));
      timestamp = Unix.gettimeofday ();
      agent_name = ctx.agent_name;
      action;
      decision_point = None;
      verdict;
      detail;
    }

let check_policy (ctx : context) ~tool_name : Oas.Policy.verdict =
  match ctx.policy with
  | None -> Oas.Policy.Allow
  | Some policy ->
    Oas.Policy.evaluate policy
      (Oas.Policy.BeforeToolCall { tool_name; agent_name = ctx.agent_name })

let dispatch (ctx : context) ~name ~args : result option =
  let handler = match name with
    | "masc_case_brief_submit" -> Some handle_case_brief_submit
    | "masc_cases" -> Some handle_cases
    | "masc_case_status" -> Some handle_case_status
    | "masc_route" -> Some handle_route
    | "masc_execute" -> Some handle_execute
    | "masc_execute_dry_run" -> Some handle_execute_dry_run
    | "masc_petition_submit" -> Some handle_petition_submit
    | "masc_governance_status" -> Some handle_governance_status
    | "masc_governance_feed" -> Some handle_governance_feed
    | "masc_ruling_status" -> Some handle_ruling_status
    | "masc_execution_orders" -> Some handle_execution_orders
    | "masc_runtime_params" -> Some handle_runtime_params
    | "masc_set_param" -> Some handle_set_param
    | _ -> None
  in
  match handler with
  | None -> None
  | Some h ->
    let verdict = check_policy ctx ~tool_name:name in
    match verdict with
    | Oas.Policy.Deny reason ->
      audit_record ctx ~action:name
        ~detail:(`Assoc [("denied", `String reason)])
        ~verdict () ;
      Some (false, Printf.sprintf "Policy denied: %s" reason)
    | _ ->
      let result = h ctx args in
      audit_record ctx ~action:name
        ~detail:(`Assoc [("result_ok", `Bool (fst result))])
        ~verdict () ;
      Some result
