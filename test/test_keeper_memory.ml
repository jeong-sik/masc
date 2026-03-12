open Alcotest

module Mention = Masc_mcp.Mention
module Keeper_memory = Masc_mcp.Keeper_memory
module Keeper_types = Masc_mcp.Keeper_types
module Types = Masc_mcp.Types

let keeper_meta ~name ~mention_targets =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("trace_id", `String "trace-1");
        ("goal", `String "keep continuity");
        ("models", `List [ `String "custom:test-model" ]);
        ("active_model", `String "custom:test-model");
        ("mention_targets", `List (List.map (fun target -> `String target) mention_targets));
      ]
  in
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error err -> fail ("failed to build keeper meta: " ^ err)

let room_message content =
  {
    Types.seq = 1;
    from_agent = "tester";
    msg_type = "broadcast";
    content;
    mention = None;
    timestamp = "2026-03-12T00:00:00Z";
  }

let test_any_mentioned_exact_target () =
  check bool "exact direct mention" true
    (Mention.any_mentioned ~targets:[ "sangsu" ] "hello @sangsu, are you there?")

let test_any_mentioned_ambient_message () =
  check bool "ambient message not a direct mention" false
    (Mention.any_mentioned ~targets:[ "sangsu" ] "hello everyone, just chatting")

let test_keeper_policy_observation_direct_mention () =
  let meta = keeper_meta ~name:"sangsu" ~mention_targets:[ "sangsu"; "director" ] in
  let obs =
    Keeper_memory.keeper_policy_observation_of_room_message
      ~meta ~room_id:"default" (room_message "@director, what do you think?")
  in
  check bool "keeper observation uses mention targets" true obs.direct_mention

let test_keeper_policy_observation_non_mention () =
  let meta = keeper_meta ~name:"sangsu" ~mention_targets:[ "sangsu"; "director" ] in
  let obs =
    Keeper_memory.keeper_policy_observation_of_room_message
      ~meta ~room_id:"default" (room_message "ambient room chatter")
  in
  check bool "keeper observation no longer hardcodes direct mention" false obs.direct_mention

let () =
  run "Keeper_memory"
    [
      ( "mention",
        [
          test_case "any_mentioned exact target" `Quick test_any_mentioned_exact_target;
          test_case "any_mentioned ambient message" `Quick test_any_mentioned_ambient_message;
          test_case "policy observation direct mention" `Quick
            test_keeper_policy_observation_direct_mention;
          test_case "policy observation ambient message" `Quick
            test_keeper_policy_observation_non_mention;
        ] );
    ]
