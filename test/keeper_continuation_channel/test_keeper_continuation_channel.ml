(* Unit tests for [Keeper_continuation_channel] (RFC-0320 W1).

   Covers the closed-variant contract:
     - codec round-trips for every constructor,
     - fail-closed parsing (unknown kind / missing or malformed field / legacy alias -> Error),
     - the routing helpers (is_routable, kind_label, same_route). *)

open Keeper_continuation_channel

let dashboard_channel thread_id = dashboard ~thread_id |> Result.get_ok

let discord_channel ~guild_id ~channel_id ~parent_channel_id ~thread_id ~user_id =
  discord ~guild_id ~channel_id ~parent_channel_id ~thread_id ~user_id
  |> Result.get_ok
;;

let slack_channel ~team_id ~channel_id ~thread_ts ~user_id =
  slack ~team_id ~channel_id ~thread_ts ~user_id |> Result.get_ok
;;

let roundtrip ch =
  match of_yojson (to_yojson ch) with
  | Ok ch' -> assert (ch' = ch)
  | Error e -> failwith ("continuation_channel roundtrip failed: " ^ e)

let test_codec_roundtrip () =
  roundtrip (dashboard_channel "thread-42");
  roundtrip
    (discord_channel
       ~guild_id:(Some "G1")
       ~channel_id:"C123"
       ~parent_channel_id:(Some "P1")
       ~thread_id:(Some "T1")
       ~user_id:"U9");
  roundtrip
    (slack_channel
       ~team_id:(Some "TEAM1")
       ~channel_id:"general"
       ~thread_ts:(Some "1710000000.000001")
       ~user_id:"U1");
  roundtrip (unrouted "connector not captured at submission")

let expect_error label json =
  match of_yojson json with
  | Error _ -> ()
  | Ok _ -> failwith ("expected Error for " ^ label)

