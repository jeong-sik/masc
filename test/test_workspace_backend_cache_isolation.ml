open Alcotest

module Workspace = Masc.Workspace

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | stat ->
      (match stat.Unix.st_kind with
       | Unix.S_DIR ->
           Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
           Unix.rmdir path
       | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
           Unix.unlink path)

let with_workspace f =
  let dir = Filename.temp_file "masc-backend-cache-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () ->
    Eio_main.run (fun env ->
      let fs = Eio.Stdenv.fs env in
      Fs_compat.set_fs fs;
      let backend_config = Workspace_utils.backend_config_for dir in
      let backend = Backend.FileSystem.create ~fs backend_config in
      let config : Workspace_utils.config =
        { base_path = dir; workspace_path = dir; lock_expiry_minutes = 2
        ; backend_config; backend = Workspace_utils.FileSystem backend } in
      let guard_was_ready = Eio_guard.is_ready () in
      Eio_guard.enable ();
      Fun.protect ~finally:(fun () -> if not guard_was_ready then Eio_guard.disable ()) (fun () ->
        ignore (Workspace.init config ~agent_name:None);
        f env config)))

let memory_config config =
  let backend = Backend.Memory.create () in
  { config with Workspace_utils.backend = Workspace_utils.Memory backend }, backend

let put_memory config backend path content =
  let key = match Workspace_utils.key_of_path config path with
    | Some key -> key
    | None -> fail "fixture path is outside its workspace" in
  match Backend.Memory.set backend key content with
  | Ok () -> ()
  | Error error -> fail (Backend_types.show_error error)

let read_backlog config =
  match Workspace_backlog.read_backlog_r config with
  | Ok backlog -> backlog
  | Error detail -> fail detail

let create_task config title =
  match Workspace_task_create.add_task_with_result config ~title ~priority:1 ~description:"" with
  | Ok result -> result.task_id
  | Error error -> fail (Workspace_task_create.add_task_error_to_string error)

let has_task (backlog : Masc_domain.backlog) task_id =
  List.exists (fun (task : Masc_domain.task) -> String.equal task.id task_id) backlog.tasks

let has_named_task (backlog : Masc_domain.backlog) task_id title =
  List.exists
    (fun (task : Masc_domain.task) -> String.equal task.id task_id && String.equal task.title title)
    backlog.tasks

let copy_initial_backlog config memory backend =
  let path = Workspace_utils.backlog_path config in
  let content = In_channel.with_open_bin path In_channel.input_all in
  put_memory memory backend path content

let filesystem_cache_does_not_supply_memory () =
  with_workspace (fun _env filesystem ->
    let memory, backend = memory_config filesystem in
    copy_initial_backlog filesystem memory backend;
    let task = create_task filesystem "filesystem only" in
    check bool "filesystem has task" true (has_task (read_backlog filesystem) task);
    check bool "memory reads its own older snapshot" false (has_task (read_backlog memory) task))

let memory_read_does_not_poison_a_filesystem_mutation () =
  with_workspace (fun _env filesystem ->
    let memory, backend = memory_config filesystem in
    copy_initial_backlog filesystem memory backend;
    let first = create_task filesystem "first filesystem task" in
    check bool "memory snapshot is still old" false (has_task (read_backlog memory) first);
    let second = create_task filesystem "second filesystem task" in
    let actual = read_backlog filesystem in
    check bool "task identities remain distinct" true (not (String.equal first second));
    check bool "first task survives the second commit" true
      (has_named_task actual first "first filesystem task");
    check bool "second task was committed" true
      (has_named_task actual second "second filesystem task");
    check int "both tasks survive" 2 (List.length actual.tasks))

let filesystem_cache_cannot_promote_memory_recovery () =
  with_workspace (fun _env filesystem ->
    let memory, backend = memory_config filesystem in
    let primary = Workspace_utils.backlog_path filesystem in
    let initial = In_channel.with_open_bin primary In_channel.input_all in
    put_memory memory backend (Workspace_backlog.backlog_recovery_path memory) initial;
    let state = Workspace_utils.state_path filesystem in
    put_memory memory backend state (In_channel.with_open_bin state In_channel.input_all);
    let task = create_task filesystem "filesystem primary" in
    check bool "filesystem primary is cached" true (has_task (read_backlog filesystem) task);
    let before = In_channel.with_open_bin primary In_channel.input_all in
    (match Workspace_backlog.read_backlog_observation_with_source_r memory with
     | Ok { recovered_from = Some _; _ } -> ()
     | Ok { recovered_from = None; _ } -> fail "memory recovery was reported as a primary"
     | Error detail -> fail detail);
    (match Workspace_backlog.read_backlog_r memory with
     | Error _ -> ()
     | Ok _ -> fail "recovery became authoritative for a mutation");
    (match Workspace_task_create.add_task_with_result memory ~title:"must not commit" ~priority:1 ~description:"" with
     | Error (Workspace_task_create.Backlog_read_failed _) -> ()
     | Error ((Workspace_task_create.Goal_source_unavailable _
              | Workspace_task_create.Goal_lock_failed _
              | Workspace_task_create.Unknown_goal _
              | Workspace_task_create.Ambiguous_goal _
              | Workspace_task_create.Goal_closed _
              | Workspace_task_create.Goal_link_write_failed _
              | Workspace_task_create.Backlog_write_failed _
              | Workspace_task_create.Unexpected_error _
              | Workspace_task_create.Unknown_predecessor _
              | Workspace_task_create.Predecessor_not_terminal _) as error) ->
         fail ("unexpected task refusal: " ^ Workspace_task_create.add_task_error_to_string error)
     | Ok _ -> fail "task committed from a recovery snapshot");
    let primary_key = match Workspace_utils.key_of_path memory primary with
      | Some key -> key
      | None -> fail "primary path is outside its workspace" in
    (match Backend.Memory.get backend primary_key with
     | Error (Backend_types.NotFound _) -> ()
     | Error ((Backend_types.AlreadyExists _ | Backend_types.IOError _ | Backend_types.InvalidKey _) as error) ->
         fail (Backend_types.show_error error)
     | Ok _ -> fail "memory primary was created from recovery");
    check string "filesystem primary remains unchanged" before
      (In_channel.with_open_bin primary In_channel.input_all))

