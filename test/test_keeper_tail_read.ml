(** Which lines the tail read of a file answers with
    ([Keeper_memory_recall.read_tail_of_file]).

    The read takes the file's last [max_bytes] bytes. A window that does not
    start at the file's first byte may have cut its first piece, so the read
    drops that piece. Blank lines are passed over after that, so the piece
    that goes is the one the window cut and not a whole line behind a blank
    one. *)

open Alcotest
open Masc

let with_file content f =
  let path = Filename.temp_file "keeper_tail_read_" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
       Out_channel.with_open_bin path (fun channel -> output_string channel content);
       f path)
;;

(* The lines the read answers with for the last [max_bytes] bytes of a file
   that holds [content]. *)
let tail content ~max_bytes =
  with_file content
  @@ fun path ->
  match Keeper_memory_recall.read_tail_of_file path ~max_bytes ~max_lines:100 with
  | Ok (Keeper_memory_recall.Tail { Keeper_memory_recall.lines; _ }) -> lines
  | Ok Keeper_memory_recall.No_file -> fail "the file was not found"
  | Error _ -> fail "the file could not be read"
;;

let lines = list string

(* The read does not look at the byte before its window, so it cannot tell a
   window that starts at a line's first byte from one that cut the line. *)
let test_which_piece_the_read_drops () =
  let content = "one\ntwo\nthree\n" in
  check
    lines
    "a window from the file's first byte drops nothing"
    [ "one"; "two"; "three" ]
    (tail content ~max_bytes:(String.length content));
  check
    lines
    "a window that cuts a line drops what is left of it"
    [ "three" ]
    (tail content ~max_bytes:(String.length "o\nthree\n"));
  check
    lines
    "a window that starts at a newline drops no line"
    [ "three" ]
    (tail content ~max_bytes:(String.length "\nthree\n"));
  check
    lines
    "a window that starts at a line's first byte drops that line"
    []
    (tail content ~max_bytes:(String.length "three\n"))
;;

let test_blank_lines_are_passed_over_after_the_drop () =
  let content = "one\n  \n\ntwo\n" in
  check
    lines
    "the blank lines of a whole file"
    [ "one"; "two" ]
    (tail content ~max_bytes:(String.length content));
  check
    lines
    "a window cut inside a blank line keeps the line after it"
    [ "two" ]
    (tail content ~max_bytes:(String.length " \n\ntwo\n"))
;;

let () =
  run
    "keeper_tail_read"
    [ ( "the piece a tail read drops"
      , [ test_case "which piece the read drops" `Quick test_which_piece_the_read_drops
        ; test_case
            "blank lines are passed over after the drop"
            `Quick
            test_blank_lines_are_passed_over_after_the_drop
        ] )
    ]
;;
