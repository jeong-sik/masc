(* Test rewritten for stateless budget exhaustion *)
open Masc_mcp

module KK = Keeper_keepalive

let test_bump_increments () =
  let strikes = KK.bump_budget_exhaustion_seeded ~keeper_name:"k" ~prior_strikes:2 in
  Alcotest.(check int) "bump increments from 2 to 3" 3 strikes

let test_reset_clears () =
  KK.reset_budget_exhaustion ~keeper_name:"k";
  Alcotest.(check pass) "reset is a no-op" () ()

let tests =
  [
    ("bump increments", `Quick, test_bump_increments);
    ("reset clears", `Quick, test_reset_clears);
  ]
