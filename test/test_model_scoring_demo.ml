(** MODEL Scoring Demo — Compare keyword vs MODEL scoring results.
    Run with: MASC_CAPABILITY_MATCH_MODE=model dune exec test/test_model_scoring_demo.exe *)

open Masc_mcp.Capability_match

let security_agent = {
  name = "claude-security";
  traits = ["analytical"; "thorough"; "careful"];
  interests = ["security"; "authentication"; "encryption"; "vulnerability"];
  capabilities = ["code-review"; "penetration-testing"];
  model = Some "claude-opus";
  activity_level = 0.8;
  role = Types_core.Reviewer;
}

let frontend_agent = {
  name = "claude-frontend";
  traits = ["creative"; "visual"; "responsive"];
  interests = ["react"; "css"; "design"; "accessibility"; "frontend"];
  capabilities = ["ui-design"; "testing"];
  model = Some "claude-sonnet";
  activity_level = 0.7;
  role = Types_core.Writer;
}

let devops_agent = {
  name = "claude-devops";
  traits = ["systematic"; "reliable"; "automation"];
  interests = ["docker"; "kubernetes"; "cicd"; "deployment"; "monitoring"];
  capabilities = ["infrastructure"; "deployment"];
  model = Some "claude-haiku";
  activity_level = 0.9;
  role = Types_core.Writer;
}

(* Tasks with semantic nuance — keyword overlap misses these *)
let cybersecurity_task = {
  task_id = "task-cyber";
  title = "Audit cybersecurity posture";
  description = "Evaluate the system for potential cyber threats and recommend hardening measures";
  priority = 1;
  keywords = extract_keywords "Audit cybersecurity posture Evaluate the system for potential cyber threats and recommend hardening measures";
  required_role = Types_core.Unassigned;
}

let ui_development_task = {
  task_id = "task-ui";
  title = "Build user interface components";
  description = "Create reusable UI widgets with responsive layout and WCAG compliance";
  priority = 2;
  keywords = extract_keywords "Build user interface components Create reusable UI widgets with responsive layout and WCAG compliance";
  required_role = Types_core.Unassigned;
}

let cloud_infra_task = {
  task_id = "task-cloud";
  title = "Migrate to cloud infrastructure";
  description = "Containerize services and set up orchestration with auto-scaling and health checks";
  priority = 3;
  keywords = extract_keywords "Migrate to cloud infrastructure Containerize services and set up orchestration with auto-scaling and health checks";
  required_role = Types_core.Unassigned;
}

let print_scores label agents tasks =
  Printf.printf "\n=== %s ===\n" label;
  List.iter (fun task ->
    Printf.printf "\nTask: %s\n" task.title;
    let ranked = rank_agents_for_task agents task in
    List.iter (fun m ->
      Printf.printf "  %-20s  total=%.3f  (trait=%.3f interest=%.3f cap=%.3f)\n"
        m.agent_name m.total_score m.trait_score m.interest_score m.capability_score
    ) ranked
  ) tasks

let () =
  let mode = get_match_mode () in
  let mode_str = match mode with Keyword -> "keyword" | Model -> "model" | Hybrid -> "hybrid" in
  Printf.printf "Mode: %s\n" mode_str;

  let agents = [security_agent; frontend_agent; devops_agent] in
  let tasks = [cybersecurity_task; ui_development_task; cloud_infra_task] in

  (* Keyword scoring *)
  Printf.printf "\n--- Keyword Scoring ---\n";
  List.iter (fun task ->
    Printf.printf "\nTask: %s\n" task.title;
    let ranked = List.map (fun a -> score_keyword a task) agents
      |> List.sort (fun a b -> compare b.total_score a.total_score) in
    List.iter (fun m ->
      Printf.printf "  %-20s  total=%.3f\n" m.agent_name m.total_score
    ) ranked
  ) tasks;

  (* Current mode scoring *)
  print_scores (Printf.sprintf "Current Mode (%s)" mode_str) agents tasks
