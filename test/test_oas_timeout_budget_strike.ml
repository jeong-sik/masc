(* PR-M (Leak 9): unit tests for the per-keeper [oas_timeout_budget]
   strike counter exposed by [Keeper_keepalive].

   These do not drive a full keeper cycle — that path requires Eio
   switches, registry state, and a meta on disk. Instead they exercise
   the file-local strike table directly through the test seam helpers
   to verify:
     1. bump returns 1, 2, 3 in order for the same keeper
     2. reset wipes the count back to 0
     3. distinct keeper names get independent counters
     4. set_for_test with strikes <= 0 is equivalent to remove
     5. first bump can hydrate from persisted restart state
*)

open Masc_mcp
module KK = Keeper_keepalive

let reset_table k = KK.set_budget_exhaustion_for_test ~keeper_name:k ~strikes:0

let test_bump_increments () =
  let k = "alpha" in
  reset_table k;
  Alcotest.(check int)
    "starts at 0" 0
    (KK.peek_budget_exhaustion_for_test ~keeper_name:k);
  Alcotest.(check int) "bump 1" 1 (KK.bump_budget_exhaustion ~keeper_name:k);
  Alcotest.(check int) "bump 2" 2 (KK.bump_budget_exhaustion ~keeper_name:k);
  Alcotest.(check int) "bump 3" 3 (KK.bump_budget_exhaustion ~keeper_name:k);
  Alcotest.(check int)
    "peek mirrors last bump" 3
    (KK.peek_budget_exhaustion_for_test ~keeper_name:k);
  reset_table k

let test_reset_clears () =
  let k = "beta" in
  reset_table k;
  let _ = KK.bump_budget_exhaustion ~keeper_name:k in
  let _ = KK.bump_budget_exhaustion ~keeper_name:k in
  KK.reset_budget_exhaustion ~keeper_name:k;
  Alcotest.(check int)
    "reset clears" 0
    (KK.peek_budget_exhaustion_for_test ~keeper_name:k);
  Alcotest.(check int)
    "next bump starts again at 1" 1
    (KK.bump_budget_exhaustion ~keeper_name:k);
  reset_table k

let test_keepers_are_independent () =
  let a = "gamma" and b = "delta" in
  reset_table a;
  reset_table b;
  let _ = KK.bump_budget_exhaustion ~keeper_name:a in
  let _ = KK.bump_budget_exhaustion ~keeper_name:a in
  let _ = KK.bump_budget_exhaustion ~keeper_name:b in
  Alcotest.(check int)
    "a strikes" 2
    (KK.peek_budget_exhaustion_for_test ~keeper_name:a);
  Alcotest.(check int)
    "b strikes" 1
    (KK.peek_budget_exhaustion_for_test ~keeper_name:b);
  KK.reset_budget_exhaustion ~keeper_name:a;
  Alcotest.(check int)
    "a cleared" 0
    (KK.peek_budget_exhaustion_for_test ~keeper_name:a);
  Alcotest.(check int)
    "b untouched by a's reset" 1
    (KK.peek_budget_exhaustion_for_test ~keeper_name:b);
  reset_table a;
  reset_table b

let test_set_zero_or_negative_removes () =
  let k = "epsilon" in
  KK.set_budget_exhaustion_for_test ~keeper_name:k ~strikes:5;
  Alcotest.(check int)
    "set 5" 5
    (KK.peek_budget_exhaustion_for_test ~keeper_name:k);
  KK.set_budget_exhaustion_for_test ~keeper_name:k ~strikes:0;
  Alcotest.(check int)
    "set 0 removes" 0
    (KK.peek_budget_exhaustion_for_test ~keeper_name:k);
  KK.set_budget_exhaustion_for_test ~keeper_name:k ~strikes:7;
  KK.set_budget_exhaustion_for_test ~keeper_name:k ~strikes:(-1);
  Alcotest.(check int)
    "negative also removes" 0
    (KK.peek_budget_exhaustion_for_test ~keeper_name:k)

let test_first_bump_hydrates_from_prior () =
  let k = "zeta" in
  reset_table k;
  Alcotest.(check int)
    "prior 2 becomes strike 3" 3
    (KK.bump_budget_exhaustion_seeded ~keeper_name:k ~prior_strikes:2);
  Alcotest.(check int)
    "in-memory count wins after hydration" 4
    (KK.bump_budget_exhaustion_seeded ~keeper_name:k ~prior_strikes:2);
  reset_table k;
  Alcotest.(check int)
    "negative prior clamps to 0" 1
    (KK.bump_budget_exhaustion_seeded ~keeper_name:k ~prior_strikes:(-9));
  reset_table k

(* The strike table is guarded by [Eio.Mutex], which requires an Eio
   fiber context. Run every case inside [Eio_main.run]. *)
let in_eio f () = Eio_main.run (fun _env -> f ())

let () =
  Alcotest.run "oas_timeout_budget_strike"
    [ ( "strike-counter"
      , [ Alcotest.test_case "bump increments" `Quick
            (in_eio test_bump_increments)
        ; Alcotest.test_case "reset clears" `Quick (in_eio test_reset_clears)
        ; Alcotest.test_case "keepers independent" `Quick
            (in_eio test_keepers_are_independent)
        ; Alcotest.test_case "set_for_test 0 or negative removes" `Quick
            (in_eio test_set_zero_or_negative_removes)
        ; Alcotest.test_case "first bump hydrates from prior" `Quick
            (in_eio test_first_bump_hydrates_from_prior)
        ] )
    ]
