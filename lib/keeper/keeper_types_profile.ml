(** Keeper_types_profile — keeper config and prompt loading.

    Extracted from keeper_types.ml to reduce file size.
    Depends only on Keeper_config (no Keeper_types dependency).

    TOML parsing, loading, and merging live in
    [Keeper_types_profile_toml] (included below). *)

include Keeper_config

include Keeper_types_profile_sandbox

type 'a context = {
  config: Workspace.config;
  agent_name: string;
  sw: Eio.Switch.t;
  clock: 'a Eio.Time.clock;
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net: [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
  publication_recovery_provider:
    Keeper_publication_recovery_availability.provider;
}

type tool_result = Tool_result.result

let tool_result_ok ?(tool_name = "") body : tool_result =
  Tool_result.make_ok
    ~tool_name
    ~start_time:(Tool_timing.start ())
    ~data:(`String body)
    ()
;;

let tool_result_ok_data ?(tool_name = "") data : tool_result =
  Tool_result.make_ok
    ~tool_name
    ~start_time:(Tool_timing.start ())
    ~data
    ()
;;

(* [class_] is required, matching [Tool_result.error] one layer down. It used
   to default to [Runtime_failure], which meant 80 of the 83 call sites said
   "this tool crashed" without anyone deciding that. Argument validation and
   not-found both arrived as faults, and [Tool_bridge] lowers a fault to
   [Unknown] rather than [Deterministic] -- so an agent retried calls that
   could never succeed. A default here undid a required argument there. *)
let tool_result_error
      ?(tool_name = "")
      ~class_
      body
  : tool_result
  =
  Tool_result.make_err
    ~tool_name
    ~class_
    ~start_time:(Tool_timing.start ())
    ~data:(`String body)
    body
;;

(* [effect_disposition] is passed through as given. Left out, the failure
   reads as [Effect_outcome_unknown] ([Tool_result.make_err]), so a caller
   that knows whether its effect happened says so. *)
let tool_result_error_data
      ?(tool_name = "")
      ?effect_disposition
      ~class_
      data
  : tool_result
  =
  Tool_result.make_err
    ~tool_name
    ~class_
    ~start_time:(Tool_timing.start ())
    ~data
    ?effect_disposition
    (Yojson.Safe.to_string data)
;;

let tool_result_with_tool_name ~tool_name : tool_result -> tool_result = function
  | Tool_result.Completed payload ->
    Tool_result.Completed { payload with tool_name }
  | Tool_result.Deferred payload ->
    Tool_result.Deferred { payload with tool_name }
  | Tool_result.Failed payload -> Tool_result.Failed { payload with tool_name }
;;

let tool_result_body = Tool_result.message
let tool_result_success = Tool_result.is_success

(* Configuration: see Keeper_config *)
include Keeper_config

let short_preview ?(max_len = 220) (s : string) : string =
  let s = String.trim s in
  if String.length s <= max_len then s
  else String_util.utf8_prefix ~max_bytes:max_len s ^ "..."

let take = List.take

(* Delegated to Keeper_fs — single fiber-safe ensure_dir implementation. *)
let ensure_dir = Keeper_fs.ensure_dir

(* ── TOML parsing, normalizers, merge, discover ──────────────────── *)
include Keeper_types_profile_toml

(* ── JSON workspace-seq helpers ───────────────────────────────────────── *)

let operator_todo_placeholder_marker = "OPERATOR_TODO"

let string_has_operator_todo_placeholder value =
  String_util.contains_substring value operator_todo_placeholder_marker
;;

let keeper_profile_defaults_materializable (defaults : keeper_profile_defaults) =
  let has_runtime_identity = Option.is_some defaults.instructions in
  match defaults.activation_mode with
  | Some (Keeper_activation_mode.On_demand | Autonomous) -> true
  | Some Manual | None -> has_runtime_identity
;;

let keeper_toml_path_opt_for_base_path ~base_path name =
  Config_dir_resolver.keeper_toml_path_opt_for_base_path ~base_path name

(* A keeper nothing declares is not configured. This used to load as
   [empty_keeper_profile_defaults], so every reader downstream -- turn
   dispatch, effective meta, autoboot, the fleet scan -- proceeded on a
   profile no file had written (audit F386). *)
