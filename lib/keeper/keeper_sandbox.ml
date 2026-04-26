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

let strip_trailing_slashes path =
  let rec loop i =
    if i > 0 && path.[i - 1] = '/' then loop (i - 1) else i
  in
  let len = loop (String.length path) in
  if len = String.length path then path else String.sub path 0 len

let backend_of_profile = function
  | Keeper_types.Local -> Local
  | Keeper_types.Docker -> Docker

let backend_to_string = function
  | Local -> "local"
  | Docker -> "docker"

let sandbox_id_of_name name =
  "keeper:" ^ Playground_paths.sanitize_keeper_name name

let host_root_rel_of_backend ~(backend : backend) name =
  match backend with
  | Local -> Playground_paths.bundle_root name
  | Docker ->
      Printf.sprintf "%s/docker/%s/"
        Playground_paths.all_playgrounds_prefix
        (Playground_paths.sanitize_keeper_name name)

let host_root_rel_of_profile sandbox_profile name =
  host_root_rel_of_backend
    ~backend:(backend_of_profile sandbox_profile)
    name

let host_root_rel_of_meta ~(meta : Keeper_types.keeper_meta) =
  host_root_rel_of_profile meta.sandbox_profile meta.name

let host_root_rel name =
  Playground_paths.bundle_root name

let host_root_abs_of_backend ~(config : Coord.config) ~(backend : backend) name =
  Filename.concat config.base_path (host_root_rel_of_backend ~backend name)

let host_root_abs_of_meta ~(config : Coord.config)
    (meta : Keeper_types.keeper_meta) =
  Filename.concat config.base_path (host_root_rel_of_meta ~meta)

let host_root_abs ~(config : Coord.config) name =
  Filename.concat config.base_path (host_root_rel name)

let container_root name =
  Filename.concat
    Env_config_keeper.DockerPlayground.container_playground_root
    (Playground_paths.sanitize_keeper_name name)

let of_meta ~(config : Coord.config) ~(meta : Keeper_types.keeper_meta) : t =
  let backend = backend_of_profile meta.sandbox_profile in
  { keeper_name = meta.name
  ; sandbox_id = sandbox_id_of_name meta.name
  ; backend
  ; sandbox_profile = Keeper_types.sandbox_profile_to_string meta.sandbox_profile
  ; network_mode = Keeper_types.network_mode_to_string meta.network_mode
  ; host_root_rel = host_root_rel_of_meta ~meta
  ; host_root_abs = host_root_abs_of_meta ~config meta
  ; container_root =
      (match backend with
       | Local -> None
       | Docker -> Some (container_root meta.name))
  ; root_arg = "."
  ; mind_arg = "mind"
  ; repos_arg = "repos"
  ; task_overlay_pattern = "repos/<repo>/.worktrees/<keeper>-<task_id>"
  }

let allowed_root_rel ~(name : string) : string =
  Playground_paths.bundle_root name

let allowed_root_rel_of_meta ~(meta : Keeper_types.keeper_meta) : string =
  host_root_rel_of_meta ~meta

let allowed_path_roots ~(name : string) : string list =
  [ allowed_root_rel ~name ]

let allowed_path_roots_of_meta ~(meta : Keeper_types.keeper_meta) : string list =
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
