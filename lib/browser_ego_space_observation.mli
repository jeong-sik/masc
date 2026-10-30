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
