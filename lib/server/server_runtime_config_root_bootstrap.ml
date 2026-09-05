let project_root_from_executable () =
  let raw_exe = Safe_ops.protect ~default:"" (fun () -> Sys.executable_name) in
  let exe =
    if String.equal raw_exe ""
    then ""
    else (
      try Unix.realpath raw_exe with
      | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> raw_exe)
  in
  if String.equal exe ""
  then None
  else (
    let rec walk_up dir =
      let parent = Filename.dirname dir in
      if String.equal parent dir
      then None
      else if String.equal (Filename.basename dir) "_build"
      then Some parent
      else walk_up parent
    in
    walk_up (Filename.dirname exe))
;;

let config_root_from_ancestor start_dir =
  let rec walk_up dir =
    let config_root = Filename.concat dir "config" in
    let runtime_config =
      Filename.concat config_root Config_dir_resolver.runtime_toml_filename
    in
    if Sys.file_exists runtime_config
    then Some config_root
    else (
      let parent = Filename.dirname dir in
      if String.equal parent dir then None else walk_up parent)
  in
  walk_up start_dir
;;

let versioned_config_root_candidates () =
  let cwd = Config_dir_resolver.current_working_dir () in
  let cwd_candidate = Filename.concat cwd "config" in
  let cwd_ancestor_candidate = config_root_from_ancestor cwd in
  let exe_candidate =
    match project_root_from_executable () with
    | Some root -> Some (Filename.concat root "config")
    | None -> None
  in
  [ Some cwd_candidate; cwd_ancestor_candidate; exe_candidate ]
  |> List.filter_map (fun x -> x)
  |> Json_util.dedupe_keep_order
  |> List.filter (fun path -> Sys.file_exists path && Sys.is_directory path)
;;

let copy_file_if_missing ~src ~dst =
  if Sys.file_exists dst
  then ()
  else (
    Fs_compat.mkdir_p (Filename.dirname dst);
    Fs_compat.save_file dst (Fs_compat.load_file src))
;;

let agent_core_models_overlay_toml_filename = "agent-core-models-overlay.toml"

let existing_file path =
  try Sys.file_exists path && not (Sys.is_directory path) with
  | Sys_error _ -> false
;;

let existing_directory path =
  try Sys.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false
;;

let rec copy_missing_tree_count ~src ~dst =
  if Sys.is_directory src
  then
    if Sys.file_exists dst && not (Sys.is_directory dst)
    then (
      Log.Server.warn
        "config bootstrap: refusing to replace file with directory (%s -> %s)"
        src
        dst;
      0)
    else (
      Fs_compat.mkdir_p dst;
      Sys.readdir src
      |> Array.fold_left
           (fun count name ->
             count
             + copy_missing_tree_count
                 ~src:(Filename.concat src name)
                 ~dst:(Filename.concat dst name))
           0)
  else if Sys.file_exists dst
  then 0
  else (
    copy_file_if_missing ~src ~dst;
    1)
;;

let rec copy_missing_tree ~src ~dst =
  if Sys.is_directory src
  then (
    if Sys.file_exists dst && not (Sys.is_directory dst)
    then
      Log.Server.warn
        "config bootstrap: refusing to replace file with directory (%s -> %s)"
        src
        dst
    else (
      Fs_compat.mkdir_p dst;
      Sys.readdir src
      |> Array.iter (fun name ->
        copy_missing_tree
          ~src:(Filename.concat src name)
          ~dst:(Filename.concat dst name))))
  else if Sys.file_exists dst
  then ()
  else copy_file_if_missing ~src ~dst
;;

let copy_missing_prompt_seed ~src_config_root ~dst_config_root =
  let src = Filename.concat src_config_root "prompts" in
  let dst = Filename.concat dst_config_root "prompts" in
  if Sys.file_exists src && Sys.is_directory src
  then copy_missing_tree_count ~src ~dst
  else 0
;;

let copy_missing_model_catalog_overlay_seed ~src_config_root ~dst_config_root =
  let src = Filename.concat src_config_root agent_core_models_overlay_toml_filename in
  let dst = Filename.concat dst_config_root agent_core_models_overlay_toml_filename in
  if existing_file src && not (Sys.file_exists dst)
  then (
    copy_file_if_missing ~src ~dst;
    1)
  else if existing_file src && existing_directory dst
  then (
    Log.Server.warn
      "config bootstrap: refusing to replace directory with model catalog overlay file (%s -> %s)"
      src
      dst;
    0)
  else 0
;;

