(* Dashboard_safe_autonomy_types — type definitions, re-exports, utilities,
   stats processing, benchmark helpers, transport health, and domain helpers.
   Extracted from dashboard_safe_autonomy.ml during godfile decomposition. *)

open Keeper_types

type domain_level = Dashboard_safe_autonomy_level.domain_level =
  | Pass
  | Warn
  | Fail

type evidence_ref = {
  kind : string;
  label : string;
  value : string;
}

type finding = {
  reason_code : string;
  domain_id : string;
  severity : domain_level;
  keeper_name : string option;
  summary : string;
  human_action_required : bool;
  suggested_next_action : string;
  evidence_refs : evidence_ref list;
}

type keeper_domain = {
  id : string;
  label : string;
  weight : int;
  status : domain_level;
  score : float;
  summary : string;
  evidence_refs : evidence_ref list;
}

type live_tool_stats = {
  calls : int;
  success_pct : float;
}

type approval_stats = {
  count : int;
  oldest_wait_sec : float option;
  entries : Yojson.Safe.t list;
}

type activity_stats = {
  count : int;
  last_ts : float option;
}

type artifact_state = {
  latest_path : string;
  history_path : string;
  fingerprint : string;
  history_appended : bool;
}

type keeper_snapshot = {
  meta : keeper_meta;
  sandbox : Keeper_sandbox.t;
  repo_readiness : Yojson.Safe.t;
  bench_recommendation : Keeper_benchmark_canary.recommendation option;
  live_tool_stats : live_tool_stats option;
  approval : approval_stats;
  activity : activity_stats;
  tool_domain : keeper_domain;
  sandbox_domain : keeper_domain;
  approval_domain : keeper_domain;
  cascade_domain : keeper_domain;
  audit_domain : keeper_domain;
  findings : finding list;
}

let tool_domain_id = Dashboard_safe_autonomy_level.tool_domain_id
let sandbox_domain_id = Dashboard_safe_autonomy_level.sandbox_domain_id
let approval_domain_id = Dashboard_safe_autonomy_level.approval_domain_id
let cascade_domain_id = Dashboard_safe_autonomy_level.cascade_domain_id
let audit_domain_id = Dashboard_safe_autonomy_level.audit_domain_id
let domain_catalog = Dashboard_safe_autonomy_level.domain_catalog
let level_to_string = Dashboard_safe_autonomy_level.level_to_string
let level_rank = Dashboard_safe_autonomy_level.level_rank
let worse_level = Dashboard_safe_autonomy_level.worse_level
let worst_level = Dashboard_safe_autonomy_level.worst_level

let non_empty_string_opt = String_util.trim_nonempty

let normalize_string_opt = function
  | Some value -> non_empty_string_opt value
  | None -> None

let float_opt_to_json = function
  | Some value -> `Float value
  | None -> `Null

let string_opt_to_json = function
  | Some value -> `String value
  | None -> `Null

let evidence_ref_json (entry : evidence_ref) =
  `Assoc
    [
      ("kind", `String entry.kind);
      ("label", `String entry.label);
      ("value", `String entry.value);
    ]

let finding_json (finding : finding) =
  `Assoc
    [
      ("reason_code", `String finding.reason_code);
      ("domain_id", `String finding.domain_id);
      ("severity", `String (level_to_string finding.severity));
      ("keeper_name", string_opt_to_json finding.keeper_name);
      ("summary", `String finding.summary);
      ("human_action_required", `Bool finding.human_action_required);
      ("suggested_next_action", `String finding.suggested_next_action);
      ( "evidence_refs",
        `List (List.map evidence_ref_json finding.evidence_refs) );
    ]

let keeper_domain_json (domain : keeper_domain) =
  `Assoc
    [
      ("id", `String domain.id);
      ("label", `String domain.label);
      ("weight", `Int domain.weight);
      ("status", `String (level_to_string domain.status));
      ("score", `Float domain.score);
      ("summary", `String domain.summary);
      ("evidence_refs", `List (List.map evidence_ref_json domain.evidence_refs));
    ]

let base_evidence_ref kind label value = { kind; label; value }

let approval_stats_of_pending_json pending_json : (string, approval_stats) Hashtbl.t =
  let table = Hashtbl.create 8 in
  let add_entry keeper_name entry =
    let current =
      match Hashtbl.find_opt table keeper_name with
      | Some value -> value
      | None -> { count = 0; oldest_wait_sec = None; entries = [] }
    in
    let waiting_s = Safe_ops.json_float_opt "waiting_s" entry in
    let oldest_wait_sec =
      match current.oldest_wait_sec, waiting_s with
      | Some left, Some right -> Some (Float.max left right)
      | Some _ as left, None -> left
      | None, other -> other
    in
    Hashtbl.replace table keeper_name
      {
        count = current.count + 1;
        oldest_wait_sec;
        entries = entry :: current.entries;
      }
  in
  (match pending_json with
   | `List items ->
       List.iter
         (fun item ->
           let keeper_name =
             Safe_ops.json_string ~default:"" "keeper_name" item |> String.trim
           in
           if keeper_name <> "" then add_entry keeper_name item)
         items
   | `Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> ());
  table

