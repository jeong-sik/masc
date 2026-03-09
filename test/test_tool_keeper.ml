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

let rec cleanup_dir path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun entry -> cleanup_dir (Filename.concat path entry));
      Unix.rmdir path
    end else
      Sys.remove path

let temp_dir () =
  Filename.temp_file "keeper-test" ""
  |> fun path ->
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

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

let test_keeper_inbox_dedup_and_ack () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      let keeper_name = "reactive-keeper" in
      let item_a : Masc_mcp.Tool_keeper.keeper_inbox_item =
        {
          event_id = "event-a";
          source = "board_post";
          created_at = 10.0;
          summary = "first";
          payload = `Assoc [ ("post_id", `String "p-1") ];
        }
      in
      let item_b : Masc_mcp.Tool_keeper.keeper_inbox_item =
        {
          event_id = "event-b";
          source = "board_post";
          created_at = 20.0;
          summary = "second";
          payload = `Assoc [ ("post_id", `String "p-2") ];
        }
      in
      match
        Masc_mcp.Tool_keeper.enqueue_keeper_inbox_items config ~keeper_name
          ~items:[ item_a; item_b; item_a ]
      with
      | Error msg -> fail msg
      | Ok fresh ->
          check int "dedup keeps two items" 2 fresh;
          (match Masc_mcp.Tool_keeper.read_keeper_inbox config keeper_name with
          | Error msg -> fail msg
          | Ok items ->
              check int "stored item count" 2 (List.length items);
              check (option string) "latest summary"
                (Some "second")
                (Masc_mcp.Tool_keeper.keeper_inbox_summary items);
              (match
                 Masc_mcp.Tool_keeper.ack_keeper_inbox_items config ~keeper_name
                   ~event_ids:[ "event-a" ]
               with
              | Error msg -> fail msg
              | Ok removed ->
                  check int "removed one item" 1 removed;
                  match Masc_mcp.Tool_keeper.read_keeper_inbox config keeper_name with
                  | Error msg -> fail msg
                  | Ok remaining ->
                      check int "remaining item count" 1 (List.length remaining);
                      check string "remaining event id" "event-b"
                        (List.hd remaining).event_id)))

let () =
  run "Tool_keeper" [
    ("read_file_tail_lines", [
         test_case "drops partial first line" `Quick test_read_file_tail_lines_drops_partial_first_line;
         test_case "keeps line-boundary start" `Quick test_read_file_tail_lines_keeps_line_boundary_start;
         test_case "keeper inbox dedup and ack" `Quick test_keeper_inbox_dedup_and_ack;
       ]);
  ]
