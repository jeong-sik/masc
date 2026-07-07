(* Unit tests for [Keeper_continuation_channel] (RFC-0320 W1).

   Covers the closed-variant contract:
     - codec round-trips for every constructor,
     - fail-closed parsing (unknown kind / missing field / non-object -> Error),
     - the routing helpers (is_routable, kind_label, same_route). *)

open Keeper_continuation_channel

let roundtrip ch =
  match of_yojson (to_yojson ch) with
  | Ok ch' -> assert (ch' = ch)
  | Error e -> failwith ("continuation_channel roundtrip failed: " ^ e)

let test_codec_roundtrip () =
  roundtrip (Dashboard { thread_id = "thread-42" });
  roundtrip
    (Discord
       { guild_id = Some "G1"
       ; channel_id = "C123"
       ; parent_channel_id = Some "P1"
       ; thread_id = Some "T1"
       ; user_id = "U9"
       });
  roundtrip
    (Slack
       { team_id = Some "TEAM1"
       ; channel_id = "general"
       ; thread_ts = Some "1710000000.000001"
       ; user_id = "U1"
       });
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
  (* discord requires user_id *)
  expect_error "missing discord user_id"
    (`Assoc [ ("kind", `String "discord"); ("channel_id", `String "C") ])

let test_missing_kind_is_error () =
  expect_error "missing kind" (`Assoc [ ("thread_id", `String "t") ])

let test_non_object_is_error () =
  expect_error "non-object string" (`String "nope");
  expect_error "non-object list" (`List [ `String "a" ])

let test_is_routable () =
  assert (is_routable (Dashboard { thread_id = "t" }));
  assert (
    is_routable
      (Discord
         { guild_id = None
         ; channel_id = "c"
         ; parent_channel_id = None
         ; thread_id = None
         ; user_id = "u"
         }));
  assert (
    is_routable
      (Slack { team_id = None; channel_id = "c"; thread_ts = None; user_id = "u" }));
  assert (not (is_routable (unrouted "x")))

let test_kind_label () =
  assert (String.equal (kind_label (Dashboard { thread_id = "t" })) "dashboard");
  assert (
    String.equal
      (kind_label
         (Discord
            { guild_id = None
            ; channel_id = "c"
            ; parent_channel_id = None
            ; thread_id = None
            ; user_id = "u"
            }))
      "discord");
  assert (
    String.equal
      (kind_label
         (Slack { team_id = None; channel_id = "c"; thread_ts = None; user_id = "u" }))
      "slack");
  assert (String.equal (kind_label (unrouted "x")) "unrouted")

let test_same_route () =
  (* same destination *)
  assert (same_route (Dashboard { thread_id = "t1" }) (Dashboard { thread_id = "t1" }));
  assert (
    same_route
      (Discord
         { guild_id = Some "g"
         ; channel_id = "c"
         ; parent_channel_id = Some "p"
         ; thread_id = Some "t"
         ; user_id = "u"
         })
      (Discord
         { guild_id = Some "g"
         ; channel_id = "c"
         ; parent_channel_id = Some "p"
         ; thread_id = Some "t"
         ; user_id = "u"
         }));
  (* differing coordinate -> different route *)
  assert (not (same_route (Dashboard { thread_id = "t1" }) (Dashboard { thread_id = "t2" })));
  assert (
    not
      (same_route
         (Discord
            { guild_id = Some "g"
            ; channel_id = "c"
            ; parent_channel_id = Some "p"
            ; thread_id = Some "t"
            ; user_id = "u"
            })
         (Discord
            { guild_id = Some "g"
            ; channel_id = "c"
            ; parent_channel_id = Some "p"
            ; thread_id = Some "t2"
            ; user_id = "u"
            })));
  (* different constructor -> different route *)
  assert (
    not
      (same_route
         (Dashboard { thread_id = "t" })
         (Slack
            { team_id = None
            ; channel_id = "c"
            ; thread_ts = None
            ; user_id = "u"
            })));
  (* two Unrouted values never share a route (no destination to share) *)
  assert (not (same_route (unrouted "a") (unrouted "a")))

let () =
  test_codec_roundtrip ();
  test_unknown_kind_is_error ();
  test_missing_field_is_error ();
  test_missing_kind_is_error ();
  test_non_object_is_error ();
  test_is_routable ();
  test_kind_label ();
  test_same_route ();
  print_endline "Keeper_continuation_channel: all tests passed"
