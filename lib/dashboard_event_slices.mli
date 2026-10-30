(** Which dashboard slice each pushed event type is delivered on -- the one
    table both ends of the wire read. See the implementation for the three
    copies that preceded it and how each drifted. *)

type entry = {
  event_type : string;
  slice : string;
  whole_projection : bool;
      (** [true] when the event carries a whole projection, so a reader that
          only needs to know something changed can drop the payload. *)
}

val entries : entry list
(** Every event type the bus routes, in delivery order of no significance.
    Exposed so a reader can quantify over the vocabulary instead of keeping
    its own list of it. *)

val slice_for_sse_type : string -> string option
(** The slice an event type is delivered on, or [None] to raw-forward. *)

val carries_whole_projection : string -> bool
(** Whether the event replaces a projection outright. [false] for a delta and
    for any type not on the table. *)

val valid_slice : string -> bool
(** Membership in [slices]. *)
