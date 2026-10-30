(** Persistence for tool-approval-mode overrides.

    The stance used to be deliberately in-memory; that reversal is the point
    of this test file. A yolo override must survive a restart (an operator's
    other authorization choices already do), setting [Auto] must remove the
    row rather than store a synonym for the default, and a store that cannot
    be read must surface an error via [last_restore_error] (including the
    store path) rather than silently appearing as an empty store. Revoking to
    the stricter [Auto] default must remove the in-memory override immediately
    even if the disk store cannot be read.
*)

open Alcotest
open Masc

module Mode = Keeper_tool_approval_mode

let temp_dir_counter = ref 0

let with_temp_dir f =
  incr temp_dir_counter;
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "tool-approval-persist-%d-%06d"
         (Unix.getpid ())
         !temp_dir_counter)
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm_rf path =
        if Sys.file_exists path
        then
          if Sys.is_directory path
          then (
            Sys.readdir path
            |> Array.iter (fun name -> rm_rf (Filename.concat path name));
            Unix.rmdir path)
          else Sys.remove path
      in
      rm_rf base)
    (fun () -> f base)
;;

let set_exn store ~base_path ~keeper_name mode =
  match Mode.set store ~base_path ~actor:"test-operator" ~keeper_name mode with
  | Ok Mode.Applied -> ()
  | Ok (Mode.Applied_audit_failed detail) ->
    fail ("set applied with unexpected audit failure: " ^ detail)
  | Error detail -> fail ("set failed: " ^ detail)
;;

let write_corrupt_store ~base_path =
  let file = Keeper_gate_path.tool_approval_modes ~base_path in
  Fs_compat.mkdir_p (Keeper_gate_path.dir ~base_path);
  match Fs_compat.save_file_atomic file "{ not a store" with
  | Ok () -> file
  | Error detail -> fail ("could not write the corrupt fixture: " ^ detail)
;;

let test_yolo_survives_a_restart () =
  with_temp_dir @@ fun base_path ->
  let keeper_name = "persist-yolo" in
  let before = Mode.create () in
  set_exn before ~base_path ~keeper_name Mode.Yolo;
  (* Simulate the restart: a fresh registry, replayed from disk. *)
  let after = Mode.create () in
  (match Mode.bind ~base_path after with
   | Ok () -> ()
   | Error detail -> fail ("bind failed: " ^ detail));
  check bool "the override survived the restart" true
    (Mode.resolve after ~keeper_name = Mode.Yolo);
  check (list (pair string string)) "overrides list the keeper" [ keeper_name, "yolo" ]
    (List.map
       (fun (name, mode) -> name, Mode.mode_to_string mode)
       (Mode.overrides after));
  (match Mode.keeper_overrides ~base_path with
   | Ok [ row ] ->
     check string "the row names the keeper" keeper_name row.keeper_name;
     check string "the row records the actor" "test-operator" row.actor
   | Ok rows -> failf "expected one persisted row, got %d" (List.length rows)
   | Error detail -> fail ("could not read the persisted rows: " ^ detail))
;;

let test_auto_removes_the_row () =
  with_temp_dir @@ fun base_path ->
  let keeper_name = "persist-auto" in
  let store = Mode.create () in
  set_exn store ~base_path ~keeper_name Mode.Yolo;
  set_exn store ~base_path ~keeper_name Mode.Auto;
  check (list string) "memory holds no override" []
    (List.map fst (Mode.overrides store));
  (match Mode.keeper_overrides ~base_path with
   | Ok [] -> ()
   | Ok rows ->
     failf "clearing left %d persisted row(s) behind" (List.length rows)
   | Error detail -> fail ("could not read the persisted rows: " ^ detail))
;;

let test_a_corrupt_store_is_an_error_not_a_quiet_auto () =
  with_temp_dir @@ fun base_path ->
  let keeper_name = "persist-corrupt" in
  let file = write_corrupt_store ~base_path in
  let store = Mode.create () in
  (match Mode.bind ~base_path store with
   | Ok () -> fail "bind succeeded on a corrupt store"
   | Error _ -> ());
  check bool "resolve falls back to Auto" true
    (Mode.resolve store ~keeper_name = Mode.Auto);
  check bool "the error is recorded and names the store path" true
    (match Mode.last_restore_error store with
     | Some detail -> Astring.String.is_infix ~affix:file detail
     | None -> false)
