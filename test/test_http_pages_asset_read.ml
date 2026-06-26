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

let with_temp_dir f =
  let dir = Filename.temp_file "masc_http_pages_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun n -> try Sys.remove (Filename.concat dir n) with _ -> ()) (Sys.readdir dir);
      try Unix.rmdir dir with _ -> ())
    (fun () -> f dir)
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
  | None -> Unix.putenv name ""
;;

let with_env vars f =
  let original = List.map (fun (name, _) -> (name, Sys.getenv_opt name)) vars in
  List.iter (fun (name, value) -> Unix.putenv name value) vars;
  Fun.protect f ~finally:(fun () ->
    List.iter (fun (name, value) -> restore_env name value) original)
;;

let write_file path contents =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc contents)
;;

let with_temp_dashboard f =
  with_temp_dir (fun dir ->
    let assets = Filename.concat dir "assets" in
    let dashboard = Filename.concat assets "dashboard" in
    Unix.mkdir assets 0o755;
    Unix.mkdir dashboard 0o755;
    Fun.protect
      (fun () -> f ~assets ~dashboard)
      ~finally:(fun () ->
        let index = Filename.concat dashboard "index.html" in
        if Sys.file_exists index then Sys.remove index;
        if Sys.file_exists dashboard then Unix.rmdir dashboard;
        if Sys.file_exists assets then Unix.rmdir assets))
;;

let short_digest body =
  String.sub (Digest.to_hex (Digest.string body)) 0 12
;;

let test_dashboard_etag_of_body_content_hash () =
  let first = Pages.dashboard_etag_of_body "first body" in
  let second = Pages.dashboard_etag_of_body "second body" in
  check string "matches content digest" (short_digest "first body") first;
  check bool "changes when content changes" true (not (String.equal first second))
;;

let test_dashboard_etag_reads_index_content () =
  with_temp_dashboard (fun ~assets ~dashboard ->
    with_env [ "MASC_ASSETS_DIR", assets ] (fun () ->
      let body = "<!doctype html><title>content-etag</title>" in
      write_file (Filename.concat dashboard "index.html") body;
      check string "index content digest" (short_digest body) (Pages.dashboard_etag ())))
;;

let () =
  run "http_pages_asset_read"
    [ ( "read_file"
      , [ test_case "binary round-trip" `Quick test_read_file_binary_roundtrip
        ; test_case "empty file" `Quick test_read_file_empty
        ; test_case "missing file -> Error" `Quick test_read_file_missing
        ] )
    ; ( "dashboard_etag"
      , [ test_case "body content hash" `Quick test_dashboard_etag_of_body_content_hash
        ; test_case "index content hash" `Quick test_dashboard_etag_reads_index_content
        ] )
    ]
;;
