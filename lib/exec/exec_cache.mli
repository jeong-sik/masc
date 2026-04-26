(** P19: Execution Result Cache

    Per-turn cache for bash command results.  Identical commands within
    the same turn return cached output instead of re-executing, saving
    execution budget and wall-clock time.

    Cache is keyed by command string.  It resets at turn start and
    does not persist across turns, avoiding stale-result issues. *)

(** Mutable cache.  Single-owner per keeper turn. *)
type t

(** Create a fresh, empty cache. *)
val create : unit -> t

(** Clear all entries (call at turn start). *)
val reset : t -> unit

type cache_entry =
  { exit_code : int
  ; output : string
  ; duration_ms : int
  ; cached_at : float (** Unix.time () *)
  }

(** Look up a previous result by command string.  Returns [None] if
    not cached or if the entry is older than [max_age_s]. *)
val lookup : t -> string -> cache_entry option

(** Store a command result. *)
val store : t -> cmd:string -> exit_code:int -> output:string -> duration_ms:int -> unit

(** Remove a specific entry (e.g. after a write command). *)
val invalidate : t -> string -> unit

(** Returns [(hits, misses)] for observability. *)
val stats : t -> int * int

(** Cache stats as JSON: [hit_count], [miss_count], [entry_count],
    [size_bytes] (approximate). *)
val to_json : t -> Yojson.Safe.t
