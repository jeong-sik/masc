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

type docker_mount_layout =
  { host_root_raw : string
  ; host_root : string
  ; container_root : string
  }

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

let normalize_path path =
  let normalized =
    try Fs_compat.realpath path with
    | Unix.Unix_error _ ->
      let rec collect_suffix p acc =
        let parent = Filename.dirname p in
        if parent = p
        then p, acc
        else (
          match
            try Some (Fs_compat.realpath p) with
            | Unix.Unix_error _ -> None
          with
          | Some resolved -> resolved, acc
          | None -> collect_suffix parent (Filename.basename p :: acc))
      in
      let resolved_base, suffix_parts = collect_suffix path [] in
      List.fold_left Filename.concat resolved_base suffix_parts
  in
  strip_trailing_slashes normalized

let backend_of_profile = function
  | Keeper_types_profile_sandbox.Local -> Local
  | Keeper_types_profile_sandbox.Docker -> Docker

let backend_to_string = function
  | Local -> "local"
  | Docker -> "docker"

let backend_of_config_agent ~(config : Workspace.config) ~(agent_name : string) =
  match
    Keeper_sandbox_config.sandbox_profile_of_agent
      ~base_path:config.Workspace.base_path
      ~agent_name
  with
  | Keeper_sandbox_config.Local -> Local
  | Keeper_sandbox_config.Docker -> Docker

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

let host_root_rel_of_config_agent ~config ~agent_name =
  Keeper_sandbox_config.host_root_rel_of_agent
    ~base_path:config.Workspace.base_path
    ~agent_name

let host_root_abs_of_config_agent ~config ~agent_name =
  Keeper_sandbox_config.host_root_abs_of_agent
    ~base_path:config.Workspace.base_path
    ~agent_name

let host_root_rel_of_meta ~(meta : Keeper_meta_contract.keeper_meta) =
  host_root_rel_of_profile meta.sandbox_profile meta.name

let host_root_abs_of_backend ~(config : Workspace.config) ~(backend : backend) name =
  Filename.concat config.base_path (host_root_rel_of_backend ~backend name)

let host_root_abs_of_meta ~(config : Workspace.config)
    (meta : Keeper_meta_contract.keeper_meta) =
  Filename.concat config.base_path (host_root_rel_of_meta ~meta)

let container_root name =
  Keeper_sandbox_config.container_root_of_agent ~agent_name:name

let docker_mount_layout_of_meta ~(config : Workspace.config)
    (meta : Keeper_meta_contract.keeper_meta) =
  let host_root_raw = host_root_abs_of_meta ~config meta |> strip_trailing_slashes in
  { host_root_raw
  ; host_root = normalize_path host_root_raw
  ; container_root = container_root meta.name |> strip_trailing_slashes
  }

let container_path_of_host layout ~host_path =
  let host_norm = normalize_path host_path in
  if String.equal host_norm layout.host_root
  then Ok layout.container_root
  else if String.starts_with ~prefix:(layout.host_root ^ "/") host_norm
  then (
    let suffix =
      String.sub
        host_norm
        (String.length layout.host_root + 1)
        (String.length host_norm - String.length layout.host_root - 1)
    in
    Ok (Filename.concat layout.container_root suffix))
  else
    Error
      (Printf.sprintf
         "container_path_of_host: %s is not inside playground %s"
         host_norm
         layout.host_root)

let container_cwd_of_host layout ~host_cwd =
  match container_path_of_host layout ~host_path:host_cwd with
  | Ok container_cwd -> container_cwd
  | Error _ -> layout.container_root

let rewrite_host_paths_to_container layout text =
  let rewritten =
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:layout.host_root_raw
      ~container_root:layout.container_root
      text
  in
  if String.equal layout.host_root_raw layout.host_root
  then rewritten
  else
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:layout.host_root
      ~container_root:layout.container_root
      rewritten

let rewrite_container_paths_to_host layout text =
  Keeper_sandbox_runtime.rewrite_host_root_to_container_root
    ~host_root:layout.container_root
    ~container_root:layout.host_root_raw
    text

let host_path_of_visible_path ~config ~agent_name raw_path =
  if Filename.is_relative raw_path
  then raw_path
  else
    match backend_of_config_agent ~config ~agent_name with
    | Local -> raw_path
    | Docker ->
        let container_prefix = container_root agent_name in
        if String.equal raw_path container_prefix
        then host_root_abs_of_config_agent ~config ~agent_name
        else if String.starts_with ~prefix:(container_prefix ^ "/") raw_path
        then (
          let suffix =
            String.sub
              raw_path
              (String.length container_prefix + 1)
              (String.length raw_path - String.length container_prefix - 1)
          in
          Filename.concat
            (host_root_abs_of_config_agent ~config ~agent_name)
            suffix)
        else
          raw_path

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
