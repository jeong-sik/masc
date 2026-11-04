(** Says that one of a workspace's datasets was written (RFC-0480 §3.4).

    The event is
    [{"type":"workspace_dataset_changed","dataset":<name>,"ts_unix":...}],
    with ["keeper"] for a dataset that belongs to one Keeper. It goes to the
    observers of [base_path]'s runtime only and carries no data: a reader that
    shows the named dataset reads it again from its own path.

    The server announces and the TUI decodes through this one type, so a
    dataset added here is a match arm both sides must handle. *)

type dataset =
  | Repositories
      (** The repository catalog, read by [GET /api/v1/repositories]. *)
  | Verification_requests
      (** The verification request store, read by the Verification queue. *)
  | Keeper_metrics of { keeper : string }
      (** [keeper]'s date-split metrics ledger
          ([.masc/keepers/<keeper>/metrics/]), whose tail the Keeper logs
          view reads. *)
  | Harness_verdicts
      (** The judge verdicts and operator labels [Eval_calibration] records,
          read by [GET /api/v1/dashboard/harness-health]. *)

val event_type : string

val dataset_name : dataset -> string
(** The ["dataset"] value the event carries. *)

val of_fields : (string * Yojson.Safe.t) list -> (dataset, string) result
(** Read the dataset an event's members name. A missing or unknown name, and
    a Keeper dataset without a non-empty ["keeper"], are errors. *)

val announce : base_path:string -> dataset -> unit
(** Broadcast the event to [base_path]'s runtime observers. A store calls this
    after its write, often under its own lock, so it must not yield and must
    not raise. An exception from resolving the runtime or from
    [Sse.broadcast_to], a [Cancelled] included, is counted on
    [keeper_sse_broadcast_failures] under the site
    [workspace_dataset_changed:<name>] and logged at WARN; the caller's next
    suspension point still sees a cancellation. *)

val install_store_observers : unit -> unit
(** Make the stores that live in libraries below this one report their writes
    to {!announce}. {!Repo_store} reports every catalog write attempt, under
    the catalog file lock. *)
