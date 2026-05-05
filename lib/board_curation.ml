module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Board_curation — AI curation readonly surface for the board.

    See board_curation.mli for the full contract. *)

(** {1 Types} *)

type curation_snapshot = {
  id : string;
  generated_at : float;
  submitted_by : string;
  model : string option;
  ordering : string list;
  highlights : string list;
  rationale : string;
  provenance : Yojson.Safe.t;
}

(** {1 ID generation} *)

(* Caller must ensure [Mirage_crypto_rng] is seeded before the first call,
   following the same contract as board post/comment ID generation in
   board_types/board_types.ml. *)
let generate_id () =
  Random_id.prefixed ~prefix:"cu-" ~bytes:16

(** {1 JSON serialisation} *)

let snapshot_to_yojson (s : curation_snapshot) : Yojson.Safe.t =
  `Assoc [
    ("id", `String s.id);
    ("generated_at", `Float s.generated_at);
    ("submitted_by", `String s.submitted_by);
    ("model", match s.model with Some m -> `String m | None -> `Null);
    ("ordering", `List (List.map (fun id -> `String id) s.ordering));
    ("highlights", `List (List.map (fun id -> `String id) s.highlights));
    ("rationale", `String s.rationale);
    ("provenance", s.provenance);
  ]

(** {1 In-memory store} *)

(* Single-slot in-memory store.  Not thread-safe — see .mli contract. *)
let current : curation_snapshot option Atomic.t = Atomic.make None

let submit_snapshot snap =
  Atomic.set current (Some snap)

let latest_snapshot () =
  Atomic.get current

let reset_for_test () =
  Atomic.set current None
