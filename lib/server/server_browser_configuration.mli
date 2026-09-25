(** The [\[browser\]] table of the [runtime.toml] of the workspace at
    [base_path] (the server's own), read once for each backend the server
    starts. A missing file is {!Browser_configuration.none}. *)
val load : base_path:string -> (Browser_configuration.t, string) result
