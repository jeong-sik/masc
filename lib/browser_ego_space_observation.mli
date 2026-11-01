(** SDK metadata for one already bound Space. A native ownership value is
    displayed verbatim, never used as admission, takeover or login authority. *)
type t = { space : Browser_lane.ego_space; ownership : string; observed_at : float }
val of_sdk : expected_id:int -> observed_at:float -> Yojson.Safe.t -> (t, string) result
(** Requires exactly the native spaceId/name/ownership fields and the original
    numeric ID. Unknown native ownership strings remain data, not decisions. *)
val to_json : t -> Yojson.Safe.t
val of_json : expected_id:int -> Yojson.Safe.t -> (t, string) result
(** Decode a dated worker publication, bound to the original numeric Space.
    Native ownership remains opaque display data, never control authority. *)

type unknown_reason = Transport_unavailable of string | Invalid_inventory of string
  | Ambiguous_inventory
type presence_state = Present | Missing | Unknown of unknown_reason
type presence = { space_id : int; observed_at : float; state : presence_state }
val inventory : expected_id:int -> observed_at:float -> Yojson.Safe.t ->
  presence * t option
(** Inspect the native listTaskSpaces rows, without opening or allocating a
    Space. A missing original ID, an unreadable list and ambiguous matches are
    distinct observations. Native ownership does not establish authority. *)
val presence_to_json : presence -> Yojson.Safe.t
val presence_of_json : expected_id:int -> Yojson.Safe.t -> (presence, string) result
