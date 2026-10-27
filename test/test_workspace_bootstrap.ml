module Types = Masc_domain

(** Unit tests for [Workspace_bootstrap] and the layout [Workspace.init]
    creates.

    Audit P2 follow-up (2026-04-29 §3.1.2) — closes the
    workspace_bootstrap entry of the "테스트 완전 부재 모듈 10건"
    group.

    - [default_workspace_state config] — pure (modulo [now_iso ()] for
      [started_at]) constructor for [Masc_domain.workspace_state].
    - [Workspace.init config] — idempotent FS init that creates
      [.masc/<dirs>] and seeds [state.json] and [backlog.json].

    Properties pinned:

    1. {b default_workspace_state constants} — every field except
       [started_at] and [project] is a fixed default; [project]
       derives from [Filename.basename config.base_path].
    2. {b init idempotency} — running it twice
       on the same tmpdir leaves the seed files unchanged
       (mtime-stable) and produces no extra directories.
    3. {b init creates expected dirs} — after
       a single call, [.masc/agents/], [.masc/keepers/],
       [.masc/traces/], [.masc/tasks/], [.masc/messages/] and the shared
       playground exist. *)

module B = Workspace_bootstrap
(* [Workspace] is the wrapper module re-exported by [masc]; it
   contains [default_config].  Other workspace internals live as
   top-level modules ([Workspace_utils], [Workspace_bootstrap]). *)
module Workspace = Masc.Workspace

(* ── Fixture helpers ───────────────────────────────────────── *)

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | stat ->
      (match stat.Unix.st_kind with
       | Unix.S_DIR ->
           Array.iter (fun n -> rm_rf (Filename.concat path n)) (Sys.readdir path);
           Unix.rmdir path
       | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
           Unix.unlink path)

let make_tmp_dir () =
  let unique =
    Printf.sprintf "masc_workspace_bootstrap_test_%d_%.0f"
      (Unix.getpid ()) (Unix.gettimeofday () *. 1_000_000.)
  in
  let path =
    Filename.concat (Filename.get_temp_dir_name ()) unique
  in
  Unix.mkdir path 0o755;
  path

(* Inside Eio with the filesystem set, so [Workspace.default_config] picks
   the filesystem backend the server runs on rather than falling back to the
   Memory backend. *)
let with_tmp_env f =
  let dir = make_tmp_dir () in
  Fun.protect
    ~finally:(fun () -> try rm_rf dir with _ -> ())
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      f env dir)

let with_tmp f = with_tmp_env (fun _env dir -> f dir)

(* ── (1) default_workspace_state ─────────────────────────────── *)

let test_default_workspace_state_constants () =
  with_tmp (fun dir ->
      let config = Workspace.default_config dir in
      let st = B.default_workspace_state config in
      assert (st.protocol_version = "0.1.0");
      assert (st.message_seq = 0);
      assert (st.active_agents = []);
      assert (st.paused = false);
      assert (st.pause_reason = None);
      assert (st.paused_by = None);
      assert (st.paused_at = None);
      assert (st.search_strategy_default = Some "best_first_v1");
      assert (st.speculation_enabled = false);
      assert (st.speculation_budget = None);
      (* started_at is non-empty (now_iso ()). *)
      assert (st.started_at <> ""))

let test_default_workspace_state_project_from_base_path () =
  (* project = Filename.basename config.base_path *)
  with_tmp (fun dir ->
      let config = Workspace.default_config dir in
      let st = B.default_workspace_state config in
      assert (st.project = Filename.basename dir))

let test_default_workspace_state_started_at_iso_format () =
  with_tmp (fun dir ->
      let config = Workspace.default_config dir in
      let st = B.default_workspace_state config in
      (* ISO 8601: starts with 4-digit year + "-". *)
      let s = st.started_at in
      assert (String.length s >= 19);
      assert (Char.code s.[0] >= Char.code '0');
      assert (Char.code s.[0] <= Char.code '9');
      assert (s.[4] = '-');
      assert (s.[7] = '-');
      assert (s.[10] = 'T'))

(* ── (2) init creates dirs ─────────────────────────────────── *)

