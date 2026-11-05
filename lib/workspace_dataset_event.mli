(** Says that one of a workspace's datasets was written (RFC-0480 §3.4).

    The event is
    [{"type":"workspace_dataset_changed","dataset":<wire>,"ts_unix":...}] and
    goes to the observers of [base_path]'s runtime only. A dataset that
    belongs to one subject carries its name beside the dataset name — a
    Keeper's OAuth login attempts carry ["keeper"]. It carries no data: a
    reader that shows the named dataset reads it again from its own path.

    The server announces and the TUI decodes through this one type, so a
    dataset added here is a match arm both sides must handle. *)

type dataset =
  | Repositories
      (** The repository catalog, read by [GET /api/v1/repositories]. *)
  | Verification_requests
      (** The verification request store, read by the Verification queue. *)
  | Harness_verdicts
      (** The judge verdicts and operator labels [Eval_calibration] records,
          read by [GET /api/v1/dashboard/harness-health]. *)
  | Clients
      (** What [GET /api/v1/dashboard/clients] lists: an agent record's row
          ({!Workspace_agent_record}) or a purge. Keeper registry rows change
          with [keeper_row_changed] instead. *)
  | Account_emails
      (** The account emails a server-run login's rewritten credentials hold,
          read by the setup account-emails route the Metrics and Config
          models panes draw. A login run in a terminal has no writer here
          and is not announced. *)
  | Provider_usage
      (** A provider usage report was recorded: the windows of the resolved
          document and the points of the provider-usage-history store moved
          together. *)
  | Provider_standing
      (** A runtime's quota or rate-limit standing in the resolved document
          changed, a reset passing included, or the standing stopped or
          started building. The history does not move with it. *)
  | Keeper_costs
      (** What [GET /api/v1/dashboard/keeper-costs] answers for its default
          window: a Keeper metrics row other than a heartbeat was written, or
          a kept row or day file left the window. *)
  | Keeper_oauth_attempts of { keeper : string }
      (** The OAuth login attempts {!Keeper_oauth_pending} holds for
          [keeper], which [GET /api/v1/keepers/oauth/attempt-status] reads.
          The event names the Keeper only: no provider, attempt id, state,
          code or consent URL. *)
  | Memory_health of { keeper : string }
      (** An input of [keeper]'s row in
          [GET /api/v1/dashboard/keeper-memory-health] was written. A reader
          reads that row alone ([?keeper=]); a Keeper that left has no row
          (RFC-0487). *)

val event_type : string

(** The kinds a dataset comes in, without its subject. The wire name has one
    table here ({!Kind.to_wire} / {!Kind.of_wire}), so adding a dataset is a
    match arm the compiler checks. *)

module Kind : sig
  type t =
    | Repositories
    | Verification_requests
    | Harness_verdicts
    | Clients
    | Account_emails
    | Provider_usage
    | Provider_standing
    | Keeper_costs
    | Keeper_oauth_attempts
    | Memory_health

  val to_wire : t -> string

  val of_wire : string -> t option
end

val kind : dataset -> Kind.t

val dataset_to_wire : dataset -> string

val of_fields : (string * Yojson.Safe.t) list -> (dataset, string) result
(** Reads the whole event field list: the dataset name and, for a dataset
    that names a subject, the subject it carries. An event whose subject
    dataset names no subject, or whose dataset this build was not taught, is
    an [Error] with the reason; the caller reports it on the undecodable
    path. *)

val announce : base_path:string -> dataset -> unit
(** Broadcast the event to [base_path]'s runtime observers. A store calls this
    after its write, often under its own lock, so it must not yield and must
    not raise. An exception from resolving the runtime or from
    [Sse.broadcast_to], a [Cancelled] included, is counted on
    [keeper_sse_broadcast_failures] under the site
    [workspace_dataset_changed:<wire>] and logged at WARN; the caller's next
    suspension point still sees a cancellation. *)

val install_store_observers : unit -> unit
(** Make the stores that live in libraries below this one report their writes
    to {!announce}. {!Repo_store} reports every catalog write attempt, under
    the catalog file lock. *)
