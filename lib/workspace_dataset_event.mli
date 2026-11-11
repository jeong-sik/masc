(** Says that one of a workspace's datasets was written (RFC-0480 §3.4).

    The event is
    [{"type":"workspace_dataset_changed","dataset":<name>,"ts_unix":...}],
    with the ["keeper"], ["machine"] or ["instance_id"] scope of a dataset that
    belongs to one such resource, or a Browser target and revision. It goes to
    the observers of [base_path]'s runtime only and carries no dataset rows: a
    reader that shows the named dataset reads it again from its own path.

    The server announces and the TUI decodes through this one type, so a
    dataset added here is a match arm both sides must handle. *)

type browser_view =
  | Read
  | Scene of { scene_view : Browser_lane.scene_view; scope : Browser_lane.node_ref option }
  | Viewport

type browser_scope = {
  source : Browser_lane.Lane_name.t;
  client_id : string option;
  tab_id : int;
  view : browser_view;
}

type browser_observation = { scope : browser_scope; revision : string }

val browser_scope_fields : browser_scope -> (string * Yojson.Safe.t) list
(** The target identity shared by the event and the observer subscription.
    Contains no page contents or image bytes. *)

val browser_scope_query : browser_scope -> string
(** URI-encoded query parameters preserving {!browser_scope_fields}. *)

val browser_scope_of_fields :
  (string * Yojson.Safe.t) list -> (browser_scope, string) result

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
  | Goals
      (** The Goal projection: the Goals, the verification ledger and the
          measurements the planning projection and the Goal tree join. *)
  | Runtime_config
      (** What [GET /api/v1/runtime/config/raw] reads may have changed: the
          server attempted a runtime.toml commit, or a server-run account
          login rewrote a credential file whose email it lists. A CLI or a
          hand edit is not announced. *)
  | Connectors
      (** What [GET /api/v1/gate/connectors] and the connector name pages
          project: gateway and poll states, ready records, startup errors,
          directories, bindings, learned names and trigger policies. *)
  | Keeper_oauth_attempts of { keeper : string }
      (** The OAuth login attempts {!Keeper_oauth_pending} holds for
          [keeper], which [GET /api/v1/keepers/oauth/attempt-status] reads.
          The event names the Keeper only: no provider, attempt id, state,
          code or consent URL. *)
  | Skill_activations of { keeper : string }
      (** A Skill activation ledger row written in one of [keeper]'s turns:
          an activation, a delivery, an action or a rejected transition, which
          the Tools Skill record ([GET /dashboard/tools?keeper=]) and the Skill
          usage counts ([GET /api/v1/skills]) read. *)
  | Skill_catalog
      (** A new Skill catalog snapshot was published, which
          [GET /api/v1/skills] and the Tools call scope read. *)
  | Clients
      (** What [GET /api/v1/dashboard/clients] lists from the workspace: an
          agent record's row ({!Workspace_agent_record}) or a purge. Keeper
          registry rows change with [keeper_row_changed] instead. *)
  | Account_emails
      (** The account emails a server-run login's rewritten credentials hold,
          read by the setup account-emails route the Metrics and Config
          models panes draw. A login run in a terminal has no writer here
          and is not announced. *)
  | Provider_usage
      (** A provider usage report was recorded: the windows of
          [GET /api/v1/runtime/resolved] and the points of
          [GET /api/v1/dashboard/provider-usage-history] moved. *)
  | Provider_standing
      (** A runtime's quota or rate-limit standing in
          [GET /api/v1/runtime/resolved] changed, a reset passing included,
          or the standing stopped or started building. The history does not
          move with it. *)
  | Keeper_costs
      (** What [GET /api/v1/dashboard/keeper-costs] answers for its default
          window: a Keeper metrics row other than a heartbeat was written, or
          a kept row or day file left the window. *)
  | Workspace_health
      (** The Home Health line, [GET /api/v1/dashboard/health-line]: a
          recomputation of the mission briefing moved the workspace health,
          the Keeper listing or the count of Keepers whose state no one can
          read. *)
  | Runtime_probe
      (** The server's runtime probe landed, [GET /api/v1/dashboard/runtime-probe]:
          a probe a forced read asked for, or a periodic one whose findings
          differ from the last probe. *)
  | Runtime_metrics
      (** What [GET /api/v1/runtime/metrics] answers: a Keeper decision row or
          a cost ledger row was written, or a kept row or cost day file left
          its 24-hour window. *)
  | Lanes
      (** The operator Lane inventory, [GET /api/v1/lanes]: the displayed
          instance phase, presence, revision, application, or browser/machine
          summary changed. *)
  | Machine_live of { machine : Machine_lane.t }
      (** A machine worker committed a new frame observation. No frame bytes
          travel in this event. *)
  | Memory_health of { keeper : string }
      (** An input of [keeper]'s row in
          [GET /api/v1/dashboard/keeper-memory-health] was written. A reader
          reads that row alone ([?keeper=]); a Keeper that left has no row. *)
  | World_memory
      (** The workspace memory inventory's durable ledger, briefing or
          constituent Keeper memory changed. Readers revalidate the inventory
          after this event rather than using a periodic HTTP read. *)
  | Play_seats
      (** A Play invitation or participation changed. The event carries no
          credential or participant data; readers revalidate their own grant. *)
  | Dashboard_observation of Sse_event.Types.dashboard_observation_changed_payload
      (** A mounted Dashboard reader's input changed. Topics and optional
          Keeper/operation scopes use the shared ATD contract. *)
  | Play_room of { machine : Machine_lane.t }
      (** A public Play room message or public membership changed. [machine]
          is the source, not a filter: the transcript is shared across machines. *)
  | Lane_addons of { instance_id : string }
      (** The open Add-on Inspect of [instance_id] has a newly committed
          observation. The event carries the instance and its reader
          visibility, never its rows. *)
  | Browser_observation of browser_observation
      (** The selected browser target has a changed observation revision.
          Carries identity only: no page contents or image bytes. *)