;;

let test_set_on_a_corrupt_store_holds_and_recovers () =
  with_temp_dir @@ fun base_path ->
  let keeper_name = "persist-corrupt-set" in
  let store = Mode.create () in
  set_exn store ~base_path ~keeper_name Mode.Yolo;
  check bool "yolo is active before corruption" true
    (Mode.resolve store ~keeper_name = Mode.Yolo);
  let file = write_corrupt_store ~base_path in
  (* Revoking to [Auto] when the disk store is unreadable still removes the
     in-memory [Yolo] override immediately (failing closed to the stricter
     [Auto] default) while reporting the store read failure. *)
  (match
     Mode.set store ~base_path ~actor:"test-operator" ~keeper_name Mode.Auto
   with
   | Ok _ -> fail "set Auto succeeded on a corrupt store"
   | Error detail ->
     check bool "the error names the corrupt store path" true
       (Astring.String.is_infix ~affix:file detail);
     check bool "the error explains in-memory revocation and repair implication" true
       (Astring.String.is_infix ~affix:"revoked to auto in memory" detail));
  check bool "in-memory override is revoked to Auto immediately" true
    (Mode.resolve store ~keeper_name = Mode.Auto);
  check (list string) "revoking Auto cleared the in-memory override" []
    (List.map fst (Mode.overrides store));
  (match
     Mode.set store ~base_path ~actor:"test-operator" ~keeper_name Mode.Yolo
   with
   | Ok _ -> fail "set Yolo succeeded on a corrupt store"
   | Error _ -> ());
  check (list string) "a failed Yolo set holds the registry" []
    (List.map fst (Mode.overrides store));
  (* Once the store reads again, a set both lands and clears the recorded
     error — the operator can repair forward without a restart. *)
  (match
     Fs_compat.save_file_atomic file
       {|{"schema":"masc.tool_approval_modes.v1","overrides":[]}|}
   with
   | Ok () -> ()
   | Error detail -> fail ("could not repair the store: " ^ detail));
  set_exn store ~base_path ~keeper_name Mode.Yolo;
  check bool "the repaired set landed" true
    (Mode.resolve store ~keeper_name = Mode.Yolo);
  check bool "the recorded error is cleared" true
    (Option.is_none (Mode.last_restore_error store))
;;

let write_store ~base_path contents =
  let file = Keeper_gate_path.tool_approval_modes ~base_path in
  Fs_compat.mkdir_p (Keeper_gate_path.dir ~base_path);
  match Fs_compat.save_file_atomic file contents with
  | Ok () -> ()
  | Error detail -> fail ("could not write the store fixture: " ^ detail)
;;

let test_concurrent_sets_do_not_lose_updates () =
  with_temp_dir @@ fun base_path ->
  let store = Mode.create () in
  (* Fatten the store so each read-modify-write's read phase is long enough
     for a second writer's read to interleave against an unfixed [set]; the
     whole operation is under one mutex now, so both writers must survive
     regardless. *)
  let churn =
    List.init 500 (fun i ->
        `Assoc
          [ "keeper_name", `String (Printf.sprintf "churn-%03d" i)
          ; "mode", `String "yolo"
          ; "updated_by", `String "test-operator"
          ; "updated_at", `String "2026-10-15T00:00:00Z"
          ])
  in
  write_store ~base_path
    (Yojson.Safe.pretty_to_string
       (`Assoc
          [ "schema", `String "masc.tool_approval_modes.v1"
          ; "overrides", `List churn
          ]));
  let go = ref false in
  let errors = ref [] in
  let worker keeper_name =
    Thread.create (fun () ->
        while not !go do
          Thread.yield ()
        done;
        match
          Mode.set store ~base_path ~actor:"test-operator" ~keeper_name Mode.Yolo
        with
        | Ok Mode.Applied -> ()
        | Ok (Mode.Applied_audit_failed detail) ->
          errors := ("audit: " ^ detail) :: !errors
        | Error detail -> errors := detail :: !errors)
      ()
  in
  let a = worker "concurrent-a" in
  let b = worker "concurrent-b" in
  go := true;
  Thread.join a;
  Thread.join b;
  check (list string) "no concurrent set errored" [] !errors;
  let file_rows =
    match Mode.keeper_overrides ~base_path with
    | Ok rows -> rows
    | Error detail -> fail ("could not read back the store: " ^ detail)
  in
  let file_names = List.map (fun row -> row.Mode.keeper_name) file_rows in
  let memory_names = List.map fst (Mode.overrides store) in
  check bool "concurrent-a survived in the file" true
    (List.mem "concurrent-a" file_names);
  check bool "concurrent-b survived in the file" true
    (List.mem "concurrent-b" file_names);
  check bool "file and memory agree after concurrent sets" true
    (List.sort String.compare file_names
     = List.sort String.compare memory_names)
