module Masc_log = Log
open Agent_sdk
module Log = Masc_log

type worker_role =
  | Discover
  | Verify
  | Summarize
  | Audit

type fixture_lane =
  | Official
  | Research
  | Reviews

type worker_plan = {
  role : worker_role;
  lane : fixture_lane;
  name : string;
  specialization : string;
  task_title : string;
  task_description : string;
  claim_marker : string;
  done_marker : string;
  final_marker : string;
  next_agent : string option;
}

type config = {
  run_id : string;
  masc_url : string;
  provider_base_url : string;
  model_id : string;
  slot_url : string;
  worker_count : int;
  min_hot_slots : int;
  required_final_markers : int;
  max_turns : int;
}

let default_config =
  {
    run_id = "swarm-live";
    masc_url = "http://127.0.0.1:8935";
    provider_base_url = "http://127.0.0.1:3034";
    model_id = Env_config.Llama.default_model;
    slot_url = Env_config.Llama.server_url;
    worker_count = 12;
    min_hot_slots = 10;
    required_final_markers = 12;
    max_turns = 8;
  }

let string_of_worker_role = function
  | Discover -> "discover"
  | Verify -> "verify"
  | Summarize -> "summarize"
  | Audit -> "audit"

let worker_specialization = function
  | Discover -> "discovery triage"
  | Verify -> "provenance verification"
  | Summarize -> "structured summarization"
  | Audit -> "final audit"

let worker_roles = [ Discover; Verify; Summarize; Audit ]
let fixture_lanes = [ Official; Research; Reviews ]

let string_of_fixture_lane = function
  | Official -> "official"
  | Research -> "research"
  | Reviews -> "reviews"

let fixture_lane_title = function
  | Official -> "official release item"
  | Research -> "research note"
  | Reviews -> "independent review"

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0 then true
  else
    let rec loop idx =
      if idx + needle_len > haystack_len then false
      else if String.sub haystack idx needle_len = needle then true
      else loop (idx + 1)
    in
    loop 0

let safe_run_id run_id =
  Room_utils.safe_filename run_id |> String.lowercase_ascii

let worker_name ?(replica=0) run_id role lane =
  let base =
    Printf.sprintf "swarm-%s-%s-%s"
      (string_of_worker_role role)
      (string_of_fixture_lane lane)
      (safe_run_id run_id)
  in
  if replica <= 0 then
    base
  else
    Printf.sprintf "%s-r%d" base (replica + 1)

let claim_marker run_id role lane =
  Printf.sprintf "HARNESS_CLAIM run_id=%s role=%s lane=%s"
    run_id (string_of_worker_role role) (string_of_fixture_lane lane)

let done_marker run_id role lane =
  Printf.sprintf "HARNESS_DONE run_id=%s role=%s lane=%s"
    run_id (string_of_worker_role role) (string_of_fixture_lane lane)

let final_marker run_id role lane =
  Printf.sprintf "FINAL_MARKER[%s:%s:%s]"
    run_id (string_of_worker_role role) (string_of_fixture_lane lane)

