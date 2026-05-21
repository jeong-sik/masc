(** Operator dashboard room descriptor extracted from [Operator_control_snapshot]. *)

val room_json : Coord.config -> Yojson.Safe.t
(** Return the current room summary JSON for the operator dashboard. *)
