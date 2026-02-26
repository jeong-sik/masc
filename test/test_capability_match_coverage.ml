(** Capability Match — Task-Agent Matching Tests *)

open Masc_mcp.Capability_match

let () = Printexc.record_backtrace true

(* ---------- Test Agents ---------- *)

let security_agent = {
  name = "claude-security";
  traits = ["analytical"; "thorough"; "careful"];
  interests = ["security"; "authentication"; "encryption"; "vulnerability"];
  capabilities = ["code-review"; "penetration-testing"];
  model = Some "claude-opus";
  activity_level = 0.8;
  role = Masc_mcp.Agent_identity.Reviewer;
}

let frontend_agent = {
  name = "claude-frontend";
  traits = ["creative"; "visual"; "responsive"];
  interests = ["react"; "css"; "design"; "accessibility"; "frontend"];
  capabilities = ["ui-design"; "testing"];
  model = Some "claude-sonnet";
  activity_level = 0.7;
  role = Masc_mcp.Agent_identity.Writer;
}

let devops_agent = {
  name = "claude-devops";
  traits = ["systematic"; "reliable"; "automation"];
  interests = ["docker"; "kubernetes"; "cicd"; "deployment"; "monitoring"];
  capabilities = ["infrastructure"; "deployment"];
  model = Some "claude-haiku";
  activity_level = 0.9;
  role = Masc_mcp.Agent_identity.Writer;
}

let generalist_agent = {
  name = "claude-general";
  traits = [];
  interests = [];
  capabilities = [];
  model = None;
  activity_level = 0.5;
  role = Masc_mcp.Agent_identity.Unassigned;
}

(* ---------- Test Tasks ---------- *)

let security_task = {
  task_id = "task-sec-001";
  title = "Fix authentication vulnerability";
  description = "Review and fix the JWT token validation bypass in the auth middleware";
  priority = 1;
  keywords = extract_keywords "Fix authentication vulnerability Review and fix the JWT token validation bypass in the auth middleware";
  required_role = Masc_mcp.Agent_identity.Unassigned;
}

let frontend_task = {
  task_id = "task-ui-001";
  title = "Improve responsive design";
  description = "Update CSS grid layout for mobile accessibility improvements";
  priority = 2;
  keywords = extract_keywords "Improve responsive design Update CSS grid layout for mobile accessibility improvements";
  required_role = Masc_mcp.Agent_identity.Unassigned;
}

let devops_task = {
  task_id = "task-ops-001";
  title = "Setup deployment pipeline";
  description = "Configure Docker and Kubernetes for automated deployment monitoring";
  priority = 3;
  keywords = extract_keywords "Setup deployment pipeline Configure Docker and Kubernetes for automated deployment monitoring";
  required_role = Masc_mcp.Agent_identity.Unassigned;
}

(* ---------- Keyword Extraction Tests ---------- *)

let test_extract_keywords_basic () =
  let kws = extract_keywords "Fix authentication vulnerability" in
  assert (List.mem "authentication" kws);
  assert (List.mem "vulnerability" kws);
  (* "fix" is a stop word *)
  assert (not (List.mem "fix" kws))

let test_extract_keywords_hyphenated () =
  let kws = extract_keywords "code-review and penetration-testing" in
  assert (List.mem "code" kws);
  assert (List.mem "review" kws);
  assert (List.mem "penetration" kws);
  assert (List.mem "testing" kws)

let test_extract_keywords_empty () =
  let kws = extract_keywords "" in
  assert (kws = [])

let test_extract_keywords_stop_words_only () =
  let kws = extract_keywords "the a an is are" in
  assert (kws = [])

let test_normalize_word () =
  assert (normalize_word "Hello" = "hello");
  assert (normalize_word "UPPER" = "upper");
  assert (normalize_word "test123" = "test123");
  assert (normalize_word "with-dash" = "withdash");
  assert (normalize_word "" = "")

(* ---------- Keyword Overlap Tests ---------- *)

let test_overlap_full () =
  let score = keyword_overlap ["auth"; "security"] ["auth"; "security"] in
  assert (score >= 0.99)

let test_overlap_partial () =
  let score = keyword_overlap ["auth"; "security"; "token"] ["auth"; "frontend"] in
  (* 1/3 = 0.33 *)
  assert (score > 0.3 && score < 0.4)

let test_overlap_none () =
  let score = keyword_overlap ["auth"; "security"] ["frontend"; "css"] in
  assert (score < 0.01)

let test_overlap_empty_reference () =
  let score = keyword_overlap [] ["anything"] in
  assert (score < 0.01)

let test_overlap_substring () =
  (* "auth" is a substring of "authentication" *)
  let score = keyword_overlap ["authentication"] ["auth"] in
  assert (score > 0.9)

(* ---------- Scoring Tests ---------- *)

let test_score_perfect_match () =
  let m = score security_agent security_task in
  assert (m.total_score > 0.0);
  assert (m.agent_name = "claude-security");
  assert (m.task_id = "task-sec-001")

let test_score_no_match () =
  let m = score generalist_agent security_task in
  assert (m.total_score < 0.01)

let test_score_cross_domain () =
  let m = score security_agent frontend_task in
  let m2 = score frontend_agent frontend_task in
  (* Frontend agent should score higher on frontend task *)
  assert (m2.total_score > m.total_score)

(* ---------- Ranking Tests ---------- *)

