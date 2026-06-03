(** Integration Test: Full MCP Cycle

    Tests the complete flow: Agent → MCP Server → Tool → Response
    Verifies agent identity preservation throughout the cycle.

    @since 0.5.0
*)

open Alcotest
open Masc

(** Test fixtures *)
module Fixtures = struct
  let make_identity_params ~agent_name =
    `Assoc [
      ("agent_name", `String agent_name);
      ("_agent_name", `String agent_name);
      ("_channel", `String "internal");
    ]

  let identity_for ?session_key agent_name =
    let session_key =
      match session_key with
      | Some value -> value
      | None -> "session-" ^ agent_name
    in
    Client_identity.from_mcp_params
      (`Assoc
        [
          ("_agent_name", `String agent_name);
          ("_session_key", `String session_key);
        ])
end

(** Test: Agent identity extracted from MCP params *)
let test_identity_extraction () =
  let params = Fixtures.make_identity_params ~agent_name:"integration-agent" in
  let args = Yojson.Safe.Util.(params |> member "arguments" |> function `Null -> params | x -> x) in
  let identity = Client_identity.from_mcp_params args in
  
  check string "agent_name extracted" "integration-agent" identity.agent_name;
  match identity.channel with
  | Some Client_identity.Internal -> ()
  | _ -> fail "expected Internal channel"

(** Test: Agent identity persists in registry *)
let test_identity_registry_persistence () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let reg = Client_identity.Registry.create () in
  
  (* First call - register agent *)
  let id1 = Fixtures.identity_for "persistent-agent" in
  let registered = Client_identity.Registry.register reg id1 in
  
  (* Simulate second call - should find existing *)
  let found = Client_identity.Registry.find_by_name reg "persistent-agent" in
  match found with
  | Some id2 ->
      check string "same session_key" registered.session_key id2.session_key;
      check bool "same agent" true (Client_identity.same_agent registered id2)
  | None -> fail "identity not found in registry"

(** Test: Multi-agent scenario - identities don't collide *)
let test_multi_agent_isolation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let reg = Client_identity.Registry.create () in
  
  let agents = ["agent-a"; "agent-b"; "agent-c"] in
  let identities = List.map (fun name ->
    Client_identity.Registry.register reg (Fixtures.identity_for name)
  ) agents in
  
  (* Verify all agents have unique session keys *)
  let session_keys = List.map (fun id -> id.Client_identity.session_key) identities in
  let unique_keys = List.sort_uniq String.compare session_keys in
  check int "all keys unique" 3 (List.length unique_keys);
  
  (* Verify each can be found by name *)
  List.iter (fun name ->
    match Client_identity.Registry.find_by_name reg name with
    | Some id -> check string "correct name" name id.agent_name
    | None -> fail (Printf.sprintf "agent %s not found" name)
  ) agents

(** Test: Capability filtering *)
let test_capability_filtering () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let reg = Client_identity.Registry.create () in
  
  let params_with_caps = `Assoc [
    ("_agent_name", `String "capable-agent");
    ("_capabilities", `List [`String "code"; `String "search"; `String "file_ops"]);
  ] in
  let id = Client_identity.from_mcp_params params_with_caps in
  let _ = Client_identity.Registry.register reg id in
  
  check bool "has code" true (Client_identity.has_capability id "code");
  check bool "has search" true (Client_identity.has_capability id "search");
  check bool "no admin" false (Client_identity.has_capability id "admin")

(** Test: Stale agent cleanup *)
let test_stale_agent_cleanup () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let reg = Client_identity.Registry.create () in
  
  (* Active agent *)
  let active = Fixtures.identity_for "active-agent" in
  let _ = Client_identity.Registry.register reg active in
  
  (* Stale agent (last_seen in the past) *)
  let stale = Client_identity.({
    (Fixtures.identity_for "stale-agent") with
    last_seen = Unix.gettimeofday () -. 3600.0;  (* 1 hour ago *)
  }) in
  let _ = Client_identity.Registry.register reg stale in
  
  check int "total count" 2 (Client_identity.Registry.count reg);
  
  let active_list = Client_identity.Registry.list_active reg ~within_seconds:60.0 in
  check int "active count" 1 (List.length active_list);
  check string "active is correct" "active-agent" (List.hd active_list).agent_name

(** Test: Concurrent registration safety *)
let test_concurrent_registration () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let reg = Client_identity.Registry.create () in
  
  (* Spawn multiple fibers registering agents *)
  Eio.Fiber.all (List.init 10 (fun i () ->
    let name = Printf.sprintf "concurrent-agent-%d" i in
    let id = Fixtures.identity_for name in
    let _ = Client_identity.Registry.register reg id in
    (* Touch a few times *)
    for _ = 1 to 5 do
      Client_identity.Registry.touch reg id.session_key ();
      Eio.Fiber.yield ()
    done
  ));
  
  check int "all registered" 10 (Client_identity.Registry.count reg)

(** Test: Session key stability across updates *)
let test_session_key_stability () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let reg = Client_identity.Registry.create () in
  
  let id = Fixtures.identity_for "stable-agent" in
  let original_key = id.session_key in
  let _ = Client_identity.Registry.register reg id in
  
  (* Multiple touches keep the session stable. *)
  Client_identity.Registry.touch reg original_key ();
  
  match Client_identity.Registry.find_by_session reg original_key with
  | Some updated ->
      check string "session_key unchanged" original_key updated.session_key
  | None -> fail "identity lost"

let () =
  run "MCP Full Cycle" [
    "identity", [
      test_case "extraction" `Quick test_identity_extraction;
      test_case "registry_persistence" `Quick test_identity_registry_persistence;
      test_case "multi_agent_isolation" `Quick test_multi_agent_isolation;
      test_case "capability_filtering" `Quick test_capability_filtering;
    ];
    "lifecycle", [
      test_case "stale_cleanup" `Quick test_stale_agent_cleanup;
      test_case "concurrent_registration" `Quick test_concurrent_registration;
      test_case "session_key_stability" `Quick test_session_key_stability;
    ];
  ]
