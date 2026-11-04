(** Writes the agent records under [.masc/agents/] and reports a change of
    what the Clients roster draws for one (RFC-0480 §3.4).

    The roster lists a record unless it is [Inactive], with its name, type,
    status, current Task and Keeper. A write that changes none of those (a
    heartbeat moving [last_seen], a reconcile that finds nothing to clear) is
    not reported. Every writer of an agent record goes through here. *)

val install_rows_changed_observer : (Workspace_utils_backend_setup.config -> unit) -> unit
(** Called after a write whose record the roster draws differently. It runs
    under the record's file lock where the caller holds one, so it must not
    yield and must not raise. The default does nothing. *)

val report_roster_changed : Workspace_utils_backend_setup.config -> unit
(** Report a roster change that is not a record write: a name added to or
    pruned from the workspace state's [active_agents]. *)

val write :
  Workspace_utils_backend_setup.config ->
  string ->
  previous:Masc_domain.agent option ->
  Masc_domain.agent ->
  unit
(** [write config path ~previous agent] writes [agent] to [path] as
    {!Workspace_utils_ops.write_json} does (a failure is logged) and reports
    the change from [previous], the record the caller read, or [None] for a
    new one. A failed write is reported as attempted. *)

val write_commit_result :
  Workspace_utils_backend_setup.config ->
  string ->
  previous:Masc_domain.agent option ->
  Masc_domain.agent ->
  (Workspace_utils_ops.write_json_commit, string) result
(** {!write} through {!Workspace_utils_ops.write_json_commit_result}, keeping
    its result. *)
