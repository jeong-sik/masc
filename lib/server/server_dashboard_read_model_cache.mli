(** Dashboard read-model cache.

    Heavy dashboard read surfaces (execution, runtime-probe, runtime-trace,
    composite snapshots) are pre-computed by a background loop and stored here.
    HTTP handlers return cached snapshots instantly; freshness is maintained by
    the proactive compute loop and explicit invalidation events. *)

type source =
  [ `Proactive
  | `On_demand
  | `Stale_fallback
  ]

type entry =
  { generated_at : float
  ; json : Yojson.Safe.t
  ; source : source
  }

type cache_key =
  | Execution of
      { actor : string option
      ; fixture : string option
      ; full : bool
      ; force : bool
      }
  | Runtime_probe of { force : bool }
  | Runtime_trace of
      { keeper_name : string
      ; trace_id : string option
      ; turn_id : int option
      ; limit : int
      }
  | Fleet_composite
  | Keeper_composite of { keeper_name : string }

type t

(** Create an empty cache. *)
val create : unit -> t

(** Global per-process cache. The server runs against one [base_path] for the
    lifetime of the process, so a single cache is sufficient. *)
val global : unit -> t

(** Look up an entry regardless of age. *)
val get : t -> cache_key -> entry option

(** Look up a fresh entry. [ttl_s] is the maximum acceptable age in seconds. *)
val get_fresh : t -> cache_key -> ttl_s:float -> entry option

(** Look up an entry even if it is slightly stale. Returns the entry with
    [source = `Stale_fallback] if it is within [stale_threshold_s], otherwise
    [None]. This lets handlers return data while a background refresh runs. *)
val get_or_stale :
  t -> cache_key -> stale_threshold_s:float -> entry option

(** Store an entry. *)
val put : t -> cache_key -> entry -> unit

(** Look up a fresh entry; on miss compute synchronously, store it, and return
    it. This is the simplest request-path pattern for surfaces that do not yet
    have a dedicated background proactive refresh fiber. *)
val get_or_compute :
  t -> cache_key -> ttl_s:float -> compute:(unit -> Yojson.Safe.t) -> Yojson.Safe.t

(** Remove a single key. *)
val invalidate : t -> cache_key -> unit

(** Remove all entries tied to a keeper (runtime-trace and per-keeper composite). *)
val invalidate_by_keeper : t -> string -> unit

(** Clear every entry. Useful for tests. *)
val clear : t -> unit
