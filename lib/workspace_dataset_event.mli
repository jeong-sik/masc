(** Says that one of a workspace's datasets was written (RFC-0480 §3.4).

    The event is
    [{"type":"workspace_dataset_changed","dataset":<wire>,"ts_unix":...}] and
    goes to the observers of [base_path]'s runtime only. It carries no data: a
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
  | Runtime_config
      (** What [GET /api/v1/runtime/config/raw] reads may have changed: the
          server attempted a runtime.toml commit, or a server-run account
          login rewrote a credential file whose email it lists. A CLI or a
          hand edit is not announced. *)
  | Keeper_oauth_attempts of { keeper : string }
      (** The OAuth login attempts {!Keeper_oauth_pending} holds for
          [keeper], which [GET /api/v1/keepers/oauth/attempt-status] reads. The event names the Keeper only: no provider, attempt id,
          state, code or consent URL. *)
  | Clients
      (** What [GET /api/v1/dashboard/clients] lists from the workspace: an
          agent record's row ({!Workspace_agent_record}) or a purge. Keeper
          registry rows change with [keeper_row_changed] instead. *)

val event_type : string

val dataset_name : dataset -> string

val of_fields : (string * Yojson.Safe.t) list -> (dataset, string) result

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
    the catalog file lock. {!Keeper_oauth_pending} reports each attempt
    change, under its table lock, as {!Keeper_oauth_attempts}.
    {!Workspace_agent_record} reports a changed roster row as {!Clients}. *)
