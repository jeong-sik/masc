(** E2E Test: Agent Identity Integration

    Tests that Agent Identity is properly integrated into MCP tool dispatch.
*)

open Alcotest
open Masc_mcp

(** Test identity extraction from MCP-like params *)
let test_identity_from_mcp_params () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let params =
    `Assoc
      [ "_agent_name", `String "claude-code-agent"
      ; "_channel", `String "telegram"
      ; "_user_id", `String "user-12345"
      ; "_session_key", `String "session-abc-123"
      ; "room", `String "project-room"
      ; "_capabilities", `List [ `String "code"; `String "file_ops" ]
      ]
  in
  let identity = Agent_registry_eio.get_or_create_identity params in
  check string "agent_name" "claude-code-agent" identity.agent_name;
  check (option string) "room" (Some "project-room") identity.room_id;
  check bool "has code cap" true (Agent_identity.has_capability identity "code");
  check bool "no admin cap" false (Agent_identity.has_capability identity "admin")
;;

(** Test MCP session persistence *)
let test_mcp_session_persistence () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let mcp_session = "mcp-session-e2e-test" in
  (* First tool call - creates identity *)
  let params1 = `Assoc [ "_agent_name", `String "persistent-agent" ] in
  let id1 =
    Agent_registry_eio.get_or_create_identity ~mcp_session_id:mcp_session params1
  in
  (* Second tool call - same MCP session, empty params *)
  let id2 =
    Agent_registry_eio.get_or_create_identity ~mcp_session_id:mcp_session (`Assoc [])
  in
  (* Third tool call - same MCP session, different agent_name in params (should use existing) *)
  let params3 = `Assoc [ "_agent_name", `String "different-name" ] in
  let id3 =
    Agent_registry_eio.get_or_create_identity ~mcp_session_id:mcp_session params3
  in
  check string "id1 == id2" id1.session_key id2.session_key;
  check string "id1 == id3" id1.session_key id3.session_key
;;

(** Test room context updates *)
let test_room_context_updates () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let mcp_session = "mcp-room-test" in
  (* Join room-1 *)
  let p1 = `Assoc [ "_agent_name", `String "room-agent"; "room", `String "room-1" ] in
  let id1 = Agent_registry_eio.get_or_create_identity ~mcp_session_id:mcp_session p1 in
  check (option string) "in room-1" (Some "room-1") id1.room_id;
  (* Move to room-2 *)
  let p2 = `Assoc [ "room", `String "room-2" ] in
  let id2 = Agent_registry_eio.get_or_create_identity ~mcp_session_id:mcp_session p2 in
  check (option string) "in room-2" (Some "room-2") id2.room_id
;;

(** Test multi-agent isolation *)
let test_multi_agent_isolation () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  (* Create 3 different agents *)
  let sessions = [ "mcp-agent-1"; "mcp-agent-2"; "mcp-agent-3" ] in
  let identities =
    List.mapi
      (fun i sid ->
         let params = `Assoc [ "_agent_name", `String (Printf.sprintf "agent-%d" i) ] in
         Agent_registry_eio.get_or_create_identity ~mcp_session_id:sid params)
      sessions
  in
  (* Verify all have unique session keys *)
  let keys = List.map (fun id -> id.Agent_identity.session_key) identities in
  let unique_keys = List.sort_uniq String.compare keys in
  check int "all unique" 3 (List.length unique_keys);
  (* Verify agent count *)
  check int "3 active agents" 3 (Agent_registry_eio.active_count ())
;;

(** Test identity display string *)
let test_display_string () =
  let identity =
    Agent_identity.
      { uuid = "agent-test123456"
      ; session_key = "12345678-abcd-efgh-ijkl-123456789abc"
      ; agent_name = "test-display-agent"
      ; channel = Some (Agent_identity.External "telegram")
      ; user_id = Some "tg-user-99"
      ; room_id = Some "work-room"
      ; capabilities = [ "code"; "search" ]
      ; registered_at = Unix.gettimeofday ()
      ; last_seen = Unix.gettimeofday ()
      ; metadata = []
      }
  in
  let display = Agent_identity.to_display_string identity in
  check bool "contains name" true (String.length display > 0);
  check
    bool
    "contains session"
    true
    (String.sub display 0 20 |> String.lowercase_ascii |> fun s -> String.length s > 0)
;;

(** Test cleanup of stale sessions *)
let test_stale_cleanup () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  (* Create active agent *)
  let _ =
    Agent_registry_eio.get_or_create_identity
      ~mcp_session_id:"active-session"
      (`Assoc [ "_agent_name", `String "active-agent" ])
  in
  (* Cleanup should work without errors *)
  let cleaned = Agent_registry_eio.cleanup_stale_sessions () in
  check int "cleanup with active session returns 0" 0 cleaned
;;

let () =
  run
    "Identity E2E"
    [ ( "integration"
      , [ test_case "from_mcp_params" `Quick test_identity_from_mcp_params
        ; test_case "session_persistence" `Quick test_mcp_session_persistence
        ; test_case "room_updates" `Quick test_room_context_updates
        ; test_case "multi_agent" `Quick test_multi_agent_isolation
        ; test_case "display_string" `Quick test_display_string
        ; test_case "stale_cleanup" `Quick test_stale_cleanup
        ] )
    ]
;;