let memory_backlog_reads_with_enabled_guard_and_pool () =
  with_workspace (fun env filesystem ->
    let memory, backend = memory_config filesystem in
    copy_initial_backlog filesystem memory backend;
    Eio.Switch.run (fun sw ->
      let previous = Domain_pool_ref.get () in
      let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
      Domain_pool_ref.set pool;
      Fun.protect
        ~finally:(fun () ->
          match previous with
          | None -> Domain_pool_ref.clear_for_tests ()
          | Some previous -> Domain_pool_ref.set previous)
        (fun () -> check int "memory backlog reads under the pool" 0 (List.length (read_backlog memory).tasks))))

let invalidation_rejects_an_older_inflight_cache_fill () =
  with_workspace (fun _env filesystem ->
    let task = create_task filesystem "race-token-OLD" in
    let path = Workspace_utils.backlog_path filesystem in
    let original = In_channel.with_open_bin path In_channel.input_all in
    let stamp = Float.floor (Unix.gettimeofday ()) -. 1. in
    Unix.utimes path stamp stamp;
    let before = Unix.stat path in
    let old_title = "race-token-OLD" and new_title = "race-token-NEW" in
    let rec find_title index =
      if index + String.length old_title > String.length original then
        fail "task title absent from persisted backlog"
      else if String.sub original index (String.length old_title) = old_title then index
      else find_title (index + 1) in
    let changed = Bytes.of_string original in
    Bytes.blit_string new_title 0 changed (find_title 0) (String.length new_title);
    Workspace_backlog.invalidate_backlog_cache filesystem;
    Eio.Switch.run (fun sw ->
      let entered, signal_entered = Eio.Promise.create () in
      let resume, signal_resume = Eio.Promise.create () in
      let finished, signal_finished = Eio.Promise.create () in
      let claimed = Atomic.make false in
      let previous = Atomic.exchange Workspace_backlog.before_backlog_cache_registration_hook
          (fun () ->
            if Atomic.compare_and_set claimed false true then begin
              Eio.Promise.resolve signal_entered ();
              Eio.Promise.await resume
            end) in
      Fun.protect
        ~finally:(fun () -> Atomic.set Workspace_backlog.before_backlog_cache_registration_hook previous)
        (fun () ->
          Eio.Fiber.fork ~sw (fun () ->
            let older = read_backlog filesystem in
            Eio.Promise.resolve signal_finished older);
          Eio.Promise.await entered;
          Out_channel.with_open_bin path (fun channel -> Out_channel.output_bytes channel changed);
          Unix.utimes path before.Unix.st_atime before.Unix.st_mtime;
          let after = Unix.stat path in
          check int "replacement keeps cache size" before.Unix.st_size after.Unix.st_size;
          check bool "replacement keeps cache mtime" true
            (Float.equal before.Unix.st_mtime after.Unix.st_mtime);
          Workspace_backlog.invalidate_backlog_cache filesystem;
          check bool "new read observes the replacement" true
            (has_named_task (read_backlog filesystem) task new_title);
          Eio.Promise.resolve signal_resume ();
          check bool "in-flight read held the old value" true
            (has_named_task (Eio.Promise.await finished) task old_title);
          check bool "older read cannot overwrite the fresh cache" true
            (has_named_task (read_backlog filesystem) task new_title))))

(* A reader in another process (the TUI) cannot see the writer's clear, so
   the file version decides alone. Writers replace the file with a rename,
   so a replacement that keeps the size and the modification time still has
   a new inode. *)
