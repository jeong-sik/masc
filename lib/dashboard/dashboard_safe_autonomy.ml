open Keeper_types

type domain_level =
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

let tool_domain_id = "tool_correctness"
let sandbox_domain_id = "sandbox_truth"
let approval_domain_id = "approval_truth"
let cascade_domain_id = "cascade_fsm_gracefulness"
let audit_domain_id = "audit_trail_completeness"

let domain_catalog =
  [
    (tool_domain_id, "Tool Correctness", 30);
    (sandbox_domain_id, "Sandbox Truth", 20);
    (approval_domain_id, "Approval Truth", 20);
    (cascade_domain_id, "Cascade & FSM Gracefulness", 20);
    (audit_domain_id, "Audit Trail Completeness", 10);
  ]

let level_to_string = function
  | Pass -> "pass"
  | Warn -> "warn"
  | Fail -> "fail"

let level_rank = function
  | Pass -> 0
  | Warn -> 1
  | Fail -> 2

let worse_level left right =
  if level_rank left >= level_rank right then left else right

let worst_level levels =
  match levels with
  | [] -> Warn
  | hd :: tl -> List.fold_left worse_level hd tl

let non_empty_string_opt value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

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

let classify_tool_correctness
    ~(manifest_path : string)
    ~(recommendation : Keeper_benchmark_canary.recommendation option)
    ~(live_stats : live_tool_stats option)
    ~(keeper_name : string) =
  let evidence_refs =
    [
      base_evidence_ref "file" "bench_manifest" manifest_path;
      base_evidence_ref "route" "tool_quality" "/api/v1/dashboard/tool-quality";
    ]
  in
  match recommendation, live_stats with
  | Some recommendation, Some stats when stats.calls >= 3 && stats.success_pct < 80.0 ->
      let summary =
        Printf.sprintf
          "benchmark recommends %s but live tool success is %.1f%% across %d calls"
          recommendation.model_label stats.success_pct stats.calls
      in
      ( make_domain ~id:tool_domain_id ~status:Fail ~score:stats.success_pct
          ~summary ~evidence_refs,
        [
          make_finding
            ~reason_code:"tool_misuse"
            ~domain_id:tool_domain_id
            ~severity:Fail
            ~keeper_name
            ~summary
            ~human_action_required:false
            ~suggested_next_action:
              "Inspect recent tool-call evidence and adjust keeper prompt/model selection."
            ~evidence_refs
            ();
        ] )
  | Some recommendation, _ ->
      let stability = Option.value recommendation.stability_score ~default:1.0 in
      let status =
        if stability >= 0.9 then Pass else Warn
      in
      let summary =
        Printf.sprintf
          "benchmark recommends %s (score %.1f, stability %.2f)"
          recommendation.model_label recommendation.composite_score stability
      in
      ( make_domain ~id:tool_domain_id ~status
          ~score:recommendation.composite_score
          ~summary ~evidence_refs,
        [] )
  | None, Some stats when stats.calls >= 3 && stats.success_pct < 80.0 ->
      let summary =
        Printf.sprintf
          "live tool success is %.1f%% across %d calls with no benchmark proof"
          stats.success_pct stats.calls
      in
      ( make_domain ~id:tool_domain_id ~status:Fail ~score:stats.success_pct
          ~summary ~evidence_refs,
        [
          make_finding
            ~reason_code:"tool_misuse"
            ~domain_id:tool_domain_id
            ~severity:Fail
            ~keeper_name
            ~summary
            ~human_action_required:false
            ~suggested_next_action:
              "Run the tool-call benchmark corpus for this keeper profile before trusting it for code work."
            ~evidence_refs
            ();
        ] )
  | None, Some stats ->
      let summary =
        Printf.sprintf
          "live tool telemetry shows %.1f%% success across %d calls, but no deterministic benchmark proof"
          stats.success_pct stats.calls
      in
      ( make_domain ~id:tool_domain_id ~status:Warn ~score:stats.success_pct
          ~summary ~evidence_refs,
        [] )
  | None, None ->
      ( make_domain ~id:tool_domain_id ~status:Warn ~score:50.0
          ~summary:"no benchmark manifest or live tool telemetry for this keeper"
          ~evidence_refs,
        [] )

