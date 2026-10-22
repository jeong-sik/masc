type verdict =
  | Not_required
  | Declared of { id : string }
  | Ambiguous of { ids : string list }
  | Missing of
      { host_directory : string
      ; directory : string
      ; unloaded : Lane_addon_config.issue list
      ; complete : bool
      }

let is_browser_declaration (declaration : Lane_addon_config.declaration) =
  declaration.enabled
  &&
  match declaration.package.Lane_addon_types.worker_service with
  | Lane_addon_types.Browser_service -> true
  | Lane_addon_types.Mcp_tools -> false
;;

(* The server reads declarations from the config root's Lane directory
   whatever the root's status is, so this does too. *)
let declaration_directory ~base_path =
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path in
  Lane_addon_config.directory
    ~config_root:resolution.Config_dir_resolver.config_root.Config_dir_resolver.path
;;

let judge ~base_path =
  let observation =
    Browser_lane_launcher.observe ~base_path ~server:Browser_lane_launcher.Not_serving
  in
  match observation.Browser_lane_launcher.launcher with
  | Browser_lane_launcher.Not_installed
  | Browser_lane_launcher.Undeclared
  | Browser_lane_launcher.Unreadable
  | Browser_lane_launcher.Describes_another_launcher -> Not_required
  | Browser_lane_launcher.Follows_workspace ->
    let directory = declaration_directory ~base_path in
    let snapshot = Lane_addon_config.load ~directory in
    (match List.filter is_browser_declaration snapshot.Lane_addon_config.declarations with
     | [ (declaration : Lane_addon_config.declaration) ] ->
       Declared { id = declaration.Lane_addon_config.id }
     | [] ->
       Missing
         { host_directory = Browser_lane_launcher.host_directory_path ~base_path
         ; directory
         ; unloaded = snapshot.Lane_addon_config.issues
         ; complete = snapshot.Lane_addon_config.complete
         }
     | _ :: _ :: _ as declarations ->
       Ambiguous
         { ids =
             List.map
               (fun (declaration : Lane_addon_config.declaration) ->
                 declaration.Lane_addon_config.id)
               declarations
         })
;;

let report = function
  | Not_required -> Ok "browser lane host not installed; the browser Add-on is not required"
  | Declared { id } -> Ok (Printf.sprintf "browser Add-on declared id=%s" id)
  | Ambiguous { ids } ->
    Error
      (Printf.sprintf
         "more than one enabled browser Add-on declaration is saved (%s), so the server cannot \
          choose which one answers a native browser host and would answer every poll with HTTP \
          503 (ambiguous_browser_addons). Keep one of them enabled."
         (String.concat ", " ids))
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
          (addons/browser/lane.toml; docs/guides/lane-addon-toml.md), or remove %s if this \
          workspace should run no browser%s%s"
         host_directory directory host_directory unloaded_note incomplete_note)
;;
