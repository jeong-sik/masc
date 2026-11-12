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
      (Http.Router.create ())
  in
  let response_buf = Buffer.create 256 in
  let conn =
    Httpun.Server_connection.create (fun reqd ->
      Http.Router.dispatch router (Httpun.Reqd.request reqd) (Masc.Http_reqd.of_httpun reqd))
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
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let ledger =
    Masc.Http_h2_response_ledger.create
      ~max_pending_bytes:H2_response_limits.default_max_pending_bytes
  in
  Masc.Http_h2_response_ledger.with_request ledger ~sw @@ fun () ->
  let router =
    Server_routes_http_routes_frontend.add_routes
      (Http.Router.create ())
  in
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
      (* The asset is answered at once, far inside the 90 s bound. *)
      let stream_end =
        Masc.Http_h2_stream.Stream_end.create
          ~stream_sw:sw
          ~clock:(Eio.Stdenv.clock env)
          ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
          ~request:(H2.Reqd.request h2_reqd)
          h2_reqd
      in
      let reqd =
        Masc.Http_reqd.of_h2
          ~stream_end
          ~ledger:(Masc.Http_h2_response_ledger.current_exn ())
          h2_reqd
      in
      Http.Router.dispatch router (Masc.Http_reqd.request reqd) reqd)
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

let test_report_snapshots_are_not_public_assets () =
  with_dashboard_asset_tree (fun asset_dir ->
    let snapshots = Filename.concat asset_dir "published-artifacts" in
    Unix.mkdir snapshots 0o755;
    let name = "artifact-0123456789abcdef0123456789abcdef-r1.json" in
    let snapshot = Filename.concat snapshots name in
    Out_channel.with_open_bin snapshot
      (fun oc -> Out_channel.output_string oc "private snapshot");
    Out_channel.with_open_bin (Filename.concat asset_dir "bundle.js")
      (fun oc -> Out_channel.output_string oc "dashboard asset");
    let nested = Filename.concat asset_dir "nested" in
    Unix.mkdir nested 0o755;
    Out_channel.with_open_bin (Filename.concat nested "bundle.js")
      (fun oc -> Out_channel.output_string oc "nested dashboard asset");
    Unix.symlink snapshots (Filename.concat asset_dir "snapshot-directory");
    Unix.symlink snapshot (Filename.concat asset_dir "snapshot-file.json");
    Unix.symlink snapshot (Filename.concat nested "snapshot.json");
    Unix.link snapshot (Filename.concat asset_dir "snapshot-hardlink.json");
    let private_paths =
      [ "/dashboard/assets/published-artifacts/" ^ name
      ; "/dashboard/assets/Published-Artifacts/" ^ name
      ; "/dashboard/assets/publiſhed-artifacts/" ^ name
      ; "/dashboard/assets/snapshot-directory/" ^ name
      ; "/dashboard/assets/snapshot-file.json"
      ; "/dashboard/assets/nested/snapshot.json"
      ; "/dashboard/assets/snapshot-hardlink.json"
      ] in
    List.iter (fun (protocol, request) ->
      List.iter (fun path ->
        let status, body = request path in
        check bool (protocol ^ " refuses " ^ path) true (status = 404 || status = 503);
        check bool (protocol ^ " does not return snapshot bytes for " ^ path) false
          (String_util.contains_substring body "private snapshot")) private_paths;
      List.iter (fun (path, expected) ->
        let status, body = request path in
        check int (protocol ^ " still serves " ^ path) 200 status;
        check string (protocol ^ " returns the asset bytes") expected body)
        [ "/dashboard/assets/bundle.js", "dashboard asset"
        ; "/dashboard/assets/nested/bundle.js", "nested dashboard asset" ])
      [ "HTTP/1", http1_dashboard_asset_response; "HTTP/2", http2_dashboard_asset_response ])
;;

let test_report_snapshot_exclusion_uses_directory_identity () =
  with_dashboard_asset_tree (fun asset_dir ->
    let snapshots = Filename.concat asset_dir "published-artifacts" in
    Unix.mkdir snapshots 0o755;
    Out_channel.with_open_bin (Filename.concat snapshots "snapshot.json")
      (fun oc -> Out_channel.output_string oc "private snapshot");
    let relative components = match Fs_compat.owned_relative_path components with
      | Ok path -> path | Error detail -> fail detail in
    let excluded = relative ["assets"; "published-artifacts"] in
    let read components =
      Fs_compat.load_single_link_regular_file_beneath
        ~root:(Filename.dirname asset_dir) ~excluded_directory:excluded (relative components) in
    check bool "the held protected directory is never read" true
      (Result.is_error (read ["assets"; "published-artifacts"; "snapshot.json"]));
    (* On case-insensitive filesystems long s can name the same directory even
       when the request uses a different spelling. Exercise that real alias. *)
    if Sys.file_exists (Filename.concat asset_dir "publiſhed-artifacts") then
      check bool "a Unicode alias of the protected directory is refused" true
        (Result.is_error (read ["assets"; "publiſhed-artifacts"; "snapshot.json"])))
;;

let relative_path components =
  match Fs_compat.owned_relative_path components with
  | Ok path -> path
  | Error detail -> fail detail
;;

let write_file path body =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc body)
;;

(* A new file under the name, as a build writes one: the bytes are written
   beside it and renamed over it. *)
let replace_file path body =
  let staged = path ^ ".staged" in
  write_file staged body;
  Unix.rename staged path
;;

let loaded_contents ~root components =
  match Fs_compat.load_single_link_regular_file_beneath ~root (relative_path components) with
  | Ok (Some contents) -> contents
  | Ok None -> fail "the file was not found"
  | Error error -> fail (Fs_compat.owned_regular_file_read_error_to_string error)
