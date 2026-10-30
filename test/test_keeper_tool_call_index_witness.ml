(* The continuity witness of [Keeper_tool_call_index] against the definition
   it had when continuity records were first written to disk: each link is
   SHA-256 of the previous link's hex, the line, and "\n", and a prefix is
   read line by line with [input_line]. A record saved by that code must still
   match, so every answer here is compared with that reading. *)

module Witness = Keeper_tool_call_index.For_testing

let reference_extend digest line =
  Agent_core_sha256.(to_hex (digest_string (digest ^ line ^ "\n")))

let reference_prefix ~path ~from ~until digest =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
    seek_in channel from;
    let rec loop digest =
      let offset = pos_in channel in
      if offset = until then Some digest
      else if offset > until then None
      else
        match input_line channel with
        | line -> loop (reference_extend digest line)
        | exception End_of_file -> None
    in
    loop digest)

let with_file contents f =
  let path = Filename.temp_file "tool-call-witness" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
      Out_channel.with_open_bin path (fun channel ->
        Out_channel.output_string channel contents);
      f path)

(* Lines long enough to cross the reader's buffer, which is the case a line
   reader most easily gets wrong. *)
let long_line_bytes = 70_000

let line_bytes_choices = [| 0; 1; 7; 80; 1_500; 65_535; 65_536; long_line_bytes |]

(* Every byte but the newline, so lines carry carriage returns, NULs and
   bytes past ASCII. *)
let random_line state =
  let length =
    line_bytes_choices.(Random.State.int state (Array.length line_bytes_choices))
  in
  String.init length (fun _ ->
    let byte = Random.State.int state 255 in
    Char.chr (if byte >= Char.code '\n' then byte + 1 else byte))

let random_contents state =
  let lines = List.init (Random.State.int state 12) (fun _ -> random_line state) in
  let joined = String.concat "\n" lines in
  (* Half the files end in a newline; the rest leave the final line open. *)
  if lines <> [] && Random.State.bool state then joined ^ "\n" else joined

(* Where a line starts, plus the end of the file. *)
let line_starts contents =
  let starts = ref [ 0 ] in
  String.iteri (fun index char -> if char = '\n' then starts := (index + 1) :: !starts) contents;
  List.sort_uniq compare (String.length contents :: !starts)

let boundaries_to_try contents ~from =
  let size = String.length contents in
  List.concat_map (fun start -> [ start - 1; start; start + 1 ]) (line_starts contents)
  @ [ size + 5; from ]
  |> List.filter (fun until -> until >= 0)
  |> List.sort_uniq compare
  |> List.filter (fun until -> until >= from - 1)

(* From the start of the file, from one line start inside it, from the byte
   after that start, and from past the end of the file. A stored boundary is
   always a line start, but the reader takes any offset, so the others are
   compared too. *)
let starts_to_try state contents =
  let starts = Array.of_list (line_starts contents) in
  let line_start = starts.(Random.State.int state (Array.length starts)) in
  List.sort_uniq compare [ 0; line_start; line_start + 1; String.length contents + 2 ]

let compare_on state contents =
  with_file contents (fun path ->
    List.iter (fun from ->
      List.iter (fun until ->
        List.iter (fun start ->
          let expected = reference_prefix ~path ~from ~until start in
          let actual = Witness.digest_prefix ~path ~from ~until start in
          if expected <> actual then
            Alcotest.failf "from %d until %d over %d bytes: expected %s, got %s" from until
              (String.length contents)
              (Option.value expected ~default:"None")
              (Option.value actual ~default:"None"))
          [ Witness.empty_digest; reference_extend Witness.empty_digest "seed" ])
        (boundaries_to_try contents ~from))
      (starts_to_try state contents))

let test_a_link_is_the_digest_it_was () =
  List.iter (fun line ->
    Alcotest.(check string) "the same link" (reference_extend Witness.empty_digest line)
      (Witness.extend_digest Witness.empty_digest line))
    [ ""; "a"; "\r"; "{\"keeper\":\"alice\"}"; "\000\255"; String.make long_line_bytes 'x' ]

let test_a_prefix_reads_as_it_did_on_edge_files () =
  let state = Random.State.make [| 1 |] in
  List.iter (compare_on state)
    [ ""; "\n"; "\n\n"; "a"; "a\n"; "a\nb"; "a\nb\n"; "\r\n\r\n"
    ; String.make long_line_bytes 'y' ^ "\n" ^ String.make long_line_bytes 'z' ]

(* Fixed seed: a failure names its file by the run that produced it. *)
let random_files = 60

let test_a_prefix_reads_as_it_did_on_random_files () =
  let state = Random.State.make [| 43_299 |] in
  for _ = 1 to random_files do
    compare_on state (random_contents state)
  done

let () =
  Alcotest.run "keeper_tool_call_index_witness"
    [
      ( "continuity witness",
        [
          Alcotest.test_case "a link is the digest it was" `Quick
            test_a_link_is_the_digest_it_was;
          Alcotest.test_case "a prefix reads as it did on edge files" `Quick
            test_a_prefix_reads_as_it_did_on_edge_files;
          Alcotest.test_case "a prefix reads as it did on random files" `Quick
            test_a_prefix_reads_as_it_did_on_random_files;
        ] );
    ]
