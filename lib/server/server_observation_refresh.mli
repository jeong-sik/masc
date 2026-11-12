(** Workspace-bound source observations. Each scope owns its subscription,
    read debt, worker and last-good cache, even when a replacement uses the
    same path. Completion callbacks are gated by the captured epoch. *)

type surface = Execution_trust | Execution | Transport_health

val install_scoped :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  install:(scope:Mcp_server.workspace_scope -> sw:Eio.Switch.t ->
           is_current:(unit -> bool) -> unit) ->
  unit
(** Install one generation's source subscriptions and workers, then return.
    The supplied switch and [is_current] fence belong to that captured scope.
    On replacement the helper cancels and releases the old switch before
    installing the new generation. An already-resolved replacement promise
    is observed too. The parent owns a daemon, so quiet subscribers never
    prevent normal release. This owns scope lifetime, not refresh policy. *)

val affects : surface -> Server_observation_input.t -> bool
(** Closed original-input dependency matrix. Computed snapshots and unrelated
    datasets are never reasons to read this surface. *)

type 'a generation = {
  config : Proactive_refresh.config;
  compute : unit -> 'a;
  on_result : 'a -> unit;
  next_deadline : 'a -> float option;
}

val start :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  surface:surface ->
  generation:(scope:Mcp_server.workspace_scope -> sw:Eio.Switch.t -> 'a generation) ->
  unit
(** Subscribe before constructing the generation's initial read. The
    generation callback creates one cache/compute binding for the captured
    scope and must not perform the read itself. Changes coalesce into one
    bounded mailbox; an input arriving during a read remains owed.

    On scope replacement the old switch is cancelled before a new generation
    is admitted. The captured scope is checked immediately before completion
    and failure callbacks. Callbacks must retain their captured cache/scope;
    a check is not a lock against a concurrent replacement. Generation-local
    cache cells also keep a
    late offloaded answer from replacing the new scope's last-good value.
    Normal parent switch release cancels the quiet daemon and unsubscribes. *)