let classify_sandbox_truth ~(config : Coord.config) ~(meta : keeper_meta)
    ~(sandbox : Keeper_sandbox.t) ~(repo_readiness : Yojson.Safe.t) =
  let host_root_exists = Fs_compat.file_exists sandbox.host_root_abs in
  let repo_state = Safe_ops.json_string ~default:"unknown" "state" repo_readiness in
  let repo_clone_path =
    Safe_ops.json_string ~default:"" "clone_path" repo_readiness
  in
  let evidence_refs =
    [
      base_evidence_ref "path" "sandbox_root" sandbox.host_root_abs;
      base_evidence_ref "path" "repo_clone" repo_clone_path;
    ]
  in
  if not host_root_exists then
    let summary =
      Printf.sprintf "sandbox root %s is missing" sandbox.host_root_abs
    in
    ( make_domain ~id:sandbox_domain_id ~status:Fail ~score:0.0
        ~summary ~evidence_refs,
      [
        make_finding
          ~reason_code:"sandbox_boundary_gap"
          ~domain_id:sandbox_domain_id
          ~severity:Fail
          ~keeper_name:meta.name
          ~summary
          ~human_action_required:false
          ~suggested_next_action:
            "Recreate the keeper sandbox bundle before allowing code or shell tools."
          ~evidence_refs
          ();
      ] )
  else
    match repo_state with
    | "ready" ->
        ( make_domain ~id:sandbox_domain_id ~status:Pass ~score:100.0
            ~summary:
              (Printf.sprintf "sandbox %s is present and repo clone is ready"
                 sandbox.sandbox_profile)
            ~evidence_refs,
          [] )
    | "auto_provisionable" ->
        ( make_domain ~id:sandbox_domain_id ~status:Warn ~score:80.0
            ~summary:
              "sandbox exists and the repo clone can be auto-provisioned on worktree creation"
            ~evidence_refs,
          [] )
    | "missing_clone" ->
        ( make_domain ~id:sandbox_domain_id ~status:Warn ~score:60.0
            ~summary:
              "sandbox exists but no repo clone is ready under the keeper playground"
            ~evidence_refs,
          [
            make_finding
              ~reason_code:"repo_not_ready"
              ~domain_id:sandbox_domain_id
              ~severity:Warn
              ~keeper_name:meta.name
              ~summary:"keeper sandbox repo clone has not been prepared yet"
              ~human_action_required:false
              ~suggested_next_action:
                "Clone the target repo into the keeper playground before autonomous code work."
              ~evidence_refs
              ();
          ] )
    | _ ->
        let summary =
          Printf.sprintf "sandbox repo readiness is %s" repo_state
        in
        ( make_domain ~id:sandbox_domain_id ~status:Fail ~score:25.0
            ~summary ~evidence_refs,
          [
            make_finding
              ~reason_code:"repo_not_ready"
              ~domain_id:sandbox_domain_id
              ~severity:Fail
              ~keeper_name:meta.name
              ~summary
              ~human_action_required:false
              ~suggested_next_action:
                "Repair the keeper sandbox clone state before allowing Git or file mutations."
              ~evidence_refs
              ();
          ] )

let classify_approval_truth ~(keeper_name : string) ~(approval : approval_stats) =
  let evidence_refs =
    [
      base_evidence_ref "route" "governance" "/api/v1/dashboard/governance";
      base_evidence_ref "tool" "approval_pending" "masc_approval_pending";
    ]
  in
  match approval.count, approval.oldest_wait_sec with
  | 0, _ ->
      ( make_domain ~id:approval_domain_id ~status:Pass ~score:100.0
          ~summary:"no pending approvals for this keeper"
          ~evidence_refs,
        [] )
  | count, Some wait_s when wait_s >= 900.0 ->
      let summary =
        Printf.sprintf
          "%d approval(s) pending; oldest has waited %.0fs"
          count wait_s
      in
      ( make_domain ~id:approval_domain_id ~status:Fail ~score:25.0
          ~summary ~evidence_refs,
        [
          make_finding
            ~reason_code:"approval_gap"
            ~domain_id:approval_domain_id
            ~severity:Fail
            ~keeper_name
            ~summary
            ~human_action_required:true
            ~suggested_next_action:
              "Review or resolve the pending approvals before continuing autonomous execution."
            ~evidence_refs
            ();
        ] )
  | count, wait_s_opt ->
      let summary =
        match wait_s_opt with
        | Some wait_s ->
            Printf.sprintf
              "%d approval(s) pending; oldest has waited %.0fs"
              count wait_s
        | None -> Printf.sprintf "%d approval(s) pending" count
      in
      ( make_domain ~id:approval_domain_id ~status:Warn ~score:60.0
          ~summary ~evidence_refs,
        [
          make_finding
            ~reason_code:"approval_pending_pause"
            ~domain_id:approval_domain_id
            ~severity:Warn
            ~keeper_name
            ~summary
            ~human_action_required:true
            ~suggested_next_action:
              "Keep the keeper paused at the human gate until the approval is resolved."
            ~evidence_refs
            ();
        ] )