let test_init_creates_dirs () =
  with_tmp (fun dir ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:None);
      let masc = Filename.concat dir ".masc" in
      assert (Sys.file_exists masc);
      assert (Sys.is_directory masc);
      List.iter
        (fun sub ->
          let p = Filename.concat masc sub in
          assert (Sys.file_exists p);
          assert (Sys.is_directory p))
        [ "agents"; "keepers"; "traces"; "tasks"; "messages" ];
      let playground = Filename.concat dir Playground_paths.all_playgrounds_prefix in
      assert (Sys.is_directory playground);
      assert (Array.length (Sys.readdir playground) = 0))

let test_init_seeds_state_json () =
  (* The state JSON file should be created. *)
  with_tmp (fun dir ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:None);
      let state_path = Workspace_utils.state_path config in
      assert (Sys.file_exists state_path);
      let backlog_path =
        Workspace_utils.backlog_path config
      in
      assert (Sys.file_exists backlog_path))

(* ── (3) idempotency ──────────────────────────────────────── *)

let test_init_idempotent () =
  (* Running twice must not corrupt or duplicate — file presence
     after the second call equals after the first. *)
  with_tmp (fun dir ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:None);
      let state_path = Workspace_utils.state_path config in
      let mtime1 = (Unix.stat state_path).st_mtime in
      (* Second invocation must NOT rewrite the seed file (the
         impl skips when path_exists). *)
      ignore (Workspace.init config ~agent_name:None);
      let mtime2 = (Unix.stat state_path).st_mtime in
      assert (mtime1 = mtime2);
      (* Seeded files still exist. *)
      assert (Sys.file_exists state_path))

let test_init_does_not_clobber_existing_state () =
  (* If a state file already exists with custom content, init
     must NOT overwrite it. *)
  with_tmp (fun dir ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:None);
      let state_path = Workspace_utils.state_path config in
      (* Replace the seeded state with a marker JSON. *)
      let oc = open_out state_path in
      output_string oc "{\"marker\":\"do not clobber\"}";
      close_out oc;
      (* Init again. *)
      ignore (Workspace.init config ~agent_name:None);
      let ic = open_in state_path in
      let body = input_line ic in
      close_in ic;
      assert (
        String.length body > 0
        && (try
              let _ = Str.search_forward
                       (Str.regexp_string "marker") body 0
              in true
            with Not_found -> false)))

let test_reinit_restores_shared_playground_without_clobber () =
  with_tmp (fun dir ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:None);
      let state_path = Workspace_utils.state_path config in
      let state_before = In_channel.with_open_bin state_path In_channel.input_all in
      let playground = Filename.concat dir Playground_paths.all_playgrounds_prefix in
      Unix.rmdir playground;
      ignore (Workspace.init config ~agent_name:None);
      assert (Sys.is_directory playground);
      assert (Array.length (Sys.readdir playground) = 0);
      let producer = Filename.concat playground "existing-producer" in
      Unix.mkdir producer 0o755;
      let evidence_path = Filename.concat producer "evidence.json" in
      let evidence = "{\"value\":3}" in
      Out_channel.with_open_bin evidence_path (fun out -> output_string out evidence);
      ignore (Workspace.init config ~agent_name:None);
      assert (In_channel.with_open_bin evidence_path In_channel.input_all = evidence);
      assert (In_channel.with_open_bin state_path In_channel.input_all = state_before))

let create_recoverable_task config =
  match
    Workspace.add_task_with_result config ~title:"recoverable task" ~priority:1
      ~description:"must remain observable"
  with
  | Ok created -> created.task_id
  | Error error -> failwith (Workspace.add_task_error_to_string error)

let assert_recovery_remains_observable config ~task_id ~recovery_before =
  let primary = Workspace_utils.backlog_path config in
  let recovery = Workspace_backlog.backlog_recovery_path config in
  assert (not (Sys.file_exists primary));
  assert (In_channel.with_open_bin recovery In_channel.input_all = recovery_before);
  (match Workspace.read_backlog_observation_with_source_r config with
   | Error error -> failwith error
   | Ok observed ->
       assert (Option.is_some observed.recovered_from);
       assert
         (List.exists
            (fun (task : Types.task) -> String.equal task.id task_id)
            observed.observed_backlog.tasks));
  (match Workspace.read_backlog_r config with
   | Error _ -> ()
   | Ok _ -> failwith "recovery became authoritative after init");
  (match
     Workspace.add_task_with_result config ~title:"must not commit" ~priority:1
       ~description:""
   with
   | Error _ -> ()
   | Ok _ -> failwith "task mutation succeeded without an authoritative backlog");
  assert (not (Sys.file_exists primary));
  assert (In_channel.with_open_bin recovery In_channel.input_all = recovery_before)

