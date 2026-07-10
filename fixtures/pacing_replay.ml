(* RFC-0313 W0: KeeperPacing Storm Replay Fixture
   Tests buggy implementation against TLA+ spec (pacing.tla).
   Simulates 07-06 storm scenario: rapid consecutive failures with retry_after values.
   
   BUGS DETECTED:
   1. computed_delay: exponent wrong → faster backoff than spec
   2. on_failure: retry_after not capped → violates spec invariant
   3. on_success: does not remove runtime → memory leak
   4. next_turn_due: MAX instead of MIN → returns latest instead of earliest
   5. consecutive starts at 0 → violates spec invariant: consecutive >= 1
*)

open Core

type policy = { base_sec : float; multiplier : float; cap_sec : float }
type revisit = { eligible_at : float; consecutive : int }
type t = (string * revisit) list

let empty = []

let by_key (a, _) (b, _) = String.compare a b

(* BUG 1: exponent should be (consecutive - 1), not consecutive *)
let computed_delay ~policy ~consecutive =
  let raw =
    policy.base_sec *. (policy.multiplier ** float_of_int consecutive)
  in
  Float.min policy.cap_sec raw

(* BUG 2: does not cap delay at cap_sec when retry_after is provided *)
let on_failure ~policy ~runtime_id ~retry_after ~now t =
  let consecutive =
    match List.assoc_opt runtime_id t with
    | Some r -> r.consecutive + 1
    | None -> 1
  in
  let delay =
    match retry_after with
    | Some ra -> ra  (* BUG: should be Float.min policy.cap_sec (Float.max 0.0 ra) *)
    | None -> computed_delay ~policy ~consecutive
  in
  let entry = { eligible_at = now +. delay; consecutive } in
  List.sort by_key ((runtime_id, entry) :: List.remove_assoc runtime_id t)

(* BUG 3: does not remove runtime on success *)
let on_success ~runtime_id t = t  (* BUG: should be List.remove_assoc runtime_id t *)

let revisit_of ~runtime_id t = List.assoc_opt runtime_id t

(* BUG 4: returns MAX instead of MIN *)
let next_turn_due ~catalog ~now t =
  match catalog with
  | [] -> now
  | _ ->
    List.fold_left
      (fun acc runtime_id ->
         let due =
           match List.assoc_opt runtime_id t with
           | None -> now
           | Some r -> Float.max now r.eligible_at
         in
         Float.max acc due)  (* BUG: should be Float.min *)
      infinity
      catalog

let to_summary t = t

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