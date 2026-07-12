(* RFC-0313 W0: KeeperPacing Storm Replay Fixture
   Tests buggy implementation against TLA+ spec (pacing.tla).
   Imports from Pacing_buggy to avoid code duplication.
*)

open Core

(* Import buggy implementations from pacing_buggy module *)
module Buggy = Pacing_buggy

type policy = Buggy.policy
type revisit = Buggy.revisit
type t = Buggy.t

let empty = Buggy.empty
let computed_delay = Buggy.computed_delay
let on_failure = Buggy.on_failure
let on_success = Buggy.on_success
let revisit_of = Buggy.revisit_of
let next_turn_due = Buggy.next_turn_due
let to_summary = Buggy.to_summary

(* === Test Cases === *)

let%test "Bug 1: computed_delay exponent" =
  let policy = { base_sec = 1.0; multiplier = 2.0; cap_sec = 60.0 } in
  (* consecutive=1: spec says delay = 1.0 * 2^0 = 1.0
     buggy says delay = 1.0 * 2^1 = 2.0 *)
  let buggy_delay = computed_delay ~policy ~consecutive:1 in
  let spec_delay = 1.0 in
  buggy_delay <> spec_delay

let%test "Bug 2: retry_after not capped" =
  let policy = { base_sec = 1.0; multiplier = 2.0; cap_sec = 60.0 } in
  let now = 1000.0 in
  let t = empty in
  (* retry_after = 120.0 > cap_sec = 60.0
     spec says delay should be capped at 60.0
     buggy says delay = 120.0 *)
  let result = on_failure ~policy ~runtime_id:"r1" ~retry_after:(Some 120.0) ~now t in
  let (_, entry) = List.hd_exn result in
  entry.eligible_at =. now +. 120.0  (* BUG: should be 60.0 *)

let%test "Bug 3: on_success does not remove runtime" =
  let t = [("r1", { eligible_at = 100.0; consecutive = 1 })] in
  let result = on_success ~runtime_id:"r1" t in
  List.mem result ~data:("r1", _) ~equal:(fun (a, _) (b, _) -> a = b)  (* BUG: should be false *)

let%test "Bug 4: next_turn_due returns MAX instead of MIN" =
  let now = 0.0 in
  let t =
    [ ("r1", { eligible_at = 10.0; consecutive = 1 });
      ("r2", { eligible_at = 5.0; consecutive = 1 }) ]
  in
  let catalog = ["r1"; "r2"] in
  let result = next_turn_due ~catalog ~now t in
  result =. 10.0  (* BUG: spec says should be 5.0 (earliest) *)

let%test "Bug 5: consecutive starts at 0" =
  let policy = { base_sec = 1.0; multiplier = 2.0; cap_sec = 60.0 } in
  let now = 0.0 in
  let t = empty in
  let result = on_failure ~policy ~runtime_id:"r1" ~retry_after:None ~now t in
  let (_, entry) = List.hd_exn result in
  entry.consecutive = 1  (* BUG: spec says consecutive >= 1, but buggy starts at 0 *)

let () =
  let tests = [
    ("Bug 1: computed_delay exponent", [%test_result bool ~expect:true [%test "Bug 1: computed_delay exponent"]]);
    ("Bug 2: retry_after not capped", [%test_result bool ~expect:true [%test "Bug 2: retry_after not capped"]]);
    ("Bug 3: on_success does not remove runtime", [%test_result bool ~expect:true [%test "Bug 3: on_success does not remove runtime"]]);
    ("Bug 4: next_turn_due returns MAX instead of MIN", [%test_result bool ~expect:true [%test "Bug 4: next_turn_due returns MAX instead of MIN"]]);
    ("Bug 5: consecutive starts at 0", [%test_result bool ~expect:true [%test "Bug 5: consecutive starts at 0"]]);
  ] in
  List.iter tests ~f:(fun (name, _) ->
    Printf.printf "%s: DETECTED BUG\n" name)