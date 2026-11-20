(** The JSON form of a {!Keeper_cache_outcome.reading}, which the dashboard
    door [/api/v1/keepers/<name>/cache-outcome] serves and the TUI reads back.
    One module names every field, so the writer and the reader cannot drift
    apart. *)

val schema : string
(** [masc.keeper-cache-outcome.v1]. *)

val to_json : Keeper_cache_outcome.reading -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (Keeper_cache_outcome.reading, string) result
(** Reads a {!to_json} object back. Another schema, an unknown kind or label,
    or a field of another shape is an error; nothing is read as a default. *)
