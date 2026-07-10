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

(* Keep cwd unchanged and pass a fresh workspace base path explicitly. This
   locks the invariant that session persistence follows the server BasePath
   rather than the process launch directory. *)
let with_temp_base_path f =
  let unique =
    Printf.sprintf "masc-session-persist-%d-%d" (Unix.getpid ())
      (int_of_float (Unix.gettimeofday () *. 1000.))
  in
  let tmp = Filename.concat (Filename.get_temp_dir_name ()) unique in
  Unix.mkdir tmp 0o755;
  Fun.protect
    ~finally:(fun () ->
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
  with_temp_base_path (fun base_path ->
    let sid = "persist-roundtrip-session" in
    let version = Session.mcp_protocol_version_default in
    let owner : Server_transport_admission.identity =
      { agent_name = "persist-owner"; role = Masc_domain.Worker }
    in
    let initialize_body =
      Printf.sprintf
        {|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"%s"}}|}
        version
    in
    let initialize_response =
      Mcp_transport_protocol.make_response ~id:(`Int 1) (`Assoc [])
    in
    (match
       Session.bind_mcp_session_owner_if_initialize_succeeded sid
         ~requester:owner ~request_body:initialize_body
         ~response_json:initialize_response
     with
     | Ok () -> ()
     | Error msg -> fail msg);
    Session.remember_protocol_version sid version;
    check bool "session known before save" true (Session.is_known_session sid);
    check (option string) "owner bound before save" (Some owner.agent_name)
      (Session.mcp_session_owner sid
       |> Option.map (fun identity -> identity.agent_name));
    Session.save_sessions_to_file ~base_path ();
    let path = Session.sessions_file_path ~base_path in
    check bool "persistence path is rooted at explicit BasePath" true
      (String.starts_with ~prefix:(Filename.concat base_path ".masc") path);
    check bool "persistence file written" true (Sys.file_exists path);
    check bool "no .tmp residue after save" false
      (Sys.file_exists (path ^ ".tmp"));
    (* Drop in-memory state, then restore it from disk. *)
    Session.forget_mcp_session sid;
    check bool "session forgotten" false (Session.is_known_session sid);
    check bool "owner forgotten" true (Option.is_none (Session.mcp_session_owner sid));
    Session.load_sessions_from_file ~base_path ();
    check bool "session restored from disk" true (Session.is_known_session sid);
    match Session.mcp_session_owner sid with
    | None -> fail "credential owner was not restored"
    | Some restored ->
        check string "owner name restored" owner.agent_name restored.agent_name;
        check bool "owner role restored" true (restored.role = owner.role))

let test_corrupt_state_is_explicit () =
  with_temp_base_path (fun base_path ->
    let path = Session.sessions_file_path ~base_path in
    Unix.mkdir (Filename.dirname path) 0o755;
    let oc = open_out path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc "{not-json");
    match Session.load_sessions_from_file ~base_path () with
    | () -> fail "corrupt persisted session state was silently accepted"
    | exception Yojson.Json_error _ -> ())

let () =
  run "server_mcp_session_persist"
    [ ( "persistence"
      , [ test_case "save/forget/load round-trip" `Quick test_roundtrip
        ; test_case "corrupt state is explicit" `Quick
            test_corrupt_state_is_explicit
        ] ) ]
