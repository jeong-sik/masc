(** The [cache.state] word shared by cached dashboard routes and their clients.
    [Cache_warming] means that no value has been computed for this key yet. *)
type state = Cache_fresh | Cache_stale_refreshing | Cache_warming

val to_string : state -> string
val of_string : string -> state option
