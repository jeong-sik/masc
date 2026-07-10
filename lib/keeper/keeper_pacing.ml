(* RFC-0313 W1 — pure per-runtime revisit pacing. See keeper_pacing.mli. *)

type policy =
  { base_sec : float
  ; multiplier : float
  ; cap_sec : float
  }

(* Policy values live in config/runtime.toml [pacing]
   (Runtime_schema.pacing_default when absent); callers build [policy]
   through [Keeper_pacing_shadow.policy_of_runtime] (RFC-0313 W3). *)

type revisit =
  { eligible_at : float
  ; consecutive : int
  }

(* Sorted-by-key unique assoc list; catalogs are small (tens of
   runtimes), so linear operations dominate any tree structure. *)
type t = (string * revisit) list

let empty = []

let by_key (a, _) (b, _) = String.compare a b

let computed_delay ~policy ~consecutive =
  let raw =
    policy.base_sec *. (policy.multiplier ** float_of_int (consecutive - 1))
  in
  Float.min policy.cap_sec raw

let on_failure ~policy ~runtime_id ~retry_after ~now t =
  let consecutive =
    match List.assoc_opt runtime_id t with
    | Some r -> r.consecutive + 1
    | None -> 1
  in
  let delay =
    match retry_after with
    | Some ra -> Float.min policy.cap_sec (Float.max 0.0 ra)
    | None -> computed_delay ~policy ~consecutive
  in
  let entry = { eligible_at = now +. delay; consecutive } in
  List.sort by_key ((runtime_id, entry) :: List.remove_assoc runtime_id t)

let on_success ~runtime_id t = List.remove_assoc runtime_id t

let revisit_of ~runtime_id t = List.assoc_opt runtime_id t

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
         Float.min acc due)
      infinity
      catalog

let to_summary t = t
