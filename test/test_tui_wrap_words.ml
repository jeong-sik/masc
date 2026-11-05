(* A word wider than a row breaks after the last [_ : / . -] that leaves the row
   at least half full. These cases pin what that leaves: no character is lost,
   no row is wider than its budget, a stretch with no break is cut exactly as
   [split_cells] cuts it, and the streaming split agrees with a plain recursive
   definition of the same rule. They check text and cells, not how a screen
   reads. *)

open Alcotest
module Layout = Masc_tui_message_layout

let cells_of = Layout.display_width

let wrap ~cells text = Layout.wrap_words ~max_cells:cells text

(* The rule written the plain way, for printable ASCII where a cell is a byte:
   take the width, end the row after its last separator when that leaves the
   row at least half full, and go on with the rest. *)
let rec reference ~cells word =
  let length = String.length word in
  if length <= cells then [ word ]
  else begin
    let head = String.sub word 0 cells in
    let cut =
      let rec last index =
        if index < 0 then cells
        else if String.contains "_:/.-" head.[index] then
          if (index + 1) * 2 >= cells then index + 1 else cells
        else last (index - 1)
      in
      last (cells - 1)
    in
    String.sub word 0 cut :: reference ~cells (String.sub word cut (length - cut))
  end

let names =
  [ "keeper_identity_drift:configured_keeper_without_runtime_meta"
  ; "keeper_fleet_safety:no_executable_keeper_fibers"
  ; "/home/example/workspace/project/.worktrees/feature/tui-ux-loop/bin/masc_tui.ml"
  ; "https://example.com/docs/guides/TUI-KEYS.md?section=keys-and-commands"
  ; "task-2183"
  ; "a:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  ; "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  ; "------------------------------------------------------------------------"
  ; "_leading_and_trailing_"
  ]

let widths = [ 1; 2; 3; 5; 8; 13; 20; 30; 44; 52; 80 ]

let test_a_name_loses_no_character () =
  List.iter
    (fun cells ->
       List.iter
         (fun name ->
            check string
              (Printf.sprintf "nothing dropped at %d cells: %s" cells name)
              name
              (String.concat "" (wrap ~cells name)))
         names)
    widths

let test_no_row_is_wider_than_its_budget () =
  List.iter
    (fun cells ->
       List.iter
         (fun name ->
            List.iter
              (fun row ->
                 check bool
                   (Printf.sprintf "a row fits %d cells: %s" cells row)
                   true (cells_of row <= cells))
              (wrap ~cells name))
         names)
    widths

let test_the_streaming_split_agrees_with_the_plain_rule () =
  List.iter
    (fun cells ->
       List.iter
         (fun name ->
            check (list string)
              (Printf.sprintf "rows at %d cells: %s" cells name)
              (reference ~cells name)
              (wrap ~cells name))
         names)
    widths

let test_a_name_breaks_after_its_last_separator () =
  check (list string) "the Dashboard's longest reason in a 54-cell card"
    [ "keeper_identity_drift:configured_keeper_without_"; "runtime_meta" ]
    (wrap ~cells:54 "keeper_identity_drift:configured_keeper_without_runtime_meta");
  check (list string) "a narrower card breaks at each part that fits"
    [ "keeper_identity_drift:"; "configured_keeper_"; "without_runtime_meta" ]
    (wrap ~cells:24 "keeper_identity_drift:configured_keeper_without_runtime_meta");
  check (list string) "a path breaks after a slash"
    [ "/home/example/workspace/"; "project/.worktrees/" ]
    (wrap ~cells:30 "/home/example/workspace/project/.worktrees/")

(* Where no break leaves the row half full, or there is none, the row is cut at
   the width exactly as [split_cells] cuts it. *)
let test_a_stretch_with_no_usable_break_is_cut_at_the_width () =
  List.iter
    (fun word ->
       check (list string) word
         (Layout.split_cells ~max_cells:20 word)
         (wrap ~cells:20 word))
    [ "0123456789abcdef0123456789abcdef0123456789abcdef"
    ; "a:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    ; "------------------------------------------------"
    ]

let test_words_that_fit_are_left_alone () =
  check (list string) "a name that fits one row stays one row"
    [ "keeper_fleet_safety:no_executable_keeper_fibers" ]
    (wrap ~cells:48 "keeper_fleet_safety:no_executable_keeper_fibers");
  check (list string) "words still wrap at spaces"
    [ "one two"; "three four" ]
    (wrap ~cells:10 "one two three four")

