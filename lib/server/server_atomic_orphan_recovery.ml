type root_kind =
  | Workspace_root
  | Activity_events
  | Agents
  | Config
  | Delegation_requests
  | Draft_skills
  | Exec_artifacts
  | Keepers
  | Media
  | Messages
  | Operator
  | Procedures
  | Schedules
  | Secrets
  | Tasks
  | Tool_blobs
  | Traces
  | Trajectories
  | Verifications

type traversal =
  | Entries_only
  | Recursive

type catalog_entry =
  { root_kind : root_kind
  ; path : string
  ; traversal : traversal
  }

type provenance =
  { root_kind : root_kind
  ; catalog_root : string
  ; relative_path : string
  ; source_path : string
  }

type pending_reason =
  | Symlink
  | Non_regular_file
  | Catalog_root_is_not_directory

type failure_stage =
  | Open_directory
  | Close_directory
  | Read_directory
  | Inspect_entry
  | Create_recovery_directory
  | Inspect_recovery_target
  | Link_recovery_target
  | Confirm_recovery_directory
  | Delete_source
  | Confirm_source_directory
  | Recovery_name_exhausted

type mutation_effect =
  | Source_unchanged
  | Recovery_link_created of string
  | Source_unlinked

type outcome =
  | Deleted of
      { provenance : provenance
      ; diagnostics : Fs_compat.Durable_mutation.diagnostic list
      }
  | Preserved of
      { provenance : provenance
      ; recovered_path : string
      ; diagnostics : Fs_compat.Durable_mutation.diagnostic list
      }
  | Pending of
      { provenance : provenance
      ; reason : pending_reason
      }
  | Failed of
      { provenance : provenance
      ; stage : failure_stage
      ; mutation_effect : mutation_effect
      ; cause : exn
      ; backtrace : Printexc.raw_backtrace
      ; diagnostics : Fs_compat.Durable_mutation.diagnostic list
      }

type summary =
  { deleted : int
  ; preserved : int
  ; pending : int
  ; failed : int
  }

let root_kind_to_string = function
  | Workspace_root -> "workspace-root"
  | Activity_events -> "activity-events"
  | Agents -> "agents"
  | Config -> "config"
  | Delegation_requests -> "delegation-requests"
  | Draft_skills -> "draft-skills"
  | Exec_artifacts -> "exec-artifacts"
  | Keepers -> Common.keepers_runtime_dirname
  | Media -> "media"
  | Messages -> "messages"
  | Operator -> "operator"
  | Procedures -> "procedures"
  | Schedules -> "schedules"
  | Secrets -> "secrets"
  | Tasks -> "tasks"
  | Tool_blobs -> "tool_blobs"
  | Traces -> "traces"
  | Trajectories -> "trajectories"
  | Verifications -> "verifications"
;;

let workspace_root_entry config =
  { root_kind = Workspace_root
  ; path = Workspace.masc_root_dir config
  ; traversal = Entries_only
  }
;;

let catalog config =
  let masc_root = Workspace.masc_root_dir config in
  let recursive root_kind =
    { root_kind
    ; path = Filename.concat masc_root (root_kind_to_string root_kind)
    ; traversal = Recursive
    }
  in
  [ workspace_root_entry config
  ; recursive Activity_events
  ; { root_kind = Agents; path = Workspace.agents_dir config; traversal = Recursive }
  ; recursive Config
  ; recursive Delegation_requests
  ; recursive Draft_skills
  ; recursive Exec_artifacts
  ; { root_kind = Keepers
    ; path = Workspace.keepers_runtime_dir config
    ; traversal = Recursive
    }
  ; recursive Media
  ; { root_kind = Messages; path = Workspace.messages_dir config; traversal = Recursive }
  ; recursive Operator
  ; recursive Procedures
  ; recursive Schedules
  ; recursive Secrets
  ; { root_kind = Tasks; path = Workspace.tasks_dir config; traversal = Recursive }
  ; recursive Tool_blobs
  ; recursive Traces
  ; recursive Trajectories
  ; recursive Verifications
  ]
;;

let relative_path components =
  match components with
  | [] -> "."
  | first :: rest -> List.fold_left Filename.concat first rest
;;

let provenance (root : catalog_entry) components source_path =
  { root_kind = root.root_kind
  ; catalog_root = root.path
  ; relative_path = relative_path components
  ; source_path
  }
