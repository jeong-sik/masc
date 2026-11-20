(** Why the first provider request of a Keeper turn read or wrote the prompt
    cache (RFC #53746 §3.2).

    A provider keeps a cache entry for a lifetime counted from the start of
    the newest request that wrote or read it. The first request of a turn can
    read only what an earlier request of the same runtime left, and only for
    the prefix the two share. This module derives, from the cost ledger's
    request rows and the provider-input snapshots, how long that runtime was
    idle, the lifetime the earlier request asked for, and where the two
    turns' inputs first differ. It stores nothing.

    The runtime matters because a lane can answer one turn on a fallback and
    the next on its first runtime again: that request can still read what the
    first runtime cached a turn earlier. *)

(** {1 Finding the two requests} *)

type walk
(** A newest-first walk over the cost ledger for one Keeper turn. It finds
    the turn's first request: the turn's oldest raw row. Then it finds the
    newest earlier raw row of the same runtime. On the way it notes the turns
    whose spend was settled and the newest other runtime the Keeper used.

    Two facts bound the walk. One Keeper runs one turn at a time, so its rows
    of two turns never interleave. Its turn numbers only grow, across a trace
    rotation too: each turn spends the next number of the count the Keeper's
    meta keeps, and a rotation keeps that count running. So a row of a lower
    turn number, of any trace, means the turn has no row. *)

val start : keeper:string -> turn_ref:Ids.Turn_ref.t -> horizon_s:(string -> float) -> walk
(** [horizon_s runtime_id] is how far before the first request's start the
    walk looks for an earlier request of that runtime. It must be at least
    the longest lifetime such a request can ask for. *)

val visit : walk -> Dated_jsonl.recent_entry -> walk
(** Rows must arrive newest first. A row that is not JSON, or that the
    current cost row contract does not decode, cannot be attributed to a
    Keeper; it is counted and passed over. A raw row of this Keeper whose
    cache fields do not read ends the walk, because it could have been
    either request. *)

val finished : walk -> bool
(** No older row can change what the walk found. *)

val reads_before : walk -> float -> bool
(** [reads_before walk t] is whether a row that ended before [t] can still
    change what the walk finds. A reader stops opening older day files when
    it is [false]. *)

(** {1 The outcome}

    The answer's types and JSON are {!Keeper_cache_outcome_reading}, which
    the TUI links too. *)

(** The parts of a snapshot the comparison reads. *)
type snapshot_view =
  { runtime_profile : string
  ; parts : Keeper_provider_input_snapshot.part list
  }

val snapshot_view : Keeper_provider_input_snapshot.manifest -> snapshot_view

val lifetime_check : idle_s:float -> lifetime_s:float -> Keeper_cache_outcome_reading.lifetime_check

val idle :
  provider_default_s:(string -> (float, Keeper_cache_outcome_reading.default_unknown) result) ->
  earlier:Keeper_cache_outcome_reading.request ->
  current:Keeper_cache_outcome_reading.request ->
  Keeper_cache_outcome_reading.idle
(** [provider_default_s runtime_id] is the default lifetime the catalog
    declares for the provider that answers [runtime_id]. *)

val compare_prefix :
  earlier:Keeper_cache_outcome_reading.request ->
  earlier_snapshot:(snapshot_view, string) result ->
  current:Keeper_cache_outcome_reading.request ->
  current_snapshot:(snapshot_view, string) result ->
  Keeper_cache_outcome_reading.prefix

val reading_of_walk :
  walk ->
  provider_default_s:(string -> (float, Keeper_cache_outcome_reading.default_unknown) result) ->
  current_snapshot:(snapshot_view, string) result ->
  earlier_snapshot:(Ids.Turn_ref.t -> (snapshot_view, string) result) ->
  Keeper_cache_outcome_reading.reading
(** Ends the walk where it stands and builds the outcome. [earlier_snapshot]
    is read only when an earlier request was found in a settled turn. *)

(** {1 Reading} *)

type read_error = Ledger_unreadable of Dated_jsonl.read_error

val read_error_to_string : read_error -> string

val read :
  config:Workspace.config ->
  keeper:string ->
  turn_ref:Ids.Turn_ref.t ->
  born_at:float ->
  provider_default_s:(string -> (float, Keeper_cache_outcome_reading.default_unknown) result) ->
  (Keeper_cache_outcome_reading.reading, read_error) result
(** Walks the cost ledger from the day the turn's snapshot was written, or
    from today when it has none, back at most to the day the Keeper was
    created ([born_at]). *)
