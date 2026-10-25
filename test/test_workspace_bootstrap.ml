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
  if not (Sys.file_exists path) then ()
  else if Sys.is_directory path then begin
    Array.iter (fun n -> rm_rf (Filename.concat path n)) (Sys.readdir path);
    Unix.rmdir path
  end else
    Unix.unlink path

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
let with_tmp f =
  let dir = make_tmp_dir () in
  Fun.protect
    ~finally:(fun () -> try rm_rf dir with _ -> ())
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      f dir)

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
  print_endline "test_workspace_bootstrap: all assertions passed"
