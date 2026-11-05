(** The push that says an internal agent run registry changed.

    The verification, goal-verification and exact-lane run registries each
    call it when a run is added or settles, and the frame names which one. A
    reader that shows one registry's runs re-fetches them only on its own
    registry's push. The server broadcasts it and the terminal client
    recognises it, so both read the name and the registry from here. *)

val event_type : string
(** The [type] field the frame carries. *)

type registry =
  | Verification
  | Goal_verification
  | Exact_lane

val registry_to_wire : registry -> string
(** The [registry] field the frame carries. *)

val registry_of_wire : string -> registry option
(** [None] for a registry this build does not know. *)

val to_json : registry -> Yojson.Safe.t
(** The whole frame. *)