let declaration_not_found ~expected_path name =
  Error
    { keeper_path = expected_path
    ; failing_path = expected_path
    ; kind = Declaration_not_found name
    ; detail =
        Printf.sprintf "keeper %s has no declaration at %s" name expected_path
    }

let load_keeper_instructions ~toml_path _name defaults =
  let reject detail =
    Error
      { keeper_path = toml_path
      ; failing_path = toml_path
      ; kind = Parse_error
      ; detail
      }
  in
  match defaults.instructions with
  | Some value when String.trim value = "" ->
    reject "keeper TOML must set a non-empty keeper.instructions"
  | Some value when string_has_operator_todo_placeholder value ->
    reject
      (Printf.sprintf
         "keeper.instructions contains %s placeholder text"
         operator_todo_placeholder_marker)
  | Some _ -> Ok defaults
  | None ->
    (* The TOML is the whole setup. An external instructions file was the
       Persona system's loader (#19978); Persona was hard cut in #27048 and
       the file path outlived it. A keeper with no [keeper.instructions] is
       not configured. *)
    Error
      { keeper_path = toml_path
      ; failing_path = toml_path
      ; kind = Parse_error
      ; detail = "keeper TOML must set a non-empty keeper.instructions"
      }

(* Runtime lookup is by filename, while discovery uses keeper.name. A
   declaration whose two names disagree is indexed under both and refused
   under both: the roster asks by keeper.name and the runtime by filename,
   and each used to get an answer the other could not see (audit F386). The
   per-file loader checks the same agreement (#36427) so /health, boot, and
   snapshot projections cannot disagree on a mismatched file. A name claimed
   by more than one file is refused at the snapshot rather than letting
   directory order pick a winner. *)
let name_mismatch_error ~path ~file_name ~keeper_name =
  Error
    { keeper_path = path
    ; failing_path = path
    ; kind = Invalid_name
    ; detail =
        Printf.sprintf
          "keeper.name %S does not match the file name %S"
          keeper_name
          file_name
    }

let load_keeper_instructions_for_file ~toml_path ~file_name keeper_name defaults =
  if not (String.equal keeper_name file_name)
  then name_mismatch_error ~path:toml_path ~file_name ~keeper_name
  else load_keeper_instructions ~toml_path keeper_name defaults

let materialization_defaults_of_content ~path bytes =
  let file_name = Filename.remove_extension (Filename.basename path) in
  Result.bind (inspect_keeper_toml_content ~path bytes) (fun (name, defaults) ->
    load_keeper_instructions_for_file ~toml_path:path ~file_name name defaults)

let load_keeper_profile_defaults_result_for_base_path ~base_path name :
    (keeper_profile_defaults, keeper_toml_load_error) result =
  let keeper_toml_path =
    Config_dir_resolver.keeper_toml_path_for_base_path ~base_path name
  in
  if not (Env_config_core.existing_file keeper_toml_path)
  then declaration_not_found ~expected_path:keeper_toml_path name
  else
    match load_keeper_toml keeper_toml_path with
    | Error _ as error -> error
    | Ok (loaded_name, defaults) ->
      let file_name = Filename.remove_extension (Filename.basename keeper_toml_path) in
      if not (String.equal loaded_name file_name)
      then name_mismatch_error ~path:keeper_toml_path ~file_name ~keeper_name:loaded_name
      else
        load_keeper_instructions_for_file
          ~toml_path:keeper_toml_path
          ~file_name:name
          loaded_name
          defaults

type keeper_profile_snapshot =
  { base_path : string
  ; configured_names : string list
  ; profiles_by_name :
      (string * (keeper_profile_defaults, keeper_toml_load_error) result) list
  }

let duplicate_claim_error ~name ~first ~others =
  Error
    { keeper_path = first
    ; failing_path = first
    ; kind = Invalid_name
    ; detail =
        Printf.sprintf
          "keeper %S is declared by more than one file: %s"
          name
          (String.concat ", " (first :: others))
    }

let index_keeper_profile_declarations declarations =
  let claims =
    List.concat_map
      (fun (path, discovery) ->
        let file_name = Filename.remove_extension (Filename.basename path) in
        match discovery with
        | Loaded { keeper_name; defaults } ->
          (match
             load_keeper_instructions_for_file
               ~toml_path:path
               ~file_name
               keeper_name
               defaults
           with
           | Error { kind = Invalid_name; _ } as refused
             when not (String.equal keeper_name file_name) ->
             [ file_name, path, refused; keeper_name, path, refused ]
           | (Ok _
             | Error
                 { kind =
                     (Read_error | Parse_error | Profile_error | Invalid_name
                     | Declaration_not_found _ | Unknown_deny_tool _)
                 ; _
                 }) as result ->
             [ file_name, path, result ])
        | Invalid { error; _ } -> [ file_name, path, Error error ])
      declarations
  in
  let rec index decided = function
    | [] -> List.rev decided
    | (name, path, result) :: rest ->
      if List.mem_assoc name decided
      then index decided rest
      else (
        match
          List.filter_map
            (fun (claimed, other_path, _) ->
              if String.equal claimed name then Some other_path else None)
            rest
        with
        | [] -> index ((name, result) :: decided) rest
        | others ->
          index
            ((name, duplicate_claim_error ~name ~first:path ~others) :: decided)
            rest)
  in
  index [] claims
;;

let snapshot_configured_keeper_names snapshot = snapshot.configured_names
let snapshot_profile_defaults snapshot name =
  match List.assoc_opt name snapshot.profiles_by_name with
  | Some result -> result
  | None ->
    declaration_not_found
      ~expected_path:
        (Config_dir_resolver.keeper_toml_path_for_base_path
           ~base_path:snapshot.base_path
           name)
      name
;;

type declarative_manifest_snapshot =
  | Declarative_manifest_missing
  | Declarative_manifest_present of
      { path : string
      ; sha256 : string
      }

type declarative_materialization_defaults =
  { profile_defaults : keeper_profile_defaults
  ; manifest_snapshot : declarative_manifest_snapshot
  }

let load_declarative_materialization_defaults ~base_path name =
  match keeper_toml_path_opt_for_base_path ~base_path name with
  | None ->
    Ok
      { profile_defaults = empty_keeper_profile_defaults
      ; manifest_snapshot = Declarative_manifest_missing
      }
  | Some path ->
    (match Safe_ops.read_file_safe path with
     | Error detail ->
       Error
         { keeper_path = path
         ; failing_path = path
         ; kind = Read_error
         ; detail
         }
     | Ok bytes ->
       (match materialization_defaults_of_content ~path bytes with
        | Error _ as error -> error
        | Ok profile_defaults ->
          Ok
            { profile_defaults
            ; manifest_snapshot =
                Declarative_manifest_present
                  { path
                  ; sha256 = Digestif.SHA256.(digest_string bytes |> to_hex)
                  }
            }))

type keeper_toml_config_error = {
  keeper_name : string;
  keeper_path : string;
  failing_path : string;
  kind : keeper_toml_error_kind;
  detail : string;
}

type keeper_config_probe_error_kind =
  | Directory_resolution_error
  | Not_a_directory
  | Directory_read_error

type keeper_config_probe_error =
  { directory_path : string option
  ; kind : keeper_config_probe_error_kind
  ; detail : string
  }

type keeper_toml_unknown_keys = {
  keeper_name : string;
  path : string;
  unknown_keys : string list;
}

let keeper_toml_config_error_to_json
    ({ keeper_name; keeper_path; failing_path; kind; detail } :
      keeper_toml_config_error)
    : Yojson.Safe.t =
  `Assoc
    [
      ("keeper", `String keeper_name);
      ("keeper_path", `String keeper_path);
      ("failing_path", `String failing_path);
      ("kind", `String (keeper_toml_error_kind_to_string kind));
      ("detail", `String detail);
      ("terminal_reason", `String "config_invalid");
      ("severity", `String "error");
      ("blocking", `Bool true);
      ("operator_action_required", `Bool true);
      ("next_action", `String "fix_keeper_toml_config");
    ]

let keeper_config_probe_error_kind_to_string = function
  | Directory_resolution_error -> "directory_resolution_error"
  | Not_a_directory -> "not_a_directory"
  | Directory_read_error -> "directory_read_error"

let keeper_config_probe_error_to_json
    ({ directory_path; kind; detail } : keeper_config_probe_error)
    : Yojson.Safe.t =
  `Assoc
    [ ("directory_path", Json_util.string_opt_to_json directory_path)
    ; ("kind", `String (keeper_config_probe_error_kind_to_string kind))
    ; ("detail", `String detail)
    ; ("blocking", `Bool true)
    ; ("operator_action_required", `Bool true)
    ; ("next_action", `String "repair_keeper_config_directory")
    ]

let keeper_toml_config_error_of_load_error
    ~keeper_name
    (error : keeper_toml_load_error) =
  { keeper_name
  ; keeper_path = error.keeper_path
  ; failing_path = error.failing_path
  ; kind = error.kind
  ; detail = error.detail
  }

let keeper_toml_unknown_keys_to_json
    ({ keeper_name; path; unknown_keys } : keeper_toml_unknown_keys)
    : Yojson.Safe.t =
  `Assoc
    [
      ("keeper", `String keeper_name);
      ("path", `String path);
      ("unknown_keys", `List (List.map (fun key -> `String key) unknown_keys));
      ("terminal_reason", `String "config_unknown_keys");
      ("severity", `String "error");
      ("blocking", `Bool true);
      ("operator_action_required", `Bool true);
      ("next_action", `String "remove_unknown_keeper_toml_keys");
    ]

let keeper_name_of_toml_path path =
  Filename.basename path |> Filename.remove_extension

let keeper_toml_unknown_keys_of_path path =
  match Safe_ops.read_file_safe path with
  | Error _ -> None
  | Ok content -> (
      match Keeper_toml_loader.parse_toml content with
      | Error _ -> None
      | Ok doc -> (
          match detect_unknown_keeper_toml_keys doc with
          | [] -> None
          | unknown_keys ->
              Some
                {
                  keeper_name = keeper_name_of_toml_path path;
                  path;
                  unknown_keys = List.sort_uniq String.compare unknown_keys;
                }))

let keeper_toml_config_error_of_path path =
  let file_name = keeper_name_of_toml_path path in
  match inspect_keeper_toml path with
  | Ok (loaded_name, _) when String.equal loaded_name file_name -> None
  | Ok (loaded_name, _) ->
    (match name_mismatch_error ~path ~file_name ~keeper_name:loaded_name with
     | Ok _ -> None
     | Error error ->
       Some (keeper_toml_config_error_of_load_error ~keeper_name:file_name error))
  | Error error ->
    Some
      (keeper_toml_config_error_of_load_error
         ~keeper_name:file_name
         error)

let keeper_toml_config_errors_in_dir_result dir =
  try
    if not (Fs_compat.file_exists dir)
    then Ok []
    else if not (Sys.is_directory dir)
    then
      Error
        { directory_path = Some dir
        ; kind = Not_a_directory
        ; detail = "keeper config path exists but is not a directory"
        }
    else
      match Safe_ops.list_dir_safe dir with
      | Error detail ->
        Error { directory_path = Some dir; kind = Directory_read_error; detail }
      | Ok files ->
        Ok
          (files
           |> List.filter (fun f -> Filename.check_suffix f ".toml")
           |> List.sort String.compare
           |> List.filter_map (fun f ->
                keeper_toml_config_error_of_path (Filename.concat dir f)))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      { directory_path = Some dir
      ; kind = Directory_read_error
      ; detail = Printexc.to_string exn
      }

let keeper_toml_unknown_keys_in_dir dir =
  if not (Fs_compat.file_exists dir && Sys.is_directory dir) then []
  else
    dir
    |> Sys.readdir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".toml")
    |> List.sort String.compare
    |> List.filter_map (fun f ->
         keeper_toml_unknown_keys_of_path (Filename.concat dir f))

let keeper_toml_config_errors_result () =
  try keeper_toml_config_errors_in_dir_result (Config_dir_resolver.keepers_dir ()) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      { directory_path = None
      ; kind = Directory_resolution_error
      ; detail = Printexc.to_string exn
      }

let keeper_toml_unknown_keys () =
  keeper_toml_unknown_keys_in_dir (Config_dir_resolver.keepers_dir ())

(* Read every source on each capture; reuse only exact captured bytes, never
   filesystem metadata. Parsing consumes this same read, so an external replace
   cannot bind the cache key to one generation and the profile to another. *)
type profile_snapshot_entry =
  { snapshot_sources : (string * (string, keeper_toml_load_error) result) list
  ; snapshot : keeper_profile_snapshot
  }

let profile_snapshot_cache : (string * string, profile_snapshot_entry) Hashtbl.t =
  Hashtbl.create 4
let profile_snapshot_mu = Stdlib.Mutex.create ()

let read_keeper_profile_snapshot ~base_path =
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let key = (base_path, keepers_dir) in
  let toml_paths = Keeper_types_profile_toml.keeper_toml_paths keepers_dir in
  let snapshot_sources = List.map (fun path ->
    path, Keeper_types_profile_toml.read_keeper_toml_content path) toml_paths in
  let cached =
    Stdlib.Mutex.protect profile_snapshot_mu (fun () ->
      Hashtbl.find_opt profile_snapshot_cache key)
  in
  match cached with
  | Some entry when entry.snapshot_sources = snapshot_sources ->
    entry.snapshot
  | Some _ | None ->
    let declarations =
      List.map
        (fun (path, contents) ->
          path, Keeper_types_profile_toml.discover_keeper_toml_read ~path contents)
        snapshot_sources
    in
    let snapshot =
      { base_path
      ; configured_names =
          declarations
          |> List.map (fun (_, discovery) -> keeper_toml_discovery_name discovery)
          |> List.sort_uniq String.compare
      ; profiles_by_name = index_keeper_profile_declarations declarations
      }
    in
    let holdable =
      List.for_all (fun (_, contents) -> Result.is_ok contents) snapshot_sources
    in
    if holdable
    then
      Stdlib.Mutex.protect profile_snapshot_mu (fun () ->
        Hashtbl.replace profile_snapshot_cache key { snapshot_sources; snapshot });
    snapshot
;;

(* A snapshot holds every declaration of its keepers dir, so an in-process
   write of one declaration drops every held snapshot. *)
let invalidate_keeper_profile_snapshots () =
  Stdlib.Mutex.protect profile_snapshot_mu (fun () ->
    Hashtbl.reset profile_snapshot_cache)

let keeper_profile_defaults_materializable_for_name ~base_path name =
  try
    (match load_keeper_profile_defaults_result_for_base_path ~base_path name with
     | Ok defaults -> keeper_profile_defaults_materializable defaults
     | Error error ->
       Log.Keeper.warn
         "profile materializable check for %s blocked by invalid config: %s"
         name
         (keeper_toml_load_error_to_string error);
       false)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ProfileLoadFailures)
        ~labels:
          [
            ( "site",
              Keeper_profile_load_failure_site.(to_label Materializable_check) );
          ]
        ();
      Log.Keeper.warn
        "profile materializable check for %s failed base_path=%s: %s"
        name
        base_path
        (Printexc.to_string exn);
      false

type keeper_default_source_snapshot = {
  source_kind : string option;
  defaults : keeper_profile_defaults;
  config_error : keeper_toml_load_error option;
}

let keeper_default_source_snapshot ~base_path name : keeper_default_source_snapshot =
  match load_keeper_profile_defaults_result_for_base_path ~base_path name with
  | Ok defaults ->
    { source_kind = Option.map (fun _ -> "toml") defaults.manifest_path
    ; defaults
    ; config_error = None
    }
  | Error config_error ->
    { source_kind = None
    ; defaults = empty_keeper_profile_defaults
    ; config_error = Some config_error
    }

let keeper_dir (config : Workspace.config) =
  let d = Workspace.keepers_runtime_dir config in
  ensure_dir d

let keeper_meta_path config name =
  Filename.concat
    (keeper_dir config)
    (Keeper_runtime_root_entry.keeper_basename
       ~keeper_name:name
       Keeper_runtime_root_entry.Metadata)

let session_base_dir (config : Workspace.config) = Keeper_fs.session_base_dir config
