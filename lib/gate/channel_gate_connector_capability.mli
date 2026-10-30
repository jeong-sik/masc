(** Closed connector capabilities advertised to dashboard consumers. *)

type t =
  | Runtime_status
  | Bindings
  | Audit

val to_wire : t -> string
val all : t list
(** Capabilities exposed by the connector dashboard contract. *)

val to_yojson : t list -> Yojson.Safe.t
val all_json : Yojson.Safe.t
(** Canonical projection of {!all}; shared by every connector descriptor. *)
