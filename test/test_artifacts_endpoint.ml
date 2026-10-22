(** Artifact lookup helpers and actual HTTP routing, including operator
    authorization, workspace admission, and exact binary responses. *)

module A = Server_routes_http_routes_artifacts
module B = Tool_blob_store
module Http = Masc.Http_server_eio
module O = Tool_output

let with_temp_base_path f =
  let dir = Filename.temp_file "masc_artifacts_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cleanup () =
    let rec rm path =
      if Sys.file_exists path then
        if Sys.is_directory path then begin
          Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
          Unix.rmdir path
        end
        else Unix.unlink path
    in
    try rm dir with _ -> ()
  in
  let r = try Ok (f dir) with e -> Error e in
  cleanup ();
  match r with Ok v -> v | Error e -> raise e

(* --- sha256 validation --- *)

let test_valid_sha256 () =
  Alcotest.(check bool) "exact 64 lowercase hex" true
    (A.is_valid_sha256
       "abc1234567890123456789012345678901234567890123456789012345678901");
  Alcotest.(check bool) "uppercase hex" false
    (A.is_valid_sha256
       "ABC1234567890123456789012345678901234567890123456789012345678901");
  Alcotest.(check bool) "63 chars" false
    (A.is_valid_sha256
       "abc123456789012345678901234567890123456789012345678901234567890");
  Alcotest.(check bool) "65 chars" false
    (A.is_valid_sha256
       "abc12345678901234567890123456789012345678901234567890123456789012");
  Alcotest.(check bool) "non-hex char" false
    (A.is_valid_sha256
       "ghi1234567890123456789012345678901234567890123456789012345678901");
  Alcotest.(check bool) "empty" false (A.is_valid_sha256 "")

let test_artifact_bytes_require_operator_auth () =
  let sha256 = String.make 64 'a' in
  Alcotest.(check bool)
    "artifact route is not public"
    false
    (Server_auth.is_public_read_path
       ("/api/v1/artifacts/" ^ sha256));
  Alcotest.(check bool)
    "prefix-confusable route is not public"
    false
    (Server_auth.is_public_read_path
       ("/api/v1/artifacts-evil/" ^ sha256));
  Alcotest.(check bool)
    "raw byte route is not public"
    false
    (Server_auth.is_public_read_path
       ("/api/v1/artifact-bytes/" ^ sha256));
  Alcotest.(check bool)
    "route authority is CanAdmin"
    true
    (A.artifact_read_permission = Masc_domain.CanAdmin);
  Alcotest.(check bool)
    "worker cannot dereference exact bytes"
    false
    (Masc_domain.has_permission Masc_domain.Worker A.artifact_read_permission);
  Alcotest.(check bool)
    "admin can dereference exact bytes"
    true
    (Masc_domain.has_permission Masc_domain.Admin A.artifact_read_permission)

let create_token_exn base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok (raw_token, _) -> raw_token
  | Error error ->
    Alcotest.fail
      ("create_token failed: " ^ Masc_domain.masc_error_to_string error)
;;