let test_a_long_name_among_words_starts_its_own_row () =
  let rows =
    wrap ~cells:30 "see keeper_identity_drift:configured_keeper_without_runtime_meta now"
  in
  check bool "the text before the name keeps its row" true
    (match rows with first :: _ -> String.equal first "see" | [] -> false);
  check bool "the text after the name follows its last part" true
    (match List.rev rows with last :: _ -> String.equal last "runtime_meta now" | [] -> false);
  check string "nothing dropped"
    "seekeeper_identity_drift:configured_keeper_without_runtime_meta now"
    (String.concat "" rows)

let test_wide_characters_break_after_a_separator_too () =
  let word = "日本語_日本語_日本語" in
  List.iter
    (fun cells ->
       let rows = wrap ~cells word in
       check string (Printf.sprintf "nothing dropped at %d cells" cells) word
         (String.concat "" rows);
       List.iter
         (fun row ->
            check bool (Printf.sprintf "a row fits %d cells: %s" cells row) true
              (cells_of row <= cells))
         rows)
    [ 6; 7; 10; 13; 20 ];
  check (list string) "the break follows the separator"
    [ "日本語_"; "日本語_"; "日本語" ]
    (wrap ~cells:10 word)

(* A separator and the mark that combines with it are one grapheme: a row may
   not start with the mark. *)
let test_a_combining_mark_stays_with_its_separator () =
  let word = "abcdefgh_\xCC\x81ijklmnopqrstuvwxyz" in
  List.iter
    (fun cells ->
       List.iter
         (fun row ->
            check bool
              (Printf.sprintf "no row starts with the mark at %d cells" cells) false
              (String.length row >= 2 && String.equal (String.sub row 0 2) "\xCC\x81"))
         (wrap ~cells word))
    [ 6; 9; 10; 12 ]

(* The bytes of an escape hold separators of their own. *)
let test_text_with_an_escape_is_cut_at_the_width () =
  let word = "\027[38:5:196mname_with_parts_and_more_parts_to_come\027[0m" in
  check (list string) "the escape's own bytes decide nothing"
    (Layout.split_cells ~max_cells:12 word)
    (wrap ~cells:12 word)

(* A long word costs a pass over it, not a pass for each row it takes. *)
let test_a_very_long_word_is_split_whole () =
  let unit_ = "segment_" in
  let word = String.concat "" (List.init 20_000 (fun _ -> unit_)) in
  let rows = wrap ~cells:52 word in
  check string "nothing dropped" word (String.concat "" rows);
  check bool "every row fits" true (List.for_all (fun row -> cells_of row <= 52) rows);
  check bool "rows end after a separator" true
    (List.for_all
       (fun row -> String.equal (String.sub row (String.length row - 1) 1) "_")
       (List.filteri (fun index _ -> index < List.length rows - 1) rows))

let () =
  run "tui wrap words"
    [ ( "contract"
      , [ test_case "a name loses no character" `Quick test_a_name_loses_no_character
        ; test_case "no row is wider than its budget" `Quick
            test_no_row_is_wider_than_its_budget
        ; test_case "the streaming split agrees with the plain rule" `Quick
            test_the_streaming_split_agrees_with_the_plain_rule
        ] )
    ; ( "breaks"
      , [ test_case "a name breaks after its last separator" `Quick
            test_a_name_breaks_after_its_last_separator
        ; test_case "a stretch with no usable break is cut at the width" `Quick
            test_a_stretch_with_no_usable_break_is_cut_at_the_width
        ; test_case "words that fit are left alone" `Quick
            test_words_that_fit_are_left_alone
        ; test_case "a long name among words starts its own row" `Quick
            test_a_long_name_among_words_starts_its_own_row
        ] )
    ; ( "text"
      , [ test_case "wide characters break after a separator too" `Quick
            test_wide_characters_break_after_a_separator_too
        ; test_case "a combining mark stays with its separator" `Quick
            test_a_combining_mark_stays_with_its_separator
        ; test_case "text with an escape is cut at the width" `Quick
            test_text_with_an_escape_is_cut_at_the_width
        ; test_case "a very long word is split whole" `Quick
            test_a_very_long_word_is_split_whole
        ] )
    ]
