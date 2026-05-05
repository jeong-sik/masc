(** Unit tests for [Coord_bootstrap].

    Audit P2 follow-up (2026-04-29 §3.1.2) — closes the
    coord_bootstrap entry of the "테스트 완전 부재 모듈 10건"
    group.

    The module has two exposed functions:

    - [default_room_state config] — pure (modulo [now_iso ()] for
      [started_at]) constructor for [Masc_domain.room_state].
    - [ensure_room_bootstrap config] — idempotent FS bootstrap
      that creates [.masc/<dirs>] and seed [room_state.json] /
      [backlog.json] under both root and scoped layouts.

    Properties pinned:

    1. {b default_room_state constants} — every field except
       [started_at] and [project] is a fixed default; [project]
       derives from [Filename.basename config.base_path].
    2. {b ensure_room_bootstrap idempotency} — running it twice
       on the same tmpdir leaves the seed files unchanged
       (mtime-stable) and produces no extra directories.
    3. {b ensure_room_bootstrap creates expected dirs} — after
       a single call, [.masc/agents/], [.masc/tasks/],
       [.masc/messages/] exist plus the root mirrors. *)

module B = Coord_bootstrap
(* [Coord] is the wrapper module re-exported by [masc_mcp]; it
   contains [default_config].  Other coord internals live as
   top-level modules ([Coord_utils], [Coord_bootstrap]). *)
module Coord = Masc_mcp.Coord

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
    Printf.sprintf "masc_coord_bootstrap_test_%d_%.0f"
      (Unix.getpid ()) (Unix.gettimeofday () *. 1_000_000.)
  in
  let path =
    Filename.concat (Filename.get_temp_dir_name ()) unique
  in
  Unix.mkdir path 0o755;
  path

let with_tmp f =
  let dir = make_tmp_dir () in
  Fun.protect
    ~finally:(fun () -> try rm_rf dir with _ -> ())
    (fun () -> f dir)

(* ── (1) default_room_state ─────────────────────────────── *)

let test_default_room_state_constants () =
  with_tmp (fun dir ->
      let config = Coord.default_config dir in
      let st = B.default_room_state config in
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

let test_default_room_state_project_from_base_path () =
  (* project = Filename.basename config.base_path *)
  with_tmp (fun dir ->
      let config = Coord.default_config dir in
      let st = B.default_room_state config in
      assert (st.project = Filename.basename dir))

let test_default_room_state_started_at_iso_format () =
  with_tmp (fun dir ->
      let config = Coord.default_config dir in
      let st = B.default_room_state config in
      (* ISO 8601: starts with 4-digit year + "-". *)
      let s = st.started_at in
      assert (String.length s >= 19);
      assert (Char.code s.[0] >= Char.code '0');
      assert (Char.code s.[0] <= Char.code '9');
      assert (s.[4] = '-');
      assert (s.[7] = '-');
      assert (s.[10] = 'T'))

(* ── (2) ensure_room_bootstrap creates dirs ──────────────── *)

let test_ensure_room_bootstrap_creates_scoped_dirs () =
  with_tmp (fun dir ->
      let config = Coord.default_config dir in
      B.ensure_room_bootstrap config;
      let masc = Filename.concat dir ".masc" in
      assert (Sys.file_exists masc);
      assert (Sys.is_directory masc);
      List.iter
        (fun sub ->
          let p = Filename.concat masc sub in
          assert (Sys.file_exists p);
          assert (Sys.is_directory p))
        [ "agents"; "tasks"; "messages" ])

let test_ensure_room_bootstrap_creates_root_dirs () =
  (* The root layout (under [.masc/] sibling) — agents / keepers /
     traces / tasks / messages — should also exist after bootstrap. *)
  with_tmp (fun dir ->
      let config = Coord.default_config dir in
      B.ensure_room_bootstrap config;
      let root_dir =
        Coord_utils.masc_root_dir config
      in
      List.iter
        (fun sub ->
          let p = Filename.concat root_dir sub in
          assert (Sys.file_exists p);
          assert (Sys.is_directory p))
        [ "agents"; "keepers"; "traces"; "tasks"; "messages" ])

let test_ensure_room_bootstrap_seeds_state_json () =
  (* The scoped state JSON file should be created. *)
  with_tmp (fun dir ->
      let config = Coord.default_config dir in
      B.ensure_room_bootstrap config;
      let state_path = Coord_utils.state_path config in
      assert (Sys.file_exists state_path);
      let backlog_path =
        Coord_utils.backlog_path config
      in
      assert (Sys.file_exists backlog_path))

(* ── (3) idempotency ──────────────────────────────────────── *)

let test_ensure_room_bootstrap_idempotent () =
  (* Running twice must not corrupt or duplicate — file presence
     after the second call equals after the first. *)
  with_tmp (fun dir ->
      let config = Coord.default_config dir in
      B.ensure_room_bootstrap config;
      let state_path = Coord_utils.state_path config in
      let mtime1 = (Unix.stat state_path).st_mtime in
      (* Second invocation must NOT rewrite the seed file (the
         impl skips when path_exists). *)
      B.ensure_room_bootstrap config;
      let mtime2 = (Unix.stat state_path).st_mtime in
      assert (mtime1 = mtime2);
      (* Seeded files still exist. *)
      assert (Sys.file_exists state_path))

let test_ensure_room_bootstrap_does_not_clobber_existing_state () =
  (* If a state file already exists with custom content, bootstrap
     must NOT overwrite it. *)
  with_tmp (fun dir ->
      let config = Coord.default_config dir in
      B.ensure_room_bootstrap config;
      let state_path = Coord_utils.state_path config in
      (* Replace the seeded state with a sentinel JSON. *)
      let oc = open_out state_path in
      output_string oc "{\"sentinel\":\"do not clobber\"}";
      close_out oc;
      (* Re-bootstrap. *)
      B.ensure_room_bootstrap config;
      let ic = open_in state_path in
      let body = input_line ic in
      close_in ic;
      assert (
        String.length body > 0
        && (try
              let _ = Str.search_forward
                       (Str.regexp_string "sentinel") body 0
              in true
            with Not_found -> false)))

(* ── runner ───────────────────────────────────────────────── *)

let () =
  test_default_room_state_constants ();
  test_default_room_state_project_from_base_path ();
  test_default_room_state_started_at_iso_format ();
  test_ensure_room_bootstrap_creates_scoped_dirs ();
  test_ensure_room_bootstrap_creates_root_dirs ();
  test_ensure_room_bootstrap_seeds_state_json ();
  test_ensure_room_bootstrap_idempotent ();
  test_ensure_room_bootstrap_does_not_clobber_existing_state ();
  print_endline "test_coord_bootstrap: all assertions passed"