let http_request ~path ?token () =
  let headers = [ "host", "localhost"; "content-length", "0" ] in
  let headers =
    match token with
    | None -> headers
    | Some value -> ("authorization", "Bearer " ^ value) :: headers
  in
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list headers)
    `GET
    path
;;

let dispatch router request =
  Eio_main.run (fun _env ->
    let response_buf = Buffer.create 1024 in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
    in
    let request_head =
      Printf.sprintf
        "%s %s HTTP/1.1\r\n%s"
        (Httpun.Method.to_string request.Httpun.Request.meth)
        request.Httpun.Request.target
        (Httpun.Headers.to_string request.Httpun.Request.headers)
    in
    let bytes =
      Bigstringaf.of_string ~off:0 ~len:(String.length request_head) request_head
    in
    let rec feed off =
      let remaining = Bigstringaf.length bytes - off in
      if remaining > 0
      then (
        let consumed =
          Httpun.Server_connection.read conn bytes ~off ~len:remaining
        in
        if consumed <= 0 then Alcotest.fail "httpun test feed made no progress";
        feed (off + consumed))
    in
    feed 0;
    let rec flush () =
      match Httpun.Server_connection.next_write_operation conn with
      | `Write iovecs ->
        List.iter
          (fun (iov : Bigstringaf.t Httpun.IOVec.t) ->
             Buffer.add_string
               response_buf
               (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len))
          iovecs;
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) -> total + iov.len)
            0
            iovecs
        in
        Httpun.Server_connection.report_write_result conn (`Ok written);
        flush ()
      | `Yield | `Close _ -> ()
    in
    flush ();
    Buffer.contents response_buf)
;;

let status_of_response response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | _ -> Alcotest.failf "could not parse response status: %S" response
;;

let headers_and_body response =
  match Astring.String.cut ~sep:"\r\n\r\n" response with
  | None -> Alcotest.fail "HTTP response has no header terminator"
  | Some (head, body) ->
    let lines = String.split_on_char '\n' head in
    let headers = match lines with
      | [] -> Alcotest.fail "HTTP response has no status line"
      | _status :: fields ->
        List.map (fun field ->
          match Astring.String.cut ~sep:":" field with
          | Some (name, value) -> String.lowercase_ascii name, String.trim value
          | None -> Alcotest.failf "invalid HTTP header: %S" field) fields
        |> Httpun.Headers.of_list
    in
    headers, body
;;

let check_workspace_receipt expected response =
  let headers, _ = headers_and_body response in
  Alcotest.(check (list string)) "workspace admission receipt" expected
    (Httpun.Headers.get_multi headers "x-masc-workspace-read")
;;

let test_artifact_route_enforces_admin_token () =
  with_temp_base_path (fun base_path ->
    let auth_config =
      { Masc_domain.default_auth_config with enabled = true; require_token = true }
    in
    Auth.save_auth_config base_path auth_config;
    let worker =
      create_token_exn
        base_path
        ~agent_name:"artifact-worker"
        ~role:Masc_domain.Worker
    in
    let admin =
      create_token_exn
        base_path
        ~agent_name:"artifact-admin"
        ~role:Masc_domain.Admin
    in
    let store = B.create ~base_path in
    let payload = "operator-only exact artifact bytes" in
    let sha256 =
      match B.put store ~bytes:payload ~mime:"text/plain" with
      | O.Stored { sha256; _ } -> sha256
    in
    let saved_state = Server_auth.For_testing.snapshot_server_state () in
    Fun.protect
      ~finally:(fun () -> Server_auth.For_testing.restore_server_state @@ saved_state)
      (fun () ->
         let state = Masc.Mcp_server.For_testing.create_state ~base_path in
         Server_auth.For_testing.restore_server_state (Some state);
         let router = A.add_routes (Http.Router.create ()) in
         let path = "/api/v1/artifacts/" ^ sha256 in
         let anonymous = dispatch router (http_request ~path ()) in
         let worker_response =
           dispatch router (http_request ~path ~token:worker ())
         in
         let admin_response =
           dispatch router (http_request ~path ~token:admin ())
         in
         Alcotest.(check int) "anonymous denied" 401 (status_of_response anonymous);
         Alcotest.(check int) "Worker denied" 403 (status_of_response worker_response);
         Alcotest.(check int) "Admin allowed" 200 (status_of_response admin_response);
         Alcotest.(check bool)
           "Admin receives exact bytes"
           true
           (Astring.String.is_infix ~affix:payload admin_response);
         let binary = "\000\255board\128attachment" in
         let binary_sha =
           match B.put store ~bytes:binary ~mime:"application/octet-stream" with
           | O.Stored { sha256; _ } -> sha256
         in
         let raw_path = "/api/v1/artifact-bytes/" ^ binary_sha in
         let anonymous_raw = dispatch router (http_request ~path:raw_path ()) in
         let worker_raw = dispatch router (http_request ~path:raw_path ~token:worker ()) in
         let admin_raw = dispatch router (http_request ~path:raw_path ~token:admin ()) in
         Alcotest.(check int) "raw anonymous denied" 401 (status_of_response anonymous_raw);
         Alcotest.(check int) "raw Worker denied" 403 (status_of_response worker_raw);
         Alcotest.(check int) "raw Admin allowed" 200 (status_of_response admin_raw);
         Alcotest.(check bool) "raw response keeps binary bytes" true
           (Astring.String.is_infix ~affix:binary admin_raw);
         Alcotest.(check bool) "raw response is a download" true
           (Astring.String.is_infix ~affix:"application/octet-stream" admin_raw);
         check_workspace_receipt [] admin_raw;
         let encode = Uri.pct_encode ~component:`Query_value in
         let base = Unix.realpath base_path in
         let root = Unix.realpath
           (Masc.Workspace.masc_dir (Masc.Mcp_server.workspace_config state)) in
         let bound_path = raw_path ^ "?expected_base_path=" ^ encode base
           ^ "&expected_masc_root=" ^ encode root in
         let matched = dispatch router (http_request ~path:bound_path ~token:admin ()) in
         Alcotest.(check int) "matched raw read succeeds" 200 (status_of_response matched);
         check_workspace_receipt ["matched-v1"] matched;
         let headers, body = headers_and_body matched in
         Alcotest.(check string) "matched read preserves the entire binary body" binary body;
         List.iter (fun (name, value) ->
           Alcotest.(check (option string)) name (Some value)
             (Httpun.Headers.get headers name))
           [ "content-type", "application/octet-stream"
           ; "content-length", string_of_int (String.length binary)
           ; "cache-control", "no-store"
           ; "x-content-type-options", "nosniff"
           ; "content-disposition", "attachment; filename=artifact-" ^ binary_sha ^ ".bin"
           ];
         List.iter (fun (token, expected_status) ->
           let refused = dispatch router (http_request ~path:bound_path ?token ()) in
           Alcotest.(check int) "bound read still requires Admin" expected_status
             (status_of_response refused);
           check_workspace_receipt [] refused)
           [ None, 401; Some worker, 403 ];
         List.iter (fun (query, expected_status) ->
           let response = dispatch router
             (http_request ~path:(raw_path ^ "?" ^ query) ~token:admin ()) in
           Alcotest.(check int) "invalid workspace cannot read bytes" expected_status
             (status_of_response response);
           check_workspace_receipt [] response;
           let _, body = headers_and_body response in
           Alcotest.(check bool) "refusal excludes artifact body" false
             (Astring.String.is_infix ~affix:binary body))
           [ "expected_base_path=" ^ encode (base ^ "-foreign")
               ^ "&expected_masc_root=" ^ encode root, 409
           ; "expected_base_path=" ^ encode base, 400
           ; "expected_base_path=" ^ encode base
               ^ "&expected_masc_root=" ^ encode root
               ^ "&expected_masc_root=" ^ encode root, 400
           ];
         let unbound_again = dispatch router (http_request ~path:raw_path ~token:admin ()) in
         Alcotest.(check int) "later unbound read succeeds" 200 (status_of_response unbound_again);
         check_workspace_receipt [] unbound_again;
         let source = Filename.concat base_path "oversized.bin" in
         let fd = Unix.openfile source [ Unix.O_CREAT; Unix.O_WRONLY ] 0o600 in
         Fun.protect
           ~finally:(fun () -> Unix.close fd)
           (fun () -> Unix.ftruncate fd (A.maximum_artifact_response_bytes + 1));
         let oversized : O.artifact_ref =
           B.put_file_durable store ~path:source ~mime:"application/octet-stream"
         in
         let oversized_path = "/api/v1/artifact-bytes/" ^ oversized.sha256 in
         let oversized_response =
           dispatch router (http_request ~path:oversized_path ~token:admin ())
         in
         Alcotest.(check int) "oversized raw artifact refused" 413
           (status_of_response oversized_response);
         Alcotest.(check bool) "response states the byte limit" true
           (Astring.String.is_infix ~affix:"maximum_bytes" oversized_response)))
