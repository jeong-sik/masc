(* A word wider than a row breaks after the last [_ : / . -] that leaves the row
   at least half full. These cases pin what that leaves: no character is lost,
   no row is wider than its budget, a stretch with no break is cut exactly as
   [split_cells] cuts it, and the streaming split agrees with a plain recursive
   definition of the same rule, over wide characters and combining marks too.
   What counts as a separator is pinned as well: the bytes of an escape are not
   text. They check text and cells, not how a screen reads. *)

open Alcotest
module Layout = Masc_tui_message_layout

let cells_of = Layout.display_width

let wrap ~cells text = Layout.wrap_words ~max_cells:cells text

let separators = [ "_"; ":"; "/"; "."; "-" ]

let contains haystack needle =
  let length = String.length needle in
  let rec at offset =
    offset + length <= String.length haystack
    && (String.equal (String.sub haystack offset length) needle || at (offset + 1))
  in
  at 0

(* The characters of [text], one string each, a combining mark (U+0300 to
   U+036F) kept with the character before it. *)
let characters text =
  let rec from offset found =
    if offset >= String.length text then List.rev found
    else
      let decoded = String.get_utf_8_uchar text offset in
      let length = Uchar.utf_decode_length decoded in
      let scalar = String.sub text offset length in
      let code = Uchar.to_int (Uchar.utf_decode_uchar decoded) in
      match found with
      | previous :: before when 0x300 <= code && code <= 0x36F ->
          from (offset + length) ((previous ^ scalar) :: before)
      | _ -> from (offset + length) (scalar :: found)
  in
  from 0 []

let opens_with_separator character =
  List.exists (fun prefix -> String.starts_with ~prefix character) separators

let first count list = List.filteri (fun index _ -> index < count) list

let after count list = List.filteri (fun index _ -> index >= count) list

(* The rule written the plain way over characters: a row takes the characters
   that fit the width, ends after the last one that opens with a separator when
   that leaves it at least half full, and the rest is wrapped the same way. A
   character wider than the width still takes a row of its own. *)
let reference ~cells word =
  let width list = cells_of (String.concat "" list) in
  let rec rows = function
    | [] -> []
    | all when width all <= cells -> [ String.concat "" all ]
    | all ->
        let rec fit used taken = function
          | next :: rest when taken = [] || used + cells_of next <= cells ->
              fit (used + cells_of next) (next :: taken) rest
          | _ -> List.rev taken
        in
        let head = fit 0 [] all in
        let last_separator =
          List.fold_left
            (fun found (index, character) ->
               if opens_with_separator character then Some (index + 1) else found)
            None
            (List.mapi (fun index character -> index, character) head)
        in
        let cut =
          match last_separator with
          | Some count when width (first count head) * 2 >= cells -> count
          | Some _ | None -> List.length head
        in
        String.concat "" (first cut all) :: rows (after cut all)
  in
  rows (characters word)

(* What an escape leaves of a row: the text it drew. *)
let strip_escapes text =
  let buffer = Buffer.create (String.length text) in
  let rec copy offset =
    if offset < String.length text then
      if Char.equal text.[offset] '\027' && offset + 1 < String.length text
         && Char.equal text.[offset + 1] '['
      then skip (offset + 2)
      else begin
        Buffer.add_char buffer text.[offset];
        copy (offset + 1)
      end
  and skip offset =
    if offset < String.length text then
      if Char.code text.[offset] >= 0x40 && Char.code text.[offset] <= 0x7E
      then copy (offset + 1)
      else skip (offset + 1)
  in
  copy 0;
  Buffer.contents buffer

(* A colour whose parameters hold separators of their own. *)
let colour = "\027[38:5:196m"

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

(* Words of narrow, wide and separator characters, some with a combining mark,
   from a fixed seed. How often a separator turns up changes from word to word,
   so breaks are sometimes close behind each other and sometimes absent. *)
let random_word state =
  let letters = [| "a"; "b"; "c"; "\xC3\xA9"; "\xE6\x97\xA5"; "\xEA\xB0\x80"; "\xF0\x9F\x98\x80" |] in
  let separator_percent = [| 5; 20; 50 |].(Random.State.int state 3) in
  String.concat ""
    (List.init
       (1 + Random.State.int state 60)
       (fun _ ->
          let character =
            if Random.State.int state 100 < separator_percent
            then List.nth separators (Random.State.int state (List.length separators))
            else letters.(Random.State.int state (Array.length letters))
          in
          if Random.State.int state 100 < 5 then character ^ "\xCC\x81" else character))

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

(* Narrow, wide and separator characters in any order, against the plain rule.
   A row that counted bytes where it should count cells breaks on one of
   these. *)
let test_wide_text_agrees_with_the_plain_rule () =
  let state = Random.State.make [| 20261105 |] in
  for _round = 1 to 800 do
    let word = random_word state in
    let cells = 1 + Random.State.int state 30 in
    check (list string)
      (Printf.sprintf "rows at %d cells: %s" cells word)
      (reference ~cells word)
      (wrap ~cells word)
  done

(* A separator and the mark that combines with it are drawn as one piece: the
   row ends after both, and no row starts with the mark. *)
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
    [ 6; 9; 10; 12 ];
  check (list string) "the break follows the separator and its mark"
    [ "abcdefgh_\xCC\x81"; "ijklmnopqrst"; "uvwxyz" ]
    (wrap ~cells:12 word)

(* The bytes of an escape are not text: where the visible text breaks does not
   depend on where the escape sits, and the separators in its parameters are
   not breaks. *)