;;

let test_wrong_schema_tag_is_rejected () =
  with_temp_dir @@ fun base_path ->
  write_store ~base_path
    {|{"schema":"masc.tool_approval_modes.v2","overrides":[]}|};
  let store = Mode.create () in
  (match Mode.bind ~base_path store with
   | Ok () -> fail "bind accepted a wrong-schema store"
   | Error detail ->
     check bool "the error names the schema mismatch" true
       (Astring.String.is_infix ~affix:"schema" detail));
  check bool "the rejection is recorded, not silent" true
    (Option.is_some (Mode.last_restore_error store))
;;

let test_invalid_mode_word_is_rejected () =
  with_temp_dir @@ fun base_path ->
  write_store ~base_path
    {|{"schema":"masc.tool_approval_modes.v1","overrides":[{"keeper_name":"bad-row","mode":"loud","updated_by":"x","updated_at":"y"}]}|};
  let store = Mode.create () in
  (match Mode.bind ~base_path store with
   | Ok () -> fail "bind accepted an invalid mode word"
   | Error detail ->
     check bool "the error names the bad mode" true
       (Astring.String.is_infix ~affix:"loud" detail));
  check bool "the rejection is recorded, not silent" true
    (Option.is_some (Mode.last_restore_error store))
;;

module Mcp_server = Masc.Mcp_server
module Http_server_eio = Masc.Http_server_eio

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed ->
    Alcotest.fail "failed to construct loopback request authority"
;;

let create_token_exn base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok token_info -> token_info
  | Error msg ->
    Alcotest.failf "create_token failed: %s" (Masc_domain.masc_error_to_string msg)
;;

let status_of_response response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | _ -> Alcotest.failf "could not parse response status: %S" response
;;

(* Drive the real dashboard router with a GET, then return the raw HTTP
   response — the same harness as the actor-log suite, minus the body. *)
let dispatch_get
      ?(path = "/api/v1/keepers/tool-approval-mode")
      ~sw
      ~clock
      ~state
      ~token
      ()
  =
  Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
      let router =
        Server_routes_http_routes_dashboard.add_routes
          ~sw
          ~clock
          (Http_server_eio.Router.create ())
      in
      Server_auth.publish_server_state state;
      let response_buf = Buffer.create 1024 in
      let conn =
        Httpun.Server_connection.create (fun reqd ->
            Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
      in
      let request_str =
        Printf.sprintf
          "GET %s HTTP/1.1\r\n\
           Host: 127.0.0.1:8935\r\n\
           Authorization: Bearer %s\r\n\
           \r\n"
          path
          token
      in
      let bytes =
        Bigstringaf.of_string ~off:0 ~len:(String.length request_str) request_str
      in
      ignore
        (Httpun.Server_connection.read_eof
           conn
           bytes
           ~off:0
           ~len:(Bigstringaf.length bytes));
      let rec flush () =
        match Httpun.Server_connection.next_write_operation conn with
        | `Write iovecs ->
          let written =
            List.fold_left
              (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
                 Buffer.add_string
                   response_buf
                   (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
                 total + iov.len)
              0
              iovecs
          in
          Httpun.Server_connection.report_write_result conn (`Ok written);
          flush ()
        | `Yield | `Close _ -> ()
      in
      flush ();
      Server_auth.clear_server_state ();
      Buffer.contents response_buf)
;;

let json_body_of response =
  match Astring.String.cut ~sep:"\r\n\r\n" response with
  | Some (_, body) ->
    (try Yojson.Safe.from_string body with
     | Yojson.Json_error error ->
       Alcotest.failf "response body is not json: %s (%s)" error body)
  | None -> Alcotest.fail "response has no header/body separator"
;;

