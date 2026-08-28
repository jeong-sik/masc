(** [Server_routes_http_pages.read_file] coverage.

    [read_file] backs GraphiQL / Playground static-asset serving.  It was
    migrated from [In_channel.with_open_bin path In_channel.input_all] to
    [Fs_compat.load_file path] so the read is Eio-native (non-blocking on
    the HTTP handler's domain) when the global fs is wired.  These tests
    pin the two invariants that migration must preserve:
    - byte-exact round-trip (asset bundles include binary PNG / woff2);
    - missing file maps to [Error _] (the handler turns it into 404). *)

open Alcotest

module Pages = Server_routes_http_pages
module Http = Masc.Http_server_eio

external unsetenv : string -> unit = "masc_test_unsetenv"

let with_temp_dir f =
  let dir = Filename.temp_file "masc_http_pages_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree dir) (fun () -> f dir)
;;

let test_read_file_binary_roundtrip () =
  with_temp_dir (fun dir ->
    let path = Filename.concat dir "asset.bin" in
    let payload = String.init 256 Char.chr in
    Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc payload);
    match Pages.read_file path with
    | Ok body -> check string "byte-exact round-trip" payload body
    | Error e -> failf "expected Ok, got Error %s" e)
;;

let test_read_file_empty () =
  with_temp_dir (fun dir ->
    let path = Filename.concat dir "empty.css" in
    Out_channel.with_open_bin path (fun _ -> ());
    match Pages.read_file path with
    | Ok body -> check string "empty file" "" body
    | Error e -> failf "expected Ok, got Error %s" e)
;;

let test_read_file_missing () =
  with_temp_dir (fun dir ->
    let path = Filename.concat dir "does-not-exist.js" in
    match Pages.read_file path with
    | Ok _ -> fail "expected Error for missing file"
    | Error _ -> ())
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> unsetenv name
;;

let with_env vars f =
  let original = List.map (fun (name, _) -> (name, Sys.getenv_opt name)) vars in
  List.iter (fun (name, value) -> Unix.putenv name value) vars;
  Fun.protect f ~finally:(fun () ->
    List.iter (fun (name, value) -> restore_env name value) original)
;;

let expected_dashboard_etag body =
  let hash = Digest.string body |> Digest.to_hex in
  String.sub hash 0 (min Pages.dashboard_etag_hex_chars (String.length hash))
;;

let test_dashboard_etag_of_body_content_hash () =
  let first = Pages.dashboard_etag_of_body "first body" in
  let second = Pages.dashboard_etag_of_body "second body" in
  check string "matches content digest" (expected_dashboard_etag "first body") first;
  check bool "changes when content changes" true (not (String.equal first second))
;;