val event_type : string

module Kind : sig
  type t =
    | Repositories
    | Verification_requests
    | Keeper_metrics
    | Harness_verdicts
    | Goals
    | Runtime_config
    | Connectors
    | Keeper_oauth_attempts
    | Skill_activations
    | Skill_catalog
    | Clients
    | Account_emails
    | Provider_usage
    | Provider_standing
    | Keeper_costs
    | Workspace_health
    | Runtime_probe
    | Runtime_metrics
    | Lanes
    | Machine_live
    | Memory_health
    | World_memory
    | Play_seats
    | Dashboard_observation
    | Play_room
    | Lane_addons
    | Browser_observation

  val to_wire : t -> string
  val of_wire : string -> t option
end

val kind : dataset -> Kind.t
val dataset_to_wire : dataset -> string
val dataset_name : dataset -> string
(** The ["dataset"] value the event carries. *)

val of_fields : (string * Yojson.Safe.t) list -> (dataset, string) result
(** Read the dataset an event's members name. A missing or unknown name is an
    error, as are a missing or empty resource scope and an unknown machine. *)

val announce : base_path:string -> dataset -> unit
(** Broadcast the event to [base_path]'s runtime observers. A store calls this
    after its write, often under its own lock, so it must not yield and must
    not raise. An exception from resolving the runtime or from
    [Sse.broadcast_to], a [Cancelled] included, is counted on
    [keeper_sse_broadcast_failures] under the site
    [workspace_dataset_changed:<name>] and logged at WARN; the caller's next
    suspension point still sees a cancellation. *)

val announce_dashboard_observation :
  base_path:string -> scope:Sse_event.Types.dashboard_observation_scope ->
  Sse_event.Types.dashboard_observation_topic -> unit
(** Announce one typed input change through the existing runtime observer bus.
    It carries no snapshot rows and follows {!announce}'s non-yielding contract. *)

val announce_lane_addon :
  base_path:string -> instance_id:string -> visibility:Yojson.Safe.t -> unit
(** Announce an open Add-on with its durable reader visibility. Live and replay
    delivery rejects a missing or malformed visibility instead of exposing the
    instance. The failure metric and non-raising contract match {!announce}. *)

val install_store_observers : unit -> unit
(** Make the stores that live in libraries below this one report their writes
    to {!announce}. {!Repo_store} reports every catalog write attempt, under
    the catalog file lock. {!Keeper_oauth_pending} reports each attempt
    change, under its table lock, as {!Keeper_oauth_attempts}.
    {!Workspace_agent_record} reports a changed roster row as {!Clients}. *)
