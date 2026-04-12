(** Tests for Agent_registry_eio module *)

open Alcotest
open Masc_mcp

(* All tests must run within Eio context due to Eio.Mutex usage *)

let test_init () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  check int "total count after reset is 0" 0 (Agent_registry_eio.total_count ())

let test_get_or_create_new () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let params = `Assoc [
    ("_agent_name", `String "test-new-agent");
    ("_channel", `String "telegram");
    ("room", `String "test-room");
  ] in
  let identity = Agent_registry_eio.get_or_create_identity params in
  check string "agent_name" "test-new-agent" identity.agent_name;
  check (option string) "room_id" (Some "test-room") identity.room_id

let test_get_or_create_existing () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let params = `Assoc [("_agent_name", `String "existing-agent")] in
  let id1 = Agent_registry_eio.get_or_create_identity params in
  let id2 = Agent_registry_eio.get_or_create_identity params in
  (* Same agent_name should be used *)
  check string "same agent_name" id1.agent_name id2.agent_name

let test_mcp_session_persistence () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let mcp_sid = Printf.sprintf "test-mcp-session-%d" (Random.int 10000) in
  let params = `Assoc [("_agent_name", `String "session-agent")] in
  
  (* First call - creates identity *)
  let id1 = Agent_registry_eio.get_or_create_identity ~mcp_session_id:mcp_sid params in
  
  (* Second call with same MCP session - should return same identity *)
  let id2 = Agent_registry_eio.get_or_create_identity ~mcp_session_id:mcp_sid (`Assoc []) in
  
  check string "same session_key" id1.session_key id2.session_key

let test_get_by_name () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let name = Printf.sprintf "lookup-agent-%d" (Random.int 10000) in
  let params = `Assoc [("_agent_name", `String name)] in
  let created = Agent_registry_eio.get_or_create_identity params in
  
  match Agent_registry_eio.get_by_name name with
  | Some found -> check string "same agent" created.agent_name found.agent_name
  | None -> fail "agent not found by name"

let test_active_count () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let initial = Agent_registry_eio.active_count () in
  
  (* Create a new agent with unique name *)
  let name = Printf.sprintf "count-test-agent-%d" (Random.int 10000) in
  let _ = Agent_registry_eio.get_or_create_identity 
    (`Assoc [("_agent_name", `String name)]) in
  
  let after = Agent_registry_eio.active_count () in
  check bool "count increased" true (after >= initial)

let test_list_active () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let name = Printf.sprintf "active-list-agent-%d" (Random.int 10000) in
  let _ = Agent_registry_eio.get_or_create_identity 
    (`Assoc [("_agent_name", `String name)]) in
  
  let active = Agent_registry_eio.list_active () in
  check bool "has active agents" true (List.length active > 0)

let test_cleanup_stale () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  (* After reset, no sessions exist so cleanup should return 0 *)
  let cleaned = Agent_registry_eio.cleanup_stale_sessions () in
  check int "cleanup after reset returns 0" 0 cleaned

let test_reset_clears_cached_session_mappings () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let sid = Printf.sprintf "reset-session-%d" (Random.int 10000) in
  let id1 =
    Agent_registry_eio.get_or_create_identity ~mcp_session_id:sid
      (`Assoc [ ("_agent_name", `String "cached-agent") ])
  in
  Agent_registry_eio.set_resolved_name sid "cached-agent";
  check (option string) "resolved name set" (Some "cached-agent")
    (Agent_registry_eio.get_resolved_name sid);
  Agent_registry_eio.reset_for_testing ();
  check (option string) "resolved name cleared" None
    (Agent_registry_eio.get_resolved_name sid);
  let id2 =
    Agent_registry_eio.get_or_create_identity ~mcp_session_id:sid
      (`Assoc [ ("_agent_name", `String "cached-agent") ])
  in
  check bool "session mapping cleared by reset" true
    (id1.session_key <> id2.session_key)

let test_concurrent_access () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();

  (* Simulate concurrent access *)
  Eio.Fiber.all (List.init 5 (fun i () ->
    let params = `Assoc [
      ("_agent_name", `String (Printf.sprintf "concurrent-agent-%d-%d" i (Random.int 10000)))
    ] in
    for _ = 1 to 10 do
      let _ = Agent_registry_eio.get_or_create_identity params in
      Eio.Fiber.yield ()
    done
  ));

  ()

(** Contract: N fibers racing to create an identity for the same
    [mcp_session_id] must converge to a single [session_key].  This
    is asserted even though under single-domain Eio with uncontended
    Registry locks, [get_or_create_identity] currently executes
    atomically and the race would not fire without the
    double-checked locking fix.  The test defends the invariant
    against future changes — a migration to multi-domain, a refactor
    that introduces a yield between [Hashtbl.find_opt] and
    [Hashtbl.replace], or Registry contention that forces
    [reg.lock] to suspend — any of which would otherwise orphan the
    first-seen identity because both fibers would observe [None] in
    [session_identity_map], both [Registry.register] with a fresh
    UUID [session_key], and only the last [Hashtbl.replace] would
    win.  See lib/agent_registry_eio.ml [session_cache_mu] comment. *)
let test_concurrent_same_mcp_session_id () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let mcp_sid =
    Printf.sprintf "race-session-%d" (Random.int 1_000_000)
  in
  let collected : Agent_identity.t list ref = ref [] in
  let collect_mu = Eio.Mutex.create () in
  Eio.Fiber.all (List.init 8 (fun _i () ->
    let params =
      `Assoc [("_agent_name", `String "racing-agent")]
    in
    let id =
      Agent_registry_eio.get_or_create_identity ~mcp_session_id:mcp_sid params
    in
    Eio.Mutex.use_rw ~protect:true collect_mu (fun () ->
      collected := id :: !collected)));
  let keys =
    List.sort_uniq compare (List.map (fun id -> id.Agent_identity.session_key)
                              !collected)
  in
  check int "all fibers converged to a single session_key" 1 (List.length keys);
  (* And the map-resolved identity is the same key. *)
  (match
     Agent_registry_eio.get_or_create_identity ~mcp_session_id:mcp_sid
       (`Assoc [])
   with
   | id -> check (list string) "re-lookup returns the shared key" keys
             [id.session_key])

let () =
  run "Agent_registry_eio" [
    "basics", [
      test_case "init" `Quick test_init;
      test_case "get_or_create_new" `Quick test_get_or_create_new;
      test_case "get_or_create_existing" `Quick test_get_or_create_existing;
      test_case "mcp_session_persistence" `Quick test_mcp_session_persistence;
      test_case "get_by_name" `Quick test_get_by_name;
    ];
    "statistics", [
      test_case "active_count" `Quick test_active_count;
      test_case "list_active" `Quick test_list_active;
      test_case "cleanup_stale" `Quick test_cleanup_stale;
      test_case "reset_clears_cached_session_mappings" `Quick
        test_reset_clears_cached_session_mappings;
    ];
    "concurrency", [
      test_case "concurrent_access" `Quick test_concurrent_access;
      test_case "concurrent_same_mcp_session_id" `Quick
        test_concurrent_same_mcp_session_id;
    ];
  ]