let synthetic_fixture =
  {|
Synthetic fixture for the live swarm harness:

1. "OpenAI launches a smaller realtime speech model" (lane: official, source: https://example.invalid/openai-realtime)
2. "OpenReview note discusses sparse MoE routing efficiency" (lane: research, source: https://example.invalid/openreview-moe)
3. "Independent review compares local Qwen 3.5 and GLM 4.7 Flash" (lane: reviews, source: https://example.invalid/review-local-models)

Role expectations:
- discover: identify the 3 items and group them by lane
- verify: confirm each item includes a canonical source URL and explain whether provenance is sufficient
- summarize: produce a two-line Korean summary for each item without inventing facts
- audit: confirm the previous steps stayed grounded in the fixture and flag any missing evidence

Do not use external network or fabricate additional items. Use only this fixture and the MASC tools.
|}

let task_description run_id role lane =
  let lane_name = string_of_fixture_lane lane in
  let lane_title = fixture_lane_title lane in
  match role with
  | Discover ->
      Printf.sprintf
        "Run %s discover step for the %s (%s). Claim this task, isolate that fixture item, and broadcast the discover claim/done markers."
        run_id lane_title lane_name
  | Verify ->
      Printf.sprintf
        "Run %s verify step for the %s (%s). Claim this task, inspect provenance sufficiency for that fixture item, and broadcast the verify claim/done markers."
        run_id lane_title lane_name
  | Summarize ->
      Printf.sprintf
        "Run %s summarize step for the %s (%s). Claim this task, write a concise Korean summary for that fixture item, and broadcast the summarize claim/done markers."
        run_id lane_title lane_name
  | Audit ->
      Printf.sprintf
        "Run %s audit step for the %s (%s). Claim this task, check grounding/provenance for that fixture item, and broadcast the audit claim/done markers."
        run_id lane_title lane_name

let task_title run_id role lane name =
  Printf.sprintf "[%s] %s %s worker task for %s"
    run_id
    (String.uppercase_ascii (string_of_worker_role role))
    (String.uppercase_ascii (string_of_fixture_lane lane))
    name

let build_worker_plans ?(worker_count=12) run_id =
  let seeds =
    fixture_lanes
    |> List.concat_map (fun lane ->
           worker_roles |> List.map (fun role -> (role, lane)))
  in
  let seed_count = List.length seeds in
  let seeds_arr = Array.of_list seeds in
  let total = max 1 worker_count in
  let plans =
    List.init total (fun idx ->
        let role, lane = seeds_arr.(idx mod seed_count) in
        let replica = idx / seed_count in
        let name = worker_name ~replica run_id role lane in
        {
          role;
          lane;
          name;
          specialization = worker_specialization role;
          task_title = task_title run_id role lane name;
          task_description = task_description run_id role lane;
          claim_marker = claim_marker run_id role lane;
          done_marker = done_marker run_id role lane;
          final_marker = final_marker run_id role lane;
          next_agent = None;
        })
  in
  let plans_arr = Array.of_list plans in
  plans
  |> List.mapi (fun idx plan ->
         let next_agent =
           if idx + 1 < Array.length plans_arr then
             Some plans_arr.(idx + 1).name
           else
             None
         in
         { plan with next_agent })

let provider_config cfg : Provider.config =
  {
    provider = Provider.Local { base_url = cfg.provider_base_url };
    model_id = cfg.model_id;
    api_key_env = "DUMMY_KEY";
  }

let common_goal cfg =
  Printf.sprintf
    "Complete the deterministic live swarm harness for run %s using only the synthetic fixture. Finish your assigned role concisely and end with the exact FINAL_MARKER."
    cfg.run_id

let worker_system_prompt cfg plan =
  Printf.sprintf
    {|
You are %s, a swarm worker in a deterministic live harness.

Run ID: %s
Role: %s
Lane: %s
Specialization: %s
Expected final marker: %s

Runtime guarantees:
- Task claim/current_task/heartbeat/done are handled outside the model.
- You do not need to use MASC tools for lifecycle in this harness.

Rules:
1. Work ONLY from the synthetic fixture below. No external fetches, no invented sources.
2. Produce the role-specific result in 3-6 short lines or bullets.
3. Keep it factual and concise.
4. Your final response MUST include the exact final marker verbatim on its own line.

Synthetic fixture:
%s
|}
    plan.name cfg.run_id (string_of_worker_role plan.role)
    (string_of_fixture_lane plan.lane) plan.specialization
    plan.final_marker synthetic_fixture

let worker_spec cfg plan : Agent_swarm_swarm.agent_spec =
  {
    Agent_swarm_swarm.name = plan.name;
    provider = provider_config cfg;
    system_prompt = worker_system_prompt cfg plan;
    tools = [];
    max_tokens = Some 256;
    max_turns = cfg.max_turns;
    temperature = None;
    include_masc_tools = false;
    managed_task =
      Some
        {
          Agent_swarm_swarm.title_fragment = plan.task_title;
          claim_marker = plan.claim_marker;
          done_marker = plan.done_marker;
        };
    expected_final_marker = Some plan.final_marker;
  }

let extract_text (response : Types.api_response) =
  response.content
  |> List.filter_map (function Types.Text text -> Some text | _ -> None)
  |> String.concat "\n"

let role_of_name name =
  List.find_map
    (fun role ->
      let needle = Printf.sprintf "-%s-" (string_of_worker_role role) in
      if contains_substring ~needle name then Some role else None)
    worker_roles

let lane_of_name name =
  List.find_map
    (fun lane ->
      let needle = Printf.sprintf "-%s-" (string_of_fixture_lane lane) in
      if contains_substring ~needle name then Some lane else None)
    fixture_lanes

let manifest_json cfg =
  let workers =
    build_worker_plans ~worker_count:cfg.worker_count cfg.run_id
    |> List.map (fun worker ->
           `Assoc
             [
               ("role", `String (string_of_worker_role worker.role));
               ("lane", `String (string_of_fixture_lane worker.lane));
               ("name", `String worker.name);
               ("specialization", `String worker.specialization);
               ("task_title", `String worker.task_title);
               ("task_description", `String worker.task_description);
               ("claim_marker", `String worker.claim_marker);
               ("done_marker", `String worker.done_marker);
               ("final_marker", `String worker.final_marker);
               ( "next_agent",
                 match worker.next_agent with
                 | Some value -> `String value
                 | None -> `Null );
             ])
  in
  `Assoc
    [
      ("run_id", `String cfg.run_id);
      ("masc_url", `String cfg.masc_url);
      ("provider_base_url", `String cfg.provider_base_url);
      ("model_id", `String cfg.model_id);
      ("slot_url", `String cfg.slot_url);
      ("worker_count", `Int cfg.worker_count);
      ("min_hot_slots", `Int cfg.min_hot_slots);
      ("required_final_markers", `Int cfg.required_final_markers);
      ("expected_worker_count", `Int (List.length workers));
      ("shared_goal", `String (common_goal cfg));
      ("workers", `List workers);
    ]

