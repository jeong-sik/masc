(** Tests for Client_identity module *)

open Alcotest
open Masc
open Types_core

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

let test_generate_session_key () =
  let key1 = Client_identity.generate_session_key () in
  let key2 = Client_identity.generate_session_key () in
  check bool "keys are different" true (key1 <> key2);
  check bool "key length >= 32" true (String.length key1 >= 32)

let test_generate_uuid_is_uuid_v7 () =
  let uuid = Client_identity.generate_uuid ~agent_name:"display-only" in
  check int "canonical length" 36 (String.length uuid);
  check char "version 7" '7' uuid.[14];
  match Uuidm.of_string uuid with
  | Some parsed ->
    check int "Uuidm version" 7 (Uuidm.version parsed);
    check bool "RFC variant" true
      (Uuidm.variant parsed >= 8 && Uuidm.variant parsed <= 11)
  | None -> fail "expected Uuidm to parse generated UUID"

let test_from_mcp_params () =
  let params = `Assoc [
    ("_agent_name", `String "mcp-agent-001");
    ("_channel", `String "telegram");
    ("_user_id", `String "12345");
    ("_capabilities", `List [`String "code"; `String "search"]);
  ] in
  let identity = Client_identity.from_mcp_params params in
  check string "agent_name" "mcp-agent-001" identity.agent_name;
  check (option string) "user_id" (Some "12345") identity.user_id;
  check int "capabilities count" 2 (List.length identity.capabilities);
  check bool "has code capability" true (Client_identity.has_capability identity "code")

let test_from_mcp_params_minimal () =
  let params = `Assoc [] in
  let identity = Client_identity.from_mcp_params params in
  check bool "agent_name starts with agent-" true 
    (String.sub identity.agent_name 0 6 = "agent-");
  check bool "session_key generated" true (String.length identity.session_key > 0)

let test_generated_fallback_agent_names_are_distinct () =
  let first = Client_identity.from_mcp_params (`Assoc []) in
  let second = Client_identity.from_mcp_params (`Assoc []) in
  check bool "fallback names do not share a timestamp prefix" true
    (first.agent_name <> second.agent_name)

let test_from_mcp_params_empty_session_key () =
  let params = `Assoc [("_session_key", `String "")] in
  let identity = Client_identity.from_mcp_params params in
  check bool "empty session_key is regenerated" true
    (String.length identity.session_key > 0);
  check bool "regenerated session agent_name starts with agent-" true
    (String.sub identity.agent_name 0 6 = "agent-")

let test_from_mcp_params_blank_session_key () =
  let params = `Assoc [("_session_key", `String "   ")] in
  let identity = Client_identity.from_mcp_params params in
  check bool "blank session_key is regenerated" true
    (String.length identity.session_key > 0);
  check bool "regenerated blank session agent_name starts with agent-" true
    (String.sub identity.agent_name 0 6 = "agent-")

let test_from_mcp_params_short_session_key () =
  let params = `Assoc [("_session_key", `String "abc")] in
  let identity = Client_identity.from_mcp_params params in
  check string "short session_key uses full key"
    "agent-abc" identity.agent_name

let test_from_mcp_params_long_session_key_prefix () =
  let params = `Assoc [("_session_key", `String "abcdefghijk")] in
  let identity = Client_identity.from_mcp_params params in
  check string "long session_key trimmed to 8 chars"
    "agent-abcdefgh" identity.agent_name

let test_anonymous () =
  let identity = Client_identity.anonymous () in
  check bool "agent_name starts with anon-" true
    (String.sub identity.agent_name 0 5 = "anon-")

let test_channel_roundtrip () =
  let channels = [
    Client_identity.External "telegram";
    Client_identity.External "discord";
    Client_identity.External "slack";
    Client_identity.External "signal";
    Client_identity.External "webchat";
    Client_identity.Api;
    Client_identity.Internal;
    Client_identity.External "custom";
  ] in
  List.iter (fun ch ->
    let str = Client_identity.string_of_channel ch in
    let back = Client_identity.channel_of_string str in
    check bool (Printf.sprintf "roundtrip for %s" str) true 
      (Client_identity.string_of_channel back = str)
  ) channels

