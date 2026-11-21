(** Why the first provider request of a Keeper turn read or wrote the prompt
    cache (RFC #53746 §3.2): the answer and its JSON.

    The server derives the answer in [Keeper_cache_outcome] from the cost
    ledger and the provider-input snapshots, and serves it at
    [/api/v1/keepers/<name>/cache-outcome]. The TUI reads it back with
    {!of_json}. The types live here, beside {!Turn_record}, so both sides read
    one definition. A tagged object has a closed list of kinds: a new
    constructor does not compile until the writer and the reader both name
    it. *)

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
  ; lifetime : Llm_provider.Types.cache_write_lifetime option
      (** [None] for a row written before rows recorded the lifetime. *)
  }

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
[@@deriving enumerate]

(** Why the length of a provider's default lifetime is not known. *)
type default_unknown =
  | Default_undeclared
      (** The catalog row of the runtime's provider declares no length. *)
  | Runtime_inactive
      (** The runtime is not active in the running configuration, so which
          provider answered it is not known. *)
[@@deriving enumerate]

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
      ; messages : Message_list_change.t
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

type reading =
  { keeper : string
  ; turn_ref : Ids.Turn_ref.t
  ; unattributed_rows : int
      (** Rows the walk passed over without knowing whose they were. *)
  ; outcome : t
  }

val to_json : reading -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (reading, string) result
(** Reads a {!to_json} object back. Another schema, an unknown kind or label,
    or a field of another shape is an error; nothing is read as a default. *)