;;

type entry_kind =
  | Regular
  | Directory
  | Symbolic_link
  | Other

type entry_stat =
  { kind : entry_kind
  ; size : int64
  ; device : int64
  ; inode : int64
  }

type open_directory =
  { descriptor : Unix.file_descr
  ; path : string
  }

external open_root_directory : string -> Unix.file_descr = "masc_durable_mutation_open_parent"

external open_child_directory
  :  Unix.file_descr
  -> string
  -> Unix.file_descr
  = "masc_atomic_orphan_open_child"

external mkdir_child
  :  Unix.file_descr
  -> string
  -> int
  -> unit
  = "masc_atomic_orphan_mkdir_child"

external lstat_entry_raw
  :  Unix.file_descr
  -> string
  -> int * int64 * int64 * int64
  = "masc_atomic_orphan_lstat_entry"

external link_entry
  :  Unix.file_descr
  -> string
  -> Unix.file_descr
  -> string
  -> unit
  = "masc_atomic_orphan_link_entry"

external unlink_entry
  :  Unix.file_descr
  -> string
  -> unit
  = "masc_durable_mutation_unlink"

external read_entries : Unix.file_descr -> string array = "masc_atomic_orphan_read_entries"

let lstat_entry descriptor name =
  let kind, size, device, inode = lstat_entry_raw descriptor name in
  let kind =
    match kind with
    | 0 -> Regular
    | 1 -> Directory
    | 2 -> Symbolic_link
    | _ -> Other
  in
  { kind; size; device; inode }
;;

let failed provenance stage mutation_effect cause diagnostics =
  Failed
    { provenance
    ; stage
    ; mutation_effect
    ; cause
    ; backtrace = Printexc.get_raw_backtrace ()
    ; diagnostics
    }
;;

let close_diagnostics descriptors =
  List.filter_map
    (fun descriptor ->
       match Unix.close descriptor with
       | () -> None
       | exception cause ->
         Some
           { Fs_compat.Durable_mutation.stage = Fs_compat.Durable_mutation.Parent_close
           ; cause
           ; backtrace = Printexc.get_raw_backtrace ()
           })
    descriptors
;;

let add_diagnostics outcome diagnostics =
  match outcome with
  | Deleted deleted -> Deleted { deleted with diagnostics = deleted.diagnostics @ diagnostics }
  | Preserved preserved ->
    Preserved { preserved with diagnostics = preserved.diagnostics @ diagnostics }
  | Failed failed -> Failed { failed with diagnostics = failed.diagnostics @ diagnostics }
  | Pending _ -> outcome
;;

let open_catalog_root ~masc_directory (root : catalog_entry) =
  let root_provenance = provenance root [] root.path in
  match root.root_kind with
  | Workspace_root ->
    (match Unix.dup masc_directory.descriptor with
     | descriptor -> `Opened { descriptor; path = root.path }
     | exception cause ->
       `Outcome (failed root_provenance Open_directory Source_unchanged cause []))
  | root_kind ->
    let name = root_kind_to_string root_kind in
    (match lstat_entry masc_directory.descriptor name with
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> `Missing
     | exception cause ->
       `Outcome (failed root_provenance Open_directory Source_unchanged cause [])
     | { kind = Symbolic_link; _ } ->
       `Outcome (Pending { provenance = root_provenance; reason = Symlink })
     | { kind = Directory; _ } ->
       (match open_child_directory masc_directory.descriptor name with
        | descriptor -> `Opened { descriptor; path = root.path }
        | exception cause ->
          `Outcome (failed root_provenance Open_directory Source_unchanged cause []))
     | { kind = Regular | Other; _ } ->
       `Outcome
         (Pending
            { provenance = root_provenance
            ; reason = Catalog_root_is_not_directory
            }))
;;

let with_open_child ~provenance parent name f =
  match open_child_directory parent.descriptor name with
  | exception cause ->
    [ failed provenance Open_directory Source_unchanged cause [] ]
  | descriptor ->
    let child = { descriptor; path = Filename.concat parent.path name } in
    let outcomes = f child in
    (match Unix.close descriptor with
     | () -> outcomes
     | exception cause ->
       failed provenance Close_directory Source_unchanged cause [] :: outcomes)
;;