let a_replacement_keeping_size_and_mtime_is_read_again () =
  with_workspace (fun _env filesystem ->
    let old_title = "stat-token-OLD" and new_title = "stat-token-NEW" in
    let task = create_task filesystem old_title in
    let path = Workspace_utils.backlog_path filesystem in
    let stamp = Float.floor (Unix.gettimeofday ()) -. 1. in
    Unix.utimes path stamp stamp;
    let first = read_backlog filesystem in
    check bool "an unchanged file is not decoded again" true
      (read_backlog filesystem == first);
    let before = Unix.stat path in
    let original = In_channel.with_open_bin path In_channel.input_all in
    let at =
      match Str.search_forward (Str.regexp_string old_title) original 0 with
      | at -> at
      | exception Not_found -> fail "task title absent from persisted backlog" in
    let changed = Bytes.of_string original in
    Bytes.blit_string new_title 0 changed at (String.length new_title);
    let replacement = path ^ ".replacement" in
    Out_channel.with_open_bin replacement (fun channel ->
      Out_channel.output_bytes channel changed);
    Unix.utimes replacement before.Unix.st_atime before.Unix.st_mtime;
    Unix.rename replacement path;
    let after = Unix.stat path in
    check int "the replacement keeps the size" before.Unix.st_size after.Unix.st_size;
    check bool "the replacement keeps the modification time" true
      (Float.equal before.Unix.st_mtime after.Unix.st_mtime);
    check bool "the replacement is another inode" true
      (before.Unix.st_ino <> after.Unix.st_ino);
    check bool "the replacement is read without an invalidation" true
      (has_named_task (read_backlog filesystem) task new_title))

let prepared_reads_follow_the_cached_filesystem_snapshot () =
  with_workspace (fun _env filesystem ->
    let memory, backend = memory_config filesystem in
    copy_initial_backlog filesystem memory backend;
    let first_task = create_task filesystem "first task" in
    let read_prepared config =
      match Workspace_backlog.read_prepared_backlog_r config with
      | Ok prepared -> prepared
      | Error detail -> fail detail
    in
    let first = read_prepared filesystem in
    check bool "raw and prepared reads share the snapshot" true
      (first.backlog == read_backlog filesystem);
    let memory_prepared = read_prepared memory in
    check int "memory projects its own task list" 0 (List.length memory_prepared.backlog.tasks);
    check bool "filesystem keeps its own prepared index" true
      (read_prepared filesystem == first);
    let second_task = create_task filesystem "second task" in
    let second = read_prepared filesystem in
    check bool "the next index contains the committed task" true
      (Workspace_backlog.Task_id_map.mem second_task second.tasks_by_id);
    check bool "the previous observation keeps the first index" true
      (Workspace_backlog.Task_id_map.mem first_task first.tasks_by_id
       && not (Workspace_backlog.Task_id_map.mem second_task first.tasks_by_id)))

let initialization_gate_uses_the_selected_backend () =
  with_workspace (fun _env filesystem ->
    let empty_memory, _ = memory_config filesystem in
    let initialized_memory, backend = memory_config filesystem in
    put_memory initialized_memory backend (Workspace_utils.state_path filesystem) "{}";
    Workspace_utils.invalidate_initialized_cache ();
    check bool "filesystem is initialized" true (Workspace_utils.is_initialized filesystem);
    check bool "empty memory is not initialized after filesystem" false
      (Workspace_utils.is_initialized empty_memory);
    (match Workspace_utils.ensure_initialized empty_memory with
     | () -> fail "empty memory passed the initialization gate"
     | exception Workspace_utils.Not_initialized -> ());
    Workspace_utils.invalidate_initialized_cache ();
    check bool "empty memory remains uninitialized" false (Workspace_utils.is_initialized empty_memory);
    check bool "filesystem is initialized after memory" true (Workspace_utils.is_initialized filesystem);
    check bool "second memory instance is initialized" true (Workspace_utils.is_initialized initialized_memory);
    check bool "memory instances do not share initialization" false (Workspace_utils.is_initialized empty_memory))

let () =
  run "workspace backend cache isolation"
    [ "backlog",
      [ test_case "filesystem cache does not supply memory" `Quick filesystem_cache_does_not_supply_memory
      ; test_case "memory read cannot erase a filesystem task" `Quick memory_read_does_not_poison_a_filesystem_mutation
      ; test_case "recovery is not promoted by a filesystem cache" `Quick filesystem_cache_cannot_promote_memory_recovery
      ; test_case "memory read with Eio guard and domain pool" `Quick memory_backlog_reads_with_enabled_guard_and_pool
      ; test_case "invalidation fences an older cache fill" `Quick invalidation_rejects_an_older_inflight_cache_fill
      ; test_case "a same-size same-mtime replacement is read again" `Quick
          a_replacement_keeping_size_and_mtime_is_read_again
      ; test_case "prepared reads follow the cached filesystem snapshot" `Quick
          prepared_reads_follow_the_cached_filesystem_snapshot
      ]
    ; "initialization",
      [ test_case "gate follows the selected backend" `Quick initialization_gate_uses_the_selected_backend ]
    ]