let classify_cascade_fsm ~(config : Coord.config) ~(meta : keeper_meta) =
  let blocker_fields =
    Keeper_status_bridge.runtime_blocker_fields_json config meta
  in
  let blocker_json = `Assoc blocker_fields in
  let blocker_class =
    Safe_ops.json_string_opt "runtime_blocker_class" blocker_json
    |> normalize_string_opt
  in
  let blocker_summary =
    Safe_ops.json_string_opt "runtime_blocker_summary" blocker_json
    |> normalize_string_opt
  in
  let continue_gate =
    Safe_ops.json_bool ~default:false "runtime_blocker_continue_gate" blocker_json
  in
  let evidence_refs =
    [ base_evidence_ref "route" "transport_health" "/api/v1/dashboard/transport-health" ]
  in
  match blocker_class, blocker_summary with
  | None, None ->
      ( make_domain ~id:cascade_domain_id ~status:Pass ~score:100.0
          ~summary:"no current runtime blocker is recorded"
          ~evidence_refs,
        [] )
  | Some "no_tool_capable_provider", Some summary ->
      ( make_domain ~id:cascade_domain_id ~status:Warn ~score:60.0
          ~summary ~evidence_refs,
        [
          make_finding
            ~reason_code:"unsupported_model_skip"
            ~domain_id:cascade_domain_id
            ~severity:Warn
            ~keeper_name:meta.name
            ~summary
            ~human_action_required:false
            ~suggested_next_action:
              "Skip this model path or refresh the keeper's model/cascade mapping."
            ~evidence_refs
            ();
        ] )
  | Some _cls, Some summary ->
      let next_action =
        if continue_gate then
          "Keep the blocker visible and watch the next turn before escalating."
        else
          "Pause or inspect the keeper before more autonomous turns are admitted."
      in
      ( make_domain ~id:cascade_domain_id ~status:Warn ~score:55.0
          ~summary ~evidence_refs,
        [
          make_finding
            ~reason_code:"cascade_thrash"
            ~domain_id:cascade_domain_id
            ~severity:Warn
            ~keeper_name:meta.name
            ~summary
            ~human_action_required:(not continue_gate)
            ~suggested_next_action:next_action
            ~evidence_refs
            ();
        ] )
  | None, Some summary ->
      ( make_domain ~id:cascade_domain_id ~status:Fail ~score:20.0
          ~summary:"keeper has a raw blocker string without normalized blocker_class"
          ~evidence_refs,
        [
          make_finding
            ~reason_code:"cascade_thrash"
            ~domain_id:cascade_domain_id
            ~severity:Fail
            ~keeper_name:meta.name
            ~summary
            ~human_action_required:true
            ~suggested_next_action:
              "Normalize the blocker path or pause this keeper until the failure is classified."
            ~evidence_refs
            ();
        ] )
  | Some _, None ->
      ( make_domain ~id:cascade_domain_id ~status:Warn ~score:50.0
          ~summary:"keeper has a typed blocker class without a summary"
          ~evidence_refs,
        [] )

let classify_audit_trail ~(config : Coord.config) ~(meta : keeper_meta)
    ~(activity : activity_stats) =
  let trace_history_count = List.length meta.runtime.trace_history in
  let total_turns = meta.runtime.usage.total_turns in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let evidence_refs =
    [
      base_evidence_ref "path" "trace_history"
        (Keeper_types.keeper_history_path config trace_id);
      base_evidence_ref "route" "workspace_evidence" "#workspace?section=evidence";
    ]
  in
  if total_turns > 0 && trace_history_count = 0 && activity.count = 0 then
    ( make_domain ~id:audit_domain_id ~status:Fail ~score:20.0
        ~summary:"keeper has turns recorded but no visible trace history or activity trail"
        ~evidence_refs,
      [
        make_finding
          ~reason_code:"history_gap"
          ~domain_id:audit_domain_id
          ~severity:Fail
          ~keeper_name:meta.name
          ~summary:
            "turns exist without trace_history, handoff lineage, or recent activity evidence"
          ~human_action_required:false
          ~suggested_next_action:
            "Inspect trace persistence and activity projection before trusting this keeper's audit trail."
          ~evidence_refs
          ();
      ] )
  else if total_turns = 0 && trace_history_count = 0 && activity.count = 0 then
    ( make_domain ~id:audit_domain_id ~status:Warn ~score:50.0
        ~summary:"keeper has little or no runtime history yet"
        ~evidence_refs,
      [] )
  else
    ( make_domain ~id:audit_domain_id ~status:Pass ~score:100.0
        ~summary:
          (Printf.sprintf
             "audit trail visible (turns=%d, handoffs=%d, recent_activity=%d)"
             total_turns trace_history_count activity.count)
        ~evidence_refs,
      [] )

let current_task_id_json meta =
  match meta.current_task_id with
  | Some task_id -> `String (Keeper_id.Task_id.to_string task_id)
  | None -> `Null

let keeper_score domains =
  let total_weight =
    List.fold_left (fun acc (domain : keeper_domain) -> acc + domain.weight) 0 domains
  in
  if total_weight = 0 then 0.0
  else
    List.fold_left
      (fun acc (domain : keeper_domain) ->
        acc +. (domain.score *. float_of_int domain.weight))
      0.0 domains
    /. float_of_int total_weight

let keeper_status_of_domains domains =
  let statuses = List.map (fun (domain : keeper_domain) -> domain.status) domains in
  worst_level statuses

let build_keeper_snapshot
    ~(config : Coord.config)
    ~(manifest_path : string)
    ~(bench_manifest : Keeper_benchmark_canary.manifest option)
    ~(live_tool_by_keeper : (string, live_tool_stats) Hashtbl.t)
    ~(approval_by_keeper : (string, approval_stats) Hashtbl.t)
    ~(activity_by_keeper : (string, activity_stats) Hashtbl.t)
    (meta : keeper_meta) =
  let sandbox = Keeper_sandbox.of_meta ~config ~meta in
  let repo_readiness = Keeper_repo_readiness.inspect ~config ~meta () in
  let recommendation =
    recommendation_for_keeper bench_manifest ~keeper_name:meta.name
  in
  let live_tool_stats = Hashtbl.find_opt live_tool_by_keeper meta.name in
  let approval =
    match Hashtbl.find_opt approval_by_keeper meta.name with
    | Some value -> value
    | None -> { count = 0; oldest_wait_sec = None; entries = [] }
  in
  let activity =
    match Hashtbl.find_opt activity_by_keeper meta.name with
    | Some value -> value
    | None -> { count = 0; last_ts = None }
  in
  let tool_domain, tool_findings =
    classify_tool_correctness ~manifest_path ~recommendation ~live_stats:live_tool_stats
      ~keeper_name:meta.name
  in
  let sandbox_domain, sandbox_findings =
    classify_sandbox_truth ~config ~meta ~sandbox ~repo_readiness
  in
  let approval_domain, approval_findings =
    classify_approval_truth ~keeper_name:meta.name ~approval
  in
  let cascade_domain, cascade_findings =
    classify_cascade_fsm ~config ~meta
  in
  let audit_domain, audit_findings =
    classify_audit_trail ~config ~meta ~activity
  in
  {
    meta;
    sandbox;
    repo_readiness;
    bench_recommendation = recommendation;
    live_tool_stats;
    approval;
    activity;
    tool_domain;
    sandbox_domain;
    approval_domain;
    cascade_domain;
    audit_domain;
    findings =
      tool_findings @ sandbox_findings @ approval_findings
      @ cascade_findings @ audit_findings;
  }

(* The safe-autonomy screen renders one row per keeper.  This probe is
   intentionally much shorter than interactive sandbox-status calls; otherwise
   a slow Docker daemon costs [timeout * keeper_count] before the dashboard can
   return any bytes.

   Floor at 1.0s rather than 0.25s: [Process_eio] timeouts surface
   through [Log.warn]-style sites that format duration with [%.0f],
   which would render the 0.25s budget as "0s" and confuse operators
   reading "command timed out after 0s".  1.0s produces a
   self-explanatory diagnostic when Docker is genuinely slow.

   Worst-case budget bookkeeping (PR #13113 review):
   [Keeper_sandbox_runtime.list_containers] internally runs TWO
   sequential Docker commands (`docker ps` then `docker inspect`),
   each gated by [~timeout_sec].  The per-row worst case is
   therefore [2 * timeout_sec], not [timeout_sec].  At 1.0s × 2
   commands × 50 keepers the screen budget is ~100s in the
   worst case where every Docker call stalls — well above the
   typical 15s client deadline, but bounded.  In the common case
   Docker responds in tens of ms and the screen returns in <1s.
   Operators who need a tighter overall budget should either
   reduce keeper count surfaced here, or wait for the upstream
   "single overall probe budget" follow-up (RFC TBD) that would
   short-circuit further probes once a wall-clock deadline is hit.
*)
let sandbox_live_probe_timeout_sec = 1.0

let keeper_snapshot_json ~(config : Coord.config) (snapshot : keeper_snapshot) =
  let meta = snapshot.meta in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let sandbox = snapshot.sandbox in
  let sandbox_live =
    Keeper_sandbox_control.live_status_json
      ~include_preflight:false
      ~config ~meta ~timeout_sec:sandbox_live_probe_timeout_sec ~verbose:false ()
  in
  let domains =
    [
      snapshot.tool_domain;
      snapshot.sandbox_domain;
      snapshot.approval_domain;
      snapshot.cascade_domain;
      snapshot.audit_domain;
    ]
  in
  let score = keeper_score domains in
  let status = keeper_status_of_domains domains in
  `Assoc
    [
      ("name", `String meta.name);
      ("agent_name", `String meta.agent_name);
      ("status", `String (level_to_string status));
      ("score", `Float score);
      ("paused", `Bool meta.paused);
      ("sandbox_profile", `String sandbox.sandbox_profile);
      ("sandbox_backend", `String (Keeper_sandbox.backend_to_string sandbox.backend));
      ("network_mode", `String sandbox.network_mode);
      ("sandbox_root", `String sandbox.host_root_abs);
      ("container_root", string_opt_to_json sandbox.container_root);
      ("sandbox_live", sandbox_live);
      ("goal", `String meta.goal);
      ("goal_horizons",
       `Assoc
         [
           ("short", `String meta.short_goal);
           ("mid", `String meta.mid_goal);
           ("long", `String meta.long_goal);
         ]);
      ("active_goal_ids", `List (List.map (fun value -> `String value) meta.active_goal_ids));
      ("current_task_id", current_task_id_json meta);
      ("trace_id", `String trace_id);
      ("trace_history_count", `Int (List.length meta.runtime.trace_history));
      ("handoff_count_total", `Int (List.length meta.runtime.trace_history));
      ("total_turns", `Int meta.runtime.usage.total_turns);
      ("approval_pending_count", `Int snapshot.approval.count);
      ("recent_activity_count", `Int snapshot.activity.count);
      ("last_activity_ts", float_opt_to_json snapshot.activity.last_ts);
      ( "last_blocker"
      , match meta.runtime.last_blocker with
        | Some info -> Keeper_types.blocker_info_to_json info
        | None -> `Null );
      ( "benchmark_recommendation",
        match snapshot.bench_recommendation with
        | None -> `Null
        | Some recommendation ->
            `Assoc
              [
                ("keeper_profile", `String recommendation.keeper_profile);
                ("model_label", `String recommendation.model_label);
                ("composite_score", `Float recommendation.composite_score);
                ("task_pass_rate", `Float recommendation.task_pass_rate);
                ("stability_score", float_opt_to_json recommendation.stability_score);
                ("cases_total", `Int recommendation.cases_total);
                ("cases_passed", `Int recommendation.cases_passed);
              ] );
      ( "live_tool_stats",
        match snapshot.live_tool_stats with
        | None -> `Null
        | Some stats ->
            `Assoc
              [
                ("calls", `Int stats.calls);
                ("success_pct", `Float stats.success_pct);
              ] );
      ("repo_readiness", snapshot.repo_readiness);
      ("domains", `List (List.map keeper_domain_json domains));
      ("findings", `List (List.map finding_json snapshot.findings));
      ( "evidence_refs",
        `List
          [
            evidence_ref_json
              (base_evidence_ref "path" "keeper_meta"
                 (Keeper_types.keeper_meta_path config meta.name));
            evidence_ref_json
              (base_evidence_ref "path" "history"
                 (Keeper_types.keeper_history_path config trace_id));
          ] );
    ]