;;

let test_generated_audio_workspace_receipt () =
  with_temp_base_path (fun base_path ->
    Auth.save_auth_config base_path
      {Masc_domain.default_auth_config with enabled=true; require_token=true};
    let token = create_token_exn base_path ~agent_name:"audio-reader" ~role:Masc_domain.Admin in
    let saved = Server_auth.For_testing.snapshot_server_state () in
    Fun.protect
      ~finally:(fun () -> Server_auth.For_testing.restore_server_state saved)
      (fun () ->
        let state = Masc.Mcp_server.For_testing.create_state ~base_path in
        Server_auth.For_testing.restore_server_state (Some state);
        let payload = "RIFF\000\255audio\128bytes" in
        let path = match Masc.Keeper_chat_media_store.persist_result
          ~base_dir:base_path ~media_type:"audio/wav" ~data:payload with
          | Ok (_, path) -> path | Error detail -> Alcotest.fail detail in
        let router = Server_routes_http_routes_voice.add_routes (Http.Router.create ()) in
        let encode = Uri.pct_encode ~component:`Query_value in
        let base = Unix.realpath base_path in
        let root = Unix.realpath (Masc.Workspace.masc_dir (Masc.Mcp_server.workspace_config state)) in
        let query base = "?expected_base_path=" ^ encode base
          ^ "&expected_masc_root=" ^ encode root in
        let matched = dispatch router (http_request ~path:(path ^ query base) ~token ()) in
        Alcotest.(check int) "original workspace reads generated audio" 200 (status_of_response matched);
        check_workspace_receipt ["matched-v1"] matched;
        let headers, body = headers_and_body matched in
        Alcotest.(check string) "audio bytes are unchanged" payload body;
        Alcotest.(check (option string)) "audio MIME" (Some "audio/wav")
          (Httpun.Headers.get headers "content-type");
        let refused = dispatch router
          (http_request ~path:(path ^ query (base ^ "-other")) ~token ()) in
        Alcotest.(check int) "different workspace cannot supply playback bytes" 409
          (status_of_response refused);
        check_workspace_receipt [] refused;
        let unbound = dispatch router (http_request ~path ~token ()) in
        check_workspace_receipt [] unbound;
        let _, original = headers_and_body unbound in
        Alcotest.(check string) "receipt is scoped to the bound request" payload original))
;;

(* --- blob_response shape --- *)

let assert_json_field key expected json =
  match Yojson.Safe.Util.member key json with
  | `String s -> Alcotest.(check string) key expected s
  | _ -> Alcotest.failf "%s missing or wrong type" key

let test_not_found () =
  with_temp_base_path (fun dir ->
      let json, status =
        A.blob_response ~base_path:dir ~sha256:(String.make 64 'a')
      in
      Alcotest.(check bool) "404 not found" true (status = `Not_found);
      assert_json_field "error" "not found" json)

let test_hit_returns_envelope () =
  with_temp_base_path (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = "the actual blob bytes" in
      let stored = B.put store ~bytes:payload ~mime:"text/plain" in
      match stored with
      | O.Stored { sha256; _ } ->
          let json, status = A.blob_response ~base_path:dir ~sha256 in
          Alcotest.(check bool) "200 OK" true (status = `OK);
          assert_json_field "sha256" sha256 json;
          assert_json_field "mime" "text/plain" json;
          assert_json_field "content" payload json;
          (match Yojson.Safe.Util.member "bytes" json with
           | `Int n ->
               Alcotest.(check int) "byte count"
                 (String.length payload) n
           | _ -> Alcotest.fail "bytes field missing"))

let () =
  Alcotest.run "artifacts_endpoint"
    [
      ( "sha256 validation",
        [ Alcotest.test_case "valid + invalid forms" `Quick test_valid_sha256
        ; Alcotest.test_case "exact bytes require operator auth" `Quick
            test_artifact_bytes_require_operator_auth
        ; Alcotest.test_case "route enforces Admin bearer" `Quick
            test_artifact_route_enforces_admin_token
        ; Alcotest.test_case "generated audio retains workspace receipt" `Quick
            test_generated_audio_workspace_receipt
        ] );
      ( "blob_response",
        [
          Alcotest.test_case "not found" `Quick test_not_found;
          Alcotest.test_case "hit returns envelope" `Quick
            test_hit_returns_envelope;
        ] );
    ]
