(** test_swarm_checkpoint.ml — Unit tests for Swarm_checkpoint module.

    Tests cover:
    - Snapshot JSON round-trip serialization
    - Summary JSON structure
    - Empty snapshot edge case
    - Goal progress round-trip

    @since 2.80.0 *)

open Masc_mcp

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

let dummy_agent_snapshot ?(name = "agent-1") ?(agent_type = "worker")
    ?(status = "online") ?(current_task = None) () :
    Swarm_checkpoint.agent_snapshot =
  { name; agent_type; status; current_task;
    last_seen = Types.now_iso () }

let dummy_task_snapshot ?(id = "task-001") ?(title = "Fix bug")
    ?(status = "Claimed") ?(assigned_to = Some "agent-1")
    ?(priority = 1) () : Swarm_checkpoint.task_snapshot =
  { id; title; status; assigned_to; priority }

let dummy_goal_progress () : Swarm_checkpoint.goal_progress =
  { goal_id = "goal-001"; title = "Improve score";
    metric_current = Some 0.7; metric_target = Some 0.95;
    completion_pct = 73.7 }

let dummy_snapshot () : Swarm_checkpoint.swarm_snapshot =
  { version = 1;
    saved_at = Types.now_iso ();
    room_id = "test-room";
    agents = [dummy_agent_snapshot ()];
    tasks = [dummy_task_snapshot ()];
    operations = [];
    goals = [dummy_goal_progress ()];
    total_tasks = 1;
    done_tasks = 0;
    active_agents = 1;
  }

(* ================================================================ *)
(* Tests                                                            *)
(* ================================================================ *)

let test_snapshot_json_roundtrip () =
  let snap = dummy_snapshot () in
  let json = Swarm_checkpoint.swarm_snapshot_to_yojson snap in
  let json_str = Yojson.Safe.to_string json in
  Alcotest.(check bool) "non-empty JSON" true (String.length json_str > 10);
  match Swarm_checkpoint.swarm_snapshot_of_yojson json with
  | Ok restored ->
      Alcotest.(check string) "room_id" snap.room_id restored.room_id;
      Alcotest.(check int) "agent count" 1 (List.length restored.agents);
      Alcotest.(check int) "task count" 1 (List.length restored.tasks);
      let agent = List.hd restored.agents in
      Alcotest.(check string) "agent name" "agent-1" agent.name;
      Alcotest.(check string) "agent_type" "worker" agent.agent_type;
      let task = List.hd restored.tasks in
      Alcotest.(check string) "task id" "task-001" task.id;
      Alcotest.(check int) "priority" 1 task.priority
  | Error e ->
      Alcotest.fail (Printf.sprintf "deserialization failed: %s" e)

let test_summary_json_structure () =
  let snap = dummy_snapshot () in
  let summary = Swarm_checkpoint.snapshot_summary_json snap in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "room" "test-room"
    (summary |> member "room_id" |> to_string);
  Alcotest.(check int) "total_tasks" 1
    (summary |> member "total_tasks" |> to_int);
  Alcotest.(check int) "active_agents" 1
    (summary |> member "active_agents" |> to_int)

let test_empty_snapshot () =
  let snap : Swarm_checkpoint.swarm_snapshot =
    { version = 1;
      saved_at = Types.now_iso ();
      room_id = "empty-room";
      agents = [];
      tasks = [];
      operations = [];
      goals = [];
      total_tasks = 0;
      done_tasks = 0;
      active_agents = 0;
    }
  in
  let json = Swarm_checkpoint.swarm_snapshot_to_yojson snap in
  match Swarm_checkpoint.swarm_snapshot_of_yojson json with
  | Ok restored ->
      Alcotest.(check string) "room_id" "empty-room" restored.room_id;
      Alcotest.(check int) "no agents" 0 (List.length restored.agents);
      Alcotest.(check int) "no tasks" 0 (List.length restored.tasks);
      Alcotest.(check int) "no goals" 0 (List.length restored.goals)
  | Error e ->
      Alcotest.fail (Printf.sprintf "empty snapshot deser failed: %s" e)

let test_goal_progress_roundtrip () =
  let gp = dummy_goal_progress () in
  let json = Swarm_checkpoint.goal_progress_to_yojson gp in
  match Swarm_checkpoint.goal_progress_of_yojson json with
  | Ok restored ->
      Alcotest.(check string) "goal_id" gp.goal_id restored.goal_id;
      Alcotest.(check string) "title" gp.title restored.title;
      Alcotest.(check (float 0.1)) "completion" gp.completion_pct restored.completion_pct
  | Error e ->
      Alcotest.fail (Printf.sprintf "goal_progress deser failed: %s" e)

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Alcotest.run "Swarm_checkpoint"
    [
      ( "serialization",
        [
          Alcotest.test_case "json round-trip" `Quick test_snapshot_json_roundtrip;
          Alcotest.test_case "summary structure" `Quick test_summary_json_structure;
          Alcotest.test_case "empty snapshot" `Quick test_empty_snapshot;
          Alcotest.test_case "goal progress round-trip" `Quick test_goal_progress_roundtrip;
        ] );
    ]