let test_rank_agents_for_task () =
  let agents = [generalist_agent; frontend_agent; security_agent; devops_agent] in
  let ranked = rank_agents_for_task agents security_task in
  assert (List.length ranked = 4);
  (* Security agent should be first *)
  assert ((List.hd ranked).agent_name = "claude-security")

let test_rank_tasks_for_agent () =
  let tasks = [frontend_task; devops_task; security_task] in
  let ranked = rank_tasks_for_agent security_agent tasks in
  assert (List.length ranked = 3);
  (* Security task should be first *)
  assert ((List.hd ranked).task_id = "task-sec-001")

let test_rank_devops_task () =
  let agents = [security_agent; frontend_agent; devops_agent] in
  let ranked = rank_agents_for_task agents devops_task in
  (* DevOps agent should rank first *)
  assert ((List.hd ranked).agent_name = "claude-devops")

let test_rank_frontend_task () =
  let agents = [security_agent; frontend_agent; devops_agent] in
  let ranked = rank_agents_for_task agents frontend_task in
  (* Frontend agent should rank first *)
  assert ((List.hd ranked).agent_name = "claude-frontend")

(* ---------- Best Agent / Suggest Task ---------- *)

let test_best_agent () =
  let agents = [generalist_agent; security_agent] in
  let best = best_agent_for_task agents security_task in
  assert (best <> None);
  assert ((Option.get best).agent_name = "claude-security")

let test_best_agent_min_score () =
  let agents = [generalist_agent] in
  let best = best_agent_for_task ~min_score:0.5 agents security_task in
  (* Generalist has 0.0 score, should return None *)
  assert (best = None)

let test_suggest_task () =
  let tasks = [frontend_task; devops_task; security_task] in
  let suggested = suggest_task_for_agent security_agent tasks in
  assert (suggested <> None);
  assert ((Option.get suggested).task_id = "task-sec-001")

(* ---------- JSON Serialization ---------- *)

let test_match_score_to_json () =
  let m = score security_agent security_task in
  let json = match_score_to_json m in
  let open Yojson.Safe.Util in
  assert (json |> member "agentName" |> to_string = "claude-security");
  assert (json |> member "taskId" |> to_string = "task-sec-001");
  assert (json |> member "totalScore" |> to_float >= 0.0)

let test_ranking_to_json () =
  let agents = [security_agent; frontend_agent] in
  let ranked = rank_agents_for_task agents security_task in
  let json = ranking_to_json ranked in
  match json with
  | `List items -> assert (List.length items = 2)
  | _ -> failwith "Expected JSON list"

(* ---------- Agent Profile from JSON ---------- *)

let test_agent_profile_of_json () =
  let json = `Assoc [
    ("name", `String "test-agent");
    ("traits", `List [`String "creative"; `String "thorough"]);
    ("interests", `List [`String "security"; `String "testing"]);
    ("model", `String "claude-opus");
    ("activityLevel", `Float 0.85);
  ] in
  let profile = agent_profile_of_json json in
  assert (profile <> None);
  let p = Option.get profile in
  assert (p.name = "test-agent");
  assert (List.length p.traits = 2);
  assert (List.length p.interests = 2);
  assert (p.activity_level > 0.8)

let test_agent_profile_of_json_string_traits () =
  (* Some agents may have traits as comma-separated string *)
  let json = `Assoc [
    ("name", `String "test-agent");
    ("traits", `String "creative, thorough");
    ("interests", `Null);
    ("model", `Null);
  ] in
  let profile = agent_profile_of_json json in
  assert (profile <> None);
  let p = Option.get profile in
  assert (List.length p.traits = 2)

(* ---------- Test Runner ---------- *)

let () =
  let tests = [
    ("extract_keywords_basic", test_extract_keywords_basic);
    ("extract_keywords_hyphenated", test_extract_keywords_hyphenated);
    ("extract_keywords_empty", test_extract_keywords_empty);
    ("extract_keywords_stop_words_only", test_extract_keywords_stop_words_only);
    ("normalize_word", test_normalize_word);
    ("overlap_full", test_overlap_full);
    ("overlap_partial", test_overlap_partial);
    ("overlap_none", test_overlap_none);
    ("overlap_empty_reference", test_overlap_empty_reference);
    ("overlap_substring", test_overlap_substring);
    ("score_perfect_match", test_score_perfect_match);
    ("score_no_match", test_score_no_match);
    ("score_cross_domain", test_score_cross_domain);
    ("rank_agents_for_task", test_rank_agents_for_task);
    ("rank_tasks_for_agent", test_rank_tasks_for_agent);
    ("rank_devops_task", test_rank_devops_task);
    ("rank_frontend_task", test_rank_frontend_task);
    ("best_agent", test_best_agent);
    ("best_agent_min_score", test_best_agent_min_score);
    ("suggest_task", test_suggest_task);
    ("match_score_to_json", test_match_score_to_json);
    ("ranking_to_json", test_ranking_to_json);
    ("agent_profile_of_json", test_agent_profile_of_json);
    ("agent_profile_of_json_string_traits", test_agent_profile_of_json_string_traits);
  ] in
  let passed = ref 0 in
  let failed = ref 0 in
  List.iter (fun (name, test) ->
    try
      test ();
      incr passed;
      Printf.printf "  \027[32m[OK]\027[0m  %s\n" name
    with e ->
      incr failed;
      Printf.printf "  \027[31m[FAIL]\027[0m %s: %s\n" name (Printexc.to_string e)
  ) tests;
  Printf.printf "\n%d passed, %d failed (%d total)\n" !passed !failed (!passed + !failed);
  if !failed > 0 then exit 1
