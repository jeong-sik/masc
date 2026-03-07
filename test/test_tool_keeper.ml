open Alcotest

let with_temp_file contents f =
  let path = Filename.temp_file "keeper-tail" ".log" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      let oc = open_out_bin path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc contents);
      f path)

let test_read_file_tail_lines_drops_partial_first_line () =
  let contents = "AAAAA\nBBBBB\nCCCCC\nDDDDD\n" in
  let len = String.length contents in
  let b_index = String.index contents 'B' in
  let start = b_index + 2 in
  let max_bytes = len - start in
  with_temp_file contents (fun path ->
    let lines = Masc_mcp.Tool_keeper.read_file_tail_lines path ~max_bytes ~max_lines:10 in
    check (list string) "drops partial fragment" ["CCCCC"; "DDDDD"] lines)

let test_read_file_tail_lines_keeps_line_boundary_start () =
  let contents = "AAAAA\nBBBBB\nCCCCC\nDDDDD\n" in
  let len = String.length contents in
  let b_index = String.index contents 'B' in
  let max_bytes = len - b_index in
  with_temp_file contents (fun path ->
    let lines = Masc_mcp.Tool_keeper.read_file_tail_lines path ~max_bytes ~max_lines:10 in
    check (list string) "keeps full first line" ["BBBBB"; "CCCCC"; "DDDDD"] lines)

let () =
  run "Tool_keeper" [
    ("read_file_tail_lines", [
         test_case "drops partial first line" `Quick test_read_file_tail_lines_drops_partial_first_line;
         test_case "keeps line-boundary start" `Quick test_read_file_tail_lines_keeps_line_boundary_start;
       ]);
  ]
