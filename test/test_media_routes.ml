(** HTTP tests for [POST /api/v1/media] and [GET /api/v1/media/<sha256>]. *)

module Media = Server_routes_http_routes_media
module Store = Masc.Keeper_chat_media_store
module Http = Masc.Http_server_eio

let upload_path = Masc_network_defaults.media_upload_path

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv key previous
      | None -> Unix.putenv key "")
    (fun () ->
      Unix.putenv key value;
      f ())
;;

let with_temp_base_path f =
  let dir = Filename.temp_file "masc_media_routes_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cleanup () =
    let rec rm path =
      if Sys.file_exists path
      then
        if Sys.is_directory path
        then (
          Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
          Unix.rmdir path)
        else Unix.unlink path
    in
    try rm dir with
    | _ -> ()
  in
  let r =
    try Ok (f dir) with
    | e -> Error e
  in
  cleanup ();
  match r with
  | Ok v -> v
  | Error e -> raise e
;;

let create_token_exn base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok (raw_token, _) -> raw_token
  | Error error ->
    Alcotest.fail ("create_token failed: " ^ Masc_domain.masc_error_to_string error)
;;

let request_trust_policy =
  match
    Server_request_authority.make_trust_policy
      ~bind_host:"localhost"
      ~bind_port:80
      ~https_port:None
      ~explicit_base_url:None
  with
  | Ok policy -> policy
  | Error error ->
    Alcotest.fail (Server_request_authority.trust_policy_error_to_string error)
;;

