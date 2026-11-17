(* Which facts the block below a Keeper chat keeps. The row a fact lands on is
   not checked here: only that an uncapped block loses and cuts nothing, that
   a capped one drops whole trailing facts and says how many, that a fact
   wider than a row is cut at the cap instead of dropped, and where such a
   fact may break. *)

open Alcotest
module Facts = Masc_tui_chat_facts
module Layout = Masc_tui_message_layout

let facts =
  [ Facts.fact Facts.Who "code-reviewer"
  ; Facts.fact (Facts.Reading "") "\xe2\x97\x8f 정상"
  ; Facts.fact ~label:"gate: " Facts.Who "allow-all"
  ; Facts.fact ~label:"turn: " Facts.Who "ollama_cloud.ollama-cloud-deepseek-v4-1-flash"
  ; Facts.fact ~label:"tokens: " Facts.Amount "in 1200 out 340"
  ; Facts.fact ~label:"컨텍스트 " Facts.Amount "71%"
  ]

let total = List.length facts
let written fact = fact.Facts.label ^ fact.Facts.value
let more = Printf.sprintf "+%d"

(* The rows as one string with the separators between facts taken out, so it
   can be compared with the facts written end to end wherever the rows broke. *)
let drawn rows =
  let text = String.concat "" (List.map Facts.text rows) in
  let separator = " \xc2\xb7 " in
  let width = String.length separator in
  let buffer = Buffer.create (String.length text) in
  let rec copy index =
    if index < String.length text
    then
      if index + width <= String.length text
         && String.equal (String.sub text index width) separator
      then copy (index + width)
      else (
        Buffer.add_char buffer text.[index];
        copy (index + 1))
  in
  copy 0;
  Buffer.contents buffer

let test_an_uncapped_block_keeps_every_fact_whole () =
  List.iter
    (fun max_cells ->
      let layout = Facts.layout ~max_cells ~max_rows:max_int ~more facts in
      let at = Printf.sprintf "%d cells" max_cells in
      check int ("nothing omitted at " ^ at) 0 layout.Facts.omitted;
      check string ("every fact written in full at " ^ at)
        (String.concat "" (List.map written facts))
        (drawn layout.Facts.rows);
      check bool ("no row wider than the block at " ^ at) true
        (List.for_all
           (fun row -> Layout.display_width (Facts.text row) <= max_cells)
           layout.Facts.rows);
      check int ("the measured rows are the drawn rows at " ^ at)
        (List.length layout.Facts.rows)
        (Facts.rows_wanted ~max_cells facts))
    [ 8; 20; 40; 60; 100; 155 ]

let test_a_capped_block_drops_whole_trailing_facts () =
  (* Wide enough that every fact of the fixture fits a row. *)
  let max_cells = 60 in
  let wanted = Facts.rows_wanted ~max_cells facts in
  check bool "the fixture needs more than one row" true (wanted > 1);
  for max_rows = 1 to wanted - 1 do
    let layout = Facts.layout ~max_cells ~max_rows ~more facts in
    let at = Printf.sprintf "%d rows" max_rows in
    let kept = total - layout.Facts.omitted in
    check bool ("some fact is omitted at " ^ at) true (layout.Facts.omitted > 0);
    check bool ("no fact is cut at " ^ at) false layout.Facts.cut;
    check bool ("no more rows than granted at " ^ at) true
      (List.compare_length_with layout.Facts.rows max_rows <= 0);
    check string ("kept facts are whole and the count follows them at " ^ at)
      (String.concat "" (List.map written (List.take kept facts))
       ^ more layout.Facts.omitted)
      (drawn layout.Facts.rows)
  done

let test_no_rows_omit_every_fact () =
  let layout = Facts.layout ~max_cells:40 ~max_rows:0 ~more facts in
  check int "nothing is drawn" 0 (List.length layout.Facts.rows);
  check int "every fact is counted as omitted" total layout.Facts.omitted

(* A fact with no text is the same block as one without it: it is not drawn,
   takes no separator and is not counted among the omitted. *)
let test_a_fact_with_no_text_is_not_a_fact () =
  let empty = Facts.fact Facts.Plain "" in
  let with_empty = (empty :: List.concat_map (fun fact -> [ fact; empty ]) facts) in
  let texts layout = List.map Facts.text layout.Facts.rows in
  List.iter
    (fun max_cells ->
      let at = Printf.sprintf "%d cells" max_cells in
      check (list string) ("the rows are the same at " ^ at)
        (texts (Facts.layout ~max_cells ~max_rows:max_int ~more facts))
        (texts (Facts.layout ~max_cells ~max_rows:max_int ~more with_empty));
      check int ("the measured rows are the same at " ^ at)
        (Facts.rows_wanted ~max_cells facts)
        (Facts.rows_wanted ~max_cells with_empty))
    [ 20; 60; 155 ];
  check int "an empty fact is not counted as omitted" total
    (Facts.layout ~max_cells:40 ~max_rows:0 ~more with_empty).Facts.omitted

(* The cap holds at every width, down to rows too narrow for a fact or for
   the count: the pane subtracts the rows it granted, so a block that drew
   one more would push the composer off its row. *)
let test_a_capped_block_takes_no_more_rows_than_granted () =
  let sentence = Facts.fact Facts.Plain "the provider closed the stream before a reply" in
  List.iter
    (fun (name, facts) ->
      for max_cells = 1 to 24 do
        for max_rows = 0 to 3 do
          let layout = Facts.layout ~max_cells ~max_rows ~more facts in
          check bool
            (Printf.sprintf "%s: %d cells, %d rows" name max_cells max_rows)
            true
            (List.compare_length_with layout.Facts.rows max_rows <= 0)
        done
      done)
    [ "names and numbers", facts; "a sentence first", sentence :: facts ]

