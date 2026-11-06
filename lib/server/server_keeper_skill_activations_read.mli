(** One Keeper's skill activation ledger, read on its own (RFC-0483).

    Two answers come from the same ledger. [GET
    /api/v1/keepers/skill-activations?keeper=<name>] answers with
    {!activations_json}: the whole projection, which the Activations pane and
    the web Tools panel draw for the Keeper they show. [GET
    /api/v1/keepers/skill-usage?keeper=<name>] answers with {!usage_json}: one
    row per catalog surface the Keeper used, which the Usage pane reads for
    every Keeper. Usage rows come from the runtime's cached session ledger,
    so reading every Keeper does not reload every ledger. A reader that heard
    [keeper_skill_activations_changed] for a Keeper reads that Keeper again. *)

val usage_rows :
  config:Workspace.config ->
  trace_id:Keeper_id.Trace_id.t ->
  Keeper_skill_catalog.skill list ->
  Yojson.Safe.t list
(** For each catalog surface the cached session ledger used, its reference and
    how many times it was invoked, delivered and acted on, and when it was last
    used. A surface the ledger never used has no row. *)

val activations_json : config:Workspace.config -> keeper_name:string -> Yojson.Safe.t
(** The activation projection for [keeper_name], the answer of
    [GET /api/v1/keepers/skill-activations?keeper=]. *)

val usage_json : config:Workspace.config -> keeper_name:string -> Yojson.Safe.t
(** [usage.state] for [keeper_name] is one of:
    - [ready], with [rows] from {!usage_rows};
    - [no_session] when the Keeper has no current session, so nothing was
      recorded;
    - [unavailable], with [reason] and [detail], when its metadata or its
      ledger cannot be read;
    - [no_catalog] when the ledger was read but the workspace has no ready
      skill catalog to count it against, including a base path that does
      not resolve to a workspace. *)
