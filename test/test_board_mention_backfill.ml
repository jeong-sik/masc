open Alcotest

module Backfill = Masc_board_handlers.Board_mention_backfill

let json_of_rewrite = function
  | Backfill.Line_rewritten line -> Yojson.Safe.from_string line
  | Backfill.Line_unchanged -> fail "expected rewritten line, got unchanged"
  | Backfill.Line_error message -> failf "expected rewritten line, got error: %s" message
;;

let mention_ids json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "mention_ids" fields with
     | Some (`List items) ->
       List.map
         (function
           | `String value -> value
           | other -> failf "unexpected mention id JSON: %s" (Yojson.Safe.to_string other))
         items
     | Some other -> failf "unexpected mention_ids JSON: %s" (Yojson.Safe.to_string other)
     | None -> fail "missing mention_ids")
  | other -> failf "unexpected row JSON: %s" (Yojson.Safe.to_string other)
;;

let check_line_error name = function
  | Backfill.Line_error _ -> ()
  | Backfill.Line_unchanged -> failf "%s: expected error, got unchanged" name
  | Backfill.Line_rewritten line -> failf "%s: expected error, got rewrite %s" name line
;;

let check_unchanged name = function
  | Backfill.Line_unchanged -> ()
  | Backfill.Line_error message -> failf "%s: expected unchanged, got error %s" name message
  | Backfill.Line_rewritten line -> failf "%s: expected unchanged, got rewrite %s" name line
;;

let test_post_line_backfill () =
  let rewritten =
    Backfill.backfill_line ~target:Backfill.Posts
      {|{"id":"p1","title":"For @Alice","body":"email@bob.com @Carol,","content":"fallback"}|}
    |> json_of_rewrite
  in
  check (list string) "post mention ids" [ "alice"; "carol" ] (mention_ids rewritten);
  check_unchanged "post with no explicit tokens"
    (Backfill.backfill_line ~target:Backfill.Posts
       {|{"id":"p2","title":"For alicex","body":"email@alice.com","content":"fallback"}|});
  check_unchanged "already stamped post"
    (Backfill.backfill_line ~target:Backfill.Posts
       {|{"id":"p3","title":"@alice","body":"","content":"","mention_ids":["alice"]}|})
;;

let test_comment_line_backfill () =
  let rewritten =
    Backfill.backfill_line ~target:Backfill.Comments
      {|{"id":"c1","post_id":"p1","content":"(@Alice) @bob"}|}
    |> json_of_rewrite
  in
  check (list string) "comment mention ids" [ "alice"; "bob" ] (mention_ids rewritten);
  check_unchanged "comment with email only"
    (Backfill.backfill_line ~target:Backfill.Comments
       {|{"id":"c2","post_id":"p1","content":"email@alice.com"}|})
;;

let test_line_errors () =
  check_line_error "malformed json"
    (Backfill.backfill_line ~target:Backfill.Posts "not json");
  check_line_error "non object"
    (Backfill.backfill_line ~target:Backfill.Posts {|["not","object"]|});
  check_line_error "missing content"
    (Backfill.backfill_line ~target:Backfill.Posts {|{"id":"p1","title":"@alice"}|});
  check_line_error "malformed existing mention ids"
    (Backfill.backfill_line ~target:Backfill.Posts
       {|{"id":"p1","content":"@alice","mention_ids":[1]}|})
;;

let temp_path name =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-%s-%06x.jsonl" name (Random.bits ()))
;;

let write_lines path lines =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () ->
      List.iter
        (fun line ->
          output_string oc line;
          output_char oc '\n')
        lines)
;;

let read_lines path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let rec loop acc =
        match input_line ic with
        | line -> loop (line :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])
;;

let test_file_backfill_idempotent () =
  let path = temp_path "board-mention-backfill" in
  write_lines path
    [ {|{"id":"p1","title":"@alice","body":"body","content":"body"}|}
    ; {|{"id":"p2","title":"quiet","body":"body","content":"body"}|}
    ];
  let dry = Backfill.backfill_file ~dry_run:true ~target:Backfill.Posts path in
  (match dry with
   | Ok report -> check int "dry run count" 1 report.rewritten
   | Error errors -> failf "dry run failed with %d error(s)" (List.length errors));
  let wet = Backfill.backfill_file ~dry_run:false ~target:Backfill.Posts path in
  (match wet with
   | Ok report -> check int "wet count" 1 report.rewritten
   | Error errors -> failf "wet run failed with %d error(s)" (List.length errors));
  let rows = read_lines path in
  check int "file line count" 2 (List.length rows);
  (match rows with
   | first :: _ ->
     check (list string) "persisted ids" [ "alice" ]
       (mention_ids (Yojson.Safe.from_string first))
   | [] -> fail "expected rewritten file to contain rows");
  let again = Backfill.backfill_file ~dry_run:false ~target:Backfill.Posts path in
  match again with
  | Ok report -> check int "idempotent count" 0 report.rewritten
  | Error errors -> failf "second run failed with %d error(s)" (List.length errors)
;;

let test_file_errors_prevent_rewrite () =
  let path = temp_path "board-mention-backfill-error" in
  let original =
    [ {|{"id":"p1","title":"@alice","body":"body","content":"body"}|}
    ; {|{"id":"p2","content":"@bob","mention_ids":[1]}|}
    ]
  in
  write_lines path original;
  let result = Backfill.backfill_file ~dry_run:false ~target:Backfill.Posts path in
  (match result with
   | Ok _ -> fail "expected file-level error"
   | Error [ { Backfill.line_no; _ } ] -> check int "error line" 2 line_no
   | Error errors -> failf "expected one error, got %d" (List.length errors));
  check (list string) "file preserved on error" original (read_lines path)
;;

let () =
  Random.self_init ();
  run "board_mention_backfill"
    [ ( "line"
      , [ test_case "post" `Quick test_post_line_backfill
        ; test_case "comment" `Quick test_comment_line_backfill
        ; test_case "errors" `Quick test_line_errors
        ] )
    ; ( "file"
      , [ test_case "idempotent" `Quick test_file_backfill_idempotent
        ; test_case "errors prevent rewrite" `Quick test_file_errors_prevent_rewrite
        ] )
    ]
;;
