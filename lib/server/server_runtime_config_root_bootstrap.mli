val config_bootstrap_mode : unit -> [> `Auto | `Empty | `Skip ]
val bootstrap_base_path_config_root : base_path:string -> unit
val startup_config_resolution : base_path:string -> Config_dir_resolver.resolution
