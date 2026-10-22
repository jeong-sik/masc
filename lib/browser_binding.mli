(** Authoritative connection in a browser command receipt. Page JSON cannot
    supply or overwrite this identity. An executed live receipt always names
    one concrete client and its transport. *)
type t
val of_target : Browser_selection.selected -> Browser_lane.target -> t
val of_json : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
val selected : t -> Browser_selection.selected
val connection_fields : t -> (string * Yojson.Safe.t) list
val same_connection : t -> t -> bool
val annotate : t -> Yojson.Safe.t -> Yojson.Safe.t
(** Replace every page-supplied source/lane/selection/connection field with the
    verified receipt values. Non-object payloads are left intact. *)
