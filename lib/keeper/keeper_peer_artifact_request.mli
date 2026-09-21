type t =
  | Export of {
      path : string;
      purpose : string;
    }
  | Materialize of {
      path : string;
      artifact : Keeper_peer_artifact_ref.t;
    }

val of_json : Yojson.Safe.t -> (t, string) result
(** Decode the request shape shared by the peer-artifact handler and its
    durable file-change projection. *)
