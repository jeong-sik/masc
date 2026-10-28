let provider_names =
  String.concat ", " (List.map Web_search_provider.label Web_search_provider.all)

let parse_provider raw =
  match Web_search_provider.of_label raw with
  | Some provider -> Ok provider
  | None ->
    Error
      (Printf.sprintf
         "%S is not a web search provider. Use one of: %s. To go back to the \
          default order, use --unset."
         raw provider_names)

let parse_providers ~flag raw =
  let names =
    String.split_on_char ',' raw
    |> List.map String.trim
    |> List.filter (fun name -> not (String.equal name ""))
  in
  let rec parse = function
    | [] -> Ok []
    | name :: rest ->
      (match parse_provider name with
       | Error message -> Error message
       | Ok provider -> Result.map (fun others -> provider :: others) (parse rest))
  in
  match parse names with
  | Error message -> Error (Printf.sprintf "--%s: %s" flag message)
  | Ok [] -> Error (Printf.sprintf "--%s names no provider" flag)
  | Ok (first :: rest) -> Ok (first, rest)

let changes
    ~searxng_url ~provider ~provider_order ~fallbacks ~timeout_sec ~cache_ttl_sec ~unset =
  let open Result.Syntax in
  let optional parse wrap = function
    | None -> Ok []
    | Some raw -> Result.map (fun parsed -> [ wrap parsed ]) (parse raw)
  in
  let* url =
    optional (fun url -> Ok url) (fun url -> Web_search_setup.Set_searxng_url url) searxng_url
  in
  let* provider =
    optional parse_provider (fun provider -> Web_search_setup.Set_provider provider) provider
  in
  let* order =
    optional (parse_providers ~flag:"provider-order")
      (fun providers -> Web_search_setup.Set_provider_order providers) provider_order
  in
  let* fallbacks =
    optional (parse_providers ~flag:"fallbacks")
      (fun providers -> Web_search_setup.Set_fallbacks providers) fallbacks
  in
  let* timeout =
    optional (fun seconds -> Ok seconds)
      (fun seconds -> Web_search_setup.Set_timeout_sec seconds) timeout_sec
  in
  let* ttl =
    optional (fun seconds -> Ok seconds)
      (fun seconds -> Web_search_setup.Set_cache_ttl_sec seconds) cache_ttl_sec
  in
  Ok
    (url @ provider @ order @ fallbacks @ timeout @ ttl
     @ List.map (fun key -> Web_search_setup.Unset key) unset)

let credential_names provider =
  String.concat " or " (Web_search_provider.credential_env_names provider)

let show ~runtime_config_path (observation : Web_search_setup.observation) =
  let settings = observation.Web_search_setup.settings in
  let text = Option.value ~default:"(not set)" in
  Printf.printf "Web search settings in %s\n" runtime_config_path;
  List.iter
    (fun (key, value) -> Printf.printf "  %-15s %s\n" (Web_search_setup.key_name key) value)
    Web_search_setup.
      [ Searxng_url, text (Option.map Web_search_setup.display_searxng_url settings.searxng_url)
      ; Provider, text settings.provider
      ; Provider_order, text settings.provider_order
      ; Fallbacks, text settings.fallbacks
      ; Timeout_sec, text (Option.map string_of_int settings.timeout_sec)
      ; Cache_ttl_sec, text (Option.map (Printf.sprintf "%g") settings.cache_ttl_sec)
      ];
  List.iter
    (fun problem -> Printf.printf "  not loadable: %s\n" problem)
    observation.Web_search_setup.problems;
  print_endline "";
  print_endline "Providers, as this shell and runtime.toml leave them:";
  List.iter
    (fun provider ->
       let note =
         (if Web_search_provider.in_default_order provider
          then ""
          else "  (used only when named in provider or provider_order)")
         ^
         if Web_search_provider.needs_credential_to_call provider
            || Web_search_provider.has_credentials provider
         then ""
         else
           Printf.sprintf "  (when named, a call tries %s)"
             Masc_network_defaults.searxng_default_url
       in
       Printf.printf "  %-18s %-8s %s%s\n"
         (Web_search_provider.label provider)
         (if Web_search_provider.has_credentials provider then "ready" else "missing")
         (credential_names provider)
         note)
    Web_search_provider.all;
  print_endline "";
  let plan = Masc.Tool_misc_web_search.provider_plan () in
  (match plan with
   | [] ->
     print_endline
       "Search order now: (empty). masc_web_search fails until one provider has a \
        credential."
   | _ :: _ -> Printf.printf "Search order now: %s\n" (String.concat ", " plan));
  List.iter
    (fun label ->
       match Web_search_provider.of_label label with
       | Some provider
         when Web_search_provider.needs_credential_to_call provider
              && not (Web_search_provider.has_credentials provider) ->
         Printf.printf
           "  %s is in that order without %s, so every call to it fails.\n"
           label (credential_names provider)
       | Some _ | None -> ())
    plan;
  print_endline
    "SearXNG needs no API key: run an instance and pass its address with --searxng-url.";
  print_endline
    "API keys are read from the environment of the process that starts the server. \
     Export them there; this command does not store them."

