(** Concurrency Stress Tests for MASC

    Tests concurrent access patterns with 20+ agents:
    1. Session lock contention
    2. Cancellation token race conditions
    3. Zombie detection under load

    Phase 4.1 of MCP Unify project.
*)

open Alcotest

module Session = Masc_mcp.Session
module Types = Types
module Env_config = Env_config

let num_agents = 20
let iterations_per_agent = 100

(** Generate agent names *)
let agent_names =
  List.init num_agents (fun i -> Printf.sprintf "agent-%02d" i)

(** {1 Session Lock Stress Tests} *)

let test_session_lock_contention () =
  Eio_main.run @@ fun _ ->
  let registry = Session.create () in

  (* Register all agents *)
  List.iter (fun name ->
    ignore (Session.register registry ~agent_name:name)
  ) agent_names;

  (* Concurrent activity updates and rate limit checks *)
  let worker agent_name =
    for _ = 1 to iterations_per_agent do
      Session.update_activity registry ~agent_name ();
      ignore (Session.check_rate_limit_ex registry ~agent_name
                ~category:Types.GeneralLimit ~role:Types.Worker);
    done
  in

  (* Run all agents concurrently *)
  Eio.Fiber.all (List.map (fun name -> fun () -> worker name) agent_names);

  (* Verify all agents still connected *)
  let connected = Session.connected_agents registry in
  check int "all agents connected" num_agents (List.length connected);

  (* Verify no negative rate limits *)
  List.iter (fun name ->
    let status =
      Session.get_rate_limit_status registry ~agent_name:name ~role:Types.Worker
    in
    let open Yojson.Safe.Util in
    let burst_remaining = status |> member "burst_remaining" |> to_int in
    check bool (Printf.sprintf "%s burst >= 0" name) true (burst_remaining >= 0)
  ) agent_names

let test_session_concurrent_register_unregister () =
  Eio_main.run @@ fun _ ->
  let registry = Session.create () in
  let success_count = Atomic.make 0 in

  (* Half agents register, half unregister repeatedly *)
  let worker i =
    let name = Printf.sprintf "temp-agent-%02d" i in
    for _ = 1 to iterations_per_agent / 2 do
      ignore (Session.register registry ~agent_name:name);
      Session.unregister registry ~agent_name:name;
      Atomic.incr success_count
    done
  in

  Eio.Fiber.all (List.init num_agents (fun i -> fun () -> worker i));

  let total = Atomic.get success_count in
  check bool "completed iterations" true (total > 0);
  Printf.printf "Completed %d register/unregister cycles\n%!" total

(** {1 Cancellation Token Stress Tests} *)

(* [test_cancellation_token_race] / [test_cancellation_cleanup_under_load]
   removed 2026-05-05 — exercised the [Cancellation.TokenStore] surface
   that was archived. See docs/audit-responses/2026-05-05-dashboard-heuristic.md §5.1. *)

(** {1 Zombie Detection Under Load} *)


let test_zombie_detection_concurrent () =
  Eio_main.run @@ fun _ ->
  (* Generate ISO timestamps for testing *)
  let now = Unix.gettimeofday () in
  let fresh_time = Unix.(gmtime now |> fun t ->
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
      t.tm_hour t.tm_min t.tm_sec) in
  let stale_time = Unix.(gmtime (now -. 600.0) |> fun t ->  (* 10 min ago *)
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
      t.tm_hour t.tm_min t.tm_sec) in

  let zombie_checks = Atomic.make 0 in
  let fresh_checks = Atomic.make 0 in

  (* Concurrent zombie/fresh checks *)
  let checker () =
    for _ = 1 to 100 do
      if Coord_resilience.Zombie.is_zombie stale_time then
        Atomic.incr zombie_checks;
      if not (Coord_resilience.Zombie.is_zombie fresh_time) then
        Atomic.incr fresh_checks
    done
  in

  Eio.Fiber.all [checker; checker; checker; checker];

  let zombies = Atomic.get zombie_checks in
  let fresh = Atomic.get fresh_checks in
  Printf.printf "Zombie checks: %d, Fresh checks: %d\n%!" zombies fresh;
  check bool "stale timestamps detected as zombies" true (zombies = 400);
  check bool "fresh timestamps not zombies" true (fresh = 400)

(** {1 Test Suite} *)

let () =
  run "Concurrency_stress" [
    "session_lock", [
      test_case "lock contention (20 agents)" `Slow test_session_lock_contention;
      test_case "register/unregister race" `Slow test_session_concurrent_register_unregister;
    ];
    "zombie", [
      test_case "concurrent detection" `Quick test_zombie_detection_concurrent;
    ];
  ]