let config_bootstrap_mode () =
  match Sys.getenv_opt "MASC_CONFIG_BOOTSTRAP" |> Env_config_core.trim_opt with
  | Some ("empty" | "EMPTY") -> `Empty
  | Some ("skip" | "SKIP") -> `Skip
  | _ -> `Auto
;;

let ensure_config_root_scaffold config_root =
  Fs_compat.mkdir_p config_root;
  [ "prompts"; "keepers" ]
  |> List.iter (fun name -> Fs_compat.mkdir_p (Filename.concat config_root name))
;;

(* Explicit base-path workspaces should inherit shared config defaults
   without silently importing repo keeper manifests into the live root. *)
let copy_missing_config_root_seed ~src ~dst =
  Fs_compat.mkdir_p dst;
  Sys.readdir src
  |> Array.iter (fun name ->
    if Common.seeds_into_fresh_config_root name
    then
      copy_missing_tree
        ~src:(Filename.concat src name)
        ~dst:(Filename.concat dst name));
  Fs_compat.mkdir_p (Filename.concat dst Common.keepers_runtime_dirname)
;;

(* Write the named embedded assets that [dst] does not already hold, and answer
   how many were written. Never overwrites: a file already on disk is the
   operator's, whichever caller asked. *)
let write_missing_embedded ~dst rels =
  List.fold_left
    (fun written rel ->
       let target = Filename.concat dst rel in
       if Sys.file_exists target
       then written
       else (
         match Embedded_config.read rel with
         | None -> written
         | Some content ->
           Fs_compat.mkdir_p (Filename.dirname target);
           Fs_compat.save_file target content;
           written + 1))
    0
    rels
;;

(* The binary embeds the repo's [config/] tree ([Embedded_config], built by
   ocaml-crunch), and a release install has no [config/] on disk beside it:
   [versioned_config_root_candidates] finds nothing, so before this fallback a
   fresh base path got a scaffold with no runtime.toml and startup died on "no
   runtime config path". Measured 2026-09-05 with the v0.31.0 binary run outside
   its repo. Same distribution/operator split as the filesystem seed above. *)
let seed_missing_from_embedded ~dst =
  Fs_compat.mkdir_p dst;
  Embedded_config.file_list
  |> List.filter Common.seeds_into_fresh_config_root
  |> write_missing_embedded ~dst
;;

(* An existing config root is operator-owned and is deliberately not refilled.
   These two files are the exception, because their absence is not a preference:
   without runtime.toml the server refuses to start at all, and the overlay is
   what the frozen model catalog is read from. Restricted to the pair the
   versioned backfill above already covers — this only adds a source for hosts
   that have no repo to copy from. *)
let backfill_startup_required_from_embedded ~config_root =
  [ Config_dir_resolver.runtime_toml_filename
  ; agent_core_models_overlay_toml_filename
  ]
  |> write_missing_embedded ~dst:config_root
;;

let bootstrap_base_path_config_root ~base_path =
  let base_path = Env_config_core.normalize_masc_base_path_input base_path in
  if Option.is_some (Config_dir_resolver.current_env_config_dir_opt ())
  then ()
  else (
    let mode = config_bootstrap_mode () in
    let config_root =
      Filename.concat (Common.masc_dir_from_base_path ~base_path) "config"
    in
    if mode = `Skip
    then Log.Server.info "config bootstrap skipped via MASC_CONFIG_BOOTSTRAP=skip"
    else if Sys.file_exists config_root
    then
      if Sys.is_directory config_root
      then (
        ensure_config_root_scaffold config_root;
        let backfilled_prompts, backfilled_model_catalog_overlay =
          match versioned_config_root_candidates () |> List.find_opt Sys.file_exists with
          | Some source ->
            ( copy_missing_prompt_seed
                ~src_config_root:source
                ~dst_config_root:config_root
            , copy_missing_model_catalog_overlay_seed
                ~src_config_root:source
                ~dst_config_root:config_root
            )
          | None -> 0, 0
        in
        (* Last resort for a root that exists but cannot start: no repo to copy
           from, so the startup-required pair comes out of the binary. *)
        let backfilled_from_embedded =
          backfill_startup_required_from_embedded ~config_root
        in
        if backfilled_prompts + backfilled_model_catalog_overlay > 0
        then
          Log.Server.info
            "backfilled %d missing prompt seed file(s) and %d model catalog overlay seed file(s) into existing base-path config root: %s"
            backfilled_prompts
            backfilled_model_catalog_overlay
            config_root;
        if backfilled_from_embedded > 0
        then
          Log.Server.info
            "backfilled %d startup-required config file(s) from binary-embedded assets into existing base-path config root: %s"
            backfilled_from_embedded
            config_root;
        if backfilled_prompts + backfilled_model_catalog_overlay
           + backfilled_from_embedded
           > 0
        then Config_dir_resolver.reset ()
        else
          Log.Server.info
            "preserved existing base-path config root without refilling operator-owned entries: %s"
            config_root)
      else
        Log.Server.warn
          "base-path config root exists but is not a directory; skipping bootstrap: %s"
          config_root
    else if mode = `Empty
    then (
      ensure_config_root_scaffold config_root;
      Log.Server.info
        "bootstrapped empty config root (MASC_CONFIG_BOOTSTRAP=empty): %s"
        config_root)
    else (
      let source_root =
        versioned_config_root_candidates () |> List.find_opt Sys.file_exists
      in
      match source_root with
      | Some source ->
        copy_missing_config_root_seed ~src:source ~dst:config_root;
        Log.Server.info "bootstrapped base-path config root: %s <- %s" config_root source
      | None ->
        ensure_config_root_scaffold config_root;
        let seeded = seed_missing_from_embedded ~dst:config_root in
        if seeded > 0
        then
          Log.Server.info
            "bootstrapped base-path config root from binary-embedded assets (%d file(s)): %s"
            seeded
            config_root
        else
          Log.Server.warn
            "bootstrapped minimal base-path config root without versioned source \
             and no embedded assets: %s"
            config_root);
    Config_dir_resolver.reset ())
;;

let startup_config_resolution ~base_path =
  Config_dir_resolver.resolve_with
    Config_dir_resolver.
      { cwd = Config_dir_resolver.current_working_dir ()
      ; executable_name = Sys.executable_name
      ; env_base_path = Some base_path
      ; env_config_dir = Config_dir_resolver.current_env_config_dir_opt ()
      }
;;
