(** SDK metadata for one already bound Space. A native ownership value is
    displayed verbatim, never used as admission, takeover or login authority. *)
type t = { space : Browser_lane.ego_space; ownership : string; observed_at : float }
val of_sdk : expected_id:int -> observed_at:float -> Yojson.Safe.t -> (t, string) result
(** Requires exactly the native spaceId/name/ownership fields and the original
    numeric ID. Unknown native ownership strings remain data, not decisions. *)
val to_json : t -> Yojson.Safe.t
