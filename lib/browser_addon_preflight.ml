type verdict =
  | Not_required
  | Declared of { id : string }
  | Missing of
      { host_directory : string
      ; directory : string
      ; unloaded : Lane_addon_config.issue list
      ; complete : bool
      }
  | Config_root_invalid of string

let is_browser_declaration (declaration : Lane_addon_config.declaration) =
  declaration.enabled
  &&
  match declaration.package.Lane_addon_types.worker_service with
  | Lane_addon_types.Browser_service -> true
  | Lane_addon_types.Mcp_tools -> false
;;

let judge ~base_path =
  let observation =
    Browser_lane_launcher.observe ~base_path ~server:Browser_lane_launcher.Not_serving
  in
  match observation.Browser_lane_launcher.launcher with
  | Browser_lane_launcher.Not_installed -> Not_required
  | Browser_lane_launcher.Undeclared
  | Browser_lane_launcher.Unreadable
  | Browser_lane_launcher.Describes_another_launcher
  | Browser_lane_launcher.Follows_workspace ->
    let resolution = Config_dir_resolver.resolve_for_base_path ~base_path in
    (match resolution.Config_dir_resolver.status with
     | Config_dir_resolver.Invalid_env_status ->
       Config_root_invalid (String.concat "; " resolution.Config_dir_resolver.warnings)
     | Config_dir_resolver.Ready
     | Config_dir_resolver.Warn
     | Config_dir_resolver.Missing_status ->
       let directory =
         Filename.concat resolution.Config_dir_resolver.config_root.Config_dir_resolver.path
           "lane-addons"
       in
       let snapshot = Lane_addon_config.load ~directory in
       (match List.find_opt is_browser_declaration snapshot.Lane_addon_config.declarations with
        | Some declaration -> Declared { id = declaration.Lane_addon_config.id }
        | None ->
          Missing
            { host_directory = Browser_lane_launcher.host_directory_path ~base_path
            ; directory
            ; unloaded = snapshot.Lane_addon_config.issues
            ; complete = snapshot.Lane_addon_config.complete
            }))
;;

let report = function
  | Not_required -> Ok "browser lane host not installed; the browser Add-on is not required"
  | Declared { id } -> Ok (Printf.sprintf "browser Add-on declared id=%s" id)
  | Config_root_invalid reason ->
    Error
      (Printf.sprintf
         "a browser lane host is installed but the directory that holds Add-on declarations \
          cannot be named, so whether the browser Add-on is declared is unknown: %s"
         reason)
  | Missing { host_directory; directory; unloaded; complete } ->
    let unloaded_note =
      match unloaded with
      | [] -> ""
      | issues ->
        "; these declarations did not load: "
        ^ String.concat "; "
            (List.map
               (fun (issue : Lane_addon_config.issue) ->
                 issue.Lane_addon_config.source_path ^ ": " ^ issue.Lane_addon_config.message)
               issues)
    in
    let incomplete_note =
      if complete then "" else "; the directory could not be read completely"
    in
    Error
      (Printf.sprintf
         "a browser lane host is installed under %s but no enabled browser Add-on declaration \
          is saved in %s, so every native browser host poll would be answered with HTTP 503 \
          (no_browser_addon). Save a declaration whose package has service = \"browser\" \
          (addons/browser/lane.toml; docs/guides/lane-addon-toml.md)%s%s"
         host_directory directory unloaded_note incomplete_note)
;;
