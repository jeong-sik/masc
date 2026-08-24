(** Activity_graph_reducer — graph reducer that folds {!event}s
    into node / edge accumulators held by the caller's tables.

    The reducer is the single seam between the append-only event
    log and the live graph view.  {!Activity_graph} consumes
    {!reduce_event} from this module via [open] and hands it
    Hashtbl-backed accumulators on every refresh.

    Internal: [entity_node_id], [payload_string], [is_generic_status],
    [ensure_node], [ensure_entity_node], [ensure_edge].  All consumed only inside {!reduce_event}.  Future
    "expose lower-level reducers" PR can reopen explicitly. *)

(** {1 Accumulator types} *)

type node_acc = {
  node_id : string;
  node_kind : string;
  label : string;
  status : Activity_graph_types.node_status;
  weight : int;
  last_event_at : string;
  meta : Yojson.Safe.t;
}
(** Per-node accumulator.  Immutable: each event hit on the same
    [node_id] rebinds the table entry to a record with [weight]
    incremented and [last_event_at] / [meta] refreshed.  A record read
    out of the table before a later event keeps the values it was read
    with. *)

type edge_acc = {
  edge_id : string;
  source : string;
  target : string;
  edge_kind : string;
  weight : int;
  active : bool;
  last_event_at : string;
  meta : Yojson.Safe.t;
}
(** Per-edge accumulator.  Immutable, like {!node_acc}: each event hit
    on the same [(source, kind, target)] tuple rebinds the table entry
    with [weight] incremented and [active] / [last_event_at] / [meta]
    refreshed.

    [edge_id] format pinned: ["<source>|<kind>|<target>"]. *)

(** {1 Reducer} *)

val reduce_event :
  nodes:(string, node_acc) Hashtbl.t ->
  edges:(string, edge_acc) Hashtbl.t ->
  Activity_graph_types.event ->
  unit
(** [reduce_event ~nodes ~edges value] folds [value] into the
    accumulator tables.  The tables are mutated; the records they hold
    are replaced, not written through.  Effects (in order):

    + If [value.actor = Some actor], ensure the entity node with
      fallback status [Active].
    + If [value.subject = Some subject], same with fallback status
      [Observed].
    + Apply event-kind-specific edges between actor / subject /
      workspace (e.g. [task.assigned] -> actor->subject [assigned] edge). *)
