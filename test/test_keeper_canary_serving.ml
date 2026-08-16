(* Serving-runtime attribution for the canary harness
   (lib/keeper_canary/keeper_canary_serving.ml, #28913). The check exists
   because the M3 sweep promoted eight antigravity receipts whose every
   turn was silently served by the degraded-retry fallback (#28912); these
   tests pin the verdict on exactly that shape. *)

module F = Keeper_canary_failover
module S = Keeper_canary_serving

let attempt ?turn ~ts ~event ~runtime () : F.attempt =
  match
    F.parse_manifest_rows
      (`Assoc
        [ ( "manifest_rows"
          , `List
              [ `Assoc
                  ([ ("ts", `String ts)
                   ; ("event", `String event)
                   ; ("runtime_id", `String "some-lane")
                   ; ("decision", `Assoc [ ("runtime_id", `String runtime) ])
                   ]
                   @
                   match turn with
                   | Some n -> [ ("keeper_turn_id", `Int n) ]
                   | None -> [])
              ] )
        ])
  with
  | Ok [ a ] -> a
  | Ok l -> Alcotest.failf "expected one attempt, got %d" (List.length l)
  | Error msg -> Alcotest.failf "attempt fixture: %s" msg

let completed ~turn ~ts ~runtime () =
  attempt ~turn ~ts ~event:"runtime_completed" ~runtime ()

let turn_pair = Alcotest.(pair int string)

let test_all_turns_served_by_expected () =
  let attempts =
    [ completed ~turn:1 ~ts:"2026-08-17T01:00:00Z" ~runtime:"agy.x" ()
    ; completed ~turn:2 ~ts:"2026-08-17T01:10:00Z" ~runtime:"agy.x" ()
    ]
  in
  let c =
    S.check
      ~expected_runtime:"agy.x"
      ~window_start:"2026-08-17T00:59:00Z"
      ~turn_ids:[ 1; 2 ]
      ~attempts
  in
  Alcotest.(check bool) "all as expected" true (S.all_as_expected c);
  Alcotest.(check (list turn_pair)) "served records both turns"
    [ (1, "agy.x"); (2, "agy.x") ]
    c.S.served

(* The #28912 incident shape: the expected runtime never completes a turn,
   the fallback completes every one, and the recall signal alone would
   still read 9/9. The check must flag every measured turn. *)
let test_silent_fallback_substitution_is_flagged () =
  let attempts =
    [ attempt ~turn:1 ~ts:"2026-08-17T01:00:00Z" ~event:"runtime_routed"
        ~runtime:"agy.x" ()
    ; attempt ~turn:1 ~ts:"2026-08-17T01:03:14Z" ~event:"runtime_failed"
        ~runtime:"agy.x" ()
    ; completed ~turn:1 ~ts:"2026-08-17T01:03:20Z" ~runtime:"oc.fallback" ()
    ; completed ~turn:2 ~ts:"2026-08-17T01:10:00Z" ~runtime:"oc.fallback" ()
    ]
  in
  let c =
    S.check
      ~expected_runtime:"agy.x"
      ~window_start:"2026-08-17T00:59:00Z"
      ~turn_ids:[ 1; 2 ]
      ~attempts
  in
  Alcotest.(check bool) "substitution fails the check" false (S.all_as_expected c);
  Alcotest.(check (list turn_pair)) "every turn is a mismatch"
    [ (1, "oc.fallback"); (2, "oc.fallback") ]
    c.S.mismatched;
  Alcotest.(check (list int)) "no unattributed turns" [] c.S.unattributed

let test_turn_without_completion_is_unattributed () =
  let attempts =
    [ completed ~turn:1 ~ts:"2026-08-17T01:00:00Z" ~runtime:"agy.x" () ]
  in
  let c =
    S.check
      ~expected_runtime:"agy.x"
      ~window_start:"2026-08-17T00:59:00Z"
      ~turn_ids:[ 1; 2 ]
      ~attempts
  in
  Alcotest.(check bool) "missing completion fails the check" false
    (S.all_as_expected c);
  Alcotest.(check (list int)) "turn 2 is unattributed" [ 2 ] c.S.unattributed;
  Alcotest.(check (list turn_pair)) "turn 1 is fine" [] c.S.mismatched

(* Rows before the window come from earlier keeper traffic (a reused
   keeper, an operator poke); counting them would attribute turns the run
   never sent. *)
let test_rows_before_window_are_ignored () =
  let attempts =
    [ completed ~turn:1 ~ts:"2026-08-16T23:00:00Z" ~runtime:"oc.fallback" ()
    ; completed ~turn:1 ~ts:"2026-08-17T01:00:00Z" ~runtime:"agy.x" ()
    ]
  in
  let c =
    S.check
      ~expected_runtime:"agy.x"
      ~window_start:"2026-08-17T00:59:00Z"
      ~turn_ids:[ 1 ]
      ~attempts
  in
  Alcotest.(check bool) "stale row is invisible" true (S.all_as_expected c);
  Alcotest.(check (list turn_pair)) "served has only the windowed row"
    [ (1, "agy.x") ]
    c.S.served

(* Wire order is not chronological order (the classify lesson): the later
   timestamp must win even when it arrives earlier in the list. *)
let test_chronologically_later_completion_wins_for_a_turn () =
  let attempts =
    [ completed ~turn:1 ~ts:"2026-08-17T01:00:05Z" ~runtime:"oc.fallback" ()
    ; completed ~turn:1 ~ts:"2026-08-17T01:00:00Z" ~runtime:"agy.x" ()
    ]
  in
  let c =
    S.check
      ~expected_runtime:"agy.x"
      ~window_start:"2026-08-17T00:59:00Z"
      ~turn_ids:[ 1 ]
      ~attempts
  in
  Alcotest.(check (list turn_pair)) "the later timestamp decides"
    [ (1, "oc.fallback") ]
    c.S.mismatched

(* [served] is the full windowed completion record: rows for turns the
   harness never sent stay visible instead of silently vanishing. *)
let test_served_keeps_rows_for_unmeasured_turns () =
  let attempts =
    [ completed ~turn:1 ~ts:"2026-08-17T01:00:00Z" ~runtime:"agy.x" ()
    ; completed ~turn:99 ~ts:"2026-08-17T01:05:00Z" ~runtime:"oc.other" ()
    ]
  in
  let c =
    S.check
      ~expected_runtime:"agy.x"
      ~window_start:"2026-08-17T00:59:00Z"
      ~turn_ids:[ 1 ]
      ~attempts
  in
  Alcotest.(check bool) "measured turn is clean" true (S.all_as_expected c);
  Alcotest.(check (list turn_pair)) "served keeps the unmeasured row"
    [ (1, "agy.x"); (99, "oc.other") ]
    c.S.served

let test_json_carries_the_verdict_inputs () =
  let c =
    S.check
      ~expected_runtime:"agy.x"
      ~window_start:"2026-08-17T00:59:00Z"
      ~turn_ids:[ 1 ]
      ~attempts:
        [ completed ~turn:1 ~ts:"2026-08-17T01:00:00Z" ~runtime:"oc.fallback" () ]
  in
  match S.to_yojson c with
  | `Assoc kvs ->
    Alcotest.(check (option string)) "expected_runtime"
      (Some "agy.x")
      (match List.assoc_opt "expected_runtime" kvs with
       | Some (`String s) -> Some s
       | _ -> None);
    let count key =
      match List.assoc_opt key kvs with
      | Some (`List l) -> List.length l
      | _ -> -1
    in
    Alcotest.(check int) "served rendered" 1 (count "served");
    Alcotest.(check int) "mismatched rendered" 1 (count "mismatched");
    Alcotest.(check int) "unattributed rendered" 0 (count "unattributed")
  | _ -> Alcotest.fail "serving JSON must be an object"

let () =
  Alcotest.run
    "keeper_canary_serving"
    [ ( "check"
      , [ Alcotest.test_case "all served by expected" `Quick
            test_all_turns_served_by_expected
        ; Alcotest.test_case "silent fallback substitution flagged" `Quick
            test_silent_fallback_substitution_is_flagged
        ; Alcotest.test_case "missing completion is unattributed" `Quick
            test_turn_without_completion_is_unattributed
        ; Alcotest.test_case "pre-window rows ignored" `Quick
            test_rows_before_window_are_ignored
        ; Alcotest.test_case "chronologically later completion wins" `Quick
            test_chronologically_later_completion_wins_for_a_turn
        ; Alcotest.test_case "served keeps unmeasured turns" `Quick
            test_served_keeps_rows_for_unmeasured_turns
        ; Alcotest.test_case "json carries verdict inputs" `Quick
            test_json_carries_the_verdict_inputs
        ] )
    ]
