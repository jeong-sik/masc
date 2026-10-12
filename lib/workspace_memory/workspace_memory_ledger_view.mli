val read : base_path:string -> (Yojson.Safe.t, string) result
(** Current durable ledger with best-effort current Keeper fact resolution.
    Old proposal files are ignored. A missing ledger is explicit; a corrupt
    ledger is an error. Resolved claims are observations, not verification. *)

val summary : base_path:string -> (Yojson.Safe.t, string) result
(** Claim/conflict summaries with member fact references only. No original
    bodies or workspace-sized fact array is returned. *)

val inventory : base_path:string -> (Yojson.Safe.t, string) result
(** Availability, counts and briefing freshness, without memory bodies. *)

val briefing : base_path:string -> (Yojson.Safe.t, string) result
(** Explicitly retrieve the shared briefing with its freshness status. *)

val search : base_path:string -> query:string -> limit:int -> (Yojson.Safe.t, string) result
(** Rank claim/conflict texts using the memory search index. Results carry
    IDs for explicit detail reads; lexical relevance is not truth validation.
    An unavailable index preserves literal and all-term matches in store order,
    with literal matches first. Ledger read failures remain errors. *)

type resolved_snapshot
val resolve_snapshot : base_path:string -> (resolved_snapshot, string) result
(** Resolve the ledger and current source records once. The immutable result
    can answer multiple IDs without further storage reads. It remains an
    observation of that read; callers must refresh before publishing after
    intervening model work. *)

val detail_in_snapshot : resolved_snapshot -> id:string -> (Yojson.Safe.t, string) result
(** Look up one claim or conflict in a previously resolved snapshot. *)

val detail : base_path:string -> id:string -> (Yojson.Safe.t, string) result
(** Resolve one claim or conflict and its current member facts. *)

module For_testing : sig
  val search_with_rank :
    rank:(query:string -> string list ->
      ((int * float) list, Keeper_memory_search_index.error) result) ->
    base_path:string -> query:string -> limit:int -> (Yojson.Safe.t, string) result
  (** Exercise index unavailability while using the real ledger read and
      query selection. Production uses [Keeper_memory_search_index.rank]. *)

  val summary_with_load :
    load:(base_path:string -> (Workspace_memory_ledger.t, string) result) ->
    base_path:string -> (Yojson.Safe.t, string) result
  (** Exercise an atomic replacement between descriptor observation and the
      content read. Production uses [Workspace_memory_ledger.load]. *)
end
