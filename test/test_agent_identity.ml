(** Tests for Agent_identity module *)

open Alcotest
open Masc_mcp
open Types_core

let test_generate_session_key () =
  let key1 = Agent_identity.generate_session_key () in
  let key2 = Agent_identity.generate_session_key () in
  check bool "keys are different" true (key1 <> key2);
  check bool "key length >= 32" true (String.length key1 >= 32)

let test_from_agent_name () =
  let identity = Agent_identity.from_agent_name "test-agent" in
  check string "agent_name matches" "test-agent" identity.agent_name;
  check bool "session_key generated" true (String.length identity.session_key > 0);
  check (option (module struct
    type t = Agent_identity.channel
    let pp = Fmt.nop
    let equal _ _ = true
  end)) "channel is None" None identity.channel

let test_from_mcp_params () =
  let params = `Assoc [
    ("_agent_name", `String "mcp-agent-001");
    ("_channel", `String "telegram");
    ("_user_id", `String "12345");
    ("room", `String "test-room");
    ("_capabilities", `List [`String "code"; `String "search"]);
  ] in
  let identity = Agent_identity.from_mcp_params params in
  check string "agent_name" "mcp-agent-001" identity.agent_name;
  check (option string) "user_id" (Some "12345") identity.user_id;
  check (option string) "room_id" (Some "test-room") identity.room_id;
  check int "capabilities count" 2 (List.length identity.capabilities);
  check bool "has code capability" true (Agent_identity.has_capability identity "code")

