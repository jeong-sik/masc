(* The TUI's stream readers get a server-sent event stream in whatever pieces
   the socket read returned. A line is returned only when its newline arrives,
   whole and once, whatever the pieces were. *)

let lines = Alcotest.(list string)

let feed_all reader chunks = List.concat_map (Masc_tui_sse_lines.feed reader) chunks

let test_a_line_over_several_chunks_comes_back_once () =
  let reader = Masc_tui_sse_lines.create () in
  Alcotest.check lines "no line has ended" [] (feed_all reader [ "da"; "ta: {\"a\""; ":1}" ]);
  Alcotest.check lines "the newline ends it" [ "data: {\"a\":1}" ]
    (Masc_tui_sse_lines.feed reader "\n")
;;

let test_lines_in_one_chunk_keep_their_order_and_the_tail_waits () =
  let reader = Masc_tui_sse_lines.create () in
  Alcotest.check lines "the ended lines" [ "id: 3"; "data: x" ]
    (Masc_tui_sse_lines.feed reader "id: 3\ndata: x\nda");
  Alcotest.check lines "the held tail joins the next chunk" [ "data: y"; "" ]
    (Masc_tui_sse_lines.feed reader "ta: y\n\n")
;;

(* A blank line ends an SSE frame, so it must come back as a line of its own;
   the frame decoder, not this reader, decides what a ['\r'] means. *)
let test_empty_lines_and_carriage_returns_are_kept () =
  let reader = Masc_tui_sse_lines.create () in
  Alcotest.check lines "as they were" [ "a"; ""; "b\r"; "\r" ]
    (Masc_tui_sse_lines.feed reader "a\n\nb\r\n\r\n")
;;

(* Every way of cutting [text] into chunks: [cuts] is a bit mask over the
   positions between bytes. *)
let chunkings text =
  let length = String.length text in
  let positions = Int.max 0 (length - 1) in
  List.init (1 lsl positions) (fun cuts ->
    let rec pieces start index acc =
      if index >= length
      then List.rev (String.sub text start (length - start) :: acc)
      else if index > 0 && cuts land (1 lsl (index - 1)) <> 0
      then pieces index (index + 1) (String.sub text start (index - start) :: acc)
      else pieces start (index + 1) acc
    in
    pieces 0 0 [])
;;

(* Fed in any pieces and then ended with a newline, a text comes back as the
   lines [String.split_on_char] finds in it. *)
let test_any_chunking_gives_the_same_lines () =
  List.iter
    (fun text ->
       let expected = String.split_on_char '\n' text in
       List.iter
         (fun chunks ->
            let reader = Masc_tui_sse_lines.create () in
            let returned = feed_all reader (chunks @ [ "\n" ]) in
            Alcotest.check lines
              (Printf.sprintf "%S in %d pieces" text (List.length chunks))
              expected returned)
         (chunkings text))
    [ ""; "\n"; "\n\n"; "a"; "ab\ncd"; "a\n\nb\r\n"; "id: 3\ndata: x\n\n"; "\n\nlast" ]
;;

(* A whole-projection snapshot is one data line of several hundred kilobytes
   that the socket delivers in pieces of at most a read buffer. *)
let test_a_long_line_in_small_pieces_comes_back_once () =
  let payload = String.make (1024 * 1024) 'x' in
  let line = "data: " ^ payload in
  let piece = 64 in
  let reader = Masc_tui_sse_lines.create () in
  let rec send offset returned =
    if offset >= String.length line
    then returned
    else (
      let length = Int.min piece (String.length line - offset) in
      send (offset + length)
        (returned @ Masc_tui_sse_lines.feed reader (String.sub line offset length)))
  in
  Alcotest.check lines "nothing before the newline" [] (send 0 []);
  match Masc_tui_sse_lines.feed reader "\nid: 4\n" with
  | [ whole; next ] ->
    Alcotest.check Alcotest.int "the whole line" (String.length line) (String.length whole);
    Alcotest.check Alcotest.bool "with its bytes" true (String.equal line whole);
    Alcotest.check Alcotest.string "and the next line starts clean" "id: 4" next
  | returned -> Alcotest.failf "expected two lines, got %d" (List.length returned)
;;

let () =
  Alcotest.run "tui sse lines"
    [ ( "feed"
      , [ Alcotest.test_case "a line over several chunks comes back once" `Quick
            test_a_line_over_several_chunks_comes_back_once
        ; Alcotest.test_case "lines in one chunk keep their order" `Quick
            test_lines_in_one_chunk_keep_their_order_and_the_tail_waits
        ; Alcotest.test_case "empty lines and carriage returns are kept" `Quick
            test_empty_lines_and_carriage_returns_are_kept
        ; Alcotest.test_case "any chunking gives the same lines" `Quick
            test_any_chunking_gives_the_same_lines
        ; Alcotest.test_case "a long line in small pieces comes back once" `Quick
            test_a_long_line_in_small_pieces_comes_back_once
        ] )
    ]
;;
