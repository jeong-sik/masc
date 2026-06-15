type t =
  { docker_args : string list
  ; cleanup : unit -> unit
  }

type secret_root_info =
  { root : string
  ; source : string
  }

val secret_root_info : base_path:string -> keeper_name:string -> secret_root_info

val secret_root : base_path:string -> keeper_name:string -> string

val local_env_for_keeper :
  ?host_env:string array ->
  base_path:string ->
  keeper_name:string ->
  unit ->
  (string array option, string) result
(** Build the child-process environment for local keeper execution from
    [secrets/<keeper>/env]. The host environment is keeper-scrubbed and
    git/gh noninteractive defaults are injected even when the keeper secret
    root is absent; a missing root only means there are no keeper-specific
    env/file overlays. When present, secret files are validated and env
    entries are overlaid without writing temp files. If the keeper does not
    supply [GH_CONFIG_DIR], local execution points [gh] at an empty system
    config directory when available to avoid ambient host config fallback. *)

val docker_args_for_keeper :
  base_path:string -> keeper_name:string -> container_name:string -> (t, string) result

val dashboard_status_json :
  base_path:string -> keeper_name:string -> Yojson.Safe.t
