include Keeper_types_profile_toml_parser

type keeper_toml_error_kind =
  | Read_error
  | Parse_error
  | Profile_error
  | Invalid_name

type keeper_toml_load_error =
  { keeper_path : string
  ; failing_path : string
  ; kind : keeper_toml_error_kind
  ; detail : string
  }

let keeper_toml_error_kind_to_string = function
  | Read_error -> "read_error"
  | Parse_error -> "parse_error"
  | Profile_error -> "profile_error"
  | Invalid_name -> "invalid_name"
;;

let keeper_toml_load_error_to_string error =
  if String.equal error.keeper_path error.failing_path
  then Printf.sprintf "%s: %s" error.failing_path error.detail
  else
    Printf.sprintf
      "%s: keeper.base %s failed: %s"
      error.keeper_path
      error.failing_path
      error.detail
;;

let keeper_toml_load_error_paths error =
  if String.equal error.keeper_path error.failing_path
  then [ error.keeper_path ]
  else [ error.keeper_path; error.failing_path ]
;;

let load_profile_doc ~keeper_path ~failing_path =
  let error kind detail =
    Error { keeper_path; failing_path; kind; detail }
  in
  match Safe_ops.read_file_safe failing_path with
  | Error detail -> error Read_error detail
  | Ok content ->
    (match Keeper_toml_loader.parse_toml content with
     | Error detail -> error Parse_error detail
     | Ok doc ->
       (match profile_defaults_of_toml doc with
        | Error detail -> error Profile_error detail
        | Ok defaults -> Ok (doc, defaults)))
;;

let inspect_keeper_toml (path : string)
    : (string * keeper_profile_defaults, keeper_toml_load_error) result =
  match load_profile_doc ~keeper_path:path ~failing_path:path with
  | Error _ as error -> error
  | Ok (doc, child_defaults) ->
    let defaults_result =
      match Keeper_toml_loader.toml_string_opt doc "keeper.base" with
      | None -> Ok child_defaults
      | Some base_file ->
        let base_path = Filename.concat (Filename.dirname path) base_file in
        (match load_profile_doc ~keeper_path:path ~failing_path:base_path with
         | Error _ as error -> error
         | Ok (_base_doc, base_defaults) ->
           Ok
             (merge_keeper_profile_defaults
                ~agent_name:"base"
                ~base:base_defaults
                ~overlay:child_defaults))
    in
    (match defaults_result with
     | Error _ as error -> error
     | Ok defaults ->
        let unknown_toml_keys = detect_unknown_keeper_toml_keys doc in
        let unknown_toml_keys = List.filter (fun k -> k <> "keeper.base") unknown_toml_keys in
        let defaults = { defaults with unknown_toml_keys } in
        let name =
          match Keeper_toml_loader.toml_string_opt doc "keeper.name" with
          | Some n when n <> "" -> n
          | _ ->
            Filename.basename path
            |> Filename.remove_extension
        in
        if not (validate_name name) then
          Error
            { keeper_path = path
            ; failing_path = path
            ; kind = Invalid_name
            ; detail = Printf.sprintf "invalid keeper name '%s'" name
            }
        else
          let id = Ids.Keeper_id.generate ~name ~path in
          Ok (name,
              { defaults with manifest_path = Some path
                            ; id = Some id }))

let load_keeper_toml path =
  match inspect_keeper_toml path with
  | Error _ as error -> error
  | Ok (_name, defaults) as loaded ->
    warn_unknown_keeper_toml_key_names ~path defaults.unknown_toml_keys;
    loaded

type keeper_toml_discovery =
  | Loaded of
      { keeper_name : string
      ; defaults : keeper_profile_defaults
      }
  | Invalid of
      { keeper_name : string
      ; error : keeper_toml_load_error
      }

let keeper_toml_discovery_name = function
  | Loaded { keeper_name; _ }
  | Invalid { keeper_name; _ } -> keeper_name

let logged_toml_discovery_error : (string * string, unit) Hashtbl.t = Hashtbl.create 8

let log_toml_discovery_error_once ~file ~error =
  let key = (file, error) in
  if Hashtbl.mem logged_toml_discovery_error key then false
  else begin
    Hashtbl.add logged_toml_discovery_error key ();
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ProfileLoadFailures)
      ~labels:
        [ ( "site"
          , Keeper_profile_load_failure_site.(to_label Toml_discovery_error) )
        ]
      ();
    Log.Keeper.warn "toml_loader: invalid discovery retained for %s: %s" file error;
    true
  end

let discover_keepers_toml (dir : string)
    : keeper_toml_discovery list =
  if not (Fs_compat.file_exists dir && Sys.is_directory dir) then []
  else
    dir
    |> Sys.readdir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".toml")
    |> List.sort String.compare
    |> List.map (fun f ->
         let path = Filename.concat dir f in
         match load_keeper_toml path with
         | Ok (keeper_name, defaults) -> Loaded { keeper_name; defaults }
         | Error e ->
           let _emitted =
             log_toml_discovery_error_once
               ~file:f
               ~error:(keeper_toml_load_error_to_string e)
           in
           Invalid
             { keeper_name = Filename.remove_extension f
             ; error = e
             })