let test_an_escape_does_not_move_a_break () =
  List.iter
    (fun cells ->
       List.iter
         (fun name ->
            let plain = wrap ~cells name in
            for offset = 0 to String.length name do
              let styled =
                String.sub name 0 offset ^ colour
                ^ String.sub name offset (String.length name - offset)
              in
              check (list string)
                (Printf.sprintf "rows at %d cells, escape at %d: %s" cells offset name)
                plain
                (List.map strip_escapes (wrap ~cells styled))
            done)
         names)
    [ 8; 13; 20; 30; 52 ]

let test_wide_text_with_an_escape_agrees_with_the_plain_rule () =
  let state = Random.State.make [| 20261106 |] in
  for _round = 1 to 400 do
    let word = random_word state in
    let cells = 1 + Random.State.int state 30 in
    let parts = characters word in
    let at = Random.State.int state (List.length parts + 1) in
    let styled =
      String.concat "" (first at parts) ^ colour ^ String.concat "" (after at parts)
    in
    check (list string)
      (Printf.sprintf "rows at %d cells, escape at %d: %s" cells at word)
      (reference ~cells word)
      (List.map strip_escapes (wrap ~cells styled))
  done

let test_the_parameters_of_an_escape_are_not_separators () =
  let word = colour ^ "0123456789abcdef0123456789abcdef" ^ "\027[0m" in
  check (list string) "cut at the width, as split_cells cuts it"
    (Layout.split_cells ~max_cells:12 word)
    (wrap ~cells:12 word)

let test_a_styled_name_breaks_after_a_separator_and_keeps_its_style () =
  check (list string) "each row opens the colour again and closes it"
    [ "\027[33mkeeper_identity_drift:configured_keeper_without_\027[0m"
    ; "\027[33mruntime_meta\027[0m"
    ]
    (Layout.wrap_styled_words ~max_cells:54
       "\027[33mkeeper_identity_drift:configured_keeper_without_runtime_meta\027[0m")

(* A word that is not valid UTF-8 is cut at the width: [split_cells] measures
   its bytes one by one and a valid stretch of it by grapheme, so rows cut at a
   separator could be wider than their budget. *)
let test_a_word_that_is_not_utf_8_is_cut_at_the_width () =
  List.iter
    (fun (cells, word) ->
       check (list string)
         (Printf.sprintf "rows at %d cells: %S" cells word)
         (Layout.split_cells ~max_cells:cells word)
         (wrap ~cells word))
    [ 1, "\xF0\x9F\x87\xBA\xF0\x9F\x87\xBA\xFF"
    ; 6, "ab:cd\xF0\x9F\x87\xB8\xE2\x80\x8Defgh.ij_kl-mn\xFF"
    ; 8, "keeper_identity_drift:configured\xFFkeeper_without_runtime_meta"
    ]

(* The source ranges the Memory journal keeps for each row of a long name come
   from the same break: one range per row, and together they spell the name. *)
let test_a_long_name_keeps_its_source_ranges () =
  let reason = "keeper_identity_drift:configured_keeper_without_runtime_meta" in
  let lines = [ Layout.Journal_drop { memory_id = "memory-id"; reason } ] in
  List.iter
    (fun width ->
       let mapped = Layout.journal_rows_with_spans ~width lines in
       check bool "the rows are the ones journal_rows draws" true
         (mapped.journal_rows = Layout.journal_rows ~width lines);
       let spans =
         List.filter
           (fun (span : Layout.journal_source_span) ->
              span.field = Layout.Journal_reason_field)
           mapped.journal_fields
       in
       let parts (span : Layout.journal_source_span) =
         List.map
           (fun (start, stop) -> String.sub span.value start (stop - start))
           span.source_ranges
       in
       check string
         (Printf.sprintf "the ranges spell the reason at %d cells" width)
         reason
         (String.concat "" (List.concat_map parts spans));
       check bool (Printf.sprintf "a narrow journal wraps the name at %d cells" width)
         true (List.length spans > 1);
       List.iter
         (fun (span : Layout.journal_source_span) ->
            let row =
              String.concat "" (List.map fst (List.nth mapped.journal_rows span.row))
            in
            List.iter
              (fun part ->
                 check bool (Printf.sprintf "%s is on its row at %d cells" part width)
                   true (contains row part))
              (parts span))
         spans)
    [ 24; 30; 38; 54 ]

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
        ; test_case "wide text agrees with the plain rule" `Quick
            test_wide_text_agrees_with_the_plain_rule
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
        ; test_case "an escape does not move a break" `Quick
            test_an_escape_does_not_move_a_break
        ; test_case "wide text with an escape agrees with the plain rule" `Quick
            test_wide_text_with_an_escape_agrees_with_the_plain_rule
        ; test_case "the parameters of an escape are not separators" `Quick
            test_the_parameters_of_an_escape_are_not_separators
        ; test_case "a styled name breaks after a separator and keeps its style" `Quick
            test_a_styled_name_breaks_after_a_separator_and_keeps_its_style
        ; test_case "a word that is not UTF-8 is cut at the width" `Quick
            test_a_word_that_is_not_utf_8_is_cut_at_the_width
        ; test_case "a very long word is split whole" `Quick
            test_a_very_long_word_is_split_whole
        ] )
    ; ( "journal"
      , [ test_case "a long name keeps its source ranges" `Quick
            test_a_long_name_keeps_its_source_ranges
        ] )
    ]