let fsync_directory ~provenance ~stage ~mutation_effect descriptor =
  match Unix.fsync descriptor with
  | () -> Ok ()
  | exception cause -> Error (failed provenance stage mutation_effect cause [])
;;

let ensure_recovery_child ~provenance parent name =
  let open_existing () =
    match open_child_directory parent.descriptor name with
    | descriptor ->
      Ok { descriptor; path = Filename.concat parent.path name }
    | exception cause ->
      Error
        (failed
           provenance
           Create_recovery_directory
           Source_unchanged
           cause
           [])
  in
  match lstat_entry parent.descriptor name with
  | { kind = Directory; _ } -> open_existing ()
  | _ ->
    Error
      (failed
         provenance
         Create_recovery_directory
         Source_unchanged
         (Failure
            (Printf.sprintf
               "recovery entry is not a directory: %s"
               (Filename.concat parent.path name)))
         [])
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    (match mkdir_child parent.descriptor name 0o700 with
     | () ->
       (match
          fsync_directory
            ~provenance
            ~stage:Create_recovery_directory
            ~mutation_effect:Source_unchanged
            parent.descriptor
        with
        | Error _ as error -> error
        | Ok () -> open_existing ())
     | exception Unix.Unix_error (Unix.EEXIST, _, _) -> open_existing ()
     | exception cause ->
       Error
         (failed
            provenance
            Create_recovery_directory
            Source_unchanged
            cause
            []))
  | exception cause ->
    Error
      (failed
         provenance
         Create_recovery_directory
         Source_unchanged
         cause
         [])
;;

let ensure_recovery_directory
    ~masc_directory
    ~(root : catalog_entry)
    ~provenance
    parent_components
  =
  let opened = ref [] in
  let rec loop parent = function
    | [] -> Ok parent
    | component :: rest ->
      (match ensure_recovery_child ~provenance parent component with
       | Error _ as error -> error
       | Ok child ->
         opened := child.descriptor :: !opened;
         loop child rest)
  in
  let result =
    loop
      masc_directory
      (".recovered"
       :: "atomic-orphans"
       :: root_kind_to_string root.root_kind
       :: parent_components)
  in
  result, opened
;;

let same_inode left right =
  Int64.equal left.device right.device && Int64.equal left.inode right.inode
;;

let max_recovery_name_attempts = 1024

let recovery_target ~provenance ~source_stat recovery name =
  let stem = Printf.sprintf "%s.%Ld" name source_stat.inode in
  let rec choose attempt =
    if attempt >= max_recovery_name_attempts
    then
      Error
        (failed
           provenance
           Recovery_name_exhausted
           Source_unchanged
           (Failure
              (Printf.sprintf
                 "no free recovery target after %d attempts"
                 max_recovery_name_attempts))
           [])
    else (
      let target_name =
        if attempt = 0 then stem else Printf.sprintf "%s.%d" stem attempt
      in
      match lstat_entry recovery.descriptor target_name with
      | target_stat when same_inode source_stat target_stat ->
        Ok (target_name, true)
      | _ -> choose (attempt + 1)
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok (target_name, false)
      | exception cause ->
        Error
          (failed
             provenance
             Inspect_recovery_target
             Source_unchanged
             cause
             []))
  in
  choose 0
;;

let delete_empty ~provenance source name =
  match unlink_entry source.descriptor name with
  | exception cause -> failed provenance Delete_source Source_unchanged cause []
  | () ->
    (match
       fsync_directory
         ~provenance
         ~stage:Confirm_source_directory
         ~mutation_effect:Source_unlinked
         source.descriptor
     with
     | Error outcome -> outcome
     | Ok () -> Deleted { provenance; diagnostics = [] })
;;

