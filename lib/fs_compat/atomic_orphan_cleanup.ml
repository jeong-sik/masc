(* See [atomic_orphan_cleanup.mli] for the ownership contract. *)

type atomic_orphan_cleanup_operation =
  | Inspect_cleanup_root
  | Read_cleanup_directory
  | Inspect_orphan
  | Create_recovery_directory
  | Sync_recovery_parent
  | Link_preserved_orphan
  | Verify_preserved_orphan
  | Sync_preserved_orphan
  | Sync_recovery_directory
  | Delete_empty_orphan
  | Delete_preserved_source
  | Sync_source_directory
  | Close_cleanup_descriptor

type atomic_orphan_cleanup_cause =
  | Unix_failure of Unix.error * string * string
  | Sys_failure of string
  | Unexpected_file_kind of Unix.file_kind
  | Outside_ownership_root of { ownership_root : string }
  | Identity_changed
  | Other_failure of exn

type atomic_orphan_cleanup_failure =
  { operation : atomic_orphan_cleanup_operation
  ; path : string
  ; cause : atomic_orphan_cleanup_cause
  }

type atomic_orphan_cleanup_report =
  { inspected : int
  ; deleted : int
  ; preserved : int
  ; failures : atomic_orphan_cleanup_failure list
  }

let atomic_orphan_cleanup_operation_to_string = function
  | Inspect_cleanup_root -> "inspect_cleanup_root"
  | Read_cleanup_directory -> "read_cleanup_directory"
  | Inspect_orphan -> "inspect_orphan"
  | Create_recovery_directory -> "create_recovery_directory"
  | Sync_recovery_parent -> "sync_recovery_parent"
  | Link_preserved_orphan -> "link_preserved_orphan"
  | Verify_preserved_orphan -> "verify_preserved_orphan"
  | Sync_preserved_orphan -> "sync_preserved_orphan"
  | Sync_recovery_directory -> "sync_recovery_directory"
  | Delete_empty_orphan -> "delete_empty_orphan"
  | Delete_preserved_source -> "delete_preserved_source"
  | Sync_source_directory -> "sync_source_directory"
  | Close_cleanup_descriptor -> "close_cleanup_descriptor"
;;

let atomic_orphan_cleanup_cause_to_string = function
  | Unix_failure (error, fn, arg) ->
    Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message error)
  | Sys_failure detail -> detail
  | Unexpected_file_kind kind ->
    Printf.sprintf
      "unexpected file kind: %s"
      (Owned_directory_chain.file_kind_to_string kind)
  | Outside_ownership_root { ownership_root } ->
    Printf.sprintf "path is outside ownership root: %s" ownership_root
  | Identity_changed -> "filesystem identity changed during cleanup"
  | Other_failure exn -> Printexc.to_string exn
;;

let atomic_orphan_cleanup_failure_to_string failure =
  Printf.sprintf
    "operation=%s path=%s reason=%s"
    (atomic_orphan_cleanup_operation_to_string failure.operation)
    failure.path
    (atomic_orphan_cleanup_cause_to_string failure.cause)
;;

let cleanup_cause_of_exn = function
  | Unix.Unix_error (error, fn, arg) -> Unix_failure (error, fn, arg)
  | Sys_error detail -> Sys_failure detail
  | exn -> Other_failure exn
;;

let same_inode left right =
  left.Unix.st_dev = right.Unix.st_dev && left.Unix.st_ino = right.Unix.st_ino
;;

