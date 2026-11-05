(** What the colour of a line of pretty-printed JSON promises.

    Three things are held to a rule: which parts of a line are tokens, that
    colouring a line never changes the text or where it wraps, and that the
    escapes it adds open and close in pairs. The tokens are checked against
    Yojson reading the same text, so the rule is not a second copy of the
    lexer. Which hue a token gets is the theme's business. *)

open Alcotest

module Colour = Masc_tui_json_colour
module Ansi = Masc_tui_ansi.Ansi
module Theme = Masc_tui_ansi.Theme

let state = Random.State.make [| 2026; 11; 5 |]

let pick array = array.(Random.State.int state (Array.length array))

(* Text that is hard for a lexer: quote marks, backslashes, colons, the
   words of the literals, digits, number marks and non-ASCII. *)
let hard_pieces =
  [| "a"; "b"; "Z"; "0"; "7"; "-"; "."; "e"; "E"; "+"; " "; ":"; ","; "\""
   ; "\\"; "{"; "}"; "["; "]"; "true"; "null"; "false"; "한"; "é"; "😀"; "/"
  |]

let hard_text () =
  String.concat ""
    (List.init (Random.State.int state 8) (fun _ -> pick hard_pieces))

let rec random_json depth : Yojson.Basic.t =
  let leaf () : Yojson.Basic.t =
    match Random.State.int state 6 with
    | 0 -> `Null
    | 1 -> `Bool (Random.State.bool state)
    | 2 -> `Int (Random.State.int state 2001 - 1000)
    | 3 -> `Float (pick [| 0.5; -2.25; 1e20; 3e-7; 12345.678; 0.0 |])
    | _ -> `String (hard_text ())
  in
  if depth = 0 then leaf ()
  else
    match Random.State.int state 4 with
    | 0 ->
      `List (List.init (Random.State.int state 4) (fun _ -> random_json (depth - 1)))
    | 1 ->
      `Assoc
        (List.init (Random.State.int state 4) (fun _ ->
           (hard_text (), random_json (depth - 1))))
    | _ -> leaf ()

(* How many of each token the value holds, read from the value itself. *)
type counts =
  { keys : int
  ; strings : int
  ; numbers : int
  ; literals : int
  }

let none = { keys = 0; strings = 0; numbers = 0; literals = 0 }

let add a b =
  { keys = a.keys + b.keys
  ; strings = a.strings + b.strings
  ; numbers = a.numbers + b.numbers
  ; literals = a.literals + b.literals
  }

let rec expected_counts (json : Yojson.Basic.t) =
  match json with
  | `Null | `Bool _ -> { none with literals = 1 }
  | `Int _ | `Float _ -> { none with numbers = 1 }
  | `String _ -> { none with strings = 1 }
  | `List items -> List.fold_left add none (List.map expected_counts items)
  | `Assoc members ->
    List.fold_left add
      { none with keys = List.length members }
      (List.map (fun (_, value) -> expected_counts value) members)

let counts_of_lines lines =
  List.fold_left
    (fun counts line ->
       List.fold_left
         (fun counts (kind, _, _) ->
            match kind with
            | Colour.Key -> { counts with keys = counts.keys + 1 }
            | Colour.String -> { counts with strings = counts.strings + 1 }
            | Colour.Number -> { counts with numbers = counts.numbers + 1 }
            | Colour.Literal -> { counts with literals = counts.literals + 1 })
         counts (Colour.tokens line))
    none lines

let show_counts counts =
  Printf.sprintf "keys %d, strings %d, numbers %d, literals %d" counts.keys
    counts.strings counts.numbers counts.literals

let lines_of text = String.split_on_char '\n' text

(* Each escape the text holds, from its escape byte through its [m]. *)
let escapes text =
  let length = String.length text in
  let rec from index found =
    if index >= length then List.rev found
    else if text.[index] <> '\027' then from (index + 1) found
    else
      let stop =
        match String.index_from_opt text index 'm' with
        | Some stop -> stop + 1
        | None -> length
      in
      from stop (String.sub text index (stop - index) :: found)
  in
  from 0 []

let without_escapes text =
  let buffer = Buffer.create (String.length text) in
  let length = String.length text in
  let rec from index =
    if index < length then
      if text.[index] = '\027' then
        match String.index_from_opt text index 'm' with
        | Some stop -> from (stop + 1)
        | None -> ()
      else begin
        Buffer.add_char buffer text.[index];
        from (index + 1)
      end
  in
  from 0;
  Buffer.contents buffer

(* Every reset closes a style something opened, and the text ends with none
   open. *)
let check_escapes_pair_up text =
  let is_open =
    List.fold_left
      (fun is_open escape ->
         if String.equal escape Ansi.reset then begin
           check bool (Printf.sprintf "%S: a reset closes a style" text) true is_open;
           false
         end
         else true)
      false (escapes text)
  in
  check bool (Printf.sprintf "%S ends with no style open" text) false is_open

let rounds = 400

let test_tokens_are_what_yojson_reads () =
  for _ = 1 to rounds do
    let value = random_json 3 in
    List.iter
      (fun (what, text) ->
         check string what
           (show_counts (expected_counts value))
           (show_counts (counts_of_lines (lines_of text))))
      [ ("pretty", Yojson.Basic.pretty_to_string value)
      ; ("compact", Yojson.Basic.to_string value)
      ]
  done

let kinds line = List.map (fun (kind, _, _) -> kind) (Colour.tokens line)

let test_a_string_before_a_colon_is_a_key () =
  check bool "key then number" true
    (kinds "  \"a\": 1" = [ Colour.Key; Colour.Number ]);
  check bool "blanks before the colon" true
    (kinds "\"a\" : 1" = [ Colour.Key; Colour.Number ]);
  check bool "a string with no colon is a string" true
    (kinds "\"a\"," = [ Colour.String ])

let test_a_colon_inside_a_string_does_not_make_a_key () =
  check bool "string value with a colon" true
    (kinds "\"a\": \"b:c\"" = [ Colour.Key; Colour.String ]);
  check bool "array string with a colon" true
    (kinds "\"b: c\"," = [ Colour.String ]);
  check bool "key with a colon" true
    (kinds "\"b:c\": 2" = [ Colour.Key; Colour.Number ])

let test_an_escaped_quote_does_not_end_a_string () =
  let line = "\"say \\\"hi\\\": x\": true" in
  check bool "one key and one literal" true
    (kinds line = [ Colour.Key; Colour.Literal ]);
  match Colour.tokens line with
  | (Colour.Key, 0, stop) :: _ ->
    check int "the key ends at the colon that follows it" (String.rindex line ':') stop
  | _ -> fail "the line did not start with a key"

let test_a_backslash_pair_before_a_quote_ends_the_string () =
  (* The string is [a\] and the backslash is escaped, so the quote closes it. *)
  check bool "key then number" true
    (kinds "\"a\\\\\": 1" = [ Colour.Key; Colour.Number ])

let test_digits_and_words_inside_strings_are_not_tokens () =
  check bool "digits in a key and in a string" true
    (kinds "\"v1\": \"2\"" = [ Colour.Key; Colour.String ]);
  check bool "literal words in a string" true
    (kinds "\"note\": \"true story null\"" = [ Colour.Key; Colour.String ])

let test_a_word_that_only_starts_like_a_literal_is_not_one () =
  check bool "nullable" true (kinds "nullable" = []);
  check bool "truest" true (kinds "truest" = []);
  check bool "null then a comma" true (kinds "null," = [ Colour.Literal ]);
  check bool "false" true (kinds "false" = [ Colour.Literal ])

let test_a_number_is_one_token_as_written () =
  match Colour.tokens "  -12.5e+3," with
  | [ (Colour.Number, 2, 10) ] -> ()
  | other ->
    failf "expected one number over 2..10, got %d tokens" (List.length other)

let test_a_string_with_no_closing_quote_runs_to_the_end () =
  List.iter
    (fun line ->
       match Colour.tokens line with
       | [ (Colour.String, 0, stop) ] ->
         check int (Printf.sprintf "%S ends at its end" line) (String.length line) stop
       | _ -> failf "%S was not one string" line)
    [ "\"abc"; "\"abc\\"; "\"" ]

let test_tokens_stay_in_the_line_in_order () =
  for _ = 1 to rounds * 4 do
    let line = hard_text () ^ hard_text () ^ hard_text () in
    let length = String.length line in
    ignore
      (List.fold_left
         (fun previous_stop (kind, start, stop) ->
            check bool
              (Printf.sprintf "%S: a token starts after the one before" line)
              true (start >= previous_stop);
            check bool
              (Printf.sprintf "%S: a token is not empty and ends in the line" line)
              true (stop > start && stop <= length);
            let first = line.[start] in
            let opens_right =
              match kind with
              | Colour.Key | Colour.String -> first = '"'
              | Colour.Number -> first = '-' || (first >= '0' && first <= '9')
              | Colour.Literal ->
                List.mem (String.sub line start (stop - start)) [ "true"; "false"; "null" ]
            in
            check bool (Printf.sprintf "%S: a token opens the way its kind does" line)
              true opens_right;
            stop)
         0 (Colour.tokens line))
  done

(* A line as the sanitiser leaves it holds no escape byte. Any other byte,
   including ones that are not UTF-8, may be in it. *)
let any_line () =
  String.init (Random.State.int state 40) (fun _ ->
    match Random.State.int state 4 with
    | 0 -> Char.chr (0x80 + Random.State.int state 0x80)
    | _ -> (pick [| "a"; "1"; "\""; "\\"; ":"; "-"; "e"; " "; "t"; "n"; ","; "." |]).[0])

let test_colouring_a_line_leaves_its_text_alone () =
  for _ = 1 to rounds * 4 do
    let lines =
      [ any_line (); hard_text () ^ hard_text () ]
      @ lines_of (Yojson.Basic.pretty_to_string (random_json 3))
    in
    List.iter
      (fun line ->
         let coloured = Colour.colour_line line in
         check string (Printf.sprintf "%S without its escapes" line) line
           (without_escapes coloured);
         check_escapes_pair_up coloured)
      lines
  done

let test_a_line_is_coloured_exactly_where_it_has_tokens () =
  for _ = 1 to rounds * 4 do
    let line = hard_text () ^ hard_text () ^ hard_text () in
    let coloured_tokens =
      List.length
        (List.filter
           (fun (kind, _, _) ->
              match kind with
              | Colour.Key | Colour.Number | Colour.Literal -> true
              | Colour.String -> false)
           (Colour.tokens line))
    in
    check int
      (Printf.sprintf "%S: one reset for each coloured token" line)
      coloured_tokens
      (List.length
         (List.filter (String.equal Ansi.reset) (escapes (Colour.colour_line line))))
  done

let test_a_line_with_nothing_to_colour_comes_back_as_it_was () =
  List.iter
    (fun line ->
       check string (Printf.sprintf "%S" line) line (Colour.colour_line line))
    [ ""; "{"; "  ],"; "\"just a string\""; "  \"a:b\","; "nullable" ]

let test_a_key_a_number_and_a_literal_each_get_a_colour () =
  let key_colour = Theme.category Theme.Slot_1
  and number_colour = Theme.category Theme.Slot_2 in
  check string "key and number"
    ("  " ^ key_colour ^ "\"a\"" ^ Ansi.reset ^ ": " ^ number_colour ^ "1"
     ^ Ansi.reset ^ ",")
    (Colour.colour_line "  \"a\": 1,");
  check string "key and literal"
    (key_colour ^ "\"ok\"" ^ Ansi.reset ^ ": " ^ number_colour ^ "true" ^ Ansi.reset)
    (Colour.colour_line "\"ok\": true");
  check bool "a key and a number are told apart" false
    (String.equal key_colour number_colour)

let test_a_string_value_stays_the_colour_of_its_line () =
  let key_colour = Theme.category Theme.Slot_1 in
  check string "only the key is coloured"
    (key_colour ^ "\"a\"" ^ Ansi.reset ^ ": \"b 1 true\"")
    (Colour.colour_line "\"a\": \"b 1 true\"")

let test_json_is_told_from_prose () =
  for _ = 1 to rounds do
    let value = random_json 3 in
    List.iter
      (fun text ->
         check bool (Printf.sprintf "%S is JSON" text) true (Colour.parses text))
      [ Yojson.Basic.pretty_to_string value; Yojson.Basic.to_string value ];
    (* Cutting the closing bracket or quote off a compound value or a string
       leaves text that is not JSON. *)
    (match value with
     | `List _ | `Assoc _ | `String _ ->
       let text = Yojson.Basic.to_string value in
       let cut = String.sub text 0 (String.length text - 1) in
       check bool (Printf.sprintf "%S is cut short" cut) false (Colour.parses cut)
     | `Null | `Bool _ | `Int _ | `Float _ -> ());
    check bool "text after the value" false
      (Colour.parses (Yojson.Basic.to_string value ^ " x"))
  done;
  List.iter
    (fun prose ->
       check bool (Printf.sprintf "%S is prose" prose) false (Colour.parses prose))
    [ ""
    ; "   "
    ; "handed off: waiting on review"
    ; "said \"no\" 3 times"
    ; "{not json}"
    ; "true story"
    ; "1 2"
    ]

let test_parses_answers_for_any_text () =
  let answered text =
    match Colour.parses text with
    | (_ : bool) -> ()
    | exception exn ->
      failf "parses raised %s on %S" (Printexc.to_string exn) text
  in
  for _ = 1 to rounds * 4 do
    answered (any_line ());
    answered (hard_text () ^ hard_text ());
    let text = Yojson.Basic.pretty_to_string (random_json 3) in
    for cut = 0 to String.length text do
      answered (String.sub text 0 cut)
    done
  done

(* Colouring is a layer over the text: where a line wraps is the plain
   line's business, whatever the colours are. *)
let test_colouring_a_line_does_not_move_where_it_wraps () =
  for _ = 1 to 120 do
    let text = Yojson.Basic.pretty_to_string (random_json 4) in
    List.iter
      (fun line ->
         List.iter
           (fun max_cells ->
              let plain = Masc_tui_text_block.preformatted_rows ~max_cells line in
              let coloured =
                Masc_tui_text_block.preformatted_styled_rows ~style:Colour.colour_line
                  ~max_cells line
              in
              check (list string)
                (Printf.sprintf "%S at %d cells" line max_cells)
                plain
                (List.map without_escapes coloured);
              List.iter check_escapes_pair_up coloured)
           [ 1; 2; 5; 9; 16; 24; 40 ])
      (lines_of text)
  done

let () =
  run "tui json colour"
    [ ( "tokens"
      , [ test_case "tokens are what yojson reads" `Quick test_tokens_are_what_yojson_reads
        ; test_case "a string before a colon is a key" `Quick
            test_a_string_before_a_colon_is_a_key
        ; test_case "a colon inside a string does not make a key" `Quick
            test_a_colon_inside_a_string_does_not_make_a_key
        ; test_case "an escaped quote does not end a string" `Quick
            test_an_escaped_quote_does_not_end_a_string
        ; test_case "a backslash pair before a quote ends the string" `Quick
            test_a_backslash_pair_before_a_quote_ends_the_string
        ; test_case "digits and words inside strings are not tokens" `Quick
            test_digits_and_words_inside_strings_are_not_tokens
        ; test_case "a word that only starts like a literal is not one" `Quick
            test_a_word_that_only_starts_like_a_literal_is_not_one
        ; test_case "a number is one token as written" `Quick
            test_a_number_is_one_token_as_written
        ; test_case "a string with no closing quote runs to the end" `Quick
            test_a_string_with_no_closing_quote_runs_to_the_end
        ; test_case "tokens stay in the line in order" `Quick
            test_tokens_stay_in_the_line_in_order
        ] )
    ; ( "colour"
      , [ test_case "colouring a line leaves its text alone" `Quick
            test_colouring_a_line_leaves_its_text_alone
        ; test_case "a line is coloured exactly where it has tokens" `Quick
            test_a_line_is_coloured_exactly_where_it_has_tokens
        ; test_case "a line with nothing to colour comes back as it was" `Quick
            test_a_line_with_nothing_to_colour_comes_back_as_it_was
        ; test_case "a key, a number and a literal each get a colour" `Quick
            test_a_key_a_number_and_a_literal_each_get_a_colour
        ; test_case "a string value stays the colour of its line" `Quick
            test_a_string_value_stays_the_colour_of_its_line
        ; test_case "colouring a line does not move where it wraps" `Quick
            test_colouring_a_line_does_not_move_where_it_wraps
        ] )
    ; ( "parses"
      , [ test_case "json is told from prose" `Quick test_json_is_told_from_prose
        ; test_case "parses answers for any text" `Quick test_parses_answers_for_any_text
        ] )
    ]