let dispatch_raw
      ~router
      ~meth
      ~path
      ?token
      ?origin
      ?content_type
      ?if_none_match
      ?content_length
      ?(body = "")
      ()
  =
  Eio_main.run (fun _env ->
    let output = Buffer.create 1024 in
    let connection =
      Httpun.Server_connection.create (fun reqd ->
        let request = Httpun.Reqd.request reqd in
        let reqd = Masc.Http_reqd.of_httpun reqd in
        match
          Server_request_authority.classify_http1_request
            ~trust_policy:request_trust_policy
            request
        with
        | Server_request_authority.Single authority ->
          Server_request_authority.with_current authority (fun () ->
            Http.Router.dispatch router request reqd)
        | Server_request_authority.Missing
        | Server_request_authority.Multiple
        | Server_request_authority.Malformed
        | Server_request_authority.Untrusted ->
          Alcotest.fail "test request must have an admitted authority")
    in
    let header_lines =
      [ Some "Host: localhost"
      ; Option.map (fun v -> "Authorization: Bearer " ^ v) token
      ; Option.map (fun v -> "Origin: " ^ v) origin
      ; Option.map (fun v -> "Content-Type: " ^ v) content_type
      ; Option.map (fun v -> "If-None-Match: " ^ v) if_none_match
      ; Some
          (Printf.sprintf
             "Content-Length: %d"
             (Option.value content_length ~default:(String.length body)))
      ]
      |> List.filter_map Fun.id
      |> String.concat "\r\n"
    in
    let raw_request = Printf.sprintf "%s %s HTTP/1.1\r\n%s\r\n\r\n%s" meth path header_lines body in
    let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request in
    ignore
      (Httpun.Server_connection.read_eof
         connection
         input
         ~off:0
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

let headers_and_body response =
  let rec find_sep idx =
    if idx + 4 > String.length response
    then Alcotest.failf "no HTTP header separator in %S" response
    else if String.sub response idx 4 = "\r\n\r\n"
    then idx
    else find_sep (idx + 1)
  in
  let sep = find_sep 0 in
  let head = String.sub response 0 sep in
  let body = String.sub response (sep + 4) (String.length response - sep - 4) in
  let lines = String.split_on_char '\n' head |> List.map String.trim in
  let pairs =
    match lines with
    | [] -> []
    | _ :: rest ->
      List.filter_map
        (fun line ->
           match String.index_opt line ':' with
           | None -> None
           | Some colon ->
             let k = String.sub line 0 colon |> String.trim |> String.lowercase_ascii in
             let v =
               String.sub line (colon + 1) (String.length line - colon - 1) |> String.trim
             in
             Some (k, v))
        rest
  in
  Httpun.Headers.of_list pairs, body
;;

let json_of_response response =
  let _, body = headers_and_body response in
  Yojson.Safe.from_string body
;;

let with_media_router f =
  with_temp_base_path (fun base_path ->
    Auth.save_auth_config
      base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let worker = create_token_exn base_path ~agent_name:"media-worker" ~role:Masc_domain.Worker in
    let admin = create_token_exn base_path ~agent_name:"media-admin" ~role:Masc_domain.Admin in
    let saved_state = Server_auth.For_testing.snapshot_server_state () in
    Fun.protect
      ~finally:(fun () -> Server_auth.For_testing.restore_server_state saved_state)
      (fun () ->
         let state = Masc.Mcp_server.For_testing.create_state ~base_path in
         Server_auth.For_testing.restore_server_state (Some state);
         let router = Media.add_routes (Http.Router.create ()) in
         f ~base_path ~state ~router ~worker ~admin))
;;

let png_64x32 =
  "\x89PNG\r\n\x1a\n"
  ^ "\x00\x00\x00\x0dIHDR"
  ^ "\x00\x00\x00\x40\x00\x00\x00\x20"
  ^ "\x08\x02\x00\x00\x00\x00\x00\x00\x00"
;;

let jpeg_16x24 =
  "\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
  ^ "\xff\xc0\x00\x0b\x08\x00\x18\x00\x10\x01\x01\x11\x00\xff\xd9"
;;

let test_upload_auth_and_round_trip () =
  with_media_router (fun ~base_path ~state:_ ~router ~worker ~admin ->
    let anon =
      dispatch_raw ~router ~meth:"POST" ~path:upload_path ~content_type:"image/png" ~body:png_64x32 ()
    in
    Alcotest.(check int) "anonymous POST refused with 401" 401 (status_of_response anon);
    let worker_resp =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:upload_path
        ~token:worker
        ~content_type:"image/png"
        ~body:png_64x32
        ()
    in
    Alcotest.(check int) "Worker POST refused with 403" 403 (status_of_response worker_resp);
    let created =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:upload_path
        ~token:admin
        ~origin:"http://localhost"
        ~content_type:"image/png"
        ~body:png_64x32
        ()
    in
    Alcotest.(check int) "Admin POST succeeds with 201" 201 (status_of_response created);
    let headers, _ = headers_and_body created in
    Alcotest.(check (option string)) "upload response is no-store" (Some "no-store")
      (Httpun.Headers.get headers "cache-control");
    let json = json_of_response created in
    let open Yojson.Safe.Util in
    let expected_sha = Store.sha256_of_bytes png_64x32 in
    Alcotest.(check string) "sha256" expected_sha (json |> member "sha256" |> to_string);
    Alcotest.(check string) "path" ("/api/v1/media/" ^ expected_sha) (json |> member "path" |> to_string);
    Alcotest.(check string) "mime" "image/png" (json |> member "mime" |> to_string);
    Alcotest.(check int) "bytes" (String.length png_64x32) (json |> member "bytes" |> to_int);
    Alcotest.(check int) "width" 64 (json |> member "width" |> to_int);
    Alcotest.(check int) "height" 32 (json |> member "height" |> to_int);
    let reupload =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:upload_path
        ~token:admin
        ~content_type:"image/png"
        ~body:png_64x32
        ()
    in
    Alcotest.(check int) "idempotent re-upload returns 201" 201 (status_of_response reupload);
    Alcotest.(check string) "idempotent sha256 matches" expected_sha
      (json_of_response reupload |> member "sha256" |> to_string);
    let jpg_resp =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:upload_path
        ~token:admin
        ~content_type:"image/jpg"
        ~body:jpeg_16x24
        ()
    in
    Alcotest.(check int) "image/jpg alias accepted for real JPEG" 201 (status_of_response jpg_resp);
    let jpg_json = json_of_response jpg_resp in
    Alcotest.(check string) "canonicalizes to image/jpeg" "image/jpeg"
      (jpg_json |> member "mime" |> to_string);
    Alcotest.(check int) "JPEG width" 16 (jpg_json |> member "width" |> to_int);
    Alcotest.(check int) "JPEG height" 24 (jpg_json |> member "height" |> to_int);
    ignore base_path)
;;

let test_upload_error_envelopes () =
  with_media_router (fun ~base_path ~state:_ ~router ~worker:_ ~admin ->
    let open Yojson.Safe.Util in
    let check_error label expected_status expected_code resp =
      Alcotest.(check int) (label ^ " status") expected_status (status_of_response resp);
      let headers, _ = headers_and_body resp in
      Alcotest.(check (option string)) (label ^ " no-store") (Some "no-store")
        (Httpun.Headers.get headers "cache-control");
      let json = json_of_response resp in
      Alcotest.(check string) (label ^ " code") expected_code (json |> member "code" |> to_string)
    in
    check_error
      "empty upload"
      400
      "empty_upload"
      (dispatch_raw ~router ~meth:"POST" ~path:upload_path ~token:admin ~content_type:"image/png" ~body:"" ());
    check_error
      "svg content-type"
      415
      "svg_not_allowed"
      (dispatch_raw
         ~router
         ~meth:"POST"
         ~path:upload_path
         ~token:admin
         ~content_type:"image/svg+xml"
         ~body:png_64x32
         ());
    check_error
      "svg payload disguised as png"
      415
      "svg_not_allowed"
      (dispatch_raw
         ~router
         ~meth:"POST"
         ~path:upload_path
         ~token:admin
         ~content_type:"image/png"
         ~body:"<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>"
         ());
    check_error
      "mime mismatch"
      415
      "mime_mismatch"
      (dispatch_raw
         ~router
         ~meth:"POST"
         ~path:upload_path
         ~token:admin
         ~content_type:"image/png"
         ~body:jpeg_16x24
         ());
    check_error
      "missing content-type"
      415
      "unsupported_media_type"
      (dispatch_raw ~router ~meth:"POST" ~path:upload_path ~token:admin ~body:png_64x32 ());
    check_error
      "unknown payload bytes"
      415
      "unsupported_media_type"
      (dispatch_raw
         ~router
         ~meth:"POST"
         ~path:upload_path
         ~token:admin
         ~content_type:"image/png"
         ~body:"definitely not a png"
         ());
    with_env "MASC_KEEPER_GENERATED_MEDIA_MAX_BYTES" "16" (fun () ->
      let oversized =
        dispatch_raw
          ~router
          ~meth:"POST"
          ~path:upload_path
          ~token:admin
          ~content_type:"image/png"
          ~body:png_64x32
          ()
      in
      check_error "oversized upload" 413 "media_too_large" oversized;
      Alcotest.(check int) "max_bytes reported" 16
        (json_of_response oversized |> member "max_bytes" |> to_int));
    match
      Media.store_upload
        ~base_path
        ~content_type:(Some "image/png")
        ~declared:(Some 4096)
        ~bytes:png_64x32
    with
    | Error (Media.Truncated_upload { declared = 4096; received }) ->
      Alcotest.(check int) "received bytes" (String.length png_64x32) received
    | Error _ -> Alcotest.fail "expected Truncated_upload"
    | Ok _ -> Alcotest.fail "truncated upload must not succeed")
;;

let test_get_headers_etag_304_and_disposition () =
  with_media_router (fun ~base_path ~state:_ ~router ~worker ~admin ->
    let uploaded =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:upload_path
        ~token:admin
        ~content_type:"image/png"
        ~body:png_64x32
        ()
    in
    let sha = Yojson.Safe.Util.(json_of_response uploaded |> member "sha256" |> to_string) in
    let path = Masc_network_defaults.media_path sha in
    (* GET requires read auth. *)
    Alcotest.(check int) "anonymous GET refused" 401
      (status_of_response (dispatch_raw ~router ~meth:"GET" ~path ~origin:"http://localhost" ()));
    (* Worker can read and receives immutable + security headers + single merged Vary. *)
    let ok_resp =
      dispatch_raw ~router ~meth:"GET" ~path ~token:worker ~origin:"http://localhost" ()
    in
    Alcotest.(check int) "Worker GET returns 200" 200 (status_of_response ok_resp);
    let headers, body = headers_and_body ok_resp in
    Alcotest.(check string) "body matches uploaded PNG" png_64x32 body;
    Alcotest.(check (option string)) "content-type" (Some "image/png")
      (Httpun.Headers.get headers "content-type");
    Alcotest.(check (option string)) "strong ETag" (Some ("\"" ^ sha ^ "\""))
      (Httpun.Headers.get headers "etag");
    Alcotest.(check (option string)) "immutable Cache-Control"
      (Some Media.immutable_cache_control)
      (Httpun.Headers.get headers "cache-control");
    Alcotest.(check (option string)) "nosniff" (Some "nosniff")
      (Httpun.Headers.get headers "x-content-type-options");
    Alcotest.(check (option string)) "CSP sandbox" (Some Media.media_csp)
      (Httpun.Headers.get headers "content-security-policy");
    Alcotest.(check (option string)) "inline Content-Disposition for raster"
      (Some (Printf.sprintf "inline; filename=\"%s.png\"" sha))
      (Httpun.Headers.get headers "content-disposition");
    Alcotest.(check (list string)) "single merged Vary header"
      [ "Origin, Authorization, Cookie" ]
      (Httpun.Headers.get_multi headers "vary");
    Alcotest.(check (option string)) "admitted Origin reflected"
      (Some "http://localhost")
      (Httpun.Headers.get headers "access-control-allow-origin");
    (* If-None-Match -> 304 Not Modified with empty body and preserved headers. *)
    List.iter
      (fun inm ->
         let not_mod =
           dispatch_raw
             ~router
             ~meth:"GET"
             ~path
             ~token:worker
             ~origin:"http://localhost"
             ~if_none_match:inm
             ()
         in
         Alcotest.(check int) ("304 for If-None-Match=" ^ inm) 304 (status_of_response not_mod);
         let h304, b304 = headers_and_body not_mod in
         Alcotest.(check string) "304 body is empty" "" b304;
         Alcotest.(check (option string)) "304 keeps ETag" (Some ("\"" ^ sha ^ "\""))
           (Httpun.Headers.get h304 "etag");
         Alcotest.(check (option string)) "304 keeps Cache-Control"
           (Some Media.immutable_cache_control)
           (Httpun.Headers.get h304 "cache-control");
         Alcotest.(check (option string)) "304 keeps nosniff" (Some "nosniff")
           (Httpun.Headers.get h304 "x-content-type-options");
         Alcotest.(check (option string)) "304 keeps CSP" (Some Media.media_csp)
           (Httpun.Headers.get h304 "content-security-policy");
         Alcotest.(check (list string)) "304 keeps single merged Vary"
           [ "Origin, Authorization, Cookie" ]
           (Httpun.Headers.get_multi h304 "vary");
         Alcotest.(check (option string)) "304 keeps CORS ACAO"
           (Some "http://localhost")
           (Httpun.Headers.get h304 "access-control-allow-origin"))
      [ "\"" ^ sha ^ "\""; "W/\"" ^ sha ^ "\""; "*" ];
    (* Absent token returns 404 even when If-None-Match: * is sent. *)
    let missing_path = Masc_network_defaults.media_path (String.make 64 '0') in
    let not_found =
      dispatch_raw ~router ~meth:"GET" ~path:missing_path ~token:worker ~if_none_match:"*" ()
    in
    Alcotest.(check int) "404 beats If-None-Match *" 404 (status_of_response not_found);
    (* Malformed token returns 400 invalid_token. *)
    let bad =
      dispatch_raw ~router ~meth:"GET" ~path:"/api/v1/media/not-a-sha" ~token:worker ()
    in
    Alcotest.(check int) "malformed token is 400" 400 (status_of_response bad);
    Alcotest.(check string) "malformed token code" "invalid_token"
      Yojson.Safe.Util.(json_of_response bad |> member "code" |> to_string);
    (* PDF gets attachment Content-Disposition; MIDI gets inline. *)
    let pdf_sha, pdf_path =
      match Store.persist_result ~base_dir ~media_type:"application/pdf" ~data:"%PDF-1.7\n%%EOF\n" with
      | Ok pair -> pair
      | Error err -> Alcotest.fail err
    in
    let pdf_resp = dispatch_raw ~router ~meth:"GET" ~path:pdf_path ~token:worker () in
    Alcotest.(check int) "PDF served with 200" 200 (status_of_response pdf_resp);
    let pdf_headers, _ = headers_and_body pdf_resp in
    Alcotest.(check (option string)) "PDF uses attachment disposition"
      (Some (Printf.sprintf "attachment; filename=\"%s.pdf\"" pdf_sha))
      (Httpun.Headers.get pdf_headers "content-disposition");
    let mid_sha, mid_path =
      match Store.persist_result ~base_dir ~media_type:"audio/midi" ~data:"MThd\x00\x00\x00\x06" with
      | Ok pair -> pair
      | Error err -> Alcotest.fail err
    in
    let mid_resp = dispatch_raw ~router ~meth:"GET" ~path:mid_path ~token:worker () in
    Alcotest.(check int) "MIDI served with 200" 200 (status_of_response mid_resp);
    let mid_headers, _ = headers_and_body mid_resp in
    Alcotest.(check (option string)) "MIDI uses inline disposition"
      (Some (Printf.sprintf "inline; filename=\"%s.mid\"" mid_sha))
      (Httpun.Headers.get mid_headers "content-disposition"))
;;

let () =
  Alcotest.run
    "media_routes"
    [ ( "media http routes"
      , [ Alcotest.test_case "upload auth and round-trip" `Quick test_upload_auth_and_round_trip
        ; Alcotest.test_case "upload error envelopes" `Quick test_upload_error_envelopes
        ; Alcotest.test_case
            "GET headers, ETag/304, and Content-Disposition"
            `Quick
            test_get_headers_etag_304_and_disposition
        ] )
    ]
;;
