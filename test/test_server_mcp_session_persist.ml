(** Round-trip persistence test for MCP HTTP session state.

    Exercises [Server_mcp_transport_http_session.save_sessions_to_file] and
    [load_sessions_from_file] through the fd-safe write path: register session
    state, persist, forget the in-memory entry, reload from disk, and assert it
    was restored.

    The fd-leak fix ([close_out_noerr] in a finally guard) cannot be exercised
    deterministically from a black-box test: the leak only triggers on a
    mid-write/flush I/O error (disk full), which is not reproducible here. This
    test locks the happy-path contract the refactor must preserve — a
    save/forget/load cycle restores state and leaves no [.tmp] residue. *)

open Alcotest
module Session = Server_mcp_transport_http_session

(* Run [f] with the process cwd pointed at a fresh temp directory so the
   base-path resolver (Sys.getcwd-driven) writes the persistence file under it.
   A dedicated test executable keeps the resolver's base-path cache clean, so
   the first resolution (inside [f]) binds to this temp dir. *)
let with_temp_cwd f =
  let unique =
    Printf.sprintf "masc-session-persist-%d-%d" (Unix.getpid ())
      (int_of_float (Unix.gettimeofday () *. 1000.))
  in
  let tmp = Filename.concat (Filename.get_temp_dir_name ()) unique in
  Unix.mkdir tmp 0o755;
  let prev = Sys.getcwd () in
  Sys.chdir tmp;
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir prev;
      let rec rm path =
        if Sys.file_exists path then
          if Sys.is_directory path then begin
            Array.iter (fun e -> rm (Filename.concat path e)) (Sys.readdir path);
            (try Unix.rmdir path with _ -> ())
          end
          else try Sys.remove path with _ -> ()
      in
      rm tmp)
    (fun () -> f tmp)

let test_roundtrip () =
  with_temp_cwd (fun _tmp ->
    let sid = "persist-roundtrip-session" in
    let version = Session.mcp_protocol_version_default in
    Session.remember_protocol_version sid version;
    check bool "session known before save" true (Session.is_known_session sid);
    Session.save_sessions_to_file ();
    let path = Session.sessions_file_path () in
    check bool "persistence file written" true (Sys.file_exists path);
    check bool "no .tmp residue after save" false
      (Sys.file_exists (path ^ ".tmp"));
    (* Drop in-memory state, then restore it from disk. *)
    Session.forget_mcp_session sid;
    check bool "session forgotten" false (Session.is_known_session sid);
    Session.load_sessions_from_file ();
    check bool "session restored from disk" true (Session.is_known_session sid))

let () =
  run "server_mcp_session_persist"
    [ ( "persistence"
      , [ test_case "save/forget/load round-trip" `Quick test_roundtrip ] ) ]
