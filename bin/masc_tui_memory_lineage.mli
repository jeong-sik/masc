(** A captured, read-only neighbourhood within one Keeper's retained history.
    Edges come only from persisted event endpoints, never claim similarity. *)
type t = private {
  selected : Masc.Keeper_memory_activity.event;
  events : Masc.Keeper_memory_activity.event list;
  journal_lines : int;
  limit : int;
  notes : string list;
}

val select : event_id:string -> Masc.Keeper_memory_activity.t -> t option
(** [None] when the selected event is absent. Retains exactly the connected
    component of observed memory identities, in original event order. *)

val mermaid : ko:bool -> t -> string
(** Summarized labels, rounded fact nodes and explicit transition nodes for
    the existing offline Pele preview. Unknown relations use dotted edges.
    The retained window and partial/stale notes remain part of the chart.
    Full claims stay in the existing captured text reading. *)
