(** Which lines the tail read of a file answers with
    ([Keeper_memory_recall.read_tail_of_file]).

    The read takes the file's last [max_bytes] bytes. A window that does not
    start at the file's first byte may have cut its first piece, so the read
    drops that piece. Blank lines are passed over after that, so the piece
    that goes is the one the window cut and not a whole line behind a blank
    one.

    The read also stops before [max_bytes] once it has passed more than
    [max_lines] newlines. What it read then starts where its last chunk
    starts, and the piece cut there goes the same way. *)

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

(* The lines the read answers with for a file that holds [content]. *)
let tail_lines content ~max_bytes ~max_lines =
  with_file content
  @@ fun path ->
  match Keeper_memory_recall.read_tail_of_file path ~max_bytes ~max_lines with
  | Ok (Keeper_memory_recall.Tail { Keeper_memory_recall.lines; _ }) -> lines
  | Ok Keeper_memory_recall.No_file -> fail "the file was not found"
  | Error _ -> fail "the file could not be read"
;;

(* The same for the last [max_bytes] bytes, with more lines asked for than
   the file holds. *)
let tail content ~max_bytes = tail_lines content ~max_bytes ~max_lines:100

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

(* A file whose last chunk of the read is [chunk] and which holds four bytes
   before it. The read is given no byte limit (a [max_bytes] of zero) and is
   asked for two lines. [chunk] has more than two newlines, so the read stops
   after that one chunk. *)
let stopped_after_one_chunk chunk = tail_lines ("zero" ^ chunk) ~max_bytes:0 ~max_lines:2

(* One chunk of the read: [starts_with], a long line, [ends_with]. *)
let chunk_of ~starts_with ~ends_with =
  let long_line =
    String.make
      (Keeper_memory_recall.tail_chunk_bytes
       - String.length starts_with
       - String.length ends_with)
      'f'
  in
  long_line, starts_with ^ long_line ^ ends_with
;;

let test_a_read_that_stops_early_drops_the_piece_its_chunk_cut () =
  (* The chunk's first piece is blank. A read that passed over blank pieces
     before the drop would drop the long line in its place. *)
  let long_line, chunk = chunk_of ~starts_with:"\n" ~ends_with:"\n\n\nlast\n" in
  check
    lines
    "a chunk that starts at a newline drops no line"
    [ long_line; "last" ]
    (stopped_after_one_chunk chunk);
  (* Two pieces are not blank and two lines are asked for. A read that kept
     the piece its chunk cut would answer with both. *)
  let long_line, chunk = chunk_of ~starts_with:"o\n" ~ends_with:"\n\n\n" in
  check
    lines
    "a chunk that cuts a line drops what is left of it"
    [ long_line ]
    (stopped_after_one_chunk chunk)
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
        ; test_case
            "a read that stops early drops the piece its chunk cut"
            `Quick
            test_a_read_that_stops_early_drops_the_piece_its_chunk_cut
        ] )
    ]
;;