let test_from_mcp_params_minimal () =
  let params = `Assoc [] in
  let identity = Agent_identity.from_mcp_params params in
  check bool "agent_name starts with agent-" true 
    (String.sub identity.agent_name 0 6 = "agent-");
  check bool "session_key generated" true (String.length identity.session_key > 0)

let test_from_mcp_params_empty_session_key () =
  let params = `Assoc [("_session_key", `String "")] in
  let identity = Agent_identity.from_mcp_params params in
  check bool "empty session_key is regenerated" true
    (String.length identity.session_key > 0);
  check bool "regenerated session agent_name starts with agent-" true
    (String.sub identity.agent_name 0 6 = "agent-")

let test_from_mcp_params_blank_session_key () =
  let params = `Assoc [("_session_key", `String "   ")] in
  let identity = Agent_identity.from_mcp_params params in
  check bool "blank session_key is regenerated" true
    (String.length identity.session_key > 0);
  check bool "regenerated blank session agent_name starts with agent-" true
    (String.sub identity.agent_name 0 6 = "agent-")

let test_from_mcp_params_short_session_key () =
  let params = `Assoc [("_session_key", `String "abc")] in
  let identity = Agent_identity.from_mcp_params params in
  check string "short session_key uses full key"
    "agent-abc" identity.agent_name

let test_from_mcp_params_long_session_key_prefix () =
  let params = `Assoc [("_session_key", `String "abcdefghijk")] in
  let identity = Agent_identity.from_mcp_params params in
  check string "long session_key trimmed to 8 chars"
    "agent-abcdefgh" identity.agent_name

let test_anonymous () =
  let identity = Agent_identity.anonymous () in
  check bool "agent_name starts with anon-" true
    (String.sub identity.agent_name 0 5 = "anon-")

let test_channel_roundtrip () =
  let channels = [
    Agent_identity.External "telegram";
    Agent_identity.External "discord";
    Agent_identity.External "slack";
    Agent_identity.External "signal";
    Agent_identity.External "webchat";
    Agent_identity.Api;
    Agent_identity.Internal;
    Agent_identity.External "custom";
  ] in
  List.iter (fun ch ->
    let str = Agent_identity.string_of_channel ch in
    let back = Agent_identity.channel_of_string str in
    check bool (Printf.sprintf "roundtrip for %s" str) true 
      (Agent_identity.string_of_channel back = str)
  ) channels

let test_channel_normalization () =
  let normalize channel =
    Agent_identity.channel_of_string channel |> Agent_identity.string_of_channel
  in
  check string "trim + lowercase external" "discord"
    (normalize "  DisCord  ");
  check string "blank becomes unknown" "unknown"
    (normalize "   ");
  check string "api normalized" "api"
    (normalize "  API  ");
  check string "internal normalized" "internal"
    (normalize "  INTERNAL  ");
  check string "external stringified as normalized label" "slack"
    (Agent_identity.string_of_channel (Agent_identity.External "  SlAck "));
  match Agent_identity.channel_of_string "  DisCord  " with
  | Agent_identity.External "discord" -> ()
  | _ -> fail "expected normalized opaque external channel"

let test_channel_yojson_backward_compat () =
  check (result string string) "legacy Discord string decodes"
    (Ok "discord")
    (match Agent_identity.channel_of_yojson (`String "Discord") with
     | Ok channel -> Ok (Agent_identity.string_of_channel channel)
     | Error err -> Error err);
  check (result string string) "tagged external Discord decodes"
    (Ok "discord")
    (match Agent_identity.channel_of_yojson
             (`List [ `String "External"; `String "discord" ])
     with
     | Ok channel -> Ok (Agent_identity.string_of_channel channel)
     | Error err -> Error err);
  check string "known external serializes as tagged external"
    "[\"External\",\"discord\"]"
    (Yojson.Safe.to_string
       (Agent_identity.channel_to_yojson (Agent_identity.External "DisCord")));
  check string "unknown external serializes as tagged external"
    "[\"External\",\"custom-edge\"]"
    (Yojson.Safe.to_string
       (Agent_identity.channel_to_yojson
          (Agent_identity.External "  Custom-Edge  ")))

let test_same_agent () =
  let id1 = Agent_identity.from_agent_name "agent-a" in
  let id2 = { id1 with Agent_identity.last_seen = Unix.gettimeofday () +. 100.0 } in
  let id3 = Agent_identity.from_agent_name "agent-a" in
  let id4 = Agent_identity.from_agent_name "agent-b" in
  check bool "same session_key" true (Agent_identity.same_agent id1 id2);
  check bool "same agent_name" true (Agent_identity.same_agent id1 id3);
  check bool "different agents" false (Agent_identity.same_agent id1 id4)

let str_contains haystack needle =
  let len_h = String.length haystack in
  let len_n = String.length needle in
  if len_n > len_h then false
  else
    let rec check i =
      if i > len_h - len_n then false
      else if String.sub haystack i len_n = needle then true
      else check (i + 1)
    in check 0

let test_to_display_string () =
  let identity = Agent_identity.({
    uuid = "agent-test123456"; session_key = "12345678-1234-1234-1234-123456789abc";
    agent_name = "test-agent";
    channel = Some (Agent_identity.External "telegram");
    user_id = Some "user123";
    room_id = Some "room-a";
    capabilities = [];
    registered_at = 0.0;
    last_seen = 0.0;
    metadata = [];
  }) in
  let display = Agent_identity.to_display_string identity in
  check bool "contains agent_name" true (String.length display > 0);
  check bool "contains channel" true (str_contains (String.lowercase_ascii display) "telegram")

let test_to_display_string_empty_session_key () =
  let identity = Agent_identity.({
    uuid = "agent-emptykey";
    session_key = "";
    agent_name = "empty-key-agent";
    channel = Some Agent_identity.Api;
    user_id = None;
    room_id = None;
    capabilities = [];
    registered_at = 0.0;
    last_seen = 0.0;
    metadata = [];
  }) in
  let display = Agent_identity.to_display_string identity in
  check bool "empty session key display uses unknown prefix" true
    (str_contains display "(unknown)")

(** Registry tests *)
module RegistryTests = struct
  (* Note: These tests require Eio runtime, run with test_integration *)
  
  let test_register_and_find () =
    Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
    let reg = Agent_identity.Registry.create () in
    let identity = Agent_identity.from_agent_name "test-agent" in
    let _ = Agent_identity.Registry.register reg identity in
    
    let found_by_session = Agent_identity.Registry.find_by_session reg identity.session_key in
    check bool "found by session" true (Option.is_some found_by_session);
    
    let found_by_name = Agent_identity.Registry.find_by_name reg "test-agent" in
    check bool "found by name" true (Option.is_some found_by_name)

  let test_unregister () =
    Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
    let reg = Agent_identity.Registry.create () in
    let identity = Agent_identity.from_agent_name "test-agent" in
    let registered = Agent_identity.Registry.register reg identity in
    
    check int "count after register" 1 (Agent_identity.Registry.count reg);
    Agent_identity.Registry.unregister reg registered.session_key;
    check int "count after unregister" 0 (Agent_identity.Registry.count reg)

  let test_touch () =
    Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
    let reg = Agent_identity.Registry.create () in
    (* Create identity with old timestamp *)
    let old_time = Unix.gettimeofday () -. 10.0 in
    let identity = Agent_identity.({
      (from_agent_name "test-agent") with
      last_seen = old_time;
      registered_at = old_time;
    }) in
    let _ = Agent_identity.Registry.register reg identity in
    
    Agent_identity.Registry.touch reg identity.session_key ~room_id:"new-room" ();
    
    match Agent_identity.Registry.find_by_session reg identity.session_key with
    | Some updated ->
        check bool "last_seen updated" true (updated.last_seen > old_time);
        check (option string) "room_id updated" (Some "new-room") updated.room_id
    | None -> fail "identity not found after touch"

  let test_list_active () =
    Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
    let reg = Agent_identity.Registry.create () in
    let id1 = Agent_identity.from_agent_name "active-agent" in
    let id2 = Agent_identity.({
      (from_agent_name "stale-agent") with
      last_seen = Unix.gettimeofday () -. 1000.0;
      registered_at = Unix.gettimeofday () -. 1000.0;
    }) in
    
    let _ = Agent_identity.Registry.register reg id1 in
    let _ = Agent_identity.Registry.register reg id2 in
    
    let active = Agent_identity.Registry.list_active reg ~within_seconds:60.0 in
    check int "only active agents" 1 (List.length active);
    check string "active agent name" "active-agent" (List.hd active).agent_name
end

let () =
  run "Agent_identity" [
    "basics", [
      test_case "generate_session_key" `Quick test_generate_session_key;
      test_case "from_agent_name" `Quick test_from_agent_name;
      test_case "from_mcp_params" `Quick test_from_mcp_params;
      test_case "from_mcp_params_minimal" `Quick test_from_mcp_params_minimal;
      test_case "from_mcp_params_empty_session_key" `Quick test_from_mcp_params_empty_session_key;
      test_case "from_mcp_params_blank_session_key" `Quick test_from_mcp_params_blank_session_key;
      test_case "from_mcp_params_short_session_key" `Quick test_from_mcp_params_short_session_key;
      test_case "from_mcp_params_long_session_key_prefix" `Quick test_from_mcp_params_long_session_key_prefix;
      test_case "anonymous" `Quick test_anonymous;
      test_case "channel_roundtrip" `Quick test_channel_roundtrip;
      test_case "channel_normalization" `Quick test_channel_normalization;
      test_case "channel_yojson_backward_compat" `Quick
        test_channel_yojson_backward_compat;
      test_case "same_agent" `Quick test_same_agent;
      test_case "to_display_string" `Quick test_to_display_string;
      test_case "to_display_string_empty_session_key" `Quick test_to_display_string_empty_session_key;
    ];
    "registry", [
      test_case "register_and_find" `Quick RegistryTests.test_register_and_find;
      test_case "unregister" `Quick RegistryTests.test_unregister;
      test_case "touch" `Quick RegistryTests.test_touch;
      test_case "list_active" `Quick RegistryTests.test_list_active;
    ];
  ]