let test_channel_normalization () =
  let normalize channel =
    Client_identity.channel_of_string channel |> Client_identity.string_of_channel
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
    (Client_identity.string_of_channel (Client_identity.External "  SlAck "));
  match Client_identity.channel_of_string "  DisCord  " with
  | Client_identity.External "discord" -> ()
  | _ -> fail "expected normalized opaque external channel"

let test_channel_yojson_backward_compat () =
  check (result string string) "legacy Discord string decodes"
    (Ok "discord")
    (match Client_identity.channel_of_yojson (`String "Discord") with
     | Ok channel -> Ok (Client_identity.string_of_channel channel)
     | Error err -> Error err);
  check (result string string) "tagged external Discord decodes"
    (Ok "discord")
    (match Client_identity.channel_of_yojson
             (`List [ `String "External"; `String "discord" ])
     with
     | Ok channel -> Ok (Client_identity.string_of_channel channel)
     | Error err -> Error err);
  check string "known external serializes as tagged external"
    "[\"External\",\"discord\"]"
    (Yojson.Safe.to_string
       (Client_identity.channel_to_yojson (Client_identity.External "DisCord")));
  check string "unknown external serializes as tagged external"
    "[\"External\",\"custom-edge\"]"
    (Yojson.Safe.to_string
       (Client_identity.channel_to_yojson
          (Client_identity.External "  Custom-Edge  ")))

let test_same_agent () =
  let id1 = identity_for ~session_key:"session-agent-a-1" "agent-a" in
  let id2 = { id1 with Client_identity.last_seen = Unix.gettimeofday () +. 100.0 } in
  let id3 = identity_for ~session_key:"session-agent-a-2" "agent-a" in
  let id4 = identity_for "agent-b" in
  check bool "same session_key" true (Client_identity.same_agent id1 id2);
  check bool "same agent_name" true (Client_identity.same_agent id1 id3);
  check bool "different agents" false (Client_identity.same_agent id1 id4)

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
  let identity = Client_identity.({
    uuid = "agent-test123456"; session_key = "12345678-1234-1234-1234-123456789abc";
    agent_name = "test-agent";
    agent_name_origin = `Supplied;
    channel = Some (Client_identity.External "telegram");
    user_id = Some "user123";
    capabilities = [];
    registered_at = 0.0;
    last_seen = 0.0;
    metadata = [];
  }) in
  let display = Client_identity.to_display_string identity in
  check bool "contains agent_name" true (String.length display > 0);
  check bool "contains channel" true (str_contains (String.lowercase_ascii display) "telegram")

let test_to_display_string_empty_session_key () =
  let identity = Client_identity.({
    uuid = "agent-emptykey";
    session_key = "";
    agent_name = "empty-key-agent";
    agent_name_origin = `Supplied;
    channel = Some Client_identity.Api;
    user_id = None;
    capabilities = [];
    registered_at = 0.0;
    last_seen = 0.0;
    metadata = [];
  }) in
  let display = Client_identity.to_display_string identity in
  check bool "empty session key display uses unknown prefix" true
    (str_contains display "(unknown)")

let () =
  run "Client_identity" [
    "basics", [
      test_case "generate_session_key" `Quick test_generate_session_key;
      test_case "generate_uuid is UUIDv7" `Quick test_generate_uuid_is_uuid_v7;
      test_case "from_mcp_params" `Quick test_from_mcp_params;
      test_case "from_mcp_params_minimal" `Quick test_from_mcp_params_minimal;
      test_case "generated fallback names are distinct" `Quick
        test_generated_fallback_agent_names_are_distinct;
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
  ]
