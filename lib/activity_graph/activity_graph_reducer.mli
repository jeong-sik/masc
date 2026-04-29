(** Activity_graph_reducer — graph reducer that folds {!event}s
    into mutable node / edge accumulators.

    The reducer is the single seam between the append-only event
    log and the live graph view.  {!Activity_graph} consumes
    {!reduce_event} from this module via [open] and hands it
    Hashtbl-backed accumulators on every refresh.

    Internal: [entity_node_id], [payload_string], [is_generic_status],
    [semantic_multiplier], [ensure_node], [ensure_entity_node],
    [ensure_edge].  All consumed only inside {!reduce_event}.  Future
    "expose lower-level reducers" PR can reopen explicitly. *)

(** {1 Accumulator types} *)

type node_acc = {
  node_id : string;
  node_kind : string;
  mutable label : string;
  mutable status : Activity_graph_types.node_status;
  mutable weight : int;
  mutable semantic_weight : float;
  mutable last_event_at : string;
  mutable meta : Yojson.Safe.t;
}
(** Per-node accumulator.  Mutable fields for in-place update —
    each event hit on the same [node_id] increments [weight] and
    refreshes [last_event_at] / [meta] in place. *)

type edge_acc = {
  edge_id : string;
  source : string;
  target : string;
  edge_kind : string;
  mutable weight : int;
  mutable active : bool;
  mutable last_event_at : string;
  mutable meta : Yojson.Safe.t;
}
(** Per-edge accumulator.  Mutable fields for in-place update —
    each event hit on the same [(source, kind, target)] tuple
    increments [weight] and updates [active] / [last_event_at] /
    [meta] in place.

    [edge_id] format pinned: ["<source>|<kind>|<target>"]. *)

(** {1 Reducer} *)

val reduce_event :
  nodes:(string, node_acc) Hashtbl.t ->
  edges:(string, edge_acc) Hashtbl.t ->
  Activity_graph_types.event ->
  unit
(** [reduce_event ~nodes ~edges value] folds [value] into the
    accumulators in place.  Effects (in order):

    + Ensure a [room:<room_id>] node exists with status [Coord]
      and the event's [ts_iso].
    + If [value.actor = Some actor], ensure the entity node with
      fallback status [Active] and add a [belongs_to] edge to the
      room node.
    + If [value.subject = Some subject], same with fallback status
      [Observed].
    + Apply event-kind-specific edges between actor / subject /
      room (e.g. [task.assigned] -> actor->subject [assigned] edge).

    Semantic weight delta applied to nodes:
    {!Activity_graph_types}-tagged kinds map to fixed multipliers
    (completion = 5.0, lifecycle = 3.0, routine = 1.0, default 1.0).
    Pinned at the contract seam — operators see [semantic_weight]
    in dashboards as the "importance" axis. *)
