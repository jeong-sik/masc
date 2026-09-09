(** Sidecar id, root, status, and script path helpers. *)

val known_ids : string list
val validate_name : string option -> (string, string) result
val parse_name : Httpun.Request.t -> (string, string) result

val trim_opt : string option -> string option

val runtime_base_path_result : ?base_path:string -> unit -> (string, string) result
(** Effective [base_path] for runtime path resolution. The request-scoped
    [base_path] wins; otherwise the resolver's env-derived base path wins. *)

val runtime_base_path : ?base_path:string -> unit -> string
(** Effective [base_path] for runtime path resolution. Raises when no
    explicit or env-derived base path is available. *)

val request_base_path : Mcp_server.server_state -> string
val dir_exists : string -> bool
val project_root_from_executable : unit -> string option
val sidecar_root : unit -> string option
val resolve_existing_sidecar_dir :
  ?sidecar_root:string ->
  ?project_root:string -> base_path:string -> string -> string option
val missing_sidecar_dir_message :
  ?sidecar_root:string ->
  ?project_root:string -> base_path:string -> string -> string

val today_yyyymmdd : unit -> string

type sidecar_status_config =
  { env_names : string list
  ; toml_keys : string list
  ; stale_after_env_name : string
  }

val sidecar_status_config : string -> sidecar_status_config

val status_stale_sec : string -> int
(** Age at which a sidecar's heartbeat stops counting as alive, read from
    the connector's [MASC_*_STATUS_STALE_SEC] variable — the same window the
    gate state modules apply when rendering "stale". Raises on an id outside
    {!known_ids}, like {!sidecar_status_config}. *)
val read_file : string -> string
val strip_matching_quotes : string -> string
val parse_env_assignment : string -> (string * string) option
val runtime_toml_path : base_path:string -> string -> string
val status_file :
  ?sidecar_root:string ->
  ?project_root:string ->
  ?sidecar_dir:string -> base_path:string -> string -> string
val today_log_file :
  ?sidecar_root:string ->
  ?project_root:string -> base_path:string -> string -> string
val runtime_sidecar_dir_result :
  ?base_path:string -> string -> (string, string) result
val runtime_sidecar_script_result :
  ?base_path:string -> string -> (string, string) result
