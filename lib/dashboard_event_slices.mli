(** Which dashboard slice each pushed event type is delivered on -- the one
    table both ends of the wire read. See the implementation for the three
    copies that preceded it and how each drifted. *)

type entry = {
  event_type : string;
  slice : string;
  whole_projection : bool;
      (** [true] for a snapshot-family event, including compact invalidations.
          A reader that only needs a change signal can drop the payload. *)
}

val execution_snapshot_type : string
(** Wire type shared by full execution snapshots and their invalidations. *)

val transport_health_snapshot_type : string
(** Wire type of the transport health measurement the server's refresh loop
    pushes after it updates the cell [/api/v1/dashboard/transport-health]
    serves. *)

val entries : entry list
(** Every event type the bus routes, in delivery order of no significance.
    Exposed so a reader can quantify over the vocabulary instead of keeping
    its own list of it. *)

val slice_for_sse_type : string -> string option
(** The slice an event type is delivered on, or [None] to raw-forward. *)

val carries_whole_projection : string -> bool
(** Whether the type belongs to a snapshot family. The payload can instead
    be an invalidation; inspect it before applying data. [false] for a delta
    and for any type not on the table. *)

val valid_slice : string -> bool
(** Membership in [slices]. *)