let timeline_entries_json
    ~(alias_to_keeper : (string, string) Hashtbl.t)
    ~(activity_items : Activity_feed.activity_item list)
    ~(approval_by_keeper : (string, approval_stats) Hashtbl.t)
    ~(keepers : keeper_snapshot list) =
  let entries = ref [] in
  let push json = entries := json :: !entries in
  List.iter
    (fun (item : Activity_feed.activity_item) ->
      let keeper_name = Hashtbl.find_opt alias_to_keeper (String.trim item.agent_name) in
      push
        (`Assoc
          [
            ("ts", `Float item.created_at);
            ("ts_iso", `String (Masc_domain.iso8601_of_unix_seconds item.created_at));
            ("kind", `String item.kind);
            ("keeper_name", string_opt_to_json keeper_name);
            ("actor", `String item.agent_name);
            ("summary", `String item.summary);
          ]))
    activity_items;
  Hashtbl.iter
    (fun keeper_name approval ->
      List.iter
        (fun entry ->
          let requested_at = Safe_ops.json_float ~default:0.0 "requested_at" entry in
          push
            (`Assoc
              [
                ("ts", `Float requested_at);
                ("ts_iso", `String (Masc_domain.iso8601_of_unix_seconds requested_at));
                ("kind", `String "approval_pending");
                ("keeper_name", `String keeper_name);
                ("actor", `String keeper_name);
                ("summary",
                 `String
                   (Printf.sprintf
                      "approval pending for %s (%s)"
                      (Safe_ops.json_string ~default:"tool" "tool_name" entry)
                      (Safe_ops.json_string ~default:"risk" "risk_level" entry)));
              ]))
        approval.entries)
    approval_by_keeper;
  List.iter
    (fun snapshot ->
      let blocker =
        match snapshot.meta.runtime.last_blocker with
        | Some info ->
          let trimmed = String.trim info.detail in
          if trimmed = "" then
            Some (Keeper_types.blocker_class_to_string info.klass)
          else Some trimmed
        | None -> None
      in
      match blocker with
      | None -> ()
      | Some summary ->
          let ts = snapshot.meta.runtime.usage.last_turn_ts in
          if ts > 0.0 then
            push
              (`Assoc
                [
                  ("ts", `Float ts);
                  ("ts_iso", `String (Masc_domain.iso8601_of_unix_seconds ts));
                  ("kind", `String "runtime_blocker");
                  ("keeper_name", `String snapshot.meta.name);
                  ("actor", `String snapshot.meta.name);
                  ("summary", `String summary);
                ]))
    keepers;
  !entries
  |> List.sort (fun left right ->
         let left_ts = Safe_ops.json_float ~default:0.0 "ts" left in
         let right_ts = Safe_ops.json_float ~default:0.0 "ts" right in
         Float.compare right_ts left_ts)
  |> List.filteri (fun idx _ -> idx < 25)

let domain_summary_json ~id ~(keepers : keeper_snapshot list)
    ?extra_status ?extra_evidence_refs ?extra_note () =
  let label, weight = domain_definition id in
  let keeper_domains =
    keepers
    |> List.map (fun snapshot ->
           match id with
           | _ when String.equal id tool_domain_id -> snapshot.tool_domain
           | _ when String.equal id sandbox_domain_id -> snapshot.sandbox_domain
           | _ when String.equal id approval_domain_id -> snapshot.approval_domain
           | _ when String.equal id cascade_domain_id -> snapshot.cascade_domain
           | _ -> snapshot.audit_domain)
  in
  let statuses = List.map (fun (domain : keeper_domain) -> domain.status) keeper_domains in
  let statuses =
    match extra_status with
    | Some level -> level :: statuses
    | None -> statuses
  in
  let status = worst_level statuses in
  let score =
    match keeper_domains with
    | [] -> 0.0
    | rows ->
        List.fold_left (fun acc (domain : keeper_domain) -> acc +. domain.score) 0.0 rows
        /. float_of_int (List.length rows)
  in
  let evidence_refs =
    (List.concat_map (fun (domain : keeper_domain) -> domain.evidence_refs) keeper_domains)
    @ Option.value ~default:[] extra_evidence_refs
  in
  let pass_count =
    List_util.count_if (fun (domain : keeper_domain) -> domain.status = Pass) keeper_domains
  in
  let warn_count =
    List_util.count_if (fun (domain : keeper_domain) -> domain.status = Warn) keeper_domains
  in
  let fail_count =
    List_util.count_if (fun (domain : keeper_domain) -> domain.status = Fail) keeper_domains
  in
  `Assoc
    [
      ("id", `String id);
      ("label", `String label);
      ("weight", `Int weight);
      ("status", `String (level_to_string status));
      ("score", `Float score);
      ("pass_count", `Int pass_count);
      ("warn_count", `Int warn_count);
      ("fail_count", `Int fail_count);
      ( "summary",
        `String
          (match extra_note with
           | Some note -> note
           | None -> Printf.sprintf "%d keepers evaluated" (List.length keeper_domains)) );
      ("evidence_refs", `List (List.map evidence_ref_json evidence_refs));
    ]

let normalize_for_hash (json : Yojson.Safe.t) =
  let rec aux = function
    | `Assoc fields ->
        `Assoc
          (fields
          |> List.filter_map (fun (key, value) ->
                 if List.mem key [ "generated_at"; "generated_at_unix"; "history" ] then None
                 else Some (key, aux value)))
    | `List values -> `List (List.map aux values)
    | other -> other
  in
  aux json

let payload_hash json =
  json
  |> normalize_for_hash
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex

let audit_dir config =
  Filename.concat (Coord.masc_root_dir config) "audits/safe_autonomy"

let artifact_paths config =
  let dir = audit_dir config in
  let latest_path = Filename.concat dir "latest.json" in
  let history_path = Filename.concat dir "history.jsonl" in
  dir, latest_path, history_path

let write_artifacts ~(config : Coord.config) payload =
  let dir, latest_path, history_path = artifact_paths config in
  Fs_compat.mkdir_p dir;
  let fingerprint = payload_hash payload in
  let previous_hash =
    match Safe_ops.read_json_file_safe latest_path with
    | Ok json -> Some (payload_hash json)
    | Error _ -> None
  in
  let history_appended = previous_hash <> Some fingerprint in
  (match Fs_compat.save_file_atomic latest_path (Yojson.Safe.pretty_to_string payload) with
   | Ok () -> ()
   | Error message ->
       Log.Dashboard.warn "safe autonomy latest artifact write failed: %s" message);
  if history_appended then Fs_compat.append_jsonl history_path payload;
  { latest_path; history_path; fingerprint; history_appended }

let read_history_scores ~(config : Coord.config) : float list =
  let _dir, _latest_path, history_path = artifact_paths config in
  if not (Fs_compat.file_exists history_path) then []
  else
    let entries = Fs_compat.load_jsonl history_path in
    let scores =
      List.filter_map
        (fun json ->
           match json with
           | `Assoc fields ->
               (match List.assoc_opt "summary" fields with
                | Some (`Assoc summary_fields) ->
                    (match List.assoc_opt "global_score" summary_fields with
                     | Some (`Float f) -> Some f
                     | Some (`Int i) -> Some (float_of_int i)
                     | _ -> None)
                | _ -> None)
           | _ -> None)
        entries
    in
    let len = List.length scores in
    if len <= 15 then scores
    else
      let rec drop n = function
        | [] -> []
        | _ :: xs when n > 0 -> drop (n - 1) xs
        | xs -> xs
      in
      drop (len - 15) scores

let global_status_of_score ~has_fail score =
  if has_fail || score < 60.0 then Fail
  else if score < 85.0 then Warn
  else Pass

let json ~(config : Coord.config) () =
  let keepers =
    Keeper_types.keeper_names config
    |> List.filter_map (fun name ->
           match Keeper_types.read_meta config name with
           | Ok (Some meta) -> Some meta
           | _ -> None)
  in
  let activity_items = Activity_feed.recent_activity config ~limit:200 () in
  let activity_by_keeper, alias_to_keeper =
    activity_stats_by_keeper keepers activity_items
  in
  let approval_queue_json = Keeper_approval_queue.list_pending_dashboard_json () in
  let approval_by_keeper = approval_stats_of_pending_json approval_queue_json in
  let approval_summary = Dashboard_governance_metrics.approval_queue_summary () in
  let live_tool_by_keeper, live_tool_payload = live_tool_stats_by_keeper () in
  let manifest_path = bench_recommendation_path () in
  let bench_manifest = Keeper_benchmark_canary.load_manifest () in
  let transport_json = Transport_metrics.transport_health_json ~config in
  let transport_level, transport_summary, transport_reason =
    transport_health_status transport_json
  in
  let keeper_snapshots =
    keepers
    |> List.map
         (build_keeper_snapshot ~config ~manifest_path
            ~bench_manifest ~live_tool_by_keeper ~approval_by_keeper
            ~activity_by_keeper)
  in
  let transport_finding =
    match transport_reason with
    | None -> []
    | Some reason_code ->
        [
          make_finding
            ~reason_code
            ~domain_id:cascade_domain_id
            ~severity:transport_level
            ~summary:transport_summary
            ~human_action_required:false
            ~suggested_next_action:
              "Inspect transport-health and runtime listener state before escalating keeper failures."
            ~evidence_refs:
              [ base_evidence_ref "route" "transport_health" "/api/v1/dashboard/transport-health" ]
            ();
        ]
  in
  let findings =
    transport_finding
    @ List.concat_map (fun snapshot -> snapshot.findings) keeper_snapshots
  in
  let domains =
    [
      domain_summary_json ~id:tool_domain_id ~keepers:keeper_snapshots ();
      domain_summary_json ~id:sandbox_domain_id ~keepers:keeper_snapshots ();
      domain_summary_json ~id:approval_domain_id ~keepers:keeper_snapshots ();
      domain_summary_json ~id:cascade_domain_id ~keepers:keeper_snapshots
        ~extra_status:transport_level
        ~extra_evidence_refs:
          [ base_evidence_ref "route" "transport_health" "/api/v1/dashboard/transport-health" ]
        ~extra_note:
          (Printf.sprintf "keeper blocker surfacing + transport health (%s)"
             transport_summary)
        ();
      domain_summary_json ~id:audit_domain_id ~keepers:keeper_snapshots ();
    ]
  in
  let per_keeper =
    List.map (keeper_snapshot_json ~config) keeper_snapshots
  in
  let total_active_goals =
    List.fold_left
      (fun acc snapshot -> acc + List.length snapshot.meta.active_goal_ids)
      0 keeper_snapshots
  in
  let keepers_with_tasks =
    List.length
      (List.filter
         (fun snapshot -> snapshot.meta.current_task_id <> None)
         keeper_snapshots)
  in
  let findings_total = List.length findings in
  let human_action_required_count =
    List.length
      (List.filter (fun finding -> finding.human_action_required) findings)
  in
  let keeper_scores =
    keeper_snapshots
    |> List.map (fun snapshot ->
           keeper_score
             [
               snapshot.tool_domain;
               snapshot.sandbox_domain;
               snapshot.approval_domain;
               snapshot.cascade_domain;
               snapshot.audit_domain;
             ])
  in
  let global_score =
    if keeper_scores = [] then 0.0
    else
      List.fold_left ( +. ) 0.0 keeper_scores
      /. float_of_int (List.length keeper_scores)
  in
  let has_fail =
    List.exists
      (fun finding -> finding.severity = Fail)
      findings
  in
  let global_status = global_status_of_score ~has_fail global_score in
  let timeline =
    timeline_entries_json ~alias_to_keeper ~activity_items ~approval_by_keeper
      ~keepers:keeper_snapshots
  in
  let history_scores = read_history_scores ~config in
  let payload =
    `Assoc
      [
        ("generated_at", `String (Masc_domain.now_iso ()));
        ("generated_at_unix", `Float (Unix.gettimeofday ()));
        ( "summary",
          `Assoc
            [
              ("global_score", `Float global_score);
              ("status", `String (level_to_string global_status));
              ("keeper_count", `Int (List.length keeper_snapshots));
              ("active_goal_count", `Int total_active_goals);
              ("keepers_with_current_task", `Int keepers_with_tasks);
              ("findings_total", `Int findings_total);
              ("human_action_required_count", `Int human_action_required_count);
              ("approval_queue_depth", `Int approval_summary.depth);
            ] );
        ("domains", `List domains);
        ("per_keeper", `List per_keeper);
        ("findings", `List (List.map finding_json findings));
        ("timeline", `List timeline);
        ( "transport",
          `Assoc
            [
              ("status", `String (level_to_string transport_level));
              ("summary", `String transport_summary);
              ("detail", transport_json);
            ] );
        ( "evidence_refs",
          `List
            [
              evidence_ref_json
                (base_evidence_ref "file" "bench_manifest" manifest_path);
              evidence_ref_json
                (base_evidence_ref "route" "tool_quality" "/api/v1/dashboard/tool-quality");
              evidence_ref_json
                (base_evidence_ref "route" "governance" "/api/v1/dashboard/governance");
              evidence_ref_json
                (base_evidence_ref "route" "transport_health" "/api/v1/dashboard/transport-health");
              evidence_ref_json
                (base_evidence_ref "route" "surface_readiness" "/api/v1/dashboard/surface-readiness");
              evidence_ref_json
                (base_evidence_ref "route" "metrics" "/metrics");
            ] );
        ("tool_quality_live", live_tool_payload);
        ("history", `List (List.map (fun s -> `Float s) history_scores));
      ]
  in
  let artifacts = write_artifacts ~config payload in
  match payload with
  | `Assoc fields ->
      `Assoc
        (fields
        @ [
            ( "artifacts",
              `Assoc
                [
                  ("latest_path", `String artifacts.latest_path);
                  ("history_path", `String artifacts.history_path);
                  ("fingerprint", `String artifacts.fingerprint);
                  ("history_appended", `Bool artifacts.history_appended);
                ] );
          ])
  | other -> other