let test_reinit_keeps_missing_primary_recovery_observable () =
  with_tmp (fun dir ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:None);
      let task_id = create_recoverable_task config in
      let primary = Workspace_utils.backlog_path config in
      let recovery = Workspace_backlog.backlog_recovery_path config in
      let recovery_before = In_channel.with_open_bin recovery In_channel.input_all in
      Unix.unlink primary;
      ignore (Workspace.init config ~agent_name:None);
      assert_recovery_remains_observable config ~task_id ~recovery_before)

let test_reinit_does_not_seed_an_initialized_workspace_with_no_backlog () =
  with_tmp (fun dir ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:None);
      let primary = Workspace_utils.backlog_path config in
      let recovery = Workspace_backlog.backlog_recovery_path config in
      assert (not (Sys.file_exists recovery));
      Unix.unlink primary;
      ignore (Workspace.init config ~agent_name:None);
      assert (not (Sys.file_exists primary));
      match Workspace.read_backlog_r config with
      | Error _ -> ()
      | Ok _ -> failwith "missing backlog was silently initialized")

let test_reinit_preserves_dangling_backlog_link () =
  with_tmp (fun dir ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:None);
      let primary = Workspace_utils.backlog_path config in
      Unix.unlink primary;
      Unix.symlink "missing-target" primary;
      ignore (Workspace.init config ~agent_name:None);
      assert (String.equal (Unix.readlink primary) "missing-target"))

let test_cold_memory_refuses_existing_local_workspace () =
  with_tmp (fun dir ->
      let fs_config = Workspace.default_config dir in
      ignore (Workspace.init fs_config ~agent_name:None);
      ignore (create_recoverable_task fs_config);
      let state = Workspace_utils.state_path fs_config in
      let primary = Workspace_utils.backlog_path fs_config in
      let recovery = Workspace_backlog.backlog_recovery_path fs_config in
      let read path = In_channel.with_open_bin path In_channel.input_all in
      let before = List.map read [ state; primary; recovery ] in
      let memory_config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      (match Workspace.init memory_config ~agent_name:None with
       | _ -> failwith "cold Memory adopted an existing local workspace"
       | exception Workspace_init.Initialization_failed
           (Workspace_init.Cold_memory_has_local_document _) -> ());
      assert (before = List.map read [ state; primary; recovery ]))

let test_memory_reinit_keeps_missing_primary_recovery_observable () =
  with_tmp (fun dir ->
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      ignore (Workspace.init config ~agent_name:None);
      let task_id = create_recoverable_task config in
      let primary = Workspace_utils.backlog_path config in
      let recovery = Workspace_backlog.backlog_recovery_path config in
      let before = In_channel.with_open_bin recovery In_channel.input_all in
      Workspace_utils.delete_path config primary;
      ignore (Workspace.init config ~agent_name:None);
      assert_recovery_remains_observable config ~task_id ~recovery_before:before)

let test_fresh_memory_workspace_still_initializes () =
  with_tmp (fun dir ->
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      ignore (Workspace.init config ~agent_name:None);
      assert (Workspace.is_initialized config);
      match Workspace.read_backlog_r config with
      | Ok backlog -> assert (backlog.tasks = [])
      | Error error -> failwith error)

let test_memory_init_can_resume_its_partial_backlog_seed () =
  with_tmp (fun dir ->
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      let path = Workspace_utils.backlog_path config in
      (match
         Workspace_utils.write_json_result config path
           (Types.backlog_to_yojson (B.empty_backlog ()))
       with
       | Ok () -> ()
       | Error error -> failwith error);
      let before = In_channel.with_open_bin path In_channel.input_all in
      ignore (Workspace.init config ~agent_name:None);
      assert (Workspace.is_initialized config);
      assert (In_channel.with_open_bin path In_channel.input_all = before))

