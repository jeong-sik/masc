(** Tests for Client_registry_eio module *)

open Alcotest
open Masc

(* All tests must run within Eio context due to Eio.Mutex usage *)

let test_init () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Client_registry_eio.reset_for_testing ();
  check int "total count after reset is 0" 0 (Client_registry_eio.total_count ())

let test_sessionless_identity_is_not_registered () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Client_registry_eio.reset_for_testing ();
  let params = `Assoc [
    ("_agent_name", `String "test-new-agent");
    ("_channel", `String "telegram");
  ] in
  let identity = Client_registry_eio.get_or_create_identity params in
  check string "agent_name" "test-new-agent" identity.agent_name;
  check int "no lifecycle owner means no registry row" 0
    (Client_registry_eio.total_count ())

let test_mcp_session_persistence () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Client_registry_eio.reset_for_testing ();
  let mcp_sid = Printf.sprintf "test-mcp-session-%d" (Random.int 10000) in
  let params = `Assoc [("_agent_name", `String "session-agent")] in
  
  (* First call - creates identity *)
  let id1 = Client_registry_eio.get_or_create_identity ~mcp_session_id:mcp_sid params in
  
  (* Second call with same MCP session - should return same identity *)
  let id2 = Client_registry_eio.get_or_create_identity ~mcp_session_id:mcp_sid (`Assoc []) in
  
  check string "same session_key" id1.session_key id2.session_key

let test_total_count () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Client_registry_eio.reset_for_testing ();
  check int "empty registry" 0 (Client_registry_eio.total_count ());
  let name = "count-test-agent" in
  let _ = Client_registry_eio.get_or_create_identity
    ~mcp_session_id:"count-session"
    (`Assoc [("_agent_name", `String name)]) in
  check int "one registered identity" 1 (Client_registry_eio.total_count ())

let test_unregister_mcp_session_removes_identity () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Client_registry_eio.reset_for_testing ();
  let _ =
    Client_registry_eio.get_or_create_identity
      ~mcp_session_id:"closed-session"
      (`Assoc [ ("_agent_name", `String "closed-agent") ])
  in
  Client_registry_eio.unregister_mcp_session "closed-session";
  check int "closed session removed" 0 (Client_registry_eio.total_count ())

let test_unregister_preserves_same_name_sibling () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Client_registry_eio.reset_for_testing ();
  let params = `Assoc [ ("_agent_name", `String "shared-agent") ] in
  let first =
    Client_registry_eio.get_or_create_identity ~mcp_session_id:"shared-1" params
  in
  let second =
    Client_registry_eio.get_or_create_identity ~mcp_session_id:"shared-2" params
  in
  Client_registry_eio.unregister_mcp_session "shared-2";
  let remaining =
    Client_registry_eio.get_or_create_identity
      ~mcp_session_id:"shared-1"
      (`Assoc [])
  in
  check string "remaining session stays registered" first.session_key
    remaining.session_key;
  check int "one registration remains" 1 (Client_registry_eio.total_count ());
  check bool "removed session is distinct" true
    (not (String.equal second.session_key remaining.session_key))

let test_reset_clears_cached_session_mappings () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Client_registry_eio.reset_for_testing ();
  let sid = Printf.sprintf "reset-session-%d" (Random.int 10000) in
  let id1 =
    Client_registry_eio.get_or_create_identity ~mcp_session_id:sid
      (`Assoc [ ("_agent_name", `String "cached-agent") ])
  in
  Client_registry_eio.set_resolved_name sid "cached-agent" ~is_ephemeral:false;
  check
    (option (pair string bool))
    "resolved name set"
    (Some ("cached-agent", false))
    (Client_registry_eio.get_resolved_name sid);
  Client_registry_eio.reset_for_testing ();
  check
    (option (pair string bool))
    "resolved name cleared"
    None
    (Client_registry_eio.get_resolved_name sid);
  let id2 =
    Client_registry_eio.get_or_create_identity ~mcp_session_id:sid
      (`Assoc [ ("_agent_name", `String "cached-agent") ])
  in
  check bool "session mapping cleared by reset" true
    (id1.session_key <> id2.session_key)

let test_concurrent_access () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Client_registry_eio.reset_for_testing ();

  (* Simulate concurrent access *)
  Eio.Fiber.all (List.init 5 (fun i () ->
    let params = `Assoc [
      ("_agent_name", `String (Printf.sprintf "concurrent-agent-%d-%d" i (Random.int 10000)))
    ] in
    for _ = 1 to 10 do
      let _ = Client_registry_eio.get_or_create_identity params in
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
  Client_registry_eio.reset_for_testing ();
  let mcp_sid =
    Printf.sprintf "race-session-%d" (Random.int 1_000_000)
  in
  let collected : Client_identity.t list ref = ref [] in
  let collect_mu = Eio.Mutex.create () in
  Eio.Fiber.all (List.init 8 (fun _i () ->
    let params =
      `Assoc [("_agent_name", `String "racing-agent")]
    in
    let id =
      Client_registry_eio.get_or_create_identity ~mcp_session_id:mcp_sid params
    in
    Eio.Mutex.use_rw ~protect:true collect_mu (fun () ->
      collected := id :: !collected)));
  let keys =
    List.sort_uniq compare (List.map (fun id -> id.Client_identity.session_key)
                              !collected)
  in
  check int "all fibers converged to a single session_key" 1 (List.length keys);
  (* And the map-resolved identity is the same key. *)
  (match
     Client_registry_eio.get_or_create_identity ~mcp_session_id:mcp_sid
       (`Assoc [])
   with
   | id -> check (list string) "re-lookup returns the shared key" keys
             [id.session_key])

let () =
  run "Client_registry_eio" [
    "basics", [
      test_case "init" `Quick test_init;
      test_case
        "sessionless identity is not registered"
        `Quick
        test_sessionless_identity_is_not_registered;
      test_case "mcp_session_persistence" `Quick test_mcp_session_persistence;
    ];
    "statistics", [
      test_case "total_count" `Quick test_total_count;
      test_case
        "unregister_mcp_session removes identity"
        `Quick
        test_unregister_mcp_session_removes_identity;
      test_case
        "unregister preserves same-name sibling"
        `Quick
        test_unregister_preserves_same_name_sibling;
      test_case "reset_clears_cached_session_mappings" `Quick
        test_reset_clears_cached_session_mappings;
    ];
    "concurrency", [
      test_case "concurrent_access" `Quick test_concurrent_access;
      test_case "concurrent_same_mcp_session_id" `Quick
        test_concurrent_same_mcp_session_id;
    ];
  ]
