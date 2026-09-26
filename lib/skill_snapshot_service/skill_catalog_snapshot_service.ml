type publication =
  | Published of Skill_catalog_snapshot.t
  | Unchanged of Skill_catalog_snapshot.t
  | Workspace_retired

type config_observation =
  | Config_text of
      { path : string
      ; source_text : string
      }
  | Config_unreadable of
      { path : string
      ; detail : string
      }

type published =
  { snapshot : Skill_catalog_snapshot.t
  ; config_path : string
  }

type additional_source = {
  source : Skill_source_config.source;
  ownership_root : string;
}
type additional_source_diagnostic = {
  source_id : Skill_source_config.source_id;
  message : string;
}

type slot_state =
  | Active of published option
  | Retired

type slot =
  { refresh_lock : Cross_context_mutex.t
  ; state : slot_state Atomic.t
  ; mutable additional_sources : additional_source list
  ; mutable config_input : (string option * config_observation) option
  ; additional_diagnostics : additional_source_diagnostic list Atomic.t
  }

type workspace =
  { base_path : string
  ; slot : slot
  }

type workspace_error = Config_dir_resolver.canonical_base_path_error

let slots_lock = Cross_context_mutex.create ()
let slots : (string, slot) Hashtbl.t = Hashtbl.create 1

let workspace_of_base_path ~base_path =
  match Config_dir_resolver.canonical_base_path base_path with
  | Error _ as error -> error
  | Ok base_path ->
    Cross_context_mutex.with_lock slots_lock (fun () ->
      let slot =
        match Hashtbl.find_opt slots base_path with
        | Some slot -> slot
        | None ->
          let slot =
            { refresh_lock = Cross_context_mutex.create ()
            ; state = Atomic.make (Active None)
            ; additional_sources = []
            ; config_input = None
            ; additional_diagnostics = Atomic.make []
            }
          in
          Hashtbl.add slots base_path slot;
          slot
      in
      Ok { base_path; slot })
;;

let find_workspace_of_base_path ~base_path =
  match Config_dir_resolver.canonical_base_path base_path with
  | Error _ as error -> error
  | Ok base_path ->
    Cross_context_mutex.with_lock slots_lock (fun () ->
      Ok
        (Hashtbl.find_opt slots base_path
         |> Option.map (fun slot -> { base_path; slot })))
;;

let workspace_base_path workspace = workspace.base_path
let current_published ~workspace =
  match Atomic.get workspace.slot.state with
  | Active published -> published
  | Retired -> None
;;

let current ~workspace =
  Option.map (fun published -> published.snapshot) (current_published ~workspace)
;;

let retire ~workspace =
  Cross_context_mutex.with_lock slots_lock (fun () ->
    match Hashtbl.find_opt slots workspace.base_path with
    | Some slot when slot == workspace.slot ->
      Atomic.set workspace.slot.state Retired;
      Hashtbl.remove slots workspace.base_path
    | Some _ | None -> ())
;;

let run_blocking ~label operation =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> operation ()
  | Eio_fiber -> Eio_unix.run_in_systhread ~label operation
;;

let protect_io ~label operation =
  try Ok (run_blocking ~label operation) with
  | Eio.Cancel.Cancelled _ as exn -> Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | (Out_of_memory | Stack_overflow | Sys.Break) as exn ->
    Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | exn -> Error (Printexc.to_string exn)
;;

let candidate_unavailable ~directory ~path detail =
  Skill_catalog_snapshot.Candidate_unreadable { directory; path; detail }
;;

let owned_read_error error = Fs_compat.owned_regular_file_read_error_to_string error

