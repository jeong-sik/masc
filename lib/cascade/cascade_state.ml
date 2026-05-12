(** See cascade_state.mli for documentation. *)

(* ── Sticky ─────────────────────────────────────────────────────── *)

type sticky_entry = {
  provider : string;
  expires_at : float;
}

module Sticky_key = struct
  type t = string * string
  let compare (k1, c1) (k2, c2) =
    let r = String.compare k1 k2 in
    if r <> 0 then r else String.compare c1 c2
end

module Sticky_map = Map.Make (Sticky_key)

let sticky_table : sticky_entry Sticky_map.t Atomic.t =
  Atomic.make Sticky_map.empty

let record_sticky_choice ~keeper ~cascade ~provider ~ttl_ms ~now =
  if ttl_ms <= 0 then ()
  else
    let expires_at = now +. (float_of_int ttl_ms /. 1000.) in
    let entry = { provider; expires_at } in
    let key = (keeper, cascade) in
    Lockfree_atomic.update sticky_table (fun cur -> Sticky_map.add key entry cur)

let lookup_sticky ~keeper ~cascade ~now =
  let key = (keeper, cascade) in
  match Sticky_map.find_opt key (Atomic.get sticky_table) with
  | Some entry when now < entry.expires_at -> Some entry.provider
  | Some _expired_entry ->
    (* Entry existed but TTL expired.  Distinct from "no entry"
       case below — surface separately so operators can tell
       too-short-TTL invalidations from first-lookup misses.
       See iter 24 commit + iter 23 sticky_drift for the related
       candidate-list-invalidation counter.
       Also CAS-evict the stale slot so the map doesn't accumulate
       expired keys and subsequent lookups don't re-tick the
       counter (event-once semantics).  Only the winner increments
       the metric: a concurrent reader that finds the slot already
       evicted or refreshed has nothing new to report. *)
    let rec evict () =
      let cur = Atomic.get sticky_table in
      match Sticky_map.find_opt key cur with
      | Some refreshed when now < refreshed.expires_at ->
        (* Refreshed under us via [record_sticky_choice] — leave
           the live entry alone and don't count this lookup as an
           expiry event. *)
        false
      | Some _still_expired ->
        let next = Sticky_map.remove key cur in
        if Atomic.compare_and_set sticky_table cur next then true
        else evict ()
      | None ->
        (* Another concurrent lookup already evicted — don't
           double-count. *)
        false
    in
    if evict () then Cascade_metrics.on_sticky_expiry ~cascade;
    None
  | None -> None

let clear_sticky () = Atomic.set sticky_table Sticky_map.empty

(* ── Round-robin ────────────────────────────────────────────────── *)

module String_map = Map.Make (String)

let rr_table : int Atomic.t String_map.t Atomic.t =
  Atomic.make String_map.empty

let get_or_create_cursor cascade =
  match String_map.find_opt cascade (Atomic.get rr_table) with
  | Some a -> a
  | None ->
    (* Allocate a fresh cursor outside the CAS loop. If a concurrent
       writer beats us in, we return their cursor; the orphan
       allocation is GC'd. The fresh cursor is started at 0 so the
       semantics match the original Mutex-protected double-checked
       lookup (Atomic.make 0). *)
    let candidate = Atomic.make 0 in
    let rec loop () =
      let cur = Atomic.get rr_table in
      match String_map.find_opt cascade cur with
      | Some winner -> winner
      | None ->
        let next = String_map.add cascade candidate cur in
        if Atomic.compare_and_set rr_table cur next then candidate
        else loop ()
    in
    loop ()

let rotate_round_robin ~cascade ~bound =
  if bound <= 0 then 0
  else
    let cursor = get_or_create_cursor cascade in
    let v = Atomic.fetch_and_add cursor 1 in
    let m = v mod bound in
    if m < 0 then m + bound else m

let peek_round_robin ~cascade =
  match String_map.find_opt cascade (Atomic.get rr_table) with
  | Some a -> Atomic.get a
  | None -> 0

let clear_round_robin () = Atomic.set rr_table String_map.empty

(* ── Bulk ───────────────────────────────────────────────────────── *)

let clear_all () =
  clear_sticky ();
  clear_round_robin ()