let test_get_surfaces_restore_error () =
  with_temp_dir @@ fun base_path ->
  Auth.save_auth_config base_path
    { Masc_domain.default_auth_config with enabled = true; require_token = true };
  let token, _ =
    create_token_exn base_path ~agent_name:"mode-reader" ~role:Masc_domain.Admin
  in
  let state = Mcp_server.For_testing.create_state ~base_path in
  (* GET routes answer through [with_public_read], which 503s until the
     server marks its startup state ready; the POST suite does not need it. *)
  Fun.protect
    ~finally:Server_startup_state.reset
    (fun () ->
      ignore (Server_startup_state.mark_state_ready ());
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let clock = Eio.Stdenv.clock env in
      let healthy = dispatch_get ~sw ~clock ~state ~token () in
      check int "GET succeeds on a healthy store" 200
        (status_of_response healthy);
      check bool "restore_error is null on a healthy store" true
        (Yojson.Safe.Util.member "restore_error" (json_body_of healthy)
         = `Null);
      write_store ~base_path "{ not a store";
      (match Mode.bind ~base_path (Mode.shared ()) with
       | Ok () -> fail "bind succeeded on a corrupt store"
       | Error _ -> ());
      let corrupt = dispatch_get ~sw ~clock ~state ~token () in
      check int "GET keeps 200 on a corrupt store" 200
        (status_of_response corrupt);
      (match
         Yojson.Safe.Util.member "restore_error" (json_body_of corrupt)
       with
       | `String detail ->
         check bool "restore_error carries a non-empty message" true
           (String.trim detail <> "")
       | other ->
         failf "restore_error should be a string, got %s"
           (Yojson.Safe.to_string other));
      (* Repair and rebind the shared registry so later suites start clean. *)
      write_store ~base_path
        {|{"schema":"masc.tool_approval_modes.v1","overrides":[]}|};
      (match Mode.bind ~base_path (Mode.shared ()) with
       | Ok () -> ()
       | Error detail -> fail ("cleanup rebind failed: " ^ detail));
      let repaired = dispatch_get ~sw ~clock ~state ~token () in
      check bool "restore_error clears after a clean rebind" true
        (Yojson.Safe.Util.member "restore_error" (json_body_of repaired)
         = `Null))
;;

let block_audit_store ~base_path =
  let masc_dir = Filename.concat base_path ".masc" in
  Fs_compat.mkdir_p masc_dir;
  let audit_path = Filename.concat masc_dir Audit_log.store_dirname in
  match Fs_compat.save_file_atomic audit_path "not-a-directory" with
  | Ok () -> audit_path
  | Error detail -> fail ("could not block audit store path: " ^ detail)
;;

let test_set_applies_when_audit_log_fails () =
  with_temp_dir @@ fun base_path ->
  ignore (block_audit_store ~base_path : string);
  let keeper_name = "persist-audit-fail" in
  let store = Mode.create () in
  (match
     Mode.set store ~base_path ~actor:"test-operator" ~keeper_name Mode.Yolo
   with
   | Ok (Mode.Applied_audit_failed detail) ->
     check bool "audit failure detail is non-empty" true
       (Astring.String.is_infix ~affix:"tool approval mode audit failed" detail)
   | Ok Mode.Applied ->
     fail "expected Applied_audit_failed when audit path is a regular file"
   | Error detail ->
     fail ("expected stance to apply despite audit failure, got Error: " ^ detail));
  check bool "in-memory stance is Yolo" true
    (Mode.resolve store ~keeper_name = Mode.Yolo);
  let after = Mode.create () in
  (match Mode.bind ~base_path after with
   | Ok () -> ()
   | Error detail -> fail ("bind after audit failure failed: " ^ detail));
  check bool "persisted stance is Yolo across restart" true
    (Mode.resolve after ~keeper_name = Mode.Yolo)
;;

let make_keeper_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String name
         ; "trace_id", `String ("trace-" ^ name)
         ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)
;;

let dispatch_post
      ?(path = "/api/v1/keepers/tool-approval-mode")
      ~sw
      ~clock
      ~state
      ~token
      ~keeper
      ~mode
      ()
  =
  Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
      let router =
        Server_routes_http_routes_dashboard.add_routes
          ~sw
          ~clock
          (Http_server_eio.Router.create ())
      in
      Server_auth.publish_server_state state;
      let response_buf = Buffer.create 1024 in
      let conn =
        Httpun.Server_connection.create (fun reqd ->
            Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
      in
      let body = Printf.sprintf {|{"name":%S,"mode":%S}|} keeper mode in
      let request_str =
        Printf.sprintf
          "POST %s HTTP/1.1\r\n\
           Host: 127.0.0.1:8935\r\n\
           Origin: http://127.0.0.1:8935\r\n\
           Authorization: Bearer %s\r\n\
           Content-Type: application/json\r\n\
           Content-Length: %d\r\n\
           \r\n\
           %s"
          path
          token
          (String.length body)
          body
      in
      let bytes =
        Bigstringaf.of_string ~off:0 ~len:(String.length request_str) request_str
      in
      ignore
        (Httpun.Server_connection.read_eof
           conn
           bytes
           ~off:0
           ~len:(Bigstringaf.length bytes));
      let rec flush () =
        match Httpun.Server_connection.next_write_operation conn with
        | `Write iovecs ->
          let written =
            List.fold_left
              (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
                 Buffer.add_string
                   response_buf
                   (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
                 total + iov.len)
              0
              iovecs
          in
          Httpun.Server_connection.report_write_result conn (`Ok written);
          flush ()
        | `Yield | `Close _ -> ()
      in
      flush ();
      Server_auth.clear_server_state ();
      Buffer.contents response_buf)
