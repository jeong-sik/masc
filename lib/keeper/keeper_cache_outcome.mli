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

val schema : string
(** [masc.keeper-cache-outcome.v1]. *)

(** One request as its raw cost row records it. *)
type request =
  { turn_ref : Ids.Turn_ref.t
  ; runtime_id : string
  ; scope : Runtime_usage_scope.t
  ; ended_at : float
      (** The row's [timestamp]. The ledger writes whole seconds, so the
          request ended within the second that follows. *)
  ; latency_ms : int option
  ; cache_read_tokens : int option
  ; cache_creation_tokens : int option
  ; lifetime : Agent_core.Types.cache_write_lifetime option
      (** [None] for a row written before rows recorded the lifetime. *)
  }

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

(** {1 The outcome} *)

type lifetime_check =
  | Outlived
      (** The later request started more than the lifetime after the
          earlier one, at every start time the two rows allow. *)
  | Within
      (** It started no later than the lifetime after it, at every start time
          the two rows allow. *)
  | Undecided
      (** The rows give each start to the second, and the lifetime falls
          inside that uncertainty. *)

(** Why the length of a provider's default lifetime is not known. *)
type default_unknown =
  | Default_undeclared
      (** The catalog row of the runtime's provider declares no length. *)
  | Runtime_inactive
      (** The runtime is not active in the running configuration, so which
          provider answered it is not known. *)

type lifetime =
  | Lifetime_unrecorded
      (** The earlier row names no lifetime: rows did not record one yet. *)
  | Provider_default_unknown of default_unknown
      (** The earlier request used its provider's default lifetime, whose
          length is not known. *)
  | Lifetime_declared of
      { lifetime_s : float
      ; check : lifetime_check
      }

type idle =
  | Start_unrecorded
      (** One of the two rows has no latency, so its start is unknown. *)
  | Idle of
      { idle_s : float
          (** From the earlier request's start to this one's, each taken as
              the row's whole-second end minus its latency. *)
      ; lifetime : lifetime
      }

type not_compared =
  | Earlier_turn_not_settled
      (** The earlier request's turn settled no spend, so its snapshot may
          hold a later request that failed rather than this one. *)
  | Snapshot_unread of
      { turn_ref : Ids.Turn_ref.t
      ; detail : string
      }
  | Snapshot_of_other_runtime of
      { turn_ref : Ids.Turn_ref.t
      ; runtime_profile : string
      }
      (** The turn's snapshot holds its last request, which another runtime
          answered. *)

type prefix =
  | Compared of
      { system_changed : bool
      ; tools_changed : bool
      ; messages : Keeper_projection_change.message_change
      }
      (** The two turns' snapshots compared. A snapshot holds its turn's last
          request, so a change inside this turn shows here as well. Only an
          [Appended] pair with neither flag set says the prefix stayed. *)
  | Not_compared of not_compared

type earlier =
  | No_earlier_request of { horizon_s : float }
      (** The runtime started no request in that many seconds before this
          one. *)
  | Earlier of
      { request : request
      ; idle : idle
      ; prefix : prefix
      }

type t =
  | Turn_not_in_ledger
      (** The ledger holds no raw row of the turn. *)
  | Ledger_row_unreadable of string
  | Not_per_request of request
      (** The turn's first row counts an official-client turn or
          conversation, not one provider request. *)
  | First_request of
      { request : request
      ; other_runtime_since : string option
          (** The newest other runtime the Keeper used between the earlier
              request and this one. *)
      ; earlier : earlier
      }

(** The parts of a snapshot the comparison reads. *)
type snapshot_view =
  { runtime_profile : string
  ; parts : Keeper_provider_input_snapshot.part list
  }

val snapshot_view : Keeper_provider_input_snapshot.manifest -> snapshot_view

val lifetime_check : idle_s:float -> lifetime_s:float -> lifetime_check

val idle :
  provider_default_s:(string -> (float, default_unknown) result) ->
  earlier:request ->
  current:request ->
  idle
(** [provider_default_s runtime_id] is the default lifetime the catalog
    declares for the provider that answers [runtime_id]. *)

val compare_prefix :
  earlier:request ->
  earlier_snapshot:(snapshot_view, string) result ->
  current:request ->
  current_snapshot:(snapshot_view, string) result ->
  prefix

type reading =
  { keeper : string
  ; turn_ref : Ids.Turn_ref.t
  ; unattributed_rows : int
      (** Rows the walk passed over without knowing whose they were. *)
  ; outcome : t
  }

val reading_of_walk :
  walk ->
  provider_default_s:(string -> (float, default_unknown) result) ->
  current_snapshot:(snapshot_view, string) result ->
  earlier_snapshot:(Ids.Turn_ref.t -> (snapshot_view, string) result) ->
  reading
(** Ends the walk where it stands and builds the outcome. [earlier_snapshot]
    is read only when an earlier request was found in a settled turn. *)

val to_json : reading -> Yojson.Safe.t

(** {1 Reading} *)

type read_error = Ledger_unreadable of Dated_jsonl.read_error

val read_error_to_string : read_error -> string

val read :
  config:Workspace.config ->
  keeper:string ->
  turn_ref:Ids.Turn_ref.t ->
  born_at:float ->
  provider_default_s:(string -> (float, default_unknown) result) ->
  (reading, read_error) result
(** Walks the cost ledger from the day the turn's snapshot was written, or
    from today when it has none, back at most to the day the Keeper was
    created ([born_at]). *)