let test_unknown_kind_is_error () =
  expect_error "unknown kind"
    (`Assoc [ ("kind", `String "webhook"); ("url", `String "https://x") ])

let test_missing_field_is_error () =
  (* dashboard requires thread_id *)
  expect_error "missing thread_id" (`Assoc [ ("kind", `String "dashboard") ]);
  expect_error
    "blank thread_id"
    (`Assoc [ "kind", `String "dashboard"; "thread_id", `String "  " ]);
  (* discord requires user_id *)
  expect_error "missing discord user_id"
    (`Assoc [ ("kind", `String "discord"); ("channel_id", `String "C") ])

let test_smart_constructors_reject_blank_coordinates () =
  assert (Result.is_error (dashboard ~thread_id:" "));
  assert (
    Result.is_error
      (discord
         ~guild_id:None
         ~channel_id:"C"
         ~parent_channel_id:None
         ~thread_id:None
         ~user_id:""));
  assert (
    Result.is_error
      (slack
         ~team_id:(Some " ")
         ~channel_id:"C"
         ~thread_ts:None
         ~user_id:"U"))

let test_duplicate_and_unknown_fields_are_errors () =
  expect_error
    "duplicate kind"
    (`Assoc
       [ "kind", `String "dashboard"
       ; "kind", `String "dashboard"
       ; "thread_id", `String "T"
       ]);
  expect_error
    "unknown dashboard field"
    (`Assoc
       [ "kind", `String "dashboard"
       ; "thread_id", `String "T"
       ; "channel_id", `String "C"
       ])

let test_optional_route_coordinates_are_strict () =
  List.iter
    (fun (label, json) -> expect_error label json)
    [ ( "discord guild_id wrong type"
      , `Assoc
          [ "kind", `String "discord"
          ; "channel_id", `String "C"
          ; "user_id", `String "U"
          ; "guild_id", `Int 1
          ] )
    ; ( "discord guild_id blank"
      , `Assoc
          [ "kind", `String "discord"
          ; "channel_id", `String "C"
          ; "user_id", `String "U"
          ; "guild_id", `String ""
          ] )
    ; ( "discord parent_channel_id wrong type"
      , `Assoc
          [ "kind", `String "discord"
          ; "channel_id", `String "C"
          ; "user_id", `String "U"
          ; "parent_channel_id", `Bool true
          ] )
    ; ( "discord thread_id wrong type"
      , `Assoc
          [ "kind", `String "discord"
          ; "channel_id", `String "C"
          ; "user_id", `String "U"
          ; "thread_id", `List []
          ] )
    ; ( "slack team_id wrong type"
      , `Assoc
          [ "kind", `String "slack"
          ; "channel_id", `String "C"
          ; "user_id", `String "U"
          ; "team_id", `Assoc []
          ] )
    ; ( "slack thread_ts wrong type"
      , `Assoc
          [ "kind", `String "slack"
          ; "channel_id", `String "C"
          ; "user_id", `String "U"
          ; "thread_ts", `Float 1.0
          ] )
    ; ( "slack thread_ts blank"
      , `Assoc
          [ "kind", `String "slack"
          ; "channel_id", `String "C"
          ; "user_id", `String "U"
          ; "thread_ts", `String " "
          ] )
    ]

let test_slack_legacy_channel_alias_is_rejected () =
  expect_error
    "legacy channel alias"
    (`Assoc
       [ "kind", `String "slack"
       ; "channel", `String "C"
       ; "user_id", `String "U"
       ]);
  expect_error
    "invalid channel_id is not masked by alias"
    (`Assoc
       [ "kind", `String "slack"
       ; "channel_id", `Int 1
       ; "channel", `String "C"
       ; "user_id", `String "U"
       ])

let test_missing_kind_is_error () =
  expect_error "missing kind" (`Assoc [ ("thread_id", `String "t") ])

let test_non_object_is_error () =
  expect_error "non-object string" (`String "nope");
  expect_error "non-object list" (`List [ `String "a" ])

let test_is_routable () =
  assert (is_routable (dashboard_channel "t"));
  assert (
    is_routable
      (discord_channel
         ~guild_id:None
         ~channel_id:"c"
         ~parent_channel_id:None
         ~thread_id:None
         ~user_id:"u"));
  assert (
    is_routable
      (slack_channel ~team_id:None ~channel_id:"c" ~thread_ts:None ~user_id:"u"));
  assert (not (is_routable (unrouted "x")))

let test_kind_label () =
  assert (String.equal (kind_label (dashboard_channel "t")) "dashboard");
  assert (
    String.equal
      (kind_label
         (discord_channel
            ~guild_id:None
            ~channel_id:"c"
            ~parent_channel_id:None
            ~thread_id:None
            ~user_id:"u"))
      "discord");
  assert (
    String.equal
      (kind_label
         (slack_channel ~team_id:None ~channel_id:"c" ~thread_ts:None ~user_id:"u"))
      "slack");
  assert (String.equal (kind_label (unrouted "x")) "unrouted")

let test_same_route () =
  (* same destination *)
  assert (same_route (dashboard_channel "t1") (dashboard_channel "t1"));
  assert (
    same_route
      (discord_channel
         ~guild_id:(Some "g")
         ~channel_id:"c"
         ~parent_channel_id:(Some "p")
         ~thread_id:(Some "t")
         ~user_id:"u")
      (discord_channel
         ~guild_id:(Some "g")
         ~channel_id:"c"
         ~parent_channel_id:(Some "p")
         ~thread_id:(Some "t")
         ~user_id:"u"));
  (* differing coordinate -> different route *)
  assert (not (same_route (dashboard_channel "t1") (dashboard_channel "t2")));
  assert (
    not
      (same_route
         (discord_channel
            ~guild_id:(Some "g")
            ~channel_id:"c"
            ~parent_channel_id:(Some "p")
            ~thread_id:(Some "t")
            ~user_id:"u")
         (discord_channel
            ~guild_id:(Some "g")
            ~channel_id:"c"
            ~parent_channel_id:(Some "p")
            ~thread_id:(Some "t2")
            ~user_id:"u")));
  (* different constructor -> different route *)
  assert (
    not
      (same_route
         (dashboard_channel "t")
         (slack_channel ~team_id:None ~channel_id:"c" ~thread_ts:None ~user_id:"u")));
  (* two Unrouted values never share a route (no destination to share) *)
  assert (not (same_route (unrouted "a") (unrouted "a")))

let () =
  test_codec_roundtrip ();
  test_unknown_kind_is_error ();
  test_missing_field_is_error ();
  test_smart_constructors_reject_blank_coordinates ();
  test_duplicate_and_unknown_fields_are_errors ();
  test_optional_route_coordinates_are_strict ();
  test_slack_legacy_channel_alias_is_rejected ();
  test_missing_kind_is_error ();
  test_non_object_is_error ();
  test_is_routable ();
  test_kind_label ();
  test_same_route ();
  print_endline "Keeper_continuation_channel: all tests passed"