let test_memory_init_preserves_partial_mirror_bytes () =
  with_tmp (fun dir ->
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      let path = Workspace_utils.backlog_path config in
      let key = Option.get (Workspace_utils.key_of_path config path) in
      let contents =
        " \n" ^ Yojson.Safe.to_string (Types.backlog_to_yojson (B.empty_backlog ())) ^ "\n"
      in
      (match Workspace_utils.backend_set config ~key ~value:contents with
       | Ok () -> ()
       | Error error -> failwith (Backend_types.show_error error));
      Workspace_utils.mkdir_p (Filename.dirname path);
      Out_channel.with_open_bin path (fun out -> output_string out contents);
      ignore (Workspace.init config ~agent_name:None);
      assert (In_channel.with_open_bin path In_channel.input_all = contents))

let test_memory_state_mirror_failure_still_binds_requested_agent () =
  with_tmp (fun dir ->
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      let root = Workspace_utils.masc_dir config in
      List.iter Workspace_utils.mkdir_p
        [ Workspace_utils.agents_dir config
        ; Workspace_utils.keepers_runtime_dir config
        ; Workspace_utils.tasks_dir config
        ; Workspace_utils.messages_dir config
        ; Filename.concat root "traces"
        ; Filename.concat root "events"
        ; Filename.concat dir Playground_paths.all_playgrounds_prefix
        ];
      Unix.chmod root 0o555;
      Fun.protect ~finally:(fun () -> Unix.chmod root 0o755) (fun () ->
        let probe = Filename.concat root ".write-probe" in
        let can_write =
          try
            let channel = open_out_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 probe in
            close_out channel;
            Unix.unlink probe;
            true
          with Sys_error _ -> false
        in
        if can_write then
          print_endline "state mirror failure fixture skipped: permissions are bypassed"
        else (
          let agent_name = "mirror-fixture-agent" in
          let result = Workspace.init config ~agent_name:(Some agent_name) in
          assert (String.starts_with ~prefix:"MASC workspace created; local state mirror failed:" result);
          assert (not (Sys.file_exists (Workspace_utils.state_path config)));
          assert (List.mem agent_name (Workspace.read_state config).active_agents);
          let agent_path =
            Filename.concat (Workspace_utils.agents_dir config)
              (Workspace_utils.safe_filename agent_name ^ ".json")
          in
          (match Workspace_utils.read_agent config agent_path with
           | Ok agent -> assert (String.equal agent.name agent_name)
           | Error error -> failwith error);
          match Workspace.init config ~agent_name:None with
          | _ -> failwith "missing local state mirror was silently accepted"
          | exception Workspace_init.Initialization_failed
              (Workspace_init.Mirror_unverified { path; _ }) ->
              assert (String.equal path (Workspace_utils.state_path config)))))

let test_memory_init_refuses_a_changed_partial_mirror () =
  with_tmp (fun dir ->
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      let path = Workspace_utils.backlog_path config in
      (match
         Workspace_utils.write_json_result config path
           (Types.backlog_to_yojson (B.empty_backlog ()))
       with
       | Ok () -> ()
       | Error error -> failwith error);
      Out_channel.with_open_bin path (fun out -> output_string out "other local data");
      (match Workspace.init config ~agent_name:None with
       | _ -> failwith "cold Memory replaced a changed local document"
       | exception Workspace_init.Initialization_failed
           (Workspace_init.Cold_memory_has_local_document _) -> ());
      assert (In_channel.with_open_bin path In_channel.input_all = "other local data"))

let test_memory_reinit_reports_mirror_failure () =
  with_tmp (fun dir ->
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      ignore (Workspace.init config ~agent_name:None);
      let primary = Workspace_utils.backlog_path config in
      Unix.unlink primary;
      Unix.mkdir primary 0o700;
      (match Workspace.init config ~agent_name:None with
       | _ -> failwith "reinit concealed the failed local mirror"
       | exception Workspace_init.Initialization_failed
           (Workspace_init.Mirror_unverified { path; _ }) -> assert (String.equal path primary));
      assert (Sys.is_directory primary))

