(* P19: Execution Result Cache
   Per-turn cache for bash command results.  Identical commands within
   the same turn return cached output, saving execution budget and time.

   Design: HashMap keyed by command string, with hit/miss counters
   for observability.  Resets at turn start; does not persist. *)

type cache_entry =
  { exit_code : int
  ; output : string
  ; duration_ms : int
  ; cached_at : float
  }

type t =
  { mutable table : (string, cache_entry) Hashtbl.t
  ; mutable hits : int
  ; mutable misses : int
  }

let create () = { table = Hashtbl.create 32; hits = 0; misses = 0 }

let reset t =
  Hashtbl.clear t.table;
  t.hits <- 0;
  t.misses <- 0
;;

let lookup t cmd =
  match Hashtbl.find_opt t.table cmd with
  | Some entry ->
    t.hits <- t.hits + 1;
    Some entry
  | None ->
    t.misses <- t.misses + 1;
    None
;;

let store t ~cmd ~exit_code ~output ~duration_ms =
  Hashtbl.replace t.table cmd { exit_code; output; duration_ms; cached_at = Unix.time () }
;;

let invalidate t cmd = Hashtbl.remove t.table cmd
let stats t = t.hits, t.misses

let to_json t =
  let entry_count = Hashtbl.length t.table in
  let size_bytes =
    Hashtbl.fold (fun _ (e : cache_entry) acc -> acc + String.length e.output) t.table 0
  in
  `Assoc
    [ "hit_count", `Int t.hits
    ; "miss_count", `Int t.misses
    ; "entry_count", `Int entry_count
    ; "size_bytes", `Int size_bytes
    ]
;;