let http1_dashboard_asset_response path =
  let router =
    Server_routes_http_routes_frontend.add_routes
      ~port:8935
      (Http.Router.create ())
  in
  let response_buf = Buffer.create 256 in
  let conn =
    Httpun.Server_connection.create (fun reqd ->
      Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
  in
  let request =
    Printf.sprintf "GET %s HTTP/1.1\r\nHost: 127.0.0.1:8935\r\n\r\n" path
  in
  let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
  let rec feed off =
    let remaining = Bigstringaf.length bytes - off in
    if remaining > 0 then begin
      let consumed = Httpun.Server_connection.read conn bytes ~off ~len:remaining in
      if consumed <= 0 then fail "HTTP/1 test connection made no read progress";
      feed (off + consumed)
    end
  in
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
  feed 0;
  flush ();
  let response = Buffer.contents response_buf in
  let body_offset =
    try Some (Str.search_forward (Str.regexp_string "\r\n\r\n") response 0 + 4)
    with Not_found -> None
  in
  match String.split_on_char ' ' response, body_offset with
  | _version :: code :: _, Some offset ->
    int_of_string code, String.sub response offset (String.length response - offset)
  | _ -> failf "invalid HTTP/1 response: %S" response
;;

let http2_dashboard_asset_response path =
  let status = ref None in
  let response_body = Buffer.create 256 in
  let body_complete = ref false in
  let connection_error = ref false in
  let stream_error = ref false in
  let client =
    H2.Client_connection.create
      ~error_handler:(fun _ -> connection_error := true)
      ()
  in
  let request =
    H2.Request.create
      ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1:8935" ])
      ~scheme:"http"
      `GET
      path
  in
  let request_body =
    H2.Client_connection.request
      client
      request
      ~error_handler:(fun _ -> stream_error := true)
      ~response_handler:(fun response body ->
        status := Some (H2.Status.to_code response.H2.Response.status);
        let rec consume () =
          H2.Body.Reader.schedule_read
            body
            ~on_eof:(fun () -> body_complete := true)
            ~on_read:(fun buffer ~off ~len ->
              Buffer.add_string
                response_body
                (Bigstringaf.substring buffer ~off ~len);
              consume ())
        in
        consume ())
  in
  H2.Body.Writer.close request_body;
  let server =
    H2.Server_connection.create (fun h2_reqd ->
      let h2_request = H2.Reqd.request h2_reqd in
      let httpun_request =
        Httpun.Request.create
          ~headers:
            (Httpun.Headers.of_list (H2.Headers.to_list h2_request.headers))
          `GET
          h2_request.target
      in
      let handled =
        Server_h2_gateway_routes_extra.dispatch
          ~h2_reqd
          ~httpun_request
          ~cors:[]
          ~path:h2_request.target
          ~config:None
          ~with_public_read:(fun f -> f ())
          `GET
      in
      if not handled then failf "HTTP/2 route was not handled: %s" path)
  in
  let transfer next_write report_write read =
    let rec drain progressed =
      match next_write () with
      | `Write iovecs ->
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t H2.IOVec.t) ->
               let rec feed off remaining =
                 if remaining > 0 then begin
                   let consumed = read iov.buffer ~off ~len:remaining in
                   if consumed <= 0 then
                     fail "HTTP/2 in-memory connection made no read progress";
                   feed (off + consumed) (remaining - consumed)
                 end
               in
               feed iov.off iov.len;
               total + iov.len)
            0
            iovecs
        in
        report_write (`Ok written);
        drain true
      | `Yield | `Close _ -> progressed
    in
    drain false
  in
  let rec pump () =
    let client_progress =
      transfer
        (fun () -> H2.Client_connection.next_write_operation client)
        (H2.Client_connection.report_write_result client)
        (H2.Server_connection.read server)
    in
    let server_progress =
      transfer
        (fun () -> H2.Server_connection.next_write_operation server)
        (H2.Server_connection.report_write_result server)
        (H2.Client_connection.read client)
    in
    if !body_complete then ()
    else if client_progress || server_progress then pump ()
    else fail "HTTP/2 in-memory connection stalled before response completion"
  in
  pump ();
  check bool "no HTTP/2 connection error" false !connection_error;
  check bool "no HTTP/2 stream error" false !stream_error;
  match !status with
  | Some code -> code, Buffer.contents response_body
  | None -> fail "HTTP/2 response did not include a status"
;;

let with_dashboard_asset_tree f =
  with_temp_dir (fun assets ->
    let asset_dir = Filename.concat assets "dashboard/assets" in
    Fs_compat.mkdir_p asset_dir;
    with_env [ "MASC_ASSETS_DIR", assets ] (fun () -> f asset_dir))
;;

let test_dashboard_static_missing_statuses () =
  with_dashboard_asset_tree (fun _asset_dir ->
    let h1_status, _ =
      http1_dashboard_asset_response "/dashboard/assets/missing.js"
    in
    let h2_status, _ =
      http2_dashboard_asset_response "/dashboard/assets/missing.js"
    in
    check int "HTTP/1 missing asset" 404
      h1_status;
    check int "HTTP/2 missing asset" 404
      h2_status)
;;

let test_dashboard_static_read_error_statuses () =
  with_dashboard_asset_tree (fun asset_dir ->
    Unix.mkdir (Filename.concat asset_dir "broken.js") 0o755;
    let h1_status, h1_body =
      http1_dashboard_asset_response "/dashboard/assets/broken.js"
    in
    let h2_status, h2_body =
      http2_dashboard_asset_response "/dashboard/assets/broken.js"
    in
    check int "HTTP/1 asset read error" 503
      h1_status;
    check int "HTTP/2 asset read error" 503
      h2_status;
    List.iter
      (fun (protocol, body) ->
        check bool
          (protocol ^ " points to typed health recovery")
          true
          (String_util.contains_substring body "/health dashboard_surface.recovery"))
      [ "HTTP/1", h1_body; "HTTP/2", h2_body ])
;;

let test_with_env_restores_missing_env_as_unset () =
  let name = "MASC_HTTP_PAGES_TEST_RESTORE_ENV" in
  unsetenv name;
  with_env [ name, "temporary" ] (fun () ->
    check (option string) "set in body" (Some "temporary") (Sys.getenv_opt name));
  check (option string) "unset after body" None (Sys.getenv_opt name)
;;

let () =
  run "http_pages_asset_read"
    [ ( "read_file"
      , [ test_case "binary round-trip" `Quick test_read_file_binary_roundtrip
        ; test_case "empty file" `Quick test_read_file_empty
        ; test_case "missing file -> Error" `Quick test_read_file_missing
        ] )
    ; ( "dashboard_assets"
      , [ test_case
            "H1/H2 missing static asset -> 404"
            `Quick
            test_dashboard_static_missing_statuses
        ; test_case
            "H1/H2 static asset read error -> 503"
            `Quick
            test_dashboard_static_read_error_statuses
        ] )
    ; ( "dashboard_etag"
      , [ test_case "body content hash" `Quick test_dashboard_etag_of_body_content_hash
        ] )
    ; ( "env_helper"
      , [ test_case "missing env restored as unset" `Quick
            test_with_env_restores_missing_env_as_unset
        ] )
    ]
;;
