open Keeper_tool_filesystem_runtime_write_target
open Keeper_tool_filesystem_runtime_write_types
open Keeper_tool_filesystem_runtime_test_seams

let created_directory_operation stage f =
  try Ok (f ()) with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Error
      { stage
      ; cause = Directory_operation_failed { exception_; backtrace }
      }
;;

let sync_created_directory directory =
  match Fs_compat.sync_directory_capability directory with
  | Ok () -> Directory_sync_succeeded
  | Error error -> Directory_sync_failed error
;;

let create_and_commit_directory_component
      ~sw
      ~permissions
      ~parent_dir
      ~component
  =
  let dispatch_fault = Eio.Fiber.get created_directory_dispatch_fault_key in
  let run_directory_operation =
    match dispatch_fault with
    | None -> created_directory_operation
    | Some fault ->
      (fun stage f ->
         created_directory_operation stage (fun () ->
           if fault.fault_stage = stage then raise fault.fault_exception;
           f ()))
  in
  let unchanged primary_failure =
    ( None
    , { component
      ; target_effect = Directory_unchanged
      ; primary_failure = Some primary_failure
      ; child_sync = Directory_sync_not_attempted
      ; parent_sync = Directory_sync_not_attempted
      } )
  in
  let created_without_child ~target_effect primary_failure =
    let parent_sync = sync_created_directory parent_dir in
    ( None
    , { component
      ; target_effect
      ; primary_failure = Some primary_failure
      ; child_sync = Directory_sync_not_attempted
      ; parent_sync
      } )
  in
  let child = Eio.Path.(parent_dir / component) in
  match
    run_directory_operation Create_directory (fun () ->
      Eio.Path.mkdir ~perm:0o700 child)
  with
  | Error primary_failure -> unchanged primary_failure
  | Ok () ->
    (match
       run_directory_operation Inspect_created_directory (fun () ->
         Eio.Path.stat ~follow:false child)
     with
     | Error primary_failure ->
       created_without_child
         ~target_effect:Directory_state_unknown
         primary_failure
     | Ok created when created.kind <> `Directory ->
       created_without_child
         ~target_effect:Directory_state_unknown
         { stage = Inspect_created_directory
         ; cause = Directory_unexpected_resource_kind created.kind
         }
     | Ok created ->
       (match
          run_directory_operation Acquire_directory_capability (fun () ->
            Eio.Path.open_dir ~sw child)
        with
        | Error primary_failure ->
          created_without_child
            ~target_effect:Directory_state_unknown
            primary_failure
        | Ok child_dir ->
          let directory_file =
            run_directory_operation Acquire_directory_capability (fun () ->
              Eio.Path.open_in ~sw Eio.Path.(child_dir / "."))
          in
          let validation =
            match directory_file with
            | Error _ as error -> error
            | Ok directory_file ->
              (match
                 run_directory_operation
                   Validate_directory_capability
                   (fun () ->
                      Eio.Path.stat ~follow:false child, Eio.File.stat directory_file)
               with
               | Error _ as error -> error
               | Ok (lexical, opened)
              when lexical.kind <> `Directory || opened.kind <> `Directory ->
                 let kind =
                   if lexical.kind <> `Directory then lexical.kind else opened.kind
                 in
                 Error
                   { stage = Validate_directory_capability
                   ; cause = Directory_unexpected_resource_kind kind
                   }
               | Ok (lexical, opened)
              when not (same_file_resource created lexical)
                   || not (same_file_resource lexical opened) ->
                 Error
                   { stage = Validate_directory_capability
                   ; cause = Directory_resource_identity_changed
                   }
               | Ok _ -> Ok ())
          in
          (match validation with
           | Error primary_failure ->
             let parent_sync = sync_created_directory parent_dir in
             ( None
             , { component
               ; target_effect = Directory_state_unknown
               ; primary_failure = Some primary_failure
               ; child_sync = Directory_sync_not_attempted
               ; parent_sync
               } )
           | Ok () ->
             let permissions_result =
               match directory_file with
               | Error failure -> Error failure
               | Ok directory_file ->
                 (match Eio_unix.Resource.fd_opt directory_file with
               | None ->
                 Error
                   { stage = Apply_directory_permissions
                   ; cause = Directory_posix_descriptor_unavailable
                   }
               | Some fd ->
                 run_directory_operation Apply_directory_permissions (fun () ->
                   Eio_unix.run_in_systhread
                     ~label:"keeper-fs-created-directory-fchmod"
                     (fun () ->
                        Eio_unix.Fd.use_exn
                          "keeper-fs-created-directory-fchmod"
                          fd
                          (fun unix_fd -> Unix.fchmod unix_fd permissions));
                   Eio.Fiber.check ()))
             in
             let child_sync = sync_created_directory child_dir in
             let parent_sync = sync_created_directory parent_dir in
             let target_effect, primary_failure =
               match permissions_result with
               | Ok () -> Directory_created_requested_mode, None
               | Error failure -> Directory_created_validated, Some failure
             in
             let child_dir =
               match primary_failure, child_sync, parent_sync with
               | None, Directory_sync_succeeded, Directory_sync_succeeded ->
                 Some child_dir
               | ( Some _
                 , ( Directory_sync_not_attempted
                   | Directory_sync_succeeded
                   | Directory_sync_failed _ )
                 , ( Directory_sync_not_attempted
                   | Directory_sync_succeeded
                   | Directory_sync_failed _ ) )
               | ( None
                 , (Directory_sync_not_attempted | Directory_sync_failed _)
                 , ( Directory_sync_not_attempted
                   | Directory_sync_succeeded
                   | Directory_sync_failed _ ) )
               | ( None
                 , Directory_sync_succeeded
                 , (Directory_sync_not_attempted | Directory_sync_failed _) ) ->
                 None
             in
             ( child_dir
             , { component
               ; target_effect
               ; primary_failure
               ; child_sync
               ; parent_sync
               } ))))
;;

let with_created_parent_directories
      ~on_interrupted
      ~permissions
      parent_dir
      missing_parents
      f
  =
  let rec loop created_parents_rev parent_dir missing_parents =
    match missing_parents with
    | [] -> f ~created_parents:(List.rev created_parents_rev) parent_dir
    | component :: rest ->
      Eio.Switch.run @@ fun sw ->
      let child_dir, commit =
        Eio.Cancel.protect (fun () ->
          create_and_commit_directory_component
            ~sw
            ~permissions
            ~parent_dir
            ~component)
      in
      (try Eio.Fiber.check () with
       | Eio.Cancel.Cancelled _ as cancellation ->
         on_interrupted commit;
         raise cancellation);
      (match child_dir with
       | None ->
         Error
           (Content_write_directory
              { failed_commit = commit
              ; created_parents = List.rev created_parents_rev
              })
       | Some child_dir ->
         (try loop (commit :: created_parents_rev) child_dir rest with
          | exception_ ->
            let backtrace = Printexc.get_raw_backtrace () in
            on_interrupted commit;
            Printexc.raise_with_backtrace exception_ backtrace))
  in
  loop [] parent_dir missing_parents
;;
