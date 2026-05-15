(** Closed sum type for the [(event_family, event_kind)] label pair of
    [Prometheus.metric_coord_telemetry_drop].

    Introduced by RFC-0088 §4 Option A (Counter-as-Fix umbrella scoping,
    Coord async-context-free telemetry drop sub-scope) as a fold-in
    amendment to RFC-0044 (`docs/rfc/RFC-0044-persistence-read-drop-typed.md`).

    Motivation: the three call sites in [Coord] that invoke
    [warn_telemetry_drop] (after catching [Stdlib.Effect.Unhandled] when
    the lifecycle/task/accountability hook runs outside an Eio scheduler)
    previously passed free strings for [event_family] / [event_kind].
    [Read_drop_reason.t] closed-sums the [reason] label of
    [metric_persistence_read_drops]; this module mirrors that pattern for
    the coord drop counter so dashboards built around the existing
    (family, kind) label set cannot silently lose tracking when a new
    site is added.

    Per RFC-0088 §4.1 the counter itself is retained: the "data loss"
    here is loss of a single observability event, not durable state, and
    the caller is a fire-and-forget lifecycle hook with no [Result.t]
    chain to propagate to. So this module narrows the *typing* surface
    without altering the *behaviour* contract.

    Adding a new constructor is, by construction, a compile obligation
    for {!Coord.warn_telemetry_drop} and every caller.

    @stability Evolving *)

(** Lifecycle kind, mirrored from {!Coord_hooks.agent_lifecycle_event}.
    Kept as a distinct sum (rather than re-exporting the [Coord_hooks]
    variant) so the wire mapping is owned by this module and adding a
    lifecycle variant in [Coord_hooks] does not silently widen the drop
    counter label set without a deliberate change here. *)
type lifecycle_kind =
  | Lifecycle_join
  | Lifecycle_rejoin
  | Lifecycle_leave

(** Drop event identifies which Coord sub-path raised
    [Stdlib.Effect.Unhandled]. *)
type t =
  | Agent_lifecycle of lifecycle_kind
      (** Lifecycle observer ([observe_agent_lifecycle]) caught
          [Effect.Unhandled] from [Audit_log.log_action] or
          [Telemetry_eio.track_agent_*]. *)
  | Task_transition of Masc_domain.task_action
      (** Task transition observer ([observe_task_transition_event])
          caught [Effect.Unhandled] from [Audit_log.log_action] or
          [Telemetry_eio.track_task_*]. *)
  | Accountability of Masc_domain.task_action
      (** Keeper accountability hook ([Keeper_accountability.record_task_transition])
          caught [Effect.Unhandled]. Carries the originating
          [task_action] so dashboards can correlate dropped
          accountability records with the transition that produced
          them. *)

(** Wire label for the [event_family] Prometheus label. Stable: matches
    the byte-for-byte strings emitted before the typed swap-over
    (["agent_lifecycle"], ["task_transition"], ["accountability"]) so
    Prometheus label cardinality does not change at the migration
    boundary. *)
val family_to_wire : t -> string

(** Wire label for the [event_kind] Prometheus label. For
    [Agent_lifecycle] this is one of ["join" / "rejoin" / "leave"]
    (matching {!Coord_hooks.agent_lifecycle_event_to_string}). For
    [Task_transition] / [Accountability] it is
    {!Masc_domain.task_action_to_string} of the carried action
    (["claim" / "start" / "done" / ...]).

    Stable: the wire strings are unchanged from the pre-typed callers,
    so existing Grafana dashboards / alerting rules keep matching. *)
val kind_to_wire : t -> string

(** Convenience: both labels in the order Prometheus expects, suitable
    for direct splat into the [~labels] argument of
    [Prometheus.inc_counter]. Equivalent to
    [[("event_family", family_to_wire t); ("event_kind", kind_to_wire t)]]
    but centralised so the label *names* are also locked at one site. *)
val to_prometheus_labels : t -> (string * string) list

(** Pretty-printer (emits ["family/kind"] using the wire labels). *)
val pp : Format.formatter -> t -> unit
