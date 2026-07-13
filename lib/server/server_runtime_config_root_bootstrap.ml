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

let oas_models_toml_filename = "oas-models.toml"

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

let copy_missing_model_catalog_seed ~src_config_root ~dst_config_root =
  let src = Filename.concat (Filename.dirname src_config_root) oas_models_toml_filename in
  let dst = Filename.concat dst_config_root oas_models_toml_filename in
  if existing_file src && not (Sys.file_exists dst)
  then (
    copy_file_if_missing ~src ~dst;
    1)
  else if existing_file src && existing_directory dst
  then (
    Log.Server.warn
      "config bootstrap: refusing to replace directory with model catalog file (%s -> %s)"
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
  [ "prompts"; "keepers"; "personas" ]
  |> List.iter (fun name -> Fs_compat.mkdir_p (Filename.concat config_root name))
;;

(* Explicit base-path workspaces should inherit shared config defaults
   without silently importing repo keeper manifests into the live root. *)
let copy_missing_config_root_seed ~src ~dst =
  Fs_compat.mkdir_p dst;
  Sys.readdir src
  |> Array.iter (fun name ->
    if
      String.equal name "keepers"
    then ()
    else
      copy_missing_tree
        ~src:(Filename.concat src name)
        ~dst:(Filename.concat dst name));
  ignore (copy_missing_model_catalog_seed ~src_config_root:src ~dst_config_root:dst);
  Fs_compat.mkdir_p (Filename.concat dst "keepers")
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
        let backfilled_prompts, backfilled_model_catalog =
          match versioned_config_root_candidates () |> List.find_opt Sys.file_exists with
          | Some source ->
            ( copy_missing_prompt_seed
                ~src_config_root:source
                ~dst_config_root:config_root
            , copy_missing_model_catalog_seed
                ~src_config_root:source
                ~dst_config_root:config_root
            )
          | None -> 0, 0
        in
        if backfilled_prompts + backfilled_model_catalog > 0
        then (
          Log.Server.info
            "backfilled %d missing prompt seed file(s) and %d model catalog seed file(s) into existing base-path config root: %s"
            backfilled_prompts
            backfilled_model_catalog
            config_root;
          Config_dir_resolver.reset ())
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
        Log.Server.warn
          "bootstrapped minimal base-path config root without versioned source: %s"
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
      ; env_personas_dir = Config_dir_resolver.current_env_personas_dir_opt ()
      }
;;
