(** Discord_dual_run_stats — measurement vehicle for RFC-0203 §Phase 2
    (Dual-run).

    Two paths run side-by-side during the dual-run window: the
    long-standing Python sidecar (path = [Sidecar]) and the in-process
    OCaml gateway (path = [Builtin]). Both increment counters and
    append entries to a shared JSONL audit so an offline diff can
    answer "did both paths see the same event count and the same
    outbound success rate?"

    No string classifier — every observable category is a closed
    sum, so a new event kind or outcome forces every reader and
    writer to be updated at compile time.

    @since RFC-0203 Phase 2 *)

(** {1 Origin path}

    Which dual-run path produced the event. *)
type path =
  | Sidecar  (** Python sidecar at sidecars/discord-bot. *)
  | Builtin  (** In-process OCaml Discord_gateway_client. *)

val string_of_path : path -> string

(** {1 Event taxonomy} *)

(** Inbound gateway events the dual-run cares about. Mirrors
    {!Discord_gateway_state.dispatched_event} but omits the bulky
    payload — only the kind matters for counter buckets. *)
type inbound_kind =
  | Ready
  | Message_create
  | Reaction_add
  | Ignored

val string_of_inbound_kind : inbound_kind -> string

(** Outbound REST attempt outcome. Wired later when the outbound
    path runs through the builtin (today the sidecar still owns
    outbound). The taxonomy is closed so adding a new outcome
    forces every emit site to be updated. *)
type outbound_outcome =
  | Ok_message_id of string
  | Err_missing_token
  | Err_transient of string
  | Err_workflow of string
  | Err_runtime of string

val string_of_outbound_outcome : outbound_outcome -> string

(** {1 Snapshot}

    Read-only view of the live counters at one instant. Returned by
    {!snapshot}; never the counters themselves so callers can not
    accidentally mutate. *)
type counts =
  { ready : int
  ; message_create : int
  ; reaction_add : int
  ; ignored : int
  ; outbound_ok : int
  ; outbound_err_missing_token : int
  ; outbound_err_transient : int
  ; outbound_err_workflow : int
  ; outbound_err_runtime : int
  }

val zero_counts : counts

val counts_to_yojson : counts -> Yojson.Safe.t

(** {1 Recording — fast path}

    These increment the live atomic counters and append a JSONL
    audit row. They never raise — IO errors are logged and
    swallowed (the dual-run audit is best-effort, not a load-bearing
    persistence layer). *)

val record_inbound : path:path -> inbound_kind -> unit

val record_outbound : path:path -> outbound_outcome -> unit

(** {1 Inspection} *)

val snapshot : path:path -> counts
(** Atomic-snapshot the live counters for the given path. *)

val audit_path : unit -> string
(** Filesystem path the recorders append to. Respects the
    [MASC_DISCORD_TRAFFIC_AUDIT_PATH] env var; defaults to
    [<base>/.gate/runtime/discord/traffic_audit.jsonl]. *)

(** {1 Reset — testing only}

    Zero the live counters for both paths. Not used in production
    code; exposed for unit tests that need a clean slate. *)
val reset_for_test : unit -> unit
