(* RFC-0313 W0: KeeperPacing Buggy Implementation
   This file contains intentional bugs that violate the TLA+ spec (pacing.tla).
   Used for storm replay fixture to verify spec compliance.
   
   BUGS:
   1. computed_delay: multiplier exponent is wrong (consecutive instead of consecutive-1)
      → Causes faster backoff than spec allows
   2. on_failure: does not cap delay at cap_sec when retry_after is provided
      → Violates spec invariant: delay <= policy`cap_sec
   3. on_success: does not remove runtime from pacing (leaks entries)
      → Violates spec: OnSuccess should remove runtime from DOMAIN pacing
   4. next_turn_due: returns MAX instead of MIN
      → Violates spec: should return earliest eligible runtime
   5. consecutive count starts at 0 instead of 1
      → Violates spec invariant: consecutive >= 1
*)

type policy =
  { base_sec : float
  ; multiplier : float
  ; cap_sec : float
  }

type revisit =
  { eligible_at : float
  ; consecutive : int
  }

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