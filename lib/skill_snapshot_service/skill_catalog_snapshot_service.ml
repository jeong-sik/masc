type publication =
  | Published of Skill_catalog_snapshot.t
  | Unchanged of Skill_catalog_snapshot.t
  | Workspace_retired

type config_observation =
  | Config_text of string
  | Config_unreadable of string

type slot =
  { lock : Cross_context_mutex.t
  ; current : Skill_catalog_snapshot.t option Atomic.t
  ; mutable retired : bool
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
            { lock = Cross_context_mutex.create ()
            ; current = Atomic.make None
            ; retired = false
            }
          in
          Hashtbl.add slots base_path slot;
          slot
      in
      Ok { base_path; slot })
;;

let workspace_base_path workspace = workspace.base_path
let current ~workspace =
  Cross_context_mutex.with_lock workspace.slot.lock (fun () ->
    if workspace.slot.retired then None else Atomic.get workspace.slot.current)
;;

let retire ~workspace =
  Cross_context_mutex.with_lock workspace.slot.lock (fun () ->
    Cross_context_mutex.with_lock slots_lock (fun () ->
      match Hashtbl.find_opt slots workspace.base_path with
      | Some slot when slot == workspace.slot ->
        workspace.slot.retired <- true;
        Atomic.set workspace.slot.current None;
        Hashtbl.remove slots workspace.base_path
      | Some _ | None -> ()))
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

let build_snapshot ~base_path ~user_home = function
  | Config_unreadable detail -> Skill_catalog_snapshot.config_unreadable ~detail
  | Config_text config_text ->
    (match Skill_source_config.parse_text config_text with
     | Error diagnostics ->
       Skill_catalog_snapshot.config_rejected ~source_text:config_text ~diagnostics
     | Ok config ->
       let scans =
         List.map
           (fun source ->
              Skill_source_config.resolve ~base_path ~user_home source
              |> scan_resolved_source)
           config.sources
       in
       (match Skill_catalog_snapshot.configured ~config scans with
        | Ok snapshot -> snapshot
        | Error _ ->
          Skill_catalog_snapshot.config_unreadable
            ~detail:"Skill snapshot source/config association failed"))
;;

let publish slot candidate =
  match Atomic.get slot.current with
  | Some current
    when Skill_catalog_snapshot.equal_snapshot_revision
           (Skill_catalog_snapshot.snapshot_revision current)
           (Skill_catalog_snapshot.snapshot_revision candidate) ->
    Unchanged current
  | Some _ | None ->
    Atomic.set slot.current (Some candidate);
    Published candidate
;;

let refresh ~workspace ~user_home ~read_config =
  Cross_context_mutex.with_lock workspace.slot.lock (fun () ->
    if workspace.slot.retired
    then Workspace_retired
    else (
      let observation = read_config () in
      build_snapshot ~base_path:workspace.base_path ~user_home observation
      |> publish workspace.slot))
;;

let refresh_config_text ~workspace ~user_home ~config_text =
  refresh ~workspace ~user_home ~read_config:(fun () -> Config_text config_text)
;;

let refresh_config_unreadable ~workspace ~detail =
  refresh
    ~workspace
    ~user_home:None
    ~read_config:(fun () -> Config_unreadable detail)
;;
