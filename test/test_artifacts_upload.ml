(** Tests for [POST /api/v1/artifacts] — the raw-binary upload route the
    board file-sharing flow consumes (a later layer posts attachment bytes
    here and keeps the returned content address).

    In-process raw HTTP through the real router, mirroring
    [test_artifacts_endpoint.ml] (GET surface + auth fixture) and
    [test_board_rest_routes.ml] (POST body dispatch through one fed
    connection). *)

module A = Server_routes_http_routes_artifacts
module B = Tool_blob_store
module Http = Masc.Http_server_eio

let upload_path = "/api/v1/artifacts"

let with_temp_base_path f =
  let dir = Filename.temp_file "masc_artifacts_upload_test" "" in
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
;;

let create_token_exn base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok (raw_token, _) -> raw_token
  | Error error ->
    Alcotest.fail
      ("create_token failed: " ^ Masc_domain.masc_error_to_string error)
;;

(* One raw request fed through a real httpun server connection, body
   included; returns the raw response bytes. *)
let dispatch_request ~router ~path ?token ?content_type ?content_length ~body () =
  Eio_main.run (fun _env ->
    let output = Buffer.create 1024 in
    let connection =
      Httpun.Server_connection.create (fun reqd ->
        Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
    in
    let authorization =
      match token with
      | None -> ""
      | Some value -> "Authorization: Bearer " ^ value ^ "\r\n"
    in
    let content_type_header =
      match content_type with
      | None -> ""
      | Some value -> "Content-Type: " ^ value ^ "\r\n"
    in
    let raw_request =
      Printf.sprintf
        "POST %s HTTP/1.1\r\nHost: localhost\r\n%s%sContent-Length: %d\r\n\r\n%s"
        path
        authorization
        content_type_header
        (Option.value content_length ~default:(String.length body))
        body
    in
    let input =
      Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request
    in
    ignore
      (Httpun.Server_connection.read_eof connection input ~off:0
         ~len:(Bigstringaf.length input));
    let rec drain () =
      match Httpun.Server_connection.next_write_operation connection with
      | `Write iovecs ->
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
               Buffer.add_string
                 output
                 (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
               total + iov.len)
            0
            iovecs
        in
        Httpun.Server_connection.report_write_result connection (`Ok written);
        drain ()
      | `Yield | `Close _ -> ()
    in
    drain ();
    Buffer.contents output)
;;

let status_of_response response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | _ -> Alcotest.failf "could not parse response status: %S" response
;;

let body_of_response response =
  let rec body_offset index =
    if index + 4 > String.length response
    then Alcotest.failf "no HTTP body: %S" response
    else if String.sub response index 4 = "\r\n\r\n"
    then index + 4
    else body_offset (index + 1)
  in
  let offset = body_offset 0 in
  String.sub response offset (String.length response - offset)
;;

let with_upload_router f =
  with_temp_base_path (fun base_path ->
    Auth.save_auth_config
      base_path
      { Masc_domain.default_auth_config with
        enabled = true
      ; require_token = true
      };
    let worker =
      create_token_exn base_path ~agent_name:"upload-worker" ~role:Masc_domain.Worker
    in
    let admin =
      create_token_exn base_path ~agent_name:"upload-admin" ~role:Masc_domain.Admin
    in
    let saved_state = Server_auth.For_testing.snapshot_server_state () in
    Fun.protect
      ~finally:(fun () ->
        Server_auth.For_testing.restore_server_state saved_state)
      (fun () ->
         Server_auth.For_testing.restore_server_state
           (Some (Masc.Mcp_server.For_testing.create_state ~base_path));
         let router = A.add_routes (Http.Router.create ()) in
         f ~base_path ~router ~worker ~admin))
;;

let stored_shas base_path = B.list_all (B.create ~base_path)

(* (a) The upload route sits behind the same operator credential gate as the
   artifact reads: anonymous is a 401, a Worker role is a 403, and neither
   stores anything. *)
let test_upload_requires_operator_credential () =
  with_upload_router (fun ~base_path ~router ~worker ~admin:_ ->
    let body = "bytes that must never be stored" in
    let anonymous =
      dispatch_request ~router ~path:upload_path ~content_type:"audio/midi" ~body ()
    in
    let worker_response =
      dispatch_request ~router ~path:upload_path ~token:worker
        ~content_type:"audio/midi" ~body ()
    in
    Alcotest.(check int) "anonymous upload refused" 401 (status_of_response anonymous);
    Alcotest.(check int) "Worker upload refused" 403 (status_of_response worker_response);
    Alcotest.(check (list string)) "refused uploads store nothing" [] (stored_shas base_path))
;;

let upload_json ~router ~token ~bytes =
  let response =
    dispatch_request ~router ~path:upload_path ~token ~body:bytes ()
  in
  Alcotest.(check int) "upload accepted" 201 (status_of_response response);
  Yojson.Safe.from_string (body_of_response response)
;;

(* A valid upload is stored under its content address and the 201 names the
   sha256 and the byte count; fetching the address returns the exact bytes. *)
