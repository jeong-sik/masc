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
val sidecar_root_candidates :
  ?sidecar_root:'a -> ?project_root:'a -> base_path:'a -> unit -> 'a list
val sidecar_dir_under : string -> string -> string
val resolve_existing_sidecar_dir :
  ?sidecar_root:string ->
  ?project_root:string -> base_path:string -> string -> string option
val missing_sidecar_dir_message :
  ?sidecar_root:string ->
  ?project_root:string -> base_path:string -> string -> string

val today_yyyymmdd : unit -> string
val legacy_status_rel : string -> string

type sidecar_status_config =
  { env_names : string list
  ; toml_keys : string list
  }

val sidecar_status_config : string -> sidecar_status_config
val read_file : string -> string
val strip_matching_quotes : string -> string
val parse_env_assignment : string -> (string * string) option
val env_file_lookup : string -> string list -> string option
val toml_lookup_result : string -> string list -> (string option, string) result
val toml_lookup : string -> string list -> string option
val resolve_relative_path : roots:string list -> string -> string list
val first_existing_or_first : string list -> string option
val runtime_toml_path : base_path:string -> string -> string
val status_file_candidates :
  ?sidecar_root:string ->
  ?project_root:string ->
  ?sidecar_dir:string -> base_path:string -> string -> string list
val status_file :
  ?sidecar_root:string ->
  ?project_root:string ->
  ?sidecar_dir:string -> base_path:string -> string -> string
val log_file_candidates :
  ?sidecar_root:string ->
  ?project_root:string -> base_path:string -> string -> string list
val today_log_file :
  ?sidecar_root:string ->
  ?project_root:string -> base_path:string -> string -> string
val runtime_sidecar_dir_result :
  ?base_path:string -> string -> (string, string) result
val runtime_sidecar_script_result :
  ?base_path:string -> string -> (string, string) result
