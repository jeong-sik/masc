(** See cascade_state.mli for documentation. *)

(* ── Sticky ─────────────────────────────────────────────────────── *)

type sticky_entry = {
  provider : string;
  expires_at : float;
}

let sticky_table : (string * string, sticky_entry) Hashtbl.t =
  Hashtbl.create 32

let sticky_mutex = Eio.Mutex.create ()

let record_sticky_choice ~keeper ~cascade ~provider ~ttl_ms ~now =
  if ttl_ms <= 0 then ()
  else
    let expires_at = now +. (float_of_int ttl_ms /. 1000.) in
    Eio.Mutex.use_rw ~protect:false sticky_mutex (fun () ->
        Hashtbl.replace sticky_table (keeper, cascade)
          { provider; expires_at })

let lookup_sticky ~keeper ~cascade ~now =
  Eio.Mutex.use_ro sticky_mutex (fun () ->
      match Hashtbl.find_opt sticky_table (keeper, cascade) with
      | Some entry when now < entry.expires_at -> Some entry.provider
      | _ -> None)

let clear_sticky () =
  Eio.Mutex.use_rw ~protect:false sticky_mutex (fun () ->
      Hashtbl.clear sticky_table)

(* ── Round-robin ────────────────────────────────────────────────── *)

let rr_table : (string, int Atomic.t) Hashtbl.t = Hashtbl.create 16
let rr_mutex = Eio.Mutex.create ()

let get_or_create_cursor cascade =
  match Hashtbl.find_opt rr_table cascade with
  | Some a -> a
  | None ->
    Eio.Mutex.use_rw ~protect:false rr_mutex (fun () ->
        match Hashtbl.find_opt rr_table cascade with
        | Some a -> a
        | None ->
          let a = Atomic.make 0 in
          Hashtbl.add rr_table cascade a;
          a)

let rotate_round_robin ~cascade ~bound =
  if bound <= 0 then 0
  else
    let cursor = get_or_create_cursor cascade in
    let v = Atomic.fetch_and_add cursor 1 in
    let m = v mod bound in
    if m < 0 then m + bound else m

let peek_round_robin ~cascade =
  match Hashtbl.find_opt rr_table cascade with
  | Some a -> Atomic.get a
  | None -> 0

let clear_round_robin () =
  Eio.Mutex.use_rw ~protect:false rr_mutex (fun () ->
      Hashtbl.clear rr_table)

(* ── Bulk ───────────────────────────────────────────────────────── *)

let clear_all () =
  clear_sticky ();
  clear_round_robin ()
