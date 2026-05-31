(** Operator dashboard coord descriptor extracted from [Operator_control_snapshot]. *)

val coord_json : Coord.config -> Yojson.Safe.t
(** Return the current coord summary JSON for the operator dashboard. *)