(* A sentence wider than a row breaks between two of its words: its rows
   joined with one space are the sentence again, which a row ending inside a
   word would not give. A name has no word to end a row on and is cut at the
   cell, so every row of it but the last is full. *)
let test_a_sentence_breaks_between_words_and_a_name_at_the_cell () =
  let sentence =
    String.concat " " (List.init 12 (fun index -> Printf.sprintf "word%02d" index))
  in
  let name = String.concat "" (List.init 12 (fun index -> Printf.sprintf "part%02d" index)) in
  let rows ~max_cells facts =
    List.map Facts.text (Facts.layout ~max_cells ~max_rows:max_int ~more facts).Facts.rows
  in
  List.iter
    (fun max_cells ->
      let at = Printf.sprintf "%d cells" max_cells in
      let sentence_rows = rows ~max_cells [ Facts.fact Facts.Plain sentence ] in
      check string ("the sentence's rows are its words at " ^ at) sentence
        (String.concat " " sentence_rows);
      check string ("so are the rows of a sentence behind a label at " ^ at)
        ("stopped: " ^ sentence)
        (String.concat " " (rows ~max_cells [ Facts.fact ~label:"stopped: " Facts.Plain sentence ]));
      check bool ("no row of the sentence is wider than the block at " ^ at) true
        (List.for_all (fun row -> Layout.display_width row <= max_cells) sentence_rows);
      let name_rows = rows ~max_cells [ Facts.fact Facts.Who name ] in
      check string ("the name's rows are the name at " ^ at) name (String.concat "" name_rows);
      check bool ("every row of the name but the last is full at " ^ at) true
        (List.for_all
           (fun row -> Layout.display_width row = max_cells)
           (List.take (List.length name_rows - 1) name_rows)))
    [ 20; 33; 47 ];
  (* The label leaves the first row eleven cells. The word that does not fit
     them goes on at the block's width, not at the first row's. *)
  check (list string) "a word wider than what the label leaves goes on at the full width"
    [ "stopped: abcdefghijk"; "lmnopqrstuvwxyz01234"; "56789 end" ]
    (rows ~max_cells:20
       [ Facts.fact ~label:"stopped: " Facts.Plain "abcdefghijklmnopqrstuvwxyz0123456789 end" ])

let mentions text word =
  let length = String.length word in
  let rec from index =
    index + length <= String.length text
    && (String.equal (String.sub text index length) word || from (index + 1))
  in
  from 0

(* A fact wider than a row is prose -- a failed turn's message. Its head is
   what the reader needs, so a cap that cannot hold all of it cuts it rather
   than replacing it with a count. A cap that holds all of it with the count
   behind it draws it whole, and says so by not marking a cut. *)
let test_a_fact_wider_than_a_row_is_cut_not_dropped () =
  let max_cells = 40 in
  let heading = "REQUEST ERROR" in
  let message =
    String.concat " " (List.init 30 (fun index -> Printf.sprintf "word%02d" index))
  in
  let facts =
    [ Facts.fact (Facts.Reading "") heading
    ; Facts.fact Facts.Plain message
    ; Facts.fact ~label:"runtime: " Facts.Who "glm"
    ]
  in
  let wanted = Facts.rows_wanted ~max_cells facts in
  check bool "the fixture needs several rows" true (wanted > 2);
  check bool "one row cuts the message" true
    (Facts.layout ~max_cells ~max_rows:1 ~more facts).Facts.cut;
  for max_rows = 1 to wanted - 1 do
    let layout = Facts.layout ~max_cells ~max_rows ~more facts in
    let at = Printf.sprintf "%d rows" max_rows in
    let text = drawn layout.Facts.rows in
    let head = heading ^ "word00" in
    check bool ("the message is marked cut exactly when its end is not drawn at " ^ at)
      (not (mentions text "word29"))
      layout.Facts.cut;
    check int ("only the fact behind it is left out at " ^ at) 1 layout.Facts.omitted;
    check string ("its head is drawn at " ^ at) head
      (String.sub text 0 (Int.min (String.length head) (String.length text)));
    check bool ("no more rows than granted at " ^ at) true
      (List.compare_length_with layout.Facts.rows max_rows <= 0);
    check bool ("no row wider than the block at " ^ at) true
      (List.for_all
         (fun row -> Layout.display_width (Facts.text row) <= max_cells)
         layout.Facts.rows)
  done

let () =
  run "tui_chat_facts"
    [ ( "layout"
      , [ test_case "an uncapped block keeps every fact whole" `Quick
            test_an_uncapped_block_keeps_every_fact_whole
        ; test_case "a capped block drops whole trailing facts" `Quick
            test_a_capped_block_drops_whole_trailing_facts
        ; test_case "no rows omit every fact" `Quick test_no_rows_omit_every_fact
        ; test_case "a fact with no text is not a fact" `Quick
            test_a_fact_with_no_text_is_not_a_fact
        ; test_case "a capped block takes no more rows than granted" `Quick
            test_a_capped_block_takes_no_more_rows_than_granted
        ; test_case "a fact wider than a row is cut, not dropped" `Quick
            test_a_fact_wider_than_a_row_is_cut_not_dropped
        ; test_case "a sentence breaks between words, a name at the cell" `Quick
            test_a_sentence_breaks_between_words_and_a_name_at_the_cell
        ] )
    ]
