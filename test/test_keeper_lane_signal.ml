(* Alcotest unit tests for
   [Keeper_world_observation_message_scope.classify_lane_line] (RFC-0230 P1).

   The classifier is a pure boundary parse, so these tests need no keeper_meta
   construction — only the keeper's identity tokens and addressable names. *)

open Masc.Keeper_world_observation_message_scope

let label = function
  | Direct_mention _ -> "direct_mention"
  | Scope_message _ -> "scope_message"
  | Self_authored -> "self_authored"
  | Ambient -> "ambient"
;;

let self_tokens = [ "dreamer" ]
let mention_targets = [ "dreamer" ]

let classify ~speaker ~text =
  classify_lane_line ~self_tokens ~mention_targets ~speaker ~text ~at:1.0
;;

let test_direct_mention () =
  let s = classify ~speaker:"alice" ~text:"hey @dreamer take a look" in
  Alcotest.(check string) "@target by another speaker" "direct_mention" (label s);
  match s with
  | Direct_mention { speaker; _ } ->
    Alcotest.(check string) "speaker preserved" "alice" speaker
  | _ -> Alcotest.fail "expected Direct_mention"
;;

let test_self_authored_wins_over_mention () =
  (* A keeper that @-mentions itself must not wake itself: self check first. *)
  let s = classify ~speaker:"Dreamer" ~text:"@dreamer note to self" in
  Alcotest.(check string) "self speaker overrides mention" "self_authored" (label s)
;;

let test_ambient () =
  let s = classify ~speaker:"alice" ~text:"just chatting about the weather" in
  Alcotest.(check string) "no mention, not self" "ambient" (label s)
;;

let test_other_target_is_ambient () =
  let s = classify ~speaker:"alice" ~text:"hey @bob can you help" in
  Alcotest.(check string) "mention of a different target" "ambient" (label s)
;;

let test_case_insensitive_mention () =
  let s = classify ~speaker:"alice" ~text:"PING @DREAMER NOW" in
  Alcotest.(check string) "uppercase @MENTION still matches" "direct_mention" (label s)
;;

let test_empty_targets_is_ambient () =
  let s =
    classify_lane_line ~self_tokens ~mention_targets:[] ~speaker:"alice"
      ~text:"@dreamer" ~at:1.0
  in
  Alcotest.(check string) "no mention_targets to match" "ambient" (label s)
;;

let () =
  Alcotest.run "keeper_lane_signal"
    [ ( "classify_lane_line"
      , [ Alcotest.test_case "direct_mention" `Quick test_direct_mention
        ; Alcotest.test_case "self_authored_wins" `Quick
            test_self_authored_wins_over_mention
        ; Alcotest.test_case "ambient" `Quick test_ambient
        ; Alcotest.test_case "other_target_ambient" `Quick test_other_target_is_ambient
        ; Alcotest.test_case "case_insensitive" `Quick test_case_insensitive_mention
        ; Alcotest.test_case "empty_targets_ambient" `Quick test_empty_targets_is_ambient
        ] )
    ]
;;