let preserve_with_data
    ~masc_directory
    ~root
    ~provenance
    ~components
    source
    name
    source_stat
  =
  let parent_components =
    match List.rev components with
    | [] | [ _ ] -> []
    | _name :: reversed_parent -> List.rev reversed_parent
  in
  let recovery_result, opened =
    ensure_recovery_directory
      ~masc_directory
      ~root
      ~provenance
      parent_components
  in
  let outcome =
    match recovery_result with
    | Error outcome -> outcome
    | Ok recovery ->
      (match recovery_target ~provenance ~source_stat recovery name with
       | Error outcome -> outcome
       | Ok (target_name, already_linked) ->
         let recovered_path = Filename.concat recovery.path target_name in
         let linked =
           if already_linked
           then Ok ()
           else
             match
               link_entry
                 source.descriptor
                 name
                 recovery.descriptor
                 target_name
             with
             | () -> Ok ()
             | exception cause -> Error cause
         in
         (match linked with
          | Error cause ->
            failed provenance Link_recovery_target Source_unchanged cause []
          | Ok () ->
            (match
               fsync_directory
                 ~provenance
                 ~stage:Confirm_recovery_directory
                 ~mutation_effect:(Recovery_link_created recovered_path)
                 recovery.descriptor
             with
             | Error outcome -> outcome
             | Ok () ->
               (match unlink_entry source.descriptor name with
                | exception cause ->
                  failed
                    provenance
                    Delete_source
                    (Recovery_link_created recovered_path)
                    cause
                    []
                | () ->
                  (match
                     fsync_directory
                       ~provenance
                       ~stage:Confirm_source_directory
                       ~mutation_effect:Source_unlinked
                       source.descriptor
                   with
                   | Error outcome -> outcome
                   | Ok () ->
                     Preserved
                       { provenance; recovered_path; diagnostics = [] })))))
  in
  add_diagnostics outcome (close_diagnostics !opened)
;;

let recover_candidate ~masc_directory ~root ~components source name stat =
  let source_path = Filename.concat source.path name in
  let provenance = provenance root components source_path in
  match stat.kind with
  | Regular when Int64.equal stat.size 0L -> delete_empty ~provenance source name
  | Regular ->
    preserve_with_data
      ~masc_directory
      ~root
      ~provenance
      ~components
      source
      name
      stat
  | Symbolic_link -> Pending { provenance; reason = Symlink }
  | Directory | Other -> Pending { provenance; reason = Non_regular_file }
;;

let inspect_candidate ~masc_directory ~root ~components source name =
  let source_path = Filename.concat source.path name in
  let provenance = provenance root components source_path in
  match lstat_entry source.descriptor name with
  | stat -> [ recover_candidate ~masc_directory ~root ~components source name stat ]
  | exception cause -> [ failed provenance Inspect_entry Source_unchanged cause [] ]
;;

let rec scan_recursive ~masc_directory ~root ~components directory =
  let directory_provenance = provenance root components directory.path in
  match read_entries directory.descriptor with
  | exception cause ->
    [ failed directory_provenance Read_directory Source_unchanged cause [] ]
  | entries ->
    entries
    |> Array.to_list
    |> List.sort String.compare
    |> List.concat_map (fun name ->
      let child_components = components @ [ name ] in
      let child_path = Filename.concat directory.path name in
      let child_provenance = provenance root child_components child_path in
      match lstat_entry directory.descriptor name with
      | exception cause ->
        [ failed child_provenance Inspect_entry Source_unchanged cause [] ]
      | { kind = Directory; _ } ->
        with_open_child
          ~provenance:child_provenance
          directory
          name
          (scan_recursive ~masc_directory ~root ~components:child_components)
      | stat when Fs_compat.Durable_mutation.is_temporary_name name ->
        [ recover_candidate
            ~masc_directory
            ~root
            ~components:child_components
            directory
            name
            stat
        ]
      | _ -> [])
;;

let scan_entries_only ~masc_directory ~root directory =
  let directory_provenance = provenance root [] directory.path in
  match read_entries directory.descriptor with
  | exception cause ->
    [ failed directory_provenance Read_directory Source_unchanged cause [] ]
  | entries ->
    entries
    |> Array.to_list
    |> List.sort String.compare
    |> List.concat_map (fun name ->
      if Fs_compat.Durable_mutation.is_temporary_name name
      then
        inspect_candidate
          ~masc_directory
          ~root
          ~components:[ name ]
          directory
          name
      else [])
;;

