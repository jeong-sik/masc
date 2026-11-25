(** Account identity proved by an external connector. An account reference
    carries neither a display name nor permission to read or send messages. *)

type t

val discord_user : string -> t option
(** The Discord gateway supplies the user ID. Callers must first exclude
    bot and webhook authors. The ID must be a canonical, positive unsigned
    64-bit snowflake. *)

val matches_actor : t -> surface:Surface_ref.t -> actor_id:string option -> bool
(** A persisted reference must agree with both the typed surface and the
    original actor ID. *)

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t option, string) result
(** A supported key is [Ok (Some account)]. An unsupported kind or version in
    a valid envelope is [Ok None], so a stored observation remains readable
    without proving an account. Malformed envelopes and malformed supported
    keys return [Error]. *)
