(** Tests for the dashboard artifact lookup helpers.

    The HTTP routing surface is integration-tested elsewhere; this file
    pins the pure helpers in [Server_routes_http_routes_artifacts]:
    sha256 validation and the JSON envelope shape returned for hit /
    miss cases. *)

module A = Server_routes_http_routes_artifacts
module B = Tool_blob_store
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

let test_strict_auth_requires_read_auth () =
  let sha256 = String.make 64 'a' in
  Alcotest.(check bool)
    "artifact route is not public in strict auth mode"
    false
    (Server_auth.is_public_read_path
       ("/api/v1/artifacts/" ^ sha256));
  Alcotest.(check bool)
    "prefix-confusable route is not public"
    false
    (Server_auth.is_public_read_path
       ("/api/v1/artifacts-evil/" ^ sha256))

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
           | _ -> Alcotest.fail "bytes field missing")
      | O.Inline _ -> Alcotest.fail "expected Stored")

let () =
  Alcotest.run "artifacts_endpoint"
    [
      ( "sha256 validation",
        [ Alcotest.test_case "valid + invalid forms" `Quick test_valid_sha256
        ; Alcotest.test_case "strict auth requires read auth" `Quick
            test_strict_auth_requires_read_auth
        ] );
      ( "blob_response",
        [
          Alcotest.test_case "not found" `Quick test_not_found;
          Alcotest.test_case "hit returns envelope" `Quick
            test_hit_returns_envelope;
        ] );
    ]