let test_memory_reinit_refuses_changed_local_backlog () =
  with_tmp (fun dir ->
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      ignore (Workspace.init config ~agent_name:None);
      let primary = Workspace_utils.backlog_path config in
      let backlog = Workspace.read_backlog config in
      let changed = { backlog with version = backlog.version + 1 } in
      (match Workspace_utils.write_json_local primary (Types.backlog_to_yojson changed) with
       | Ok () -> ()
       | Error error -> failwith error);
      let local_before = In_channel.with_open_bin primary In_channel.input_all in
      (match Workspace.init config ~agent_name:None with
       | _ -> failwith "reinit accepted a divergent local backlog"
       | exception Workspace_init.Initialization_failed
           (Workspace_init.Mirror_unverified { path; _ }) -> assert (String.equal path primary));
      assert (In_channel.with_open_bin primary In_channel.input_all = local_before))

let test_memory_reinit_refuses_nonregular_local_backlog () =
  with_tmp (fun dir ->
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      ignore (Workspace.init config ~agent_name:None);
      let primary = Workspace_utils.backlog_path config in
      let saved = primary ^ ".saved" in
      Unix.rename primary saved;
      let check_rejected () =
        match Workspace.init config ~agent_name:None with
        | _ -> failwith "a non-regular mirror was accepted"
        | exception Workspace_init.Initialization_failed
            (Workspace_init.Mirror_unverified { path; _ }) -> assert (String.equal path primary)
        | exception Workspace_init.Initialization_failed
            (Workspace_init.Document_presence_unavailable { path; _ }) -> assert (String.equal path primary)
      in
      Unix.symlink saved primary;
      check_rejected ();
      assert (String.equal (Unix.readlink primary) saved);
      Unix.unlink primary;
      Unix.mkfifo primary 0o600;
      check_rejected ();
      assert ((Unix.lstat primary).Unix.st_kind = Unix.S_FIFO))

let test_memory_reinit_accepts_a_linked_workspace_root () =
  with_tmp (fun dir ->
      let runtime = Filename.concat dir "runtime" in
      let root = Filename.concat dir ".masc" in
      Unix.mkdir runtime 0o755;
      Unix.symlink runtime root;
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      ignore (Workspace.init config ~agent_name:None);
      ignore (Workspace.init config ~agent_name:None);
      assert (String.equal (Unix.readlink root) runtime))

let test_memory_reinit_preserves_local_document_if_backend_is_invalid () =
  with_tmp (fun dir ->
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      ignore (Workspace.init config ~agent_name:None);
      let primary = Workspace_utils.backlog_path config in
      let before = In_channel.with_open_bin primary In_channel.input_all in
      let key = Option.get (Workspace_utils.key_of_path config primary) in
      List.iter
        (fun contents ->
          (match Workspace_utils.backend_set config ~key ~value:contents with
           | Ok () -> ()
           | Error error -> failwith (Backend_types.show_error error));
          (match Workspace.init config ~agent_name:None with
           | _ -> failwith "invalid backend document replaced its local mirror"
           | exception Workspace_init.Initialization_failed
               (Workspace_init.Mirror_unverified { path; _ }) ->
               assert (String.equal path primary));
          assert (In_channel.with_open_bin primary In_channel.input_all = before))
        [ ""; "  \n"; "{not-json"; "{}"; "[]" ])

let test_memory_reinit_preserves_local_state_if_backend_is_invalid () =
  with_tmp (fun dir ->
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      ignore (Workspace.init config ~agent_name:None);
      let state = Workspace_utils.state_path config in
      let before = In_channel.with_open_bin state In_channel.input_all in
      let key = Option.get (Workspace_utils.key_of_path config state) in
      (match Workspace_utils.backend_set config ~key ~value:"{}" with
       | Ok () -> ()
       | Error error -> failwith (Backend_types.show_error error));
      (match Workspace.init config ~agent_name:None with
       | _ -> failwith "invalid backend state replaced its local mirror"
       | exception Workspace_init.Initialization_failed
           (Workspace_init.Mirror_unverified { path; _ }) ->
           assert (String.equal path state));
      assert (In_channel.with_open_bin state In_channel.input_all = before))

