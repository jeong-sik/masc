open Alcotest

module Pele = Masc_tui_pele

let with_cache test =
  let directory = Filename.temp_dir "tui-pele-protocol-" "" in
  Fun.protect ~finally:(fun () -> Unix.rmdir directory) (fun () ->
    let result = test directory in
    check int "temporary files were removed" 0 (Array.length (Sys.readdir directory));
    result)

let write path value = Out_channel.with_open_bin path (fun out -> Out_channel.output_string out value)

let scene = Pele.scene ~format:Mermaid ~max_width:640 ~font_size:16
    ~now_ms:0L ~colors:None "graph TD; A-->B"

let run_probe ~cache_dir ~status ~stderr ~stdout =
  let request = ref None in
  let runner ~input ~output ~errors =
    request := Some (Yojson.Safe.from_file input);
    write output stdout;
    write errors stderr;
    status in
  let crop = {Pele.left=0.; top=0.; right=0.5; bottom=0.5} in
  let raster = {Pele.width=320; height=240; crop=Some crop} in
  let result = Pele.render ~cache_dir ~runner ~raster scene in
  result, Option.get !request

let test_confirmed_success () = with_cache (fun cache_dir ->
  let rendered, request = run_probe ~cache_dir ~status:(Unix.WEXITED 0)
      ~stderr:"node startup warning\n" ~stdout:"masc-pele-protocol:1\npng" in
  check (result string string) "confirmed image" (Ok "png") rendered;
  let open Yojson.Safe.Util in
  check int "requested protocol" 1 (request |> member "protocol" |> to_int);
  check string "requested source format" "mermaid" (request |> member "format" |> to_string);
  check int "requested raster width" 320 (request |> member "raster" |> member "width" |> to_int))

let test_unconfirmed_success () = with_cache (fun cache_dir ->
  List.iter (fun stdout ->
    let result, _ = run_probe ~cache_dir ~status:(Unix.WEXITED 0) ~stderr:"" ~stdout in
    check bool "unconfirmed pixels are rejected" true (Result.is_error result))
    ["\137PNG\r\n\026\nold image"; "masc-pele-protocol:1"; "masc-pele-protocol:2\npng";
     "noise\nmasc-pele-protocol:1\npng"])

let test_errors () = with_cache (fun cache_dir ->
  let check_error stdout =
    let result, _ = run_probe ~cache_dir ~status:(Unix.WEXITED 1) ~stderr:"bad diagram\n" ~stdout in
    match result with
    | Error message ->
        check bool "renderer diagnostic is retained" true
          (String.ends_with ~suffix:"bad diagram" message);
        message
    | Ok _ -> fail "failed renderer returned an image" in
  let confirmed = check_error "masc-pele-protocol:1\n" in
  let unconfirmed = check_error "" in
  check bool "renderer failure and unconfirmed helper are distinct" true
    (not (String.equal confirmed unconfirmed));
  let empty, _ = run_probe ~cache_dir ~status:(Unix.WEXITED 0)
      ~stderr:"" ~stdout:"masc-pele-protocol:1\n" in
  check bool "receipt without pixels is rejected" true (Result.is_error empty);
  let signalled, _ = run_probe ~cache_dir ~status:(Unix.WSIGNALED Sys.sigkill)
      ~stderr:"" ~stdout:"masc-pele-protocol:1\npartial image" in
  check bool "signalled renderer is rejected" true (Result.is_error signalled))

let () = run "Pele protocol" ["renderer", [
  test_case "confirmed request" `Quick test_confirmed_success;
  test_case "unconfirmed output" `Quick test_unconfirmed_success;
  test_case "renderer failures" `Quick test_errors;
]]
