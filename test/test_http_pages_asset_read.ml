(** [Server_routes_http_pages.read_file] coverage.

    [read_file] backs GraphiQL / Playground static-asset serving.  It was
    migrated from [In_channel.with_open_bin path In_channel.input_all] to
    [Fs_compat.load_file path] so the read is Eio-native (non-blocking on
    the HTTP handler's domain) when the global fs is wired.  These tests
    pin the two invariants that migration must preserve:
    - byte-exact round-trip (asset bundles include binary PNG / woff2);
    - missing file maps to [Error _] (the handler turns it into 404). *)

open Alcotest

module Pages = Masc_mcp.Server_routes_http_pages

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

let () =
  run "http_pages_asset_read"
    [ ( "read_file"
      , [ test_case "binary round-trip" `Quick test_read_file_binary_roundtrip
        ; test_case "empty file" `Quick test_read_file_empty
        ; test_case "missing file -> Error" `Quick test_read_file_missing
        ] )
    ]
;;
