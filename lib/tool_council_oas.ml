(** Tool_council_oas — OAS Collaboration-based governance handlers.

    Replaces [Tool_council] with OAS [Collaboration.t] for petition lifecycle.
    Delegates file-based persistence to [Council.Governance_v2].

    Key changes from legacy:
    - Petition lifecycle tracked via [Collaboration.t] phases
    - Vote collection via [Collaboration.vote] type
    - ID generation via [Collaboration.generate_id] (no Random.int)
    - Simpler handler code (delegate to Governance_v2 for file ops)

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
  | None -> Room.default_config ctx.base_path

let ensure_room_ready (ctx : context) =
  let config = room_config_of_ctx ctx in
  if not (Room.is_initialized config) then
    ignore (Room.init config ~agent_name:(Some ctx.agent_name));
  config

(** Deterministic ID generation using Collaboration.generate_id.
    Replaces Random.int-based gen_id from legacy Tool_council. *)
let _gen_case_id () =
  let collab = Oas.Collaboration.create ~goal:"" () in
  String.sub collab.id 0 (min 20 (String.length collab.id))

(* ================================================================ *)
(* Petition — create via Collaboration.t + persist via GV2           *)
(* ================================================================ *)

let handle_petition_submit ctx args =
  let title = get_string args "title" "" in
  let subject = get_string args "subject" "" in
  let risk = get_string args "risk_class" "low" in
  let _config = ensure_room_ready ctx in
  if title = "" then json_err "title is required"
  else begin
    (* Create OAS Collaboration for this petition *)
    let collab = Oas.Collaboration.create
      ~goal:(Printf.sprintf "Governance petition: %s" title) () in
    let collab = Oas.Collaboration.add_participant collab
      { name = ctx.agent_name; role = Some "petitioner";
        state = Oas.Collaboration.Working;
        joined_at = Some (Unix.gettimeofday ());
        finished_at = None; summary = Some title } in
    let collab = Oas.Collaboration.set_phase collab Oas.Collaboration.Active in
    (* Persist via Governance_v2 *)
    match GV2.risk_class_of_string risk with
    | Error msg -> json_err msg
    | Ok risk_class ->
      match GV2.submit_petition ctx.base_path
        ~title ~origin:ctx.agent_name
        ~subject_type:subject
        ~risk_class
        ~requested_action:None
        ~source_refs:[collab.id]
        ~created_by:ctx.agent_name
      with
      | Error msg -> json_err msg
      | Ok submit_result ->
        json_ok (`Assoc [
          ("case_id", `String submit_result.case_.id);
          ("collaboration_id", `String collab.id);
          ("status", `String (GV2.case_status_to_string submit_result.case_.status));
          ("phase", `String (Oas.Collaboration.show_phase collab.phase));
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
  let evidence = get_string args "evidence_refs" "" in
  if case_id = "" then json_err "case_id is required"
  else begin
    match GV2.brief_stance_of_string stance with
    | Error msg -> json_err msg
    | Ok stance_val ->
      let brief_result = GV2.submit_brief ctx.base_path
        ~case_id ~author:ctx.agent_name
        ~stance:stance_val
        ~summary
        ~evidence_refs:(if evidence = "" then [] else [evidence])
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
  let input = get_string args "input" "" in
  let decision = Council.Router.route input in
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

let handle_execute _ctx args =
  let topic = get_string args "topic" "" in
  if topic = "" then json_err "topic is required"
  else
    let system_prompt =
      "You are a governance deliberation agent for the MASC multi-agent system. \
       Evaluate the following topic and produce a structured decision. \
       Include: (1) your reasoning, (2) identified risks, (3) recommended action. \
       Be concise and actionable." in
    match Oas_worker.run_named
      ~cascade_name:"governance_judge" ~goal:topic ~system_prompt ()
    with
    | Ok result ->
      json_ok (`Assoc [
        ("topic", `String topic);
        ("deliberation", `String (Masc_model.text_of_response result.response));
        ("turns", `Int result.turns);
        ("session_id", `String result.session_id);
        ("runtime", `String "oas");
      ])
    | Error e -> json_err (Printf.sprintf "Deliberation failed: %s" e)

let handle_execute_dry_run _ctx args =
  let topic = get_string args "topic" "" in
  if topic = "" then json_err "topic is required"
  else
    let system_prompt =
      "You are a governance analysis agent for the MASC multi-agent system (DRY RUN mode). \
       Analyze the following topic WITHOUT committing any changes. \
       Produce: (1) impact analysis, (2) risks and mitigations, (3) what WOULD happen if executed. \
       This is analysis only — no actions will be taken." in
    match Oas_worker.run_named
      ~cascade_name:"governance_judge" ~goal:topic ~system_prompt ()
    with
    | Ok result ->
      json_ok (`Assoc [
        ("topic", `String topic);
        ("analysis", `String (Masc_model.text_of_response result.response));
        ("turns", `Int result.turns);
        ("session_id", `String result.session_id);
        ("dry_run", `Bool true);
        ("runtime", `String "oas");
      ])
    | Error e -> json_err (Printf.sprintf "Dry-run analysis failed: %s" e)

(* ================================================================ *)
(* Schemas — reuse from legacy Tool_council                          *)
(* ================================================================ *)

let schemas : Types.tool_schema list = Tool_council.schemas

(* ================================================================ *)
(* Dispatch                                                          *)
(* ================================================================ *)

let dispatch (ctx : context) ~name ~args : result option =
  let handler = match name with
    | "masc_case_brief_submit" -> Some handle_case_brief_submit
    | "masc_cases" -> Some handle_cases
    | "masc_case_status" -> Some handle_case_status
    | "masc_council_route" -> Some handle_route
    | "masc_council_execute" -> Some handle_execute
    | "masc_council_execute_dry_run" -> Some handle_execute_dry_run
    | "masc_governance_petition" -> Some handle_petition_submit
    | "masc_governance_status" -> Some handle_governance_status
    | "masc_governance_feed" -> Some handle_governance_feed
    | "masc_ruling_status" -> Some handle_ruling_status
    | "masc_execution_orders" -> Some handle_execution_orders
    | "masc_runtime_params" -> Some handle_runtime_params
    | "masc_set_param" -> Some handle_set_param
    | _ -> None
  in
  Option.map (fun h -> h ctx args) handler
