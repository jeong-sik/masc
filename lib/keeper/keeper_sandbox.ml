(** Keeper sandbox contract.

    Keeper-facing tools expose exactly one logical sandbox.  The current
    local storage implementation is still under [.masc/playground/], but
    that path is an implementation detail of the local/docker backends. *)

type backend =
  | Local
  | Docker

type t =
  { keeper_name : string
  ; sandbox_id : string
  ; backend : backend
  ; sandbox_profile : string
  ; network_mode : string
  ; host_root_rel : string
  ; host_root_abs : string
  ; container_root : string option
  ; root_arg : string
  ; mind_arg : string
  ; repos_arg : string
  ; task_overlay_pattern : string
  }

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

let backend_of_profile = function
  | Keeper_types_profile_sandbox.Local -> Local
  | Keeper_types_profile_sandbox.Docker -> Docker

let backend_to_string = function
  | Local -> "local"
  | Docker -> "docker"

let sandbox_id_of_name name =
  "keeper:" ^ Playground_paths.sanitize_keeper_name name

let host_root_rel_of_profile sandbox_profile name =
  Keeper_sandbox_config.host_root_rel_of_profile sandbox_profile name

let host_root_rel_of_meta ~(meta : Keeper_meta_contract.keeper_meta) =
  host_root_rel_of_profile meta.sandbox_profile meta.name

let host_root_abs_of_meta ~(config : Workspace.config)
    (meta : Keeper_meta_contract.keeper_meta) =
  Filename.concat config.base_path (host_root_rel_of_meta ~meta)

let container_root name =
  Filename.concat
    "/home/keeper/playground"
    (Playground_paths.sanitize_keeper_name name)

let keeper_visible_root_abs_of_meta ~(config : Workspace.config)
    (meta : Keeper_meta_contract.keeper_meta) =
  match backend_of_profile meta.sandbox_profile with
  | Local -> host_root_abs_of_meta ~config meta
  | Docker -> container_root meta.name

let of_meta ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) : t =
  let backend = backend_of_profile meta.sandbox_profile in
  { keeper_name = meta.name
  ; sandbox_id = sandbox_id_of_name meta.name
  ; backend
  ; sandbox_profile = Keeper_types_profile_sandbox.sandbox_profile_to_string meta.sandbox_profile
  ; network_mode = Keeper_types_profile_sandbox.network_mode_to_string meta.network_mode
  ; host_root_rel = host_root_rel_of_meta ~meta
  ; host_root_abs = host_root_abs_of_meta ~config meta
  ; container_root =
      (match backend with
       | Local -> None
       | Docker -> Some (container_root meta.name))
  ; root_arg = "."
  ; mind_arg = "mind"
  ; repos_arg = "repos"
  ; task_overlay_pattern = "repos/<repo>"
  }

let allowed_root_rel_of_meta ~(meta : Keeper_meta_contract.keeper_meta) : string =
  host_root_rel_of_meta ~meta

let allowed_path_roots_of_meta ~(meta : Keeper_meta_contract.keeper_meta) : string list =
  [ allowed_root_rel_of_meta ~meta ]

let keeper_visible_root_abs (t : t) : string =
  match t.container_root with
  | Some container -> container
  | None -> t.host_root_abs

let storage_lifetime = "persistent_backend_task_overlay"

let context_status_fields (t : t) : (string * Yojson.Safe.t) list =
  [ "sandbox_id", `String t.sandbox_id
  ; "sandbox_backend", `String (backend_to_string t.backend)
  ; "sandbox_profile", `String t.sandbox_profile
  ; "sandbox_network_mode", `String t.network_mode
  ; "sandbox_lifetime", `String storage_lifetime
  ; "sandbox_root", `String t.root_arg
  ; "sandbox_mind", `String t.mind_arg
  ; "sandbox_repos", `String t.repos_arg
  ; "sandbox_task_overlay_pattern", `String t.task_overlay_pattern
  ; ( "sandbox_paths"
    , `Assoc
        [ "root", `String t.root_arg
        ; "mind", `String t.mind_arg
        ; "repos", `String t.repos_arg
        ] )
  ]
