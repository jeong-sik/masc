(** The pass that calls a Keeper Memory store commit.

    Every commit function of {!Keeper_memory_os_current} takes one, so a call
    site that names none does not compile. The store labels the changes a
    commit made with it (RFC-0517 §2.2). A program publication names the lane
    that publishes it: [Continuity] or [Durable]. *)

type t =
  | Admission
  | Durable
  | Continuity
  | Cleanup
  | Keeper_write
  | Keeper_delete
  | Operator_delete

val to_label : t -> string
(** The [pass] label value of the Memory change metrics. *)
