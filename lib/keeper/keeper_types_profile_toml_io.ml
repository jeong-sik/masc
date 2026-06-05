include Keeper_types_profile_toml_parser

let load_keeper_toml (path : string)
    : (string * keeper_profile_defaults, string) result =
  match Safe_ops.read_file_safe path with
  | Error e -> Error (Printf.sprintf "cannot read %s: %s" path e)
  | Ok content ->
    match Keeper_toml_loader.parse_toml content with
    | Error e -> Error (Printf.sprintf "%s: %s" path e)
    | Ok doc ->
      match profile_defaults_of_toml doc with
      | Error e -> Error (Printf.sprintf "%s: %s" path e)
      | Ok defaults ->
        let defaults =
          match Keeper_toml_loader.toml_string_opt doc "keeper.base" with
          | Some base_file ->
              let base_path = Filename.concat (Filename.dirname path) base_file in
              (match Safe_ops.read_file_safe base_path with
               | Ok base_content ->
                   (match Keeper_toml_loader.parse_toml base_content with
                    | Ok base_doc ->
                        (match profile_defaults_of_toml base_doc with
                         | Ok base_defaults ->
                             merge_keeper_profile_defaults ~agent_name:"base" ~base:base_defaults ~overlay:defaults
                         | Error _ -> defaults)
                    | Error _ -> defaults)
               | Error _ -> defaults)
          | None -> defaults
        in
        let unknown_toml_keys = detect_unknown_keeper_toml_keys doc in
        let unknown_toml_keys = List.filter (fun k -> k <> "keeper.base") unknown_toml_keys in
        warn_unknown_keeper_toml_keys ~path doc;
        let defaults = { defaults with unknown_toml_keys } in
        let name =
          match Keeper_toml_loader.toml_string_opt doc "keeper.name" with
          | Some n when n <> "" -> n
          | _ ->
            Filename.basename path
            |> Filename.remove_extension
        in
        if not (validate_name name) then
          Error (Printf.sprintf "%s: invalid keeper name '%s'" path name)
        else
          let id = Ids.Keeper_id.generate ~name ~path in
          Ok (name,
              { defaults with manifest_path = Some path
                            ; id = Some id })

let logged_toml_skip : (string * string, unit) Hashtbl.t = Hashtbl.create 8

let log_toml_skip_once ~file ~error =
  let key = (file, error) in
  if Hashtbl.mem logged_toml_skip key then false
  else begin
    Hashtbl.add logged_toml_skip key ();
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ProfileLoadFailures)
      ~labels:[("site", Keeper_profile_load_failure_site.(to_label Toml_skip))]
      ();
    Log.Keeper.warn "toml_loader: skipping %s: %s" file error;
    true
  end

let reset_logged_toml_skip_for_test () = Hashtbl.clear logged_toml_skip

let discover_keepers_toml (dir : string)
    : (string * keeper_profile_defaults) list =
  if not (Fs_compat.file_exists dir && Sys.is_directory dir) then []
  else
    dir
    |> Sys.readdir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".toml")
    |> List.sort String.compare
    |> List.filter_map (fun f ->
         let path = Filename.concat dir f in
         match load_keeper_toml path with
         | Ok pair -> Some pair
         | Error e ->
           let _emitted = log_toml_skip_once ~file:f ~error:e in
           None)
