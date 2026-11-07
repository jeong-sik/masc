type keeper =
  | Addon_managed of { port : int; profile : string }
  | Addon_off
  | Not_configured
  | Not_known

let keeper ~configuration ~firefox = match configuration with
  | None -> Not_known
  | Some { Browser_configuration.live_bidi = None; _ } -> Not_configured
  | Some { Browser_configuration.live_bidi = Some config; _ } ->
      (match firefox () with
       | Some true -> Addon_managed { port = config.port; profile = config.profile }
       | Some false -> Addon_off
       | None -> Not_known)

(* Whether an enabled declaration of the workspace runs the Addon-managed
   Firefox, read as the server reads its Lane directory. *)
let firefox_declared ~base_path =
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path in
  match resolution.status with
  | Config_dir_resolver.Invalid_env_status -> None
  | Ready | Warn | Missing_status ->
      Lane_addon_config.browser_source_on
        (Lane_addon_config.load
           ~directory:(Lane_addon_config.directory ~config_root:resolution.config_root.path))
        Browser_lane.Backend.Owned_firefox

let observe ~base_path ~configuration =
  keeper ~configuration ~firefox:(fun () -> firefox_declared ~base_path)

let message = function
  | Addon_managed { port; profile } ->
      Printf.sprintf
        "The Browser Addon manages its own Firefox and BiDi connection, configured on port %d \
         with profile %s. Check the Addon observation for readiness. Existing Firefox \
         processes are not adopted or restarted."
        port profile
  | Addon_off ->
      "[browser.live.bidi] is set, but no enabled browser-firefox Lane Add-on declaration \
       runs it, so the Browser Addon does not start that Firefox."
  | Not_configured -> "No Addon-managed live Firefox is configured in [browser.live.bidi]."
  | Not_known ->
      "Whether the Browser Addon starts a live Firefox is not known: runtime.toml or the Lane \
       Add-on declarations could not all be read."