(* Whether a running server picks a change up is the registry's to say, per
   key. A key it does not name is reported as needing a restart, the answer
   that does not promise an effect that has not happened. *)
let needs_restart change =
  Option.fold
    ~none:true
    ~some:Keeper_runtime_setting_registry.requires_restart
    (Keeper_runtime_setting_registry.find_by_toml_key
       (Web_search_setup.toml_key (Web_search_setup.change_key change)))

(* The file the server reads: [MASC_CONFIG_DIR] first, then the workspace's own
   [.masc/config]. The settings overlay below is seeded from the same
   resolution, so the file shown, the file written and the state computed are
   one file. *)
let runtime_config_path_of ~base_path =
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path in
  Filename.concat
    resolution.Config_dir_resolver.config_root.Config_dir_resolver.path
    Config_dir_resolver.runtime_toml_filename

let run
    ~base_path ~searxng_url ~provider ~provider_order ~fallbacks ~timeout_sec
    ~cache_ttl_sec ~unset =
  let refuse message = prerr_endline message; 1 in
  let runtime_config_path = runtime_config_path_of ~base_path in
  (* Web search settings are a section of the configuration [masc init] writes,
     so a directory that was never initialized has nowhere to put them. Checked
     by the file's existence, as voice-local-setup does. *)
  if not (Sys.file_exists runtime_config_path) then
    refuse
      (Printf.sprintf
         "No masc workspace at %s: %s does not exist. Run masc init --base-path %s \
          first, then this again."
         base_path runtime_config_path (Filename.quote base_path))
  else
    match
      changes ~searxng_url ~provider ~provider_order ~fallbacks ~timeout_sec ~cache_ttl_sec
        ~unset
    with
    | Error message -> refuse message
    | Ok changes ->
      (match Web_search_setup.observe ~runtime_config_path with
       | Error error -> refuse (Web_search_setup.error_message error)
       | Ok observation ->
         let written =
           match changes with
           | [] -> Ok None
           | _ :: _ ->
             Web_search_setup.apply ~runtime_config_path
               ~expected_revision:observation.Web_search_setup.revision changes
             |> Result.map Option.some
         in
         (match written with
          | Error error -> refuse (Web_search_setup.error_message error)
          | Ok revision ->
            (* The settings the server will read, seeded the way it seeds them,
               so the plan and the credential state below are what a search
               resolves and not only what this shell exports. *)
            (match Keeper_runtime_config.load_and_apply ~base_path with
             | Ok _ -> ()
             | Error failure ->
               Printf.eprintf
                 "Could not seed the settings into this process, so the state below is \
                  the environment only: %s\n"
                 (Keeper_runtime_config.load_failure_to_string failure));
            (match Web_search_setup.observe ~runtime_config_path with
             | Error error ->
               (* The write, if there was one, has already landed. *)
               refuse
                 ((match revision with
                   | Some _ -> "The settings were written, but reading them back failed: "
                   | None -> "")
                  ^ Web_search_setup.error_message error)
             | Ok shown ->
               (match revision with
                | None -> ()
                | Some written_revision ->
                  (* A commit of identical bytes yields the revision that was
                     observed: nothing changed. *)
                  if String.equal written_revision observation.Web_search_setup.revision
                  then print_endline "web search settings already are as requested"
                  else begin
                    print_endline "web search settings are written";
                    if List.exists needs_restart changes
                    then print_endline "A running server reads these when it restarts."
                  end;
                  print_endline "");
               show ~runtime_config_path shown;
               0)))