let scan_catalog_root ~masc_directory root =
  match open_catalog_root ~masc_directory root with
  | `Missing -> []
  | `Outcome outcome -> [ outcome ]
  | `Opened directory ->
    let outcomes =
      match root.traversal with
      | Entries_only -> scan_entries_only ~masc_directory ~root directory
      | Recursive ->
        scan_recursive ~masc_directory ~root ~components:[] directory
    in
    (match Unix.close directory.descriptor with
     | () -> outcomes
     | exception cause ->
       failed
         (provenance root [] root.path)
         Close_directory
         Source_unchanged
         cause
         []
       :: outcomes)
;;

let recover_blocking ~config =
  let masc_root = Workspace.masc_root_dir config in
  let workspace_root = workspace_root_entry config in
  let root_provenance = provenance workspace_root [] masc_root in
  match open_root_directory masc_root with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> []
  | exception cause ->
    [ failed root_provenance Open_directory Source_unchanged cause [] ]
  | descriptor ->
    let masc_directory = { descriptor; path = masc_root } in
    let outcomes =
      catalog config |> List.concat_map (scan_catalog_root ~masc_directory)
    in
    (match Unix.close descriptor with
     | () -> outcomes
     | exception cause ->
       failed root_provenance Close_directory Source_unchanged cause []
       :: outcomes)
;;

let recover_eio ~config =
  Eio.Cancel.protect (fun () ->
    Eio_unix.run_in_systhread ~label:"atomic-orphan-recovery" (fun () ->
      recover_blocking ~config))
;;

let summarize outcomes =
  List.fold_left
    (fun summary -> function
       | Deleted _ -> { summary with deleted = summary.deleted + 1 }
       | Preserved _ -> { summary with preserved = summary.preserved + 1 }
       | Pending _ -> { summary with pending = summary.pending + 1 }
       | Failed _ -> { summary with failed = summary.failed + 1 })
    { deleted = 0; preserved = 0; pending = 0; failed = 0 }
    outcomes
;;

let pending_reason_to_string = function
  | Symlink -> "symlink"
  | Non_regular_file -> "non-regular-file"
  | Catalog_root_is_not_directory -> "catalog-root-is-not-directory"
;;

let failure_stage_to_string = function
  | Open_directory -> "open-directory"
  | Close_directory -> "close-directory"
  | Read_directory -> "read-directory"
  | Inspect_entry -> "inspect-entry"
  | Create_recovery_directory -> "create-recovery-directory"
  | Inspect_recovery_target -> "inspect-recovery-target"
  | Link_recovery_target -> "link-recovery-target"
  | Confirm_recovery_directory -> "confirm-recovery-directory"
  | Delete_source -> "delete-source"
  | Confirm_source_directory -> "confirm-source-directory"
  | Recovery_name_exhausted -> "recovery-name-exhausted"
;;

let effect_to_string = function
  | Source_unchanged -> "source-unchanged"
  | Recovery_link_created path -> "recovery-link-created:" ^ path
  | Source_unlinked -> "source-unlinked"
;;

let diagnostics_to_string diagnostics =
  match diagnostics with
  | [] -> ""
  | diagnostics ->
    Printf.sprintf
      " diagnostics=[%s]"
      (String.concat
         "; "
         (List.map Fs_compat.Durable_mutation.diagnostic_to_string diagnostics))
;;

let outcome_to_string = function
  | Deleted { provenance; diagnostics } ->
    Printf.sprintf
      "deleted root=%s relative=%s source=%s%s"
      (root_kind_to_string provenance.root_kind)
      provenance.relative_path
      provenance.source_path
      (diagnostics_to_string diagnostics)
  | Preserved { provenance; recovered_path; diagnostics } ->
    Printf.sprintf
      "preserved root=%s relative=%s source=%s recovered=%s%s"
      (root_kind_to_string provenance.root_kind)
      provenance.relative_path
      provenance.source_path
      recovered_path
      (diagnostics_to_string diagnostics)
  | Pending { provenance; reason } ->
    Printf.sprintf
      "pending root=%s relative=%s source=%s reason=%s"
      (root_kind_to_string provenance.root_kind)
      provenance.relative_path
      provenance.source_path
      (pending_reason_to_string reason)
  | Failed
      { provenance
      ; stage
      ; mutation_effect
      ; cause
      ; diagnostics
      ; backtrace = _
      } ->
    Printf.sprintf
      "failed root=%s relative=%s source=%s stage=%s effect=%s cause=%s%s"
      (root_kind_to_string provenance.root_kind)
      provenance.relative_path
      provenance.source_path
      (failure_stage_to_string stage)
      (effect_to_string mutation_effect)
      (Printexc.to_string cause)
      (diagnostics_to_string diagnostics)
;;
