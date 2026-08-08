(** Plan-Execute demo: goal decomposition with dependency tracking.

    Demonstrates:
    - Creating a plan with dependent steps
    - Executing steps in dependency order
    - Re-planning when a step fails
    - Progress tracking and serialization

    No LLM required — runs standalone.

    Usage:
      dune exec examples/plan_execute_demo.exe *)

open Agent_sdk

(* ── Helper: execute a plan step by step ──────────── *)

(** Simple executor that runs steps in dependency order. *)
let execute_plan plan =
  let rec loop plan =
    match Plan.current_step plan with
    | None ->
      (* No more steps — finish *)
      Plan.finish plan
    | Some step ->
      if not (Plan.deps_satisfied plan step.id)
      then (
        Printf.printf "  [skip] %s: deps not satisfied\n%!" step.id;
        let plan = Plan.skip_step plan step.id in
        loop plan)
      else (
        Printf.printf "  [run]  %s: %s\n%!" step.id step.description;
        let plan = Plan.start_step plan step.id in
        (* Simulate step execution *)
        let result =
          `Assoc
            [ "step", `String step.id
            ; "output", `String (Printf.sprintf "%s completed" step.description)
            ]
        in
        let plan = Plan.complete_step plan step.id ~result in
        Printf.printf
          "         -> Done (progress: %.0f%%)\n%!"
          (Plan.progress plan *. 100.0);
        loop plan)
  in
  loop (Plan.start plan)
;;

(* ── Main scenario ───────────────────────────────── *)

let () =
  Printf.printf "=== OAS Plan-Execute Demo (v0.77.0) ===\n\n";
  (* Scenario 1: Linear plan *)
  Printf.printf "--- Scenario 1: Linear deployment plan ---\n";
  let plan =
    Plan.create ~goal:"deploy service v2" ~planner:"ci-agent" ()
    |> fun p ->
    Plan.add_step p ~id:"build" ~description:"build Docker image" ()
    |> fun p ->
    Plan.add_step
      p
      ~id:"test"
      ~description:"run integration tests"
      ~depends_on:[ "build" ]
      ()
    |> fun p ->
    Plan.add_step p ~id:"stage" ~description:"deploy to staging" ~depends_on:[ "test" ] ()
    |> fun p ->
    Plan.add_step
      p
      ~id:"prod"
      ~description:"deploy to production"
      ~depends_on:[ "stage" ]
      ()
  in
  Printf.printf "  Goal: %s\n" (Plan.goal plan);
  Printf.printf "  Steps: %d\n" (Plan.step_count plan);
  let plan = execute_plan plan in
  Printf.printf "  Status: %s\n\n" (Plan.plan_status_to_string (Plan.status plan));
  (* Scenario 2: Plan with failure and re-planning *)
  Printf.printf "--- Scenario 2: Re-planning after failure ---\n";
  let plan2 =
    Plan.create ~goal:"data migration" ~planner:"etl-agent" ()
    |> fun p ->
    Plan.add_step p ~id:"backup" ~description:"backup existing data" ()
    |> fun p ->
    Plan.add_step
      p
      ~id:"migrate"
      ~description:"run migration scripts"
      ~depends_on:[ "backup" ]
      ()
    |> fun p ->
    Plan.add_step
      p
      ~id:"verify"
      ~description:"verify data integrity"
      ~depends_on:[ "migrate" ]
      ()
    |> Plan.start
  in
  (* Execute backup *)
  let plan2 = Plan.start_step plan2 "backup" in
  let plan2 = Plan.complete_step plan2 "backup" ~result:(`String "backup.tar.gz") in
  Printf.printf "  backup: Done\n";
  (* Migrate fails *)
  let plan2 = Plan.start_step plan2 "migrate" in
  let plan2 = Plan.fail_step plan2 "migrate" ~reason:"schema conflict" in
  Printf.printf "  migrate: Failed (schema conflict)\n";
  Printf.printf "  Progress before replan: %.0f%%\n" (Plan.progress plan2 *. 100.0);
  (* Re-plan: replace remaining pending steps *)
  let new_steps : Plan.step list =
    [ { id = "fix-schema"
      ; description = "fix schema conflicts"
      ; status = Pending
      ; result = None
      ; depends_on = []
      }
    ; { id = "retry-migrate"
      ; description = "retry migration"
      ; status = Pending
      ; result = None
      ; depends_on = [ "fix-schema" ]
      }
    ; { id = "verify-v2"
      ; description = "verify with updated checks"
      ; status = Pending
      ; result = None
      ; depends_on = [ "retry-migrate" ]
      }
    ]
  in
  let plan2 = Plan.replan plan2 ~new_steps in
  Printf.printf "  Re-planned: %d steps now\n" (Plan.step_count plan2);
  Printf.printf "  Status: %s\n\n" (Plan.plan_status_to_string (Plan.status plan2));
  (* Scenario 3: Serialization round-trip *)
  Printf.printf "--- Scenario 3: State serialization ---\n";
  let json = Plan.to_json plan in
  let json_str = Yojson.Safe.to_string json in
  Printf.printf "  Serialized: %d bytes\n" (String.length json_str);
  (match Plan.of_json json with
   | Ok restored ->
     Printf.printf
       "  Restored: goal='%s', steps=%d, status=%s\n"
       (Plan.goal restored)
       (Plan.step_count restored)
       (Plan.plan_status_to_string (Plan.status restored))
   | Error e -> Printf.printf "  Error: %s\n" e);
  (* Scenario 4: Dependency graph *)
  Printf.printf "\n--- Scenario 4: Dependency tracking ---\n";
  let dag =
    Plan.create ~goal:"ML pipeline" ~planner:"ml-agent" ()
    |> fun p ->
    Plan.add_step p ~id:"data" ~description:"fetch dataset" ()
    |> fun p ->
    Plan.add_step
      p
      ~id:"features"
      ~description:"extract features"
      ~depends_on:[ "data" ]
      ()
    |> fun p ->
    Plan.add_step p ~id:"train" ~description:"train model" ~depends_on:[ "features" ] ()
    |> fun p ->
    Plan.add_step p ~id:"eval" ~description:"evaluate model" ~depends_on:[ "train" ] ()
    |> fun p ->
    Plan.add_step
      p
      ~id:"deploy-model"
      ~description:"deploy to API"
      ~depends_on:[ "eval"; "data" ]
      ()
  in
  Printf.printf
    "  deploy-model deps_satisfied? %b (expected: false)\n"
    (Plan.deps_satisfied dag "deploy-model");
  let dag = Plan.complete_step dag "data" ~result:`Null in
  let dag = Plan.complete_step dag "features" ~result:`Null in
  let dag = Plan.complete_step dag "train" ~result:`Null in
  let dag = Plan.complete_step dag "eval" ~result:`Null in
  Printf.printf
    "  deploy-model deps_satisfied? %b (expected: true)\n"
    (Plan.deps_satisfied dag "deploy-model");
  ignore dag;
  Printf.printf "\nDone.\n"
;;