let activity_stats_by_keeper
    (keepers : keeper_meta list) (items : Activity_feed.activity_item list) =
  let alias_to_keeper = Hashtbl.create (List.length keepers * 2 + 1) in
  let stats = Hashtbl.create (List.length keepers + 1) in
  let register_alias alias keeper_name =
    let alias = String.trim alias in
    if alias <> "" then Hashtbl.replace alias_to_keeper alias keeper_name
  in
  List.iter
    (fun meta ->
      register_alias meta.name meta.name;
      register_alias meta.agent_name meta.name;
      Hashtbl.replace stats meta.name { count = 0; last_ts = None })
    keepers;
  List.iter
    (fun (item : Activity_feed.activity_item) ->
      let actor = String.trim item.agent_name in
      match Hashtbl.find_opt alias_to_keeper actor with
      | None -> ()
      | Some keeper_name ->
          let current =
            match Hashtbl.find_opt stats keeper_name with
            | Some value -> value
            | None -> { count = 0; last_ts = None }
          in
          let last_ts =
            match current.last_ts with
            | Some value -> Some (Float.max value item.created_at)
            | None -> Some item.created_at
          in
          Hashtbl.replace stats keeper_name
            { count = current.count + 1; last_ts })
    items;
  stats, alias_to_keeper

let bench_recommendation_path () =
  match Env_config_core.raw_value_opt "MASC_KEEPER_BENCH_CANARY_PATH" with
  | Some path ->
      let trimmed = String.trim path in
      if trimmed <> "" then trimmed else Keeper_benchmark_canary.default_manifest_path ()
  | None -> Keeper_benchmark_canary.default_manifest_path ()

let candidate_keeper_profiles keeper_name =
  let trimmed = String.trim keeper_name in
  if trimmed = "" then []
  else if String.starts_with ~prefix:"bench-" trimmed then
    let bare =
      String.sub trimmed 6 (String.length trimmed - 6)
    in
    Keeper_types.dedupe_keep_order [ trimmed; bare ]
  else
    Keeper_types.dedupe_keep_order [ trimmed; "bench-" ^ trimmed ]

let recommendation_for_keeper
    (manifest : Keeper_benchmark_canary.manifest option) ~keeper_name =
  match manifest with
  | None -> None
  | Some manifest ->
      let candidates = candidate_keeper_profiles keeper_name in
      List.find_map
        (fun keeper_profile ->
          List.find_opt
            (fun (recommendation : Keeper_benchmark_canary.recommendation) ->
              String.equal recommendation.keeper_profile keeper_profile)
            manifest.recommendations)
        candidates

let live_tool_stats_by_keeper () =
  let table = Hashtbl.create 8 in
  let payload = Dashboard_http_tool_quality.aggregate () in
  let items =
    match Yojson.Safe.Util.member "by_keeper" payload with
    | `List rows -> rows
    | _ -> []
  in
  List.iter
    (fun row ->
      let name = Safe_ops.json_string ~default:"" "name" row |> String.trim in
      if name <> "" then
        Hashtbl.replace table name
          {
            calls = Safe_ops.json_int ~default:0 "calls" row;
            success_pct = Safe_ops.json_float ~default:0.0 "success_pct" row;
          })
    items;
  table, payload

let transport_health_status transport_json =
  let queue_pressure =
    transport_json
    |> Yojson.Safe.Util.member "summary"
    |> Safe_ops.json_string ~default:"unknown" "queue_pressure"
  in
  let grpc_json = Yojson.Safe.Util.member "grpc" transport_json in
  let ws_json = Yojson.Safe.Util.member "websocket" transport_json in
  let grpc_enabled = Safe_ops.json_bool ~default:false "enabled" grpc_json in
  let grpc_reachable = Safe_ops.json_bool ~default:false "reachable" grpc_json in
  let ws_enabled = Safe_ops.json_bool ~default:false "enabled" ws_json in
  let ws_reachable = Safe_ops.json_bool ~default:false "reachable" ws_json in
  if (grpc_enabled && not grpc_reachable) || (ws_enabled && not ws_reachable) then
    ( Fail,
      "configured transport is unreachable",
      Some "transport_unhealthy" )
  else if String.equal queue_pressure "high" then
    (Warn, "transport queue pressure is high", Some "transport_unhealthy")
  else if String.equal queue_pressure "watch" then
    (Warn, "transport queue pressure is elevated", None)
  else
    (Pass, "transport paths are healthy", None)

let domain_definition id =
  match List.find_opt (fun (candidate, _, _) -> String.equal candidate id) domain_catalog with
  | Some (_, label, weight) -> (label, weight)
  | None -> (id, 0)

let make_domain ~id ~status ~score ~summary ~evidence_refs =
  let label, weight = domain_definition id in
  { id; label; weight; status; score; summary; evidence_refs }

let make_finding
    ~reason_code
    ~domain_id
    ~severity
    ?keeper_name
    ~summary
    ~human_action_required
    ~suggested_next_action
    ~evidence_refs
    () =
  {
    reason_code;
    domain_id;
    severity;
    keeper_name;
    summary;
    human_action_required;
    suggested_next_action;
    evidence_refs;
  }