let cleanup_atomic_orphans ~ownership_root ~(base_path : string) () =
  let recovered_name = ".recovered" in
  let empty_report = { inspected = 0; deleted = 0; preserved = 0; failures = [] } in
  let add_failure report ~operation ~path cause =
    { report with failures = { operation; path; cause } :: report.failures }
  in
  let record_exn report ~operation ~path exn =
    match exn with
    | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
    | exn -> add_failure report ~operation ~path (cleanup_cause_of_exn exn)
  in
  let lstat report ~operation path =
    try Some (Unix.lstat path), report with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> None, report
    | exn -> None, record_exn report ~operation ~path exn (* cancel-guard-ok: Unix.lstat performs no Eio operation *)
  in
  let identity_is_current report ~operation ~path ~expected ~kind =
    match lstat report ~operation path with
    | Some actual, report
      when actual.Unix.st_kind = kind && same_inode expected actual ->
      true, report
    | Some actual, report when actual.Unix.st_kind <> kind ->
      ( false
      , add_failure
          report
          ~operation
          ~path
          (Unexpected_file_kind actual.Unix.st_kind) )
    | Some _, report ->
      false, add_failure report ~operation ~path Identity_changed
    | None, report ->
      false, add_failure report ~operation ~path Identity_changed
  in
  let inspect_owned_chain report =
    try
      match Owned_directory_chain.inspect ~ownership_root base_path with
      | Ok Owned_directory_chain.Owned_directory_missing -> None, report
      | Ok (Owned_directory_chain.Owned_directory stat) -> Some stat, report
      | Error (Owned_directory_chain.Owned_path_outside_root _) ->
        ( None
        , add_failure
            report
            ~operation:Inspect_cleanup_root
            ~path:base_path
            (Outside_ownership_root { ownership_root }) )
      | Error (Owned_directory_chain.Owned_path_non_directory { path; kind }) ->
        ( None
        , add_failure
            report
            ~operation:Inspect_cleanup_root
            ~path
            (Unexpected_file_kind kind) )
    with
    | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
    | exn ->
      None, record_exn report ~operation:Inspect_cleanup_root ~path:base_path exn
  in
  let close_descriptor report path fd =
    try Unix.close fd; report with
    | exn -> record_exn report ~operation:Close_cleanup_descriptor ~path exn (* cancel-guard-ok: Unix.close performs no Eio operation, so Cancelled cannot originate in this body. *)
  in
  let sync_verified_path report ~operation ~path ~expected ~kind =
    let opened =
      try
        Ok
          (Unix.openfile
             path
             [ Unix.O_RDONLY; Unix.O_CLOEXEC; Unix.O_NONBLOCK ]
             0)
      with
      | exn -> Error exn (* cancel-guard-ok: Unix.openfile performs no Eio operation, so Cancelled cannot originate in this body. *)
    in
    match opened with
    | Error exn -> None, record_exn report ~operation ~path exn
    | Ok fd ->
      let finish report result =
        let report = close_descriptor report path fd in
        result, report
      in
      (try
         let actual = Unix.fstat fd in
         if actual.Unix.st_kind <> kind || not (same_inode expected actual)
         then finish report None
                |> fun (_, report) ->
                None, add_failure report ~operation ~path Identity_changed
         else (
           Unix.fsync fd;
           finish report (Some ()))
       with
       | exn -> (* cancel-guard-ok: Unix.fstat and Unix.fsync perform no Eio operation, so Cancelled cannot originate in this body. *)
         let report = record_exn report ~operation ~path exn in
         finish report None)
  in
  let ensure_child_directory report ~parent ~parent_stat name =
    let path = Filename.concat parent name in
    match lstat report ~operation:Create_recovery_directory path with
    | Some stat, report when stat.Unix.st_kind = Unix.S_DIR ->
      Some (path, stat), report
    | Some stat, report ->
      ( None
      , add_failure
          report
          ~operation:Create_recovery_directory
          ~path
          (Unexpected_file_kind stat.Unix.st_kind) )
    | None, report ->
      (try
         Unix.mkdir path 0o700;
         let synced_parent, report =
           sync_verified_path
             report
             ~operation:Sync_recovery_parent
             ~path:parent
             ~expected:parent_stat
             ~kind:Unix.S_DIR
         in
         (match synced_parent with
          | None -> None, report
          | Some () ->
            (match lstat report ~operation:Create_recovery_directory path with
             | Some stat, report when stat.Unix.st_kind = Unix.S_DIR ->
               Some (path, stat), report
             | Some stat, report ->
               ( None
               , add_failure
                   report
                   ~operation:Create_recovery_directory
                   ~path
                   (Unexpected_file_kind stat.Unix.st_kind) )
             | None, report ->
               ( None
               , add_failure
                   report
                   ~operation:Create_recovery_directory
                   ~path
                   Identity_changed )))
       with
       | Unix.Unix_error (Unix.EEXIST, _, _) ->
         (match lstat report ~operation:Create_recovery_directory path with
          | Some stat, report when stat.Unix.st_kind = Unix.S_DIR ->
            Some (path, stat), report
          | Some stat, report ->
            ( None
            , add_failure
                report
                ~operation:Create_recovery_directory
                ~path
                (Unexpected_file_kind stat.Unix.st_kind) )
          | None, report ->
            ( None
            , add_failure
                report
                ~operation:Create_recovery_directory
                ~path
                Identity_changed ))
       | exn -> (* cancel-guard-ok: Unix.mkdir performs no Eio operation *)
         None, record_exn report ~operation:Create_recovery_directory ~path exn)
  in
  let ensure_recovery_directory report ~base_stat =
    match
      ensure_child_directory
        report
        ~parent:base_path
        ~parent_stat:base_stat
        recovered_name
    with
    | None, report -> None, report
    | Some (recovered, recovered_stat), report ->
      ensure_child_directory
        report
        ~parent:recovered
        ~parent_stat:recovered_stat
        "root"
  in
  let find_or_create_preserved_link
        report
        ~source_path
        ~source_stat
        ~source_dir
        ~source_dir_stat
        ~destination
        ~destination_stat
        name
    =
    let rec loop report collision =
      let candidate_name =
        if collision = 0 then name else Printf.sprintf "%s.%d" name collision
      in
      let candidate = Filename.concat destination candidate_name in
      let source_current, report =
        identity_is_current
          report
          ~operation:Verify_preserved_orphan
          ~path:source_path
          ~expected:source_stat
          ~kind:Unix.S_REG
      in
      let source_dir_current, report =
        identity_is_current
          report
          ~operation:Verify_preserved_orphan
          ~path:source_dir
          ~expected:source_dir_stat
          ~kind:Unix.S_DIR
      in
      let destination_current, report =
        identity_is_current
          report
          ~operation:Verify_preserved_orphan
          ~path:destination
          ~expected:destination_stat
          ~kind:Unix.S_DIR
      in
      if not (source_current && source_dir_current && destination_current)
      then None, report
      else
        try
          Unix.link ~follow:false source_path candidate;
          Some candidate, report
        with
        | Unix.Unix_error (Unix.EEXIST, _, _) ->
          (match lstat report ~operation:Verify_preserved_orphan candidate with
           | Some stat, report
             when stat.Unix.st_kind = Unix.S_REG && same_inode source_stat stat ->
             Some candidate, report
           | _, report -> loop report (collision + 1))
        | exn -> (* cancel-guard-ok: Unix.link performs no Eio operation *)
          ( None
          , record_exn report ~operation:Link_preserved_orphan ~path:candidate exn )
    in
    loop report 0
  in
  let preserve_nonempty report ~base_stat ~dir ~dir_stat name source_stat =
    match ensure_recovery_directory report ~base_stat with
    | None, report -> report
    | Some (destination, destination_stat), report ->
      let source_path = Filename.concat dir name in
      (match
         find_or_create_preserved_link
           report
           ~source_path
           ~source_stat
           ~source_dir:dir
           ~source_dir_stat:dir_stat
           ~destination
           ~destination_stat
           name
       with
       | None, report -> report
       | Some target, report ->
         let target_stat, report =
           lstat report ~operation:Verify_preserved_orphan target
         in
         (match target_stat with
          | Some target_stat
            when target_stat.Unix.st_kind = Unix.S_REG
                 && same_inode source_stat target_stat ->
            let synced_file, report =
              sync_verified_path
                report
                ~operation:Sync_preserved_orphan
                ~path:target
                ~expected:target_stat
                ~kind:Unix.S_REG
            in
            let synced_destination, report =
              sync_verified_path
                report
                ~operation:Sync_recovery_directory
                ~path:destination
                ~expected:destination_stat
                ~kind:Unix.S_DIR
            in
            (match synced_file, synced_destination with
             | Some (), Some () ->
               let source_current, report =
                 identity_is_current
                   report
                   ~operation:Delete_preserved_source
                   ~path:source_path
                   ~expected:source_stat
                   ~kind:Unix.S_REG
               in
               let source_dir_current, report =
                 identity_is_current
                   report
                   ~operation:Delete_preserved_source
                   ~path:dir
                   ~expected:dir_stat
                   ~kind:Unix.S_DIR
               in
               if not (source_current && source_dir_current)
               then report
               else
                 (try
                    Unix.unlink source_path;
                    let _, report =
                      sync_verified_path
                        report
                        ~operation:Sync_source_directory
                        ~path:dir
                        ~expected:dir_stat
                        ~kind:Unix.S_DIR
                    in
                    { report with preserved = report.preserved + 1 }
                  with
                  | exn -> (* cancel-guard-ok: this body is Unix stat and unlink calls only, no Eio operation, so Cancelled cannot originate in this body. *)
                    record_exn
                      report
                      ~operation:Delete_preserved_source
                      ~path:source_path
                      exn)
             | None, _ | _, None -> report)
          | Some target_stat when target_stat.Unix.st_kind <> Unix.S_REG ->
            add_failure
              report
              ~operation:Verify_preserved_orphan
              ~path:target
              (Unexpected_file_kind target_stat.Unix.st_kind)
          | Some _ ->
            add_failure
              report
              ~operation:Verify_preserved_orphan
              ~path:target
              Identity_changed
          | None ->
            add_failure
              report
              ~operation:Verify_preserved_orphan
              ~path:target
              Identity_changed))
  in
  let delete_empty report ~dir ~dir_stat ~source_stat path =
    let source_current, report =
      identity_is_current
        report
        ~operation:Delete_empty_orphan
        ~path
        ~expected:source_stat
        ~kind:Unix.S_REG
    in
    let source_dir_current, report =
      identity_is_current
        report
        ~operation:Delete_empty_orphan
        ~path:dir
        ~expected:dir_stat
        ~kind:Unix.S_DIR
    in
    if not (source_current && source_dir_current)
    then report
    else
      try
        Unix.unlink path;
        let _, report =
          sync_verified_path
            report
            ~operation:Sync_source_directory
            ~path:dir
            ~expected:dir_stat
            ~kind:Unix.S_DIR
        in
        { report with deleted = report.deleted + 1 }
      with
      | exn -> record_exn report ~operation:Delete_empty_orphan ~path exn (* cancel-guard-ok: this body is Unix stat and unlink calls only, no Eio operation, so Cancelled cannot originate in this body. *)
  in
  (* TEL-OK: this leaf returns every cleanup decision/failure in the typed
     [report]; the schema owner records that report to its metric namespace. *)
  let handle_orphan report ~base_stat ~dir ~dir_stat name =
    let path = Filename.concat dir name in
    match lstat report ~operation:Inspect_orphan path with
    | None, report ->
      add_failure report ~operation:Inspect_orphan ~path Identity_changed
    | Some stat, report when stat.Unix.st_kind <> Unix.S_REG ->
      add_failure
        report
        ~operation:Inspect_orphan
        ~path
        (Unexpected_file_kind stat.Unix.st_kind)
    | Some stat, report when stat.Unix.st_size = 0 ->
      delete_empty report ~dir ~dir_stat ~source_stat:stat path
    | Some stat, report ->
      preserve_nonempty report ~base_stat ~dir ~dir_stat name stat
  in
  let fold_directory report ~base_stat ~dir ~dir_stat ~on_entry =
    let opened =
      try Ok (Unix.opendir dir) with
      | exn -> Error exn (* cancel-guard-ok: Unix.opendir performs no Eio operation, so Cancelled cannot originate in this body. *)
    in
    match opened with
    | Error exn ->
      record_exn report ~operation:Read_cleanup_directory ~path:dir exn
    | Ok handle ->
      let close_after_exception exn =
        let backtrace = Printexc.get_raw_backtrace () in
        (try Unix.closedir handle with
         | close_exn -> (* cancel-guard-ok: Unix.closedir performs no Eio operation, so Cancelled cannot originate in this body. *)
           Stdlib.Printf.eprintf
             "[atomic_write] close after cleanup exception failed path=%s primary=%s close=%s\n%!"
             dir
             (Printexc.to_string exn)
             (Printexc.to_string close_exn));
        Printexc.raise_with_backtrace exn backtrace
      in
      let rec loop report =
        match Unix.readdir handle with
        | name ->
          let report =
            if String.equal name "." || String.equal name ".."
            then report
            else on_entry report ~base_stat ~dir ~dir_stat name
          in
          loop report
        | exception End_of_file -> report
        | exception exn -> (* cancel-guard-ok: Unix.readdir and the entry handler are Unix calls only, no Eio operation, so Cancelled cannot originate in this body. *)
          record_exn report ~operation:Read_cleanup_directory ~path:dir exn
      in
      let report =
        try loop report with
        | exn -> close_after_exception exn (* cancel-guard-ok: the directory fold it runs is Unix calls only, no Eio operation, so Cancelled cannot originate in this body. *)
      in
      (try Unix.closedir handle; report with
       | exn -> (* cancel-guard-ok: Unix.closedir performs no Eio operation, so Cancelled cannot originate in this body. *)
         record_exn report ~operation:Close_cleanup_descriptor ~path:dir exn)
  in
  let result =
    match inspect_owned_chain empty_report with
    | None, report -> report
    | Some base_stat, report ->
      fold_directory
        report
        ~base_stat
        ~dir:base_path
        ~dir_stat:base_stat
        ~on_entry:(fun report ~base_stat ~dir ~dir_stat name ->
          if Atomic_temp_name.is_name name
          then
            handle_orphan
              { report with inspected = report.inspected + 1 }
              ~base_stat
              ~dir
              ~dir_stat
              name
          else report)
  in
  { result with failures = List.rev result.failures }
;;
