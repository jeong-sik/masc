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

let test_dashboard_asset_root_uses_env_assets_dir () =
  with_temp_dir (fun assets ->
    with_env [ "MASC_ASSETS_DIR", assets ] (fun () ->
      let dashboard = Filename.concat assets "dashboard" in
      check string "dashboard asset root" dashboard (Pages.dashboard_asset_root ());
      check
        string
        "dashboard index path"
        (Filename.concat dashboard "index.html")
        (Pages.dashboard_index_path ())))
;;

let test_dashboard_etag_of_body_content_hash () =
  let first = Pages.dashboard_etag_of_body "first body" in
  let second = Pages.dashboard_etag_of_body "second body" in
  check string "matches content digest" (expected_dashboard_etag "first body") first;
  check bool "changes when content changes" true (not (String.equal first second))
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
            "asset root follows MASC_ASSETS_DIR"
            `Quick
            test_dashboard_asset_root_uses_env_assets_dir
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
