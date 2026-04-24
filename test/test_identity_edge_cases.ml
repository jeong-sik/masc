(** Edge Case Tests for Agent Identity *)

open Alcotest
open Masc_mcp

(* Empty/null params *)
let test_empty_params () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let identity = Agent_registry_eio.get_or_create_identity (`Assoc []) in
  check bool "has agent_name" true (String.length identity.agent_name > 0);
  check bool "starts with agent-" true 
    (String.sub identity.agent_name 0 6 = "agent-")

(* Null values in params *)
let test_null_values () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let params = `Assoc [
    ("_agent_name", `Null);
    ("room", `Null);
  ] in
  let identity = Agent_registry_eio.get_or_create_identity params in
  check bool "generated name" true (String.length identity.agent_name > 0)

(* Very long agent name *)
let test_long_agent_name () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let long_name = String.make 1000 'a' in
  let params = `Assoc [("_agent_name", `String long_name)] in
  let identity = Agent_registry_eio.get_or_create_identity params in
  check string "preserves long name" long_name identity.agent_name

(* Special characters in names *)
let test_special_chars () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let special_name = "agent-🤖-τεστ-テスト" in
  let params = `Assoc [("_agent_name", `String special_name)] in
  let identity = Agent_registry_eio.get_or_create_identity params in
  check string "preserves special chars" special_name identity.agent_name

(* Unknown channel *)
let test_unknown_channel () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let params = `Assoc [
    ("_agent_name", `String "test");
    ("_channel", `String "unknown_platform_xyz");
  ] in
  let identity = Agent_registry_eio.get_or_create_identity params in
  match identity.channel with
  | Some (Agent_identity.External s) -> check string "opaque external" "unknown_platform_xyz" s
  | _ -> fail "expected opaque external channel"

(* Empty capabilities list *)
let test_empty_capabilities () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let params = `Assoc [
    ("_agent_name", `String "test");
    ("_capabilities", `List []);
  ] in
  let identity = Agent_registry_eio.get_or_create_identity params in
  check int "no capabilities" 0 (List.length identity.capabilities)

(* Invalid capabilities format *)
let test_invalid_capabilities () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let params = `Assoc [
    ("_agent_name", `String "test");
    ("_capabilities", `String "not_a_list");
  ] in
  let identity = Agent_registry_eio.get_or_create_identity params in
  check int "ignores invalid" 0 (List.length identity.capabilities)

(* #9788: tools/call payload arrives as `Null instead of an object.
   Previously crashed inside Yojson.Safe.Util.member; must degrade
   to anonymous identity. *)
let test_null_payload () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let identity = Agent_registry_eio.get_or_create_identity `Null in
  check bool "has agent_name" true (String.length identity.agent_name > 0);
  check bool "starts with agent-" true
    (String.length identity.agent_name >= 6
     && String.sub identity.agent_name 0 6 = "agent-")

(* Same defensive behavior for non-object scalars. *)
let test_scalar_payload () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  let identity_string = Agent_registry_eio.get_or_create_identity (`String "garbage") in
  let identity_int = Agent_registry_eio.get_or_create_identity (`Int 42) in
  let identity_list = Agent_registry_eio.get_or_create_identity (`List []) in
  check bool "string payload tolerated" true (String.length identity_string.agent_name > 0);
  check bool "int payload tolerated" true (String.length identity_int.agent_name > 0);
  check bool "list payload tolerated" true (String.length identity_list.agent_name > 0)

(* Rapid session creation *)
let test_rapid_creation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Agent_registry_eio.reset_for_testing ();
  for i = 1 to 100 do
    let params = `Assoc [("_agent_name", `String (Printf.sprintf "rapid-%d" i))] in
    let _ = Agent_registry_eio.get_or_create_identity params in
    ()
  done;
  check bool "created 100" true (Agent_registry_eio.total_count () >= 100)

let () =
  run "Identity Edge Cases" [
    "params", [
      test_case "empty" `Quick test_empty_params;
      test_case "null_values" `Quick test_null_values;
      test_case "null_payload" `Quick test_null_payload;
      test_case "scalar_payload" `Quick test_scalar_payload;
      test_case "long_name" `Quick test_long_agent_name;
      test_case "special_chars" `Quick test_special_chars;
    ];
    "channels", [
      test_case "unknown" `Quick test_unknown_channel;
    ];
    "capabilities", [
      test_case "empty" `Quick test_empty_capabilities;
      test_case "invalid" `Quick test_invalid_capabilities;
    ];
    "stress", [
      test_case "rapid_creation" `Quick test_rapid_creation;
    ];
  ]
