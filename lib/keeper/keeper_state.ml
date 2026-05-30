(** See keeper_state.mli for documentation. *)

(* ── Round-robin ────────────────────────────────────────────────── *)

module String_map = Set_util.StringMap

let rr_table : int Atomic.t String_map.t Atomic.t =
  Atomic.make String_map.empty

let get_or_create_cursor cascade =
  match String_map.find_opt cascade (Atomic.get rr_table) with
  | Some a -> a
  | None ->
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
  clear_round_robin ()