let test_memory_reinit_preserves_local_backlog_with_dropped_task_fields () =
  with_tmp (fun dir ->
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      ignore (Workspace.init config ~agent_name:None);
      ignore (create_recoverable_task config);
      let primary = Workspace_utils.backlog_path config in
      let before = In_channel.with_open_bin primary In_channel.input_all in
      let key = Option.get (Workspace_utils.key_of_path config primary) in
      let original = Workspace.read_json config primary in
      List.iter
        (fun field ->
          let damaged =
            match original with
            | `Assoc fields ->
                let tasks =
                  match List.assoc_opt "tasks" fields with
                  | Some (`List (`Assoc task :: rest)) ->
                      `List (`Assoc ((field, `String "corrupt") :: List.remove_assoc field task) :: rest)
                  | _ -> failwith "fixture task is missing"
                in
                `Assoc (("tasks", tasks) :: List.remove_assoc "tasks" fields)
            | _ -> failwith "fixture backlog is not an object"
          in
          (match Workspace_utils.backend_set config ~key ~value:(Yojson.Safe.to_string damaged) with
           | Ok () -> ()
           | Error error -> failwith (Backend_types.show_error error));
          (match Workspace.init config ~agent_name:None with
           | _ -> failwith "dropped task fields replaced the local backlog"
           | exception Workspace_init.Initialization_failed
               (Workspace_init.Mirror_unverified { path; _ }) ->
               assert (String.equal path primary));
          assert (In_channel.with_open_bin primary In_channel.input_all = before))
        [ "handoff_context"; "reclaim_policy" ])

let test_memory_reinit_allows_identical_backlog_with_dropped_task_fields () =
  with_tmp (fun dir ->
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      ignore (Workspace.init config ~agent_name:None);
      let task_id = create_recoverable_task config in
      let primary = Workspace_utils.backlog_path config in
      let damaged =
        match Workspace.read_json config primary with
        | `Assoc fields ->
            let tasks =
              match List.assoc_opt "tasks" fields with
              | Some (`List (`Assoc task :: rest)) ->
                  `List (`Assoc (("handoff_context", `String "corrupt") :: task) :: rest)
              | _ -> failwith "fixture task is missing"
            in
            `Assoc (("tasks", tasks) :: List.remove_assoc "tasks" fields)
        | _ -> failwith "fixture backlog is not an object"
      in
      (match Workspace_utils.write_json_result config primary damaged with
       | Ok () -> ()
       | Error error -> failwith error);
      let before = In_channel.with_open_bin primary In_channel.input_all in
      ignore (Workspace.init config ~agent_name:None);
      assert (In_channel.with_open_bin primary In_channel.input_all = before);
      match Workspace.read_backlog_r config with
      | Ok backlog ->
          assert (List.exists (fun (task : Types.task) -> String.equal task.id task_id) backlog.tasks)
      | Error error -> failwith error)

let test_memory_reinit_waits_for_backlog_mutation () =
  with_tmp_env (fun env dir ->
      let fs_config = Workspace.default_config dir in
      let config =
        { fs_config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      in
      ignore (Workspace.init config ~agent_name:None);
      let task_id = create_recoverable_task config in
      let lock_path = Workspace_backlog.backlog_lock_path config in
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () ->
        Eio.Switch.run (fun sw ->
          Workspace_utils.with_file_lock config lock_path (fun () ->
            Eio.Fiber.fork ~sw (fun () -> ignore (Workspace.init config ~agent_name:None));
            while File_lock_eio.For_testing.holders_and_waiters ~lock_path < 2 do
              Eio.Fiber.yield ()
            done;
            let backlog = Workspace.read_backlog config in
            let tasks =
              List.map
                (fun (task : Types.task) ->
                  if String.equal task.id task_id then { task with title = "newer" } else task)
                backlog.tasks
            in
            Workspace.write_backlog config { backlog with tasks })));
      let primary = Workspace_utils.backlog_path config in
      let local =
        match Workspace_utils.read_json_local_result primary with
        | Ok json -> json
        | Error error -> failwith error
      in
      assert (local = Workspace.read_json config primary);
      assert
        (List.exists
           (fun (task : Types.task) ->
             String.equal task.id task_id && String.equal task.title "newer")
           (Workspace.read_backlog config).tasks))

let test_seed_checks_recovery_inside_lease_fence () =
  with_tmp (fun dir ->
      let config = Workspace.default_config dir in
      let primary = Workspace_utils.backlog_path config in
      let recovery = Workspace_backlog.backlog_recovery_path config in
      let lock_path = Workspace_backlog.backlog_lock_path config in
      let key = Option.get (Workspace_utils.key_of_path config lock_path) in
      let seam = Backend.FileSystem.after_lease_owner_read_hook in
      let previous = Atomic.get seam in
      let inserted = ref false in
      Fun.protect
        ~finally:(fun () -> Atomic.set seam previous)
        (fun () ->
          Atomic.set seam (fun ~key:seen ->
              if String.equal seen key && not !inserted then (
                inserted := true;
                Out_channel.with_open_bin recovery (fun out -> output_string out "preserve")));
          ignore (Workspace.init config ~agent_name:None));
      assert !inserted;
      assert (not (Sys.file_exists primary));
      assert (In_channel.with_open_bin recovery In_channel.input_all = "preserve"))

let test_state_seed_rechecks_inside_lease_fence () =
  with_tmp (fun dir ->
      let config = Workspace.default_config dir in
      let path = Workspace_utils.state_path config in
      let key = Option.get (Workspace_utils.key_of_path config path) in
      let prior = { (B.default_workspace_state config) with paused = true } in
      let seam = Backend.FileSystem.after_lease_owner_read_hook in
      let previous = Atomic.get seam in
      let inserted = ref false in
      let result =
        Fun.protect
          ~finally:(fun () -> Atomic.set seam previous)
          (fun () ->
            Atomic.set seam (fun ~key:seen ->
                if String.equal seen key && not !inserted then (
                  inserted := true;
                  match Workspace_utils.write_json_local path (Types.workspace_state_to_yojson prior) with
                  | Ok () -> ()
                  | Error error -> failwith error));
            Workspace.init config ~agent_name:None)
      in
      assert !inserted;
      assert (String.equal result "MASC already initialized.");
      assert ((Workspace.read_state config).paused))

(* ── runner ───────────────────────────────────────────────── *)

let () =
  test_default_workspace_state_constants ();
  test_default_workspace_state_project_from_base_path ();
  test_default_workspace_state_started_at_iso_format ();
  test_init_creates_dirs ();
  test_init_seeds_state_json ();
  test_init_idempotent ();
  test_init_does_not_clobber_existing_state ();
  test_reinit_restores_shared_playground_without_clobber ();
  test_reinit_keeps_missing_primary_recovery_observable ();
  test_reinit_does_not_seed_an_initialized_workspace_with_no_backlog ();
  test_reinit_preserves_dangling_backlog_link ();
  test_cold_memory_refuses_existing_local_workspace ();
  test_memory_reinit_keeps_missing_primary_recovery_observable ();
  test_fresh_memory_workspace_still_initializes ();
  test_memory_init_can_resume_its_partial_backlog_seed ();
  test_memory_init_preserves_partial_mirror_bytes ();
  test_memory_state_mirror_failure_still_binds_requested_agent ();
  test_memory_init_refuses_a_changed_partial_mirror ();
  test_memory_reinit_reports_mirror_failure ();
  test_memory_reinit_refuses_changed_local_backlog ();
  test_memory_reinit_refuses_nonregular_local_backlog ();
  test_memory_reinit_accepts_a_linked_workspace_root ();
  test_memory_reinit_preserves_local_document_if_backend_is_invalid ();
  test_memory_reinit_preserves_local_state_if_backend_is_invalid ();
  test_memory_reinit_preserves_local_backlog_with_dropped_task_fields ();
  test_memory_reinit_allows_identical_backlog_with_dropped_task_fields ();
  test_memory_reinit_waits_for_backlog_mutation ();
  test_seed_checks_recovery_inside_lease_fence ();
  test_state_seed_rechecks_inside_lease_fence ();
  print_endline "test_workspace_bootstrap: all assertions passed"
