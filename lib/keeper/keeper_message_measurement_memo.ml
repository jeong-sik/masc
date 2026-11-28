module Table = Hashtbl.Make (Agent_core.Types.Message_value)

(* [key] is the message the table holds as this entry's key, so a hit can
   tell whether that is the asked value itself or an equal copy. [last_walk]
   is the newest walk that asked for it. *)
type entry =
  { bytes : int
  ; mutable key : Agent_core.Types.message
  ; mutable last_walk : int
  }

(* [swept_walk] is the newest walk that swept the table for room. *)
type table =
  { lock : Mutex.t
  ; entries : entry Table.t
  ; mutable retained_bytes : int
  ; mutable walks : int
  ; mutable swept_walk : int
  }

type encoder =
  { id : int
  ; make_measurer : unit -> Agent_core.Types.message -> int
  ; max_retained_bytes : int
  }

let per_keeper_retained_bytes = 64 * 1024 * 1024

let next_encoder_id = Atomic.make 0

let encoder ~max_retained_bytes make_measurer =
  { id = Atomic.fetch_and_add next_encoder_id 1; make_measurer; max_retained_bytes }
;;

(* One table per Keeper name and encoder. A Keeper's walks follow each other,
   but each runs as a CPU-pool job that may land on any domain, and two
   Keepers walk at the same time, so the registry and every table take a
   lock. No lock is held across a measurement or an Eio operation. *)
let tables : (string * int, table) Hashtbl.t = Hashtbl.create 32

let tables_lock = Mutex.create ()

let table_of ~keeper_name encoder =
  Mutex.protect tables_lock (fun () ->
    let key = keeper_name, encoder.id in
    match Hashtbl.find_opt tables key with
    | Some table -> table
    | None ->
      let table =
        { lock = Mutex.create ()
        ; entries = Table.create 1024
        ; retained_bytes = 0
        ; walks = 0
        ; swept_walk = 0
        }
      in
      Hashtbl.replace tables key table;
      table)
;;

(* Entries that neither this walk nor the one before asked for: messages the
   Keeper's history no longer holds, or a part of it the last two walks did
   not reach. A later walk that reaches them measures them again. *)
let drop_unasked table ~walk =
  Table.filter_map_inplace
    (fun (_ : Agent_core.Types.message) entry ->
       if entry.last_walk >= walk - 1
       then Some entry
       else (
         table.retained_bytes <- table.retained_bytes - entry.bytes;
         None))
    table.entries
;;

(* Called with the table locked. Another walk of the same Keeper may have
   kept the message since this walk looked.

   A walk sweeps at most once. An entry only ever gains walks, so after this
   walk's sweep every entry left was asked for by this walk or the one before,
   and a second sweep would scan the whole table to drop nothing. Without the
   guard, a history larger than the bound would scan the table once per
   message the walk could not keep. *)
let admit table ~max_retained_bytes ~walk message bytes =
  match Table.find_opt table.entries message with
  | Some entry -> entry.last_walk <- Int.max entry.last_walk walk
  | None ->
    if table.retained_bytes + bytes > max_retained_bytes && table.swept_walk < walk
    then (
      table.swept_walk <- walk;
      drop_unasked table ~walk);
    if table.retained_bytes + bytes <= max_retained_bytes
    then (
      Table.add table.entries message { bytes; key = message; last_walk = walk };
      table.retained_bytes <- table.retained_bytes + bytes)
;;

let measurer ~keeper_name encoder =
  let table = table_of ~keeper_name encoder in
  let walk =
    Mutex.protect table.lock (fun () ->
      table.walks <- table.walks + 1;
      table.walks)
  in
  let measure = encoder.make_measurer () in
  fun message ->
    let kept =
      Mutex.protect table.lock (fun () ->
        match Table.find_opt table.entries message with
        | None -> None
        | Some entry ->
          entry.last_walk <- Int.max entry.last_walk walk;
          if entry.key != message
          then (
            (* The key an earlier run decoded holds that run's copy of the
               message. Taking this walk's value lets the copy go. *)
            Table.replace table.entries message entry;
            entry.key <- message);
          Some entry.bytes)
    in
    match kept with
    | Some bytes -> bytes
    | None ->
      let bytes = measure message in
      Mutex.protect table.lock (fun () ->
        admit table ~max_retained_bytes:encoder.max_retained_bytes ~walk message bytes);
      bytes
;;