let inspect_skill_package root directory =
  let package_path = Filename.concat root directory in
  match
    protect_io
      ~label:"inspect Skill package directory"
      (fun () -> Fs_compat.exact_path_kind ~follow:false package_path)
  with
  | Error detail ->
    Some (candidate_unavailable ~directory ~path:package_path detail)
  | Ok (Fs_compat.Exact_kind Unix.S_DIR) ->
    let skill_path = Filename.concat package_path "SKILL.md" in
    (match Fs_compat.load_owned_regular_file ~ownership_root:root skill_path with
     | Ok None -> None
     | Ok (Some source_text) ->
       Some (Skill_catalog_snapshot.Candidate_document { directory; source_text })
     | Error error ->
       Some
         (candidate_unavailable
            ~directory
            ~path:skill_path
            (owned_read_error error)))
  | Ok Fs_compat.Exact_missing -> None
  | Ok Fs_compat.Exact_unknown ->
    Some
      (candidate_unavailable
         ~directory
         ~path:package_path
         "package path kind unavailable")
  | Ok (Fs_compat.Exact_kind Unix.S_LNK) ->
    Some
      (candidate_unavailable
         ~directory
         ~path:package_path
         "package directory is a symbolic link")
  | Ok (Fs_compat.Exact_kind _) -> None
;;

let scan_resolved_source (resolved : Skill_source_config.resolved_source) =
  match resolved.resolution with
  | Skill_source_config.Resolved resolved_path ->
    (match
       protect_io
         ~label:"inspect Skill source directory"
         (fun () -> Fs_compat.exact_path_kind ~follow:false resolved_path)
     with
     | Error detail ->
       { Skill_catalog_snapshot.source = resolved
       ; observation =
           Source_unavailable
             { resolved_path; operation = Inspect_source; detail }
       ; candidates = []
       }
     | Ok Fs_compat.Exact_missing ->
       { source = resolved
       ; observation = Source_missing { resolved_path }
       ; candidates = []
       }
     | Ok (Fs_compat.Exact_kind Unix.S_DIR) ->
       (match
          protect_io
            ~label:"read Skill source directory"
            (fun () -> Fs_compat.read_dir resolved_path)
        with
        | Error detail ->
          { source = resolved
          ; observation =
              Source_unavailable
                { resolved_path; operation = Read_source_directory; detail }
          ; candidates = []
          }
        | Ok directories ->
          (* Directory enumeration is path-based, but file contents are not.
             Every candidate is read through [load_owned_regular_file], which
             revalidates the no-symlink parent chain and file identity before
             and after the descriptor read. A replaced source may expose names,
             but cannot redirect Skill bytes outside [resolved_path]. *)
          let candidates =
            directories
            |> List.sort String.compare
            |> List.filter_map (inspect_skill_package resolved_path)
          in
          { source = resolved
          ; observation =
              Source_ready { resolved_path; candidates = List.length candidates }
          ; candidates
          })
     | Ok (Fs_compat.Exact_kind kind) ->
       { source = resolved
       ; observation = Source_not_directory { resolved_path; kind }
       ; candidates = []
       }
     | Ok Fs_compat.Exact_unknown ->
       { source = resolved
       ; observation =
           Source_unavailable
             { resolved_path
             ; operation = Inspect_source
             ; detail = "source path kind unavailable"
             }
       ; candidates = []
       })
  | resolution ->
    { Skill_catalog_snapshot.source = resolved
    ; observation = Source_unresolved resolution
    ; candidates = []
    }
;;

let scan_additional_source ~base_path ~user_home addition =
  let resolved = Skill_source_config.resolve ~base_path ~user_home addition.source in
  match resolved.resolution with
  | Skill_source_config.Resolved resolved_path ->
      let inspect () = protect_io ~label:"inspect package Skill boundary" (fun () ->
        Fs_compat.inspect_owned_directory_chain ~ownership_root:addition.ownership_root resolved_path) in
      let rejected detail =
        { Skill_catalog_snapshot.source = resolved;
          observation = Source_unavailable {resolved_path; operation = Inspect_source; detail};
          candidates = [] } in
      (match inspect () with
       | Error detail -> rejected detail
       | Ok (Error error) -> rejected (Fs_compat.owned_directory_chain_rejection_to_string error)
       | Ok (Ok Owned_directory_missing) ->
           { Skill_catalog_snapshot.source = resolved;
             observation = Source_missing {resolved_path}; candidates = [] }
       | Ok (Ok (Owned_directory before)) ->
           let scan = scan_resolved_source resolved in
           (match inspect () with
            | Ok (Ok (Owned_directory after))
              when before.Unix.st_dev = after.Unix.st_dev && before.Unix.st_ino = after.Unix.st_ino -> scan
            | _ -> rejected "package Skill directory changed while scanning"))
  | Anchor_unavailable _ | Anchor_invalid _ | Path_rejected _ -> scan_resolved_source resolved