let test_upload_stores_exact_bytes () =
  with_upload_router (fun ~base_path ~router ~worker:_ ~admin ->
    let bytes = "\000\255board\128attachment\000" in
    let json = upload_json ~router ~token:admin ~bytes in
    let open Yojson.Safe.Util in
    let sha256 = json |> member "sha256" |> to_string in
    Alcotest.(check int) "byte count" (String.length bytes) (json |> member "bytes" |> to_int);
    match B.fetch (B.create ~base_path) ~sha256 with
    | Ok (Some stored) ->
      Alcotest.(check string) "stored bytes round-trip" bytes stored
    | Ok None -> Alcotest.fail "uploaded sha256 missing from the store"
    | Error error -> Alcotest.fail (B.fetch_error_to_string error))
;;

(* The store is content-addressed: re-uploading the same bytes returns the
   same sha256 and keeps exactly one stored blob. *)
let test_reupload_is_idempotent () =
  with_upload_router (fun ~base_path ~router ~worker:_ ~admin ->
    let bytes = "same bytes, same address" in
    let first = upload_json ~router ~token:admin ~bytes in
    let second = upload_json ~router ~token:admin ~bytes in
    let open Yojson.Safe.Util in
    let first_sha = first |> member "sha256" |> to_string in
    Alcotest.(check string) "same bytes, same sha256" first_sha
      (second |> member "sha256" |> to_string);
    Alcotest.(check (list string)) "one stored blob" [ first_sha ] (stored_shas base_path))
;;

(* The upload's limit is the artifact limit -- what the download routes can
   serve -- and the refusal says that number. The request only has to
   declare the length for the reader to refuse it. *)
let test_upload_above_the_artifact_limit_is_413 () =
  with_upload_router (fun ~base_path ~router ~worker:_ ~admin ->
    let response =
      dispatch_request ~router ~path:upload_path ~token:admin
        ~content_length:(B.max_served_bytes + 1) ~body:"x" ()
    in
    Alcotest.(check int) "oversized upload refused" 413 (status_of_response response);
    Alcotest.(check int) "the refusal names the artifact limit" B.max_served_bytes
      Yojson.Safe.Util.(
        Yojson.Safe.from_string (body_of_response response)
        |> member "maximum_bytes" |> to_int);
    Alcotest.(check (list string)) "oversized upload stored nothing" []
      (stored_shas base_path))
;;

(* A file larger than the cap other requests live under still fits the
   artifact store: the upload does not read against that cap. *)
let test_upload_is_not_held_to_the_general_request_cap () =
  with_upload_router (fun ~base_path:_ ~router ~worker:_ ~admin ->
    let bytes = String.make (Http.Request.max_body_bytes + 1) 'x' in
    let json = upload_json ~router ~token:admin ~bytes in
    Alcotest.(check int) "the whole file was stored" (String.length bytes)
      Yojson.Safe.Util.(json |> member "bytes" |> to_int))
;;

(* An empty body is not a file. *)
let test_empty_upload_is_refused () =
  with_upload_router (fun ~base_path ~router ~worker:_ ~admin ->
    let response =
      dispatch_request ~router ~path:upload_path ~token:admin ~body:"" ()
    in
    Alcotest.(check int) "empty upload refused" 400 (status_of_response response);
    Alcotest.(check (list string)) "empty upload stored nothing" []
      (stored_shas base_path))
;;

(* A transfer cut short hands the handler the bytes that arrived. Stored,
   they would be a different file under a digest nobody asked for. *)
let test_truncated_upload_is_not_stored () =
  with_upload_router (fun ~base_path ~router ~worker:_ ~admin ->
    ignore
      (dispatch_request ~router ~path:upload_path ~token:admin
         ~content_length:4096 ~body:"only the first few bytes" ());
    Alcotest.(check (list string)) "the partial body stored nothing" []
      (stored_shas base_path);
    match
      A.store_upload ~base_path ~declared:(Some 4096) ~bytes:"only the first few bytes"
    with
    | Error (A.Truncated_upload { declared = 4096; received = 24 }) -> ()
    | Error _ -> Alcotest.fail "a short body was refused for another reason"
    | Ok _ -> Alcotest.fail "a short body was stored")
;;

let () =
  Alcotest.run "artifacts_upload"
    [ ( "upload route"
      , [ Alcotest.test_case "requires an operator credential" `Quick
            test_upload_requires_operator_credential
        ; Alcotest.test_case "stores the exact bytes" `Quick
            test_upload_stores_exact_bytes
        ; Alcotest.test_case "re-upload is idempotent" `Quick
            test_reupload_is_idempotent
        ; Alcotest.test_case "above the artifact limit is 413" `Quick
            test_upload_above_the_artifact_limit_is_413
        ; Alcotest.test_case "not held to the general request cap" `Quick
            test_upload_is_not_held_to_the_general_request_cap
        ; Alcotest.test_case "an empty upload is refused" `Quick
            test_empty_upload_is_refused
        ; Alcotest.test_case "a truncated upload is not stored" `Quick
            test_truncated_upload_is_not_stored
        ] )
    ]
;;