;;

let test_post_surfaces_audit_error_on_200 () =
  with_temp_dir @@ fun base_path ->
  Auth.save_auth_config base_path
    { Masc_domain.default_auth_config with enabled = true; require_token = true };
  let token, _ =
    create_token_exn base_path ~agent_name:"mode-writer" ~role:Masc_domain.Admin
  in
  let state = Mcp_server.For_testing.create_state ~base_path in
  let keeper = "audit-fail-route-canary" in
  ignore
    (Masc.Keeper_registry.For_testing.register
       ~base_path
       keeper
       (make_keeper_meta keeper));
  ignore (block_audit_store ~base_path : string);
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.For_testing.unregister ~base_path keeper;
      write_store ~base_path
        {|{"schema":"masc.tool_approval_modes.v1","overrides":[]}|};
      ignore (Mode.bind ~base_path (Mode.shared ())))
    (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let clock = Eio.Stdenv.clock env in
      let response =
        dispatch_post ~sw ~clock ~state ~token ~keeper ~mode:"yolo" ()
      in
      check int "POST still returns 200 when stance applied but audit failed" 200
        (status_of_response response);
      let body = json_body_of response in
      check string "response confirms yolo mode" "yolo"
        (Yojson.Safe.Util.member "mode" body |> Yojson.Safe.Util.to_string);
      (match Yojson.Safe.Util.member "audit_error" body with
       | `String detail ->
         check bool "response carries audit_error detail" true
           (Astring.String.is_infix ~affix:"tool approval mode audit failed" detail)
       | other ->
         failf "expected string audit_error on 200 response, got %s"
           (Yojson.Safe.to_string other)))
;;

let () =
  run
    "keeper_tool_approval_mode_persist"
    [ ( "persist"
      , [ test_case "yolo survives a restart" `Quick test_yolo_survives_a_restart
        ; test_case "auto removes the row" `Quick test_auto_removes_the_row
        ; test_case "a corrupt store is an error, not a quiet auto" `Quick
            test_a_corrupt_store_is_an_error_not_a_quiet_auto
        ; test_case "set on a corrupt store holds and recovers" `Quick
            test_set_on_a_corrupt_store_holds_and_recovers
        ; test_case "concurrent sets do not lose updates" `Quick
            test_concurrent_sets_do_not_lose_updates
        ; test_case "wrong schema tag is rejected" `Quick
            test_wrong_schema_tag_is_rejected
        ; test_case "invalid mode word is rejected" `Quick
            test_invalid_mode_word_is_rejected
        ; test_case "set applies when audit log fails" `Quick
            test_set_applies_when_audit_log_fails
        ] )
    ; ( "route"
      , [ test_case "GET surfaces restore_error" `Quick
            test_get_surfaces_restore_error
        ; test_case "POST surfaces audit_error on 200" `Quick
            test_post_surfaces_audit_error_on_200
        ] )
    ]
;;