;;

let build_snapshot ~base_path ~user_home ~additional_sources = function
  | Config_unreadable { detail; _ } ->
      Skill_catalog_snapshot.config_unreadable ~detail,
      List.map (fun addition -> {source_id = addition.source.id;
        message = "workspace Skill configuration is unreadable: " ^ detail}) additional_sources
  | Config_text { source_text = config_text; _ } ->
    (match Skill_source_config.parse_text config_text with
     | Error diagnostics ->
       Skill_catalog_snapshot.config_rejected ~source_text:config_text ~diagnostics,
       List.map (fun addition -> {source_id = addition.source.id;
         message = "workspace Skill configuration is invalid: " ^
           String.concat "; " (List.map Skill_source_config.diagnostic_to_string diagnostics)}) additional_sources
     | Ok config ->
       let combined, accepted, diagnostics = List.fold_left
         (fun (config, accepted, diagnostics) addition ->
           match Skill_source_config.append_sources config [addition.source] with
           | Ok config -> config, addition :: accepted, diagnostics
           | Error errors -> config, accepted,
               {source_id = addition.source.id;
                message = String.concat "; " (List.map Skill_source_config.diagnostic_to_string errors)} :: diagnostics)
         (config, [], []) additional_sources in
       let original_scans =
         List.map
           (fun source ->
              Skill_source_config.resolve ~base_path ~user_home source
              |> scan_resolved_source)
           config.sources
       in
       let additional_scans = List.rev_map (scan_additional_source ~base_path ~user_home) accepted in
       let scan_diagnostics = List.filter_map (fun (scan : Skill_catalog_snapshot.source_scan) ->
         match scan.observation with
         | Source_unavailable {detail; _} -> Some {source_id = scan.source.source.id; message = detail}
         | Source_missing _ -> Some {source_id = scan.source.source.id; message = "package Skill directory is missing"}
         | Source_not_directory _ -> Some {source_id = scan.source.source.id; message = "package Skill source is not a directory"}
         | Source_unresolved _ -> Some {source_id = scan.source.source.id; message = "package Skill source is unresolved"}
         | Source_ready _ -> None) additional_scans in
       (match Skill_catalog_snapshot.configured ~config:combined (original_scans @ additional_scans) with
        | Ok snapshot -> snapshot, List.rev diagnostics @ scan_diagnostics
        | Error _ ->
          Skill_catalog_snapshot.config_unreadable
            ~detail:"Skill snapshot source/config association failed", List.rev diagnostics))
;;

let observation_path = function
  | Config_text { path; _ } | Config_unreadable { path; _ } -> path
;;

let configured_line ~headline ~config_path snapshot =
  Printf.sprintf
    "%s: skills=%d rejections=%d (file: %s) snapshot_revision=%s catalog_revision=%s"
    headline
    (List.length (Skill_catalog_snapshot.entries snapshot))
    (List.length (Skill_catalog_snapshot.rejections snapshot))
    config_path
    (Skill_catalog_snapshot.snapshot_revision snapshot
     |> Skill_catalog_snapshot.snapshot_revision_to_string)
    (Skill_catalog_snapshot.catalog_revision snapshot
     |> Skill_catalog_snapshot.catalog_revision_to_string)
;;

