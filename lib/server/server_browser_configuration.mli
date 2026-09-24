(** The [\[browser\]] table of the workspace's [runtime.toml], read once for
    each backend the server starts. A missing file is {!Browser_configuration.none}. *)
val load : unit -> (Browser_configuration.t, string) result
