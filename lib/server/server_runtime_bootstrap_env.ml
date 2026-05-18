let force_jsonl_fallback_env () =
  Unix.putenv Env_config_core.storage_type_env_key "filesystem"

let requested_backend_mode () =
  Env_config_core.storage_type ()

let storage_enforcement_fallback_reason ~requested ~effective =
  let requested = requested |> String.trim |> String.lowercase_ascii in
  let effective = effective |> String.trim |> String.lowercase_ascii in
  if requested = "" || String.equal requested effective then
    None
  else
    Some
      (Printf.sprintf
         "MASC_STORAGE_TYPE=%s requested; filesystem-only bootstrap enforced as %s"
         requested effective)

let note_storage_enforcement_fallback ~requested ~effective =
  match storage_enforcement_fallback_reason ~requested ~effective with
  | Some reason -> Server_startup_state.note_fallback reason
  | None -> ()

let ensure_default_oas_cascade_timeout_env () =
  match Sys.getenv_opt "OAS_CASCADE_MODEL_TIMEOUT_SEC" |> Env_config_core.trim_opt with
  | Some _ -> ()
  | None ->
      let keeper_oas_timeout_s = Env_config_keeper.KeeperKeepalive.oas_timeout_sec in
      let derived_timeout_s =
        Float.max 30.0 (Float.min 120.0 (keeper_oas_timeout_s /. 5.0))
      in
      Unix.putenv "OAS_CASCADE_MODEL_TIMEOUT_SEC"
        (Printf.sprintf "%.0f" derived_timeout_s)

let project_root_from_executable () =
  let raw_exe =
    Safe_ops.protect ~default:"" (fun () -> Sys.executable_name)
  in
  let exe =
    if String.equal raw_exe "" then ""
    else
      try Unix.realpath raw_exe
      with Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> raw_exe
  in
  if String.equal exe "" then None
  else
    let rec walk_up dir =
      let parent = Filename.dirname dir in
      if String.equal parent dir then None
      else if String.equal (Filename.basename dir) "_build" then Some parent
      else walk_up parent
    in
    walk_up (Filename.dirname exe)

let config_root_from_ancestor start_dir =
  let rec walk_up dir =
    let config_root = Filename.concat dir "config" in
    let tool_policy =
      Filename.concat config_root Config_dir_resolver.tool_policy_toml_filename
    in
    if Sys.file_exists tool_policy then Some config_root
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir then None else walk_up parent
  in
  walk_up start_dir

let dedupe_keep_order items =
  let seen = Hashtbl.create (List.length items) in
  List.filter
    (fun item ->
      if Hashtbl.mem seen item then
        false
      else (
        Hashtbl.add seen item ();
        true))
    items

let versioned_config_root_candidates () =
  let cwd_candidate = Filename.concat (Sys.getcwd ()) "config" in
  let cwd_ancestor_candidate = config_root_from_ancestor (Sys.getcwd ()) in
  let exe_candidate =
    match project_root_from_executable () with
    | Some root -> Some (Filename.concat root "config")
    | None -> None
  in
  [ Some cwd_candidate; cwd_ancestor_candidate; exe_candidate ]
  |> List.filter_map (fun x -> x)
  |> dedupe_keep_order
  |> List.filter (fun path -> Sys.file_exists path && Sys.is_directory path)

let copy_file_if_missing ~src ~dst =
  if Sys.file_exists dst then
    ()
  else begin
    Fs_compat.mkdir_p (Filename.dirname dst);
    Fs_compat.save_file dst (Fs_compat.load_file src)
  end

let rec copy_missing_tree ~src ~dst =
  if Sys.is_directory src then begin
    if Sys.file_exists dst && not (Sys.is_directory dst) then
      Log.Server.warn
        "config bootstrap: refusing to replace file with directory (%s -> %s)"
        src dst
    else begin
      Fs_compat.mkdir_p dst;
      Sys.readdir src
      |> Array.iter (fun name ->
             copy_missing_tree
               ~src:(Filename.concat src name)
               ~dst:(Filename.concat dst name))
    end
  end else if Sys.file_exists dst then
    ()
  else
    copy_file_if_missing ~src ~dst

let config_bootstrap_mode () =
  match Sys.getenv_opt "MASC_CONFIG_BOOTSTRAP" |> Env_config_core.trim_opt with
  | Some ("empty" | "EMPTY") -> `Empty
  | Some ("skip" | "SKIP") -> `Skip
  | _ -> `Auto

let ensure_config_root_scaffold config_root =
  Fs_compat.mkdir_p config_root;
  [ "prompts"; "keepers"; "personas" ]
  |> List.iter (fun name -> Fs_compat.mkdir_p (Filename.concat config_root name))

(* Explicit base-path workspaces should inherit shared config defaults
   without silently importing repo keeper manifests into the live root. *)
let copy_missing_config_root_seed ~src ~dst =
  Fs_compat.mkdir_p dst;
  Sys.readdir src
  |> Array.iter (fun name ->
         if String.equal name "keepers" then
           ()
         else
           copy_missing_tree
             ~src:(Filename.concat src name)
             ~dst:(Filename.concat dst name));
  Fs_compat.mkdir_p (Filename.concat dst "keepers")

let bootstrap_base_path_config_root ~base_path =
  let base_path = Env_config_core.normalize_masc_base_path_input base_path in
  if Option.is_some (Config_dir_resolver.current_env_config_dir_opt ()) then
    ()
  else begin
    let mode = config_bootstrap_mode () in
    let config_root =
      Filename.concat (Common.masc_dir_from_base_path ~base_path) "config"
    in
    if mode = `Skip then
      Log.Server.info "config bootstrap skipped via MASC_CONFIG_BOOTSTRAP=skip"
    else if Sys.file_exists config_root then
      if Sys.is_directory config_root then begin
        ensure_config_root_scaffold config_root;
        Log.Server.info
          "preserved existing base-path config root without refilling missing entries: %s"
          config_root
      end else
        Log.Server.warn
          "base-path config root exists but is not a directory; skipping bootstrap: %s"
          config_root
    else if mode = `Empty then begin
      ensure_config_root_scaffold config_root;
      Log.Server.info
        "bootstrapped empty config root (MASC_CONFIG_BOOTSTRAP=empty): %s"
        config_root
    end else
      let source_root =
        versioned_config_root_candidates () |> List.find_opt Sys.file_exists
      in
      (match source_root with
       | Some source ->
           copy_missing_config_root_seed ~src:source ~dst:config_root;
           Log.Server.info
             "bootstrapped base-path config root: %s <- %s"
             config_root source
       | None ->
           ensure_config_root_scaffold config_root;
           (* RFC-0058 §9.3: cascade.toml is the only cascade source.
              [""] is the smallest valid TOML document — a document
              with no tables and no keys; the materializer parses it
              and renders an empty in-memory catalog. *)
           let cascade_path =
             Filename.concat config_root Config_dir_resolver.cascade_toml_filename
           in
           if not (Sys.file_exists cascade_path) then
             Fs_compat.save_file cascade_path "";
           Log.Server.warn
             "bootstrapped minimal base-path config root without versioned source: %s"
             config_root);
    Config_dir_resolver.reset ()
  end

let startup_config_resolution ~base_path =
  Config_dir_resolver.resolve_with
    Config_dir_resolver.
      {
        cwd = Sys.getcwd ();
        executable_name = Sys.executable_name;
        env_base_path = Some base_path;
        env_config_dir = Config_dir_resolver.current_env_config_dir_opt ();
        env_personas_dir = Config_dir_resolver.current_env_personas_dir_opt ();
      }