(* Every publication passes through [publish], so boot, a runtime config save,
   a reread of runtime.toml from disk and a package source change are logged by
   one rule, from the snapshot the CAS replaced (#39269). The first publication
   logs the state it publishes; a later one logs only a change of config
   state. A rejected [skills] table empties every Keeper's catalog, so its
   line carries each diagnostic and the file, in the words the save-path 400
   uses (#39274). *)
let log_publication ~config_path ~replaced snapshot =
  let snapshot_revision () =
    Skill_catalog_snapshot.snapshot_revision snapshot
    |> Skill_catalog_snapshot.snapshot_revision_to_string
  in
  match
    Option.map Skill_catalog_snapshot.config_state replaced,
    Skill_catalog_snapshot.config_state snapshot
  with
  | Some (Configured _), Configured _
  | Some (Config_rejected _), Config_rejected _
  | Some (Config_unreadable _), Config_unreadable _ -> ()
  | None, Configured _ ->
    Log.Server.info "%s" (configured_line ~headline:"Skill snapshot ready" ~config_path snapshot)
  | Some (Config_rejected _ | Config_unreadable _), Configured _ ->
    Log.Server.info
      "%s"
      (configured_line ~headline:"Skill catalog configured again" ~config_path snapshot)
  | (None | Some (Configured _ | Config_unreadable _)), Config_rejected { diagnostics; _ } ->
    Log.Server.warn
      "Skill catalog is empty for every Keeper until this is fixed. %s \
       snapshot_revision=%s"
      (Skill_source_config.rejection_message ~config_path diagnostics)
      (snapshot_revision ())
  | (None | Some (Configured _ | Config_rejected _)), Config_unreadable { detail } ->
    Log.Server.error
      "Skill catalog is empty for every Keeper: its configuration is unreadable: \
       %s (file: %s) snapshot_revision=%s"
      detail
      config_path
      (snapshot_revision ())
;;

let rec publish workspace ~config_path candidate =
  let observed = Atomic.get workspace.slot.state in
  match observed with
  | Retired -> Workspace_retired
  | Active (Some current)
    when Skill_catalog_snapshot.equal_snapshot_revision
           (Skill_catalog_snapshot.snapshot_revision current.snapshot)
           (Skill_catalog_snapshot.snapshot_revision candidate)
         && String.equal current.config_path config_path ->
    Unchanged current.snapshot
  | Active replaced ->
    if
      Atomic.compare_and_set
        workspace.slot.state
        observed
        (Active (Some { snapshot = candidate; config_path }))
    then begin
      log_publication
        ~config_path
        ~replaced:(Option.map (fun published -> published.snapshot) replaced)
        candidate;
      Published candidate
    end
    else publish workspace ~config_path candidate
;;

type source_update = Retain_sources | Replace_sources of additional_source list

let refresh_internal ~workspace ~user_home ~source_update ~read_config =
  Cross_context_mutex.with_lock workspace.slot.refresh_lock (fun () ->
    match Atomic.get workspace.slot.state with
    | Retired -> Workspace_retired
    | Active _ ->
      let observation = read_config () in
      let additions = match source_update with
        | Retain_sources -> workspace.slot.additional_sources
        | Replace_sources sources -> sources in
      let candidate, diagnostics = build_snapshot ~base_path:workspace.base_path
          ~user_home ~additional_sources:additions observation in
      (* Both scans have completed. Cancellation before this point publishes
         neither a partial source selection nor a partial catalog. *)
      workspace.slot.additional_sources <- additions;
      workspace.slot.config_input <- Some (user_home, observation);
      Atomic.set workspace.slot.additional_diagnostics diagnostics;
      publish workspace ~config_path:(observation_path observation) candidate)
;;

let refresh ~workspace ~user_home ~read_config =
  refresh_internal ~workspace ~user_home ~source_update:Retain_sources ~read_config
;;
let refresh_with_sources ~workspace ~user_home ~sources ~read_config =
  refresh_internal ~workspace ~user_home ~source_update:(Replace_sources sources) ~read_config
;;
let additional_source_diagnostics ~workspace = Atomic.get workspace.slot.additional_diagnostics

let has_additional_sources ~workspace =
  Cross_context_mutex.with_lock workspace.slot.refresh_lock (fun () -> workspace.slot.additional_sources <> [])
;;

let update_additional_sources ~workspace ~sources =
  Cross_context_mutex.with_lock workspace.slot.refresh_lock (fun () ->
    match Atomic.get workspace.slot.state with
    | Retired -> Ok Workspace_retired
    | Active _ ->
        match workspace.slot.config_input with
        | None ->
            workspace.slot.additional_sources <- sources;
            Error "workspace Skill configuration has not been published"
        | Some (user_home, observation) ->
            let candidate, diagnostics = build_snapshot ~base_path:workspace.base_path
                ~user_home ~additional_sources:sources observation in
            workspace.slot.additional_sources <- sources;
            Atomic.set workspace.slot.additional_diagnostics diagnostics;
            Ok (publish workspace ~config_path:(observation_path observation) candidate))
;;