;;

let reread =
  testable
    (fun fmt -> function
       | Fs_compat.Same_file -> Format.pp_print_string fmt "Same_file"
       | Fs_compat.Read contents -> Format.fprintf fmt "Read %S" contents.Fs_compat.content)
    (fun left right ->
       match left, right with
       | Fs_compat.Same_file, Fs_compat.Same_file -> true
       | Fs_compat.Read left, Fs_compat.Read right ->
         String.equal left.Fs_compat.content right.Fs_compat.content
       | Fs_compat.Same_file, Fs_compat.Read _ | Fs_compat.Read _, Fs_compat.Same_file -> false)
;;

(* What a reload answers, with the bytes alone standing for a read. *)
let reloaded ~root ~held components =
  match
    Fs_compat.reload_single_link_regular_file_beneath ~root ~held (relative_path components)
  with
  | Ok (Some answer) -> answer
  | Ok None -> fail "the file was not found"
  | Error error -> fail (Fs_compat.owned_regular_file_read_error_to_string error)
;;

let read_of body =
  (* Only the bytes are compared, so any snapshot stands here. *)
  fun (held : Fs_compat.owned_regular_file_snapshot) ->
    Fs_compat.Read { Fs_compat.content = body; snapshot = held }
;;

let test_reload_does_not_read_the_file_it_holds () =
  with_temp_dir (fun root ->
    write_file (Filename.concat root "kept.js") "kept bytes";
    let held = (loaded_contents ~root [ "kept.js" ]).Fs_compat.snapshot in
    check reread "the file is as it was" Fs_compat.Same_file (reloaded ~root ~held [ "kept.js" ]))
;;

let test_reload_reads_a_replaced_file () =
  with_temp_dir (fun root ->
    let path = Filename.concat root "bundle.js" in
    write_file path "first bytes";
    let held = (loaded_contents ~root [ "bundle.js" ]).Fs_compat.snapshot in
    replace_file path "bytes of a new file";
    check
      reread
      "a new file under the name"
      (read_of "bytes of a new file" held)
      (reloaded ~root ~held [ "bundle.js" ]))
;;

let test_reload_reads_a_file_written_to_another_length () =
  with_temp_dir (fun root ->
    let path = Filename.concat root "index.html" in
    write_file path "short";
    let held = (loaded_contents ~root [ "index.html" ]).Fs_compat.snapshot in
    write_file path "written in place, longer";
    check int "the write kept the inode" held.Fs_compat.inode (Unix.stat path).Unix.st_ino;
    check
      reread
      "the same inode with another length"
      (read_of "written in place, longer" held)
      (reloaded ~root ~held [ "index.html" ]))
;;

let test_reload_keeps_the_checks_of_the_load () =
  with_temp_dir (fun root ->
    let path = Filename.concat root "linked.js" in
    write_file path "linked bytes";
    let held = (loaded_contents ~root [ "linked.js" ]).Fs_compat.snapshot in
    Unix.link path (Filename.concat root "second-name.js");
    check bool "a second hard link is refused" true
      (Result.is_error
         (Fs_compat.reload_single_link_regular_file_beneath
            ~root ~held (relative_path [ "linked.js" ])));
    let snapshots = Filename.concat root "published-artifacts" in
    Unix.mkdir snapshots 0o755;
    write_file (Filename.concat snapshots "snapshot.json") "private snapshot";
    let held =
      (loaded_contents ~root [ "published-artifacts"; "snapshot.json" ]).Fs_compat.snapshot
    in
    check bool "the excluded directory is refused to a caller that holds its file" true
      (Result.is_error
         (Fs_compat.reload_single_link_regular_file_beneath
            ~root
            ~excluded_directory:(relative_path [ "published-artifacts" ])
            ~held
            (relative_path [ "published-artifacts"; "snapshot.json" ]))))
;;

let test_dashboard_static_serves_a_replaced_asset () =
  with_dashboard_asset_tree (fun asset_dir ->
    List.iter
      (fun (protocol, name, request) ->
         let path = Filename.concat asset_dir name in
         let url = "/dashboard/assets/" ^ name in
         write_file path "first asset bytes";
         check (pair int string) (protocol ^ " first request") (200, "first asset bytes") (request url);
         check (pair int string) (protocol ^ " file as it was") (200, "first asset bytes") (request url);
         replace_file path "the asset after a rebuild";
         check
           (pair int string)
           (protocol ^ " new file under the name")
           (200, "the asset after a rebuild")
           (request url))
      [ "HTTP/1", "reread-h1.js", http1_dashboard_asset_response
      ; "HTTP/2", "reread-h2.js", http2_dashboard_asset_response
      ])
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
        ; test_case
            "H1/H2 refuse static report snapshots"
            `Quick
            test_report_snapshots_are_not_public_assets
        ; test_case
            "snapshot exclusion uses directory identity"
            `Quick
            test_report_snapshot_exclusion_uses_directory_identity
        ; test_case
            "H1/H2 serve a replaced asset"
            `Quick
            test_dashboard_static_serves_a_replaced_asset
        ] )
    ; ( "reload"
      , [ test_case "the held file is not read" `Quick test_reload_does_not_read_the_file_it_holds
        ; test_case "a replaced file is read" `Quick test_reload_reads_a_replaced_file
        ; test_case
            "a file written to another length is read"
            `Quick
            test_reload_reads_a_file_written_to_another_length
        ; test_case "the checks of the load stay" `Quick test_reload_keeps_the_checks_of_the_load
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
