(** Keeper Failure Circuit Breaker — detect repeated tool failures and
    inject corrective hints into error responses.

    After [threshold] consecutive failures of the same error class,
    appends a corrective hint to the error message. Resets on success.

    @since v0.5.11 *)

(** Coarse error categories for grouping failures. *)
type error_class =
  | Path_not_found
  | Path_not_allowed
  | Cwd_not_directory
  | Shell_exit_nonzero
  | Other

(** Classify an error message string into an error class. *)
val classify_error : string -> error_class

(** Record a successful tool call (resets consecutive counter). *)
val record_success : keeper_name:string -> unit

(** Enrich an error message with a corrective hint if the circuit
    breaker threshold has been reached. Returns the original message
    unchanged if under threshold, or message + hint if tripped. *)
val maybe_enrich_error : keeper_name:string -> error_msg:string -> string

(** {1 Failure signature diagnostics (task-240)}

    When the breaker trips, "3 consecutive other failures" on its own
    gives an operator no handle on *which* three failures caused it.
    To preserve that context, every [record_failure] call also writes a
    bounded-size signature (timestamp + class + fingerprint of the
    error message) to a per-keeper ring buffer. The trip log line
    names the buffer contents, and downstream observers (dashboard,
    snapshot JSON) can read them via [recent_failures_of]. *)

type failure_signature =
  { ts : float
  ; cls : error_class
  ; fingerprint : string
  }

(** Collapse an error message into a single-line, size-bounded
    fingerprint suitable for logs and JSON payloads. Default
    [max_len = 120]. Not cryptographic — pattern-matching only. *)
val fingerprint_of_error : ?max_len:int -> string -> string

(** Last-N failure signatures for [keeper_name] (newest first). Returns
    [[]] for keepers that have never failed. N is bounded internally
    (currently 3, matching the trip threshold). *)
val recent_failures_of : keeper_name:string -> failure_signature list

(** JSON snapshot of all breaker states for diagnostics.

    Each entry adds a [recent_failures] array (newest first):
    {[ { "ts": 1..., "class": "other", "fingerprint": "..." } ]}
    *)
val snapshot_json : unit -> Yojson.Safe.t

(** {1 Observable display state (LT-16-KCB)}

    The internal breaker advances through several micro-states during
    [record_failure], but [tripped] is NOT observable — on trip, the
    function immediately resets [consecutive_count] to 0 and only
    [total_tripped] increments. Any snapshot taken between tool calls
    therefore reports one of three stable states:

    - ["clean"]   — never failed: [consecutive_count = 0] AND
                    [total_tripped = 0].
    - ["warning"] — partial failure streak: [consecutive_count > 0]
                    (always below [threshold] because a trip resets it).
    - ["cooling"] — recovered from at least one trip:
                    [consecutive_count = 0] AND [total_tripped > 0].

    Exposed so downstream observers (the composite-FSM matrix, test
    harnesses) can classify a KCB snapshot without reaching into the
    private mutable record.

    @since v0.10.x — LT-16-KCB Phase 1. *)

(** Display state derived from raw counter values. *)
type display_state =
  | Clean
  | Warning
  | Cooling

(** Pure classifier: [derive_display_state ~consecutive_count ~total_tripped].
    Does not care about [threshold] — [consecutive_count] above threshold
    cannot occur in a well-formed record (the mutator resets on trip),
    so any non-zero count is classified as [Warning]. *)
val derive_display_state : consecutive_count:int -> total_tripped:int -> display_state

(** Lower-case string rendering ([clean | warning | cooling]). *)
val display_state_to_string : display_state -> string

(** Per-keeper display state lookup. Returns [Clean] for keepers that
    have never entered the internal state table — matching the
    "never failed" semantic. Safe to call from any fiber; acquires
    the same read lock as {!snapshot_json}.

    Single-keeper alternative to classifying a whole snapshot — used by
    the composite observer so fleet snapshotting stays O(fleet). *)
val display_state_of : keeper_name:string -> display_state

(** Walk the JSON produced by {!snapshot_json} and return an association
    list from [keeper_name] to its display state. Returns [Error msg] if
    the JSON is not shaped as expected. Useful for composite observers
    that need to fold KCB state into a fleet matrix row.

    Unknown / missing fields on a per-entry basis are skipped silently
    rather than failing the whole walk, so one malformed record does not
    hide the rest. *)
val classify_snapshot_json
  :  Yojson.Safe.t
  -> ((string * display_state) list, string) result