let seed_tasks ~sw ~net ~masc_url plans =
  let coordinator =
    Agent_swarm_client.create_managed ~net ~base_url:masc_url
      ~agent_name:"swarm-coordinator"
  in
  (match Agent_swarm_client.join ~sw coordinator with
   | Error e ->
       Log.Swarm.warn "MASC join warning: %s" e
   | Ok _ -> ());
  let tasks =
    List.map
      (fun (plan : worker_plan) -> (plan.task_title, plan.task_description))
      plans
  in
  (match Agent_swarm_client.batch_add_tasks ~sw coordinator ~tasks with
   | Error e ->
       Log.Swarm.warn "batch_add_tasks warning: %s" e
   | Ok _ ->
       Log.Swarm.info "seeded %d tasks"
         (List.length tasks));
  ignore (Agent_swarm_client.leave ~sw coordinator)

let run ~sw ~net ~clock cfg =
  let plans = build_worker_plans ~worker_count:cfg.worker_count cfg.run_id in
  seed_tasks ~sw ~net ~masc_url:cfg.masc_url plans;
  let swarm_config =
    {
      Agent_swarm_swarm.masc_url = cfg.masc_url;
      agents = List.map (worker_spec cfg) plans;
    }
  in
  let on_complete (results : Agent_swarm_swarm.agent_result list) =
    let success_count =
      List.length (List.filter
        (fun (r : Agent_swarm_swarm.agent_result) ->
          match r.result with Ok _ -> true | Error _ -> false) results)
    in
    let total = List.length results in
    Log.Swarm.info "swarm-live on_complete: %d/%d agents succeeded"
      success_count total
  in
  let results =
    Agent_swarm_swarm.run ~sw ~net ~clock ~on_complete swarm_config
      ~goal:(common_goal cfg)
  in
  let plan_by_name = List.map (fun worker -> (worker.name, worker)) plans in
  let rows =
    results
    |> List.map (fun (result : Agent_swarm_swarm.agent_result) ->
           let plan =
             match List.assoc_opt result.agent_name plan_by_name with
             | Some worker -> worker
             | None ->
               let inferred_role =
                   match role_of_name result.agent_name with
                   | Some role -> role
                   | None -> Discover
                 in
                let inferred_lane =
                  match lane_of_name result.agent_name with
                  | Some lane -> lane
                  | None -> Official
                in
                 {
                   role = inferred_role;
                   lane = inferred_lane;
                   name = result.agent_name;
                   specialization = worker_specialization inferred_role;
                   task_title = "";
                   task_description = "";
                   claim_marker = claim_marker cfg.run_id inferred_role inferred_lane;
                   done_marker = done_marker cfg.run_id inferred_role inferred_lane;
                   final_marker = final_marker cfg.run_id inferred_role inferred_lane;
                   next_agent = None;
                 }
           in
           match result.result with
           | Ok completion ->
               let text = extract_text completion.response in
               `Assoc
                 [
                   ("agent_name", `String result.agent_name);
                   ("role", `String (string_of_worker_role plan.role));
                   ("lane", `String (string_of_fixture_lane plan.lane));
                   ("status", `String "ok");
                   ("final_marker", `String plan.final_marker);
                   ("final_marker_seen", `Bool completion.model_final_marker_seen);
                   ("runtime_assisted_final_marker", `Bool completion.final_marker_assisted);
                   ("done_marker", `String plan.done_marker);
                   ("response_text", `String text);
                 ]
           | Error message ->
               `Assoc
                 [
                   ("agent_name", `String result.agent_name);
                   ("role", `String (string_of_worker_role plan.role));
                   ("lane", `String (string_of_fixture_lane plan.lane));
                   ("status", `String "error");
                   ("final_marker", `String plan.final_marker);
                   ("final_marker_seen", `Bool false);
                   ("runtime_assisted_final_marker", `Bool false);
                   ("done_marker", `String plan.done_marker);
                   ("error", `String message);
                 ])
  in
  let success_count =
    rows
    |> List.fold_left
         (fun acc row ->
           let text = Yojson.Safe.Util.member "status" row |> Yojson.Safe.Util.to_string in
           if String.equal text "ok" then acc + 1 else acc)
         0
  in
  let final_marker_count =
    rows
    |> List.fold_left
         (fun acc row ->
           if Yojson.Safe.Util.member "final_marker_seen" row
              |> Yojson.Safe.Util.to_bool_option |> Option.value ~default:false
           then acc + 1
           else acc)
         0
  in
  let runtime_assisted_final_marker_count =
    rows
    |> List.fold_left
         (fun acc row ->
           if Yojson.Safe.Util.member "runtime_assisted_final_marker" row
              |> Yojson.Safe.Util.to_bool_option |> Option.value ~default:false
           then acc + 1
           else acc)
         0
  in
  `Assoc
    [
      ("run_id", `String cfg.run_id);
      ("status", `String (if success_count = List.length rows then "ok" else "error"));
      ( "summary",
        `Assoc
          [
            ("expected_workers", `Int (List.length rows));
            ("successful_workers", `Int success_count);
            ("completed_workers", `Int success_count);
            ("final_markers_seen", `Int final_marker_count);
            ("runtime_assisted_final_markers", `Int runtime_assisted_final_marker_count);
          ] );
      ("workers", `List rows);
    ]
