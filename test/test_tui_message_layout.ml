open Alcotest

module Layout = Masc_tui_message_layout
module Markdown_cache = Masc_tui_markdown_render_cache

let entry ?(timestamp = "12:34:56")
    ?(markdown_source = Layout.Markdown_streaming) style role request_label body :
    Layout.entry =
  { style; timestamp; role_label = role; request_label; body; markdown_source }

let test_keeps_latest_reply () =
  let entries =
    [ entry Layout.User "you" "tui-..aaaaaaaa" (String.make 600 'u')
    ; entry Layout.Keeper "keeper.one" "tui-..bbbbbbbb" "reply"
    ]
  in
  List.iter
    (fun cols ->
      let inner = cols - 4 in
      let rows = Layout.visible_rows ~inner_width:inner ~height:5 entries in
      check bool (Printf.sprintf "%d columns keeps reply metadata" cols) true
        (List.exists
           (fun (row : Layout.row) ->
             row.style = Layout.Keeper
             && String.starts_with ~prefix:"[12:34:56]" row.text)
           rows);
      check bool (Printf.sprintf "%d columns keeps reply body" cols) true
        (List.exists
           (fun (row : Layout.row) -> String.equal row.text "  reply")
           rows);
      check bool (Printf.sprintf "%d columns bounds every plain row" cols) true
        (List.for_all
           (fun (row : Layout.row) ->
             Layout.display_width row.text <= inner)
           rows))
    [ 20; 40; 80 ]

let test_keeps_newest_metadata_and_bytes () =
  let body = String.init 160 (fun index -> Char.chr (97 + (index mod 26))) in
  let newest = entry Layout.Keeper "keeper.one" "tui-..cccccccc" body in
  let all_rows = Layout.visible_rows ~inner_width:20 ~height:100 [ newest ] in
  let reconstructed =
    all_rows
    |> List.filteri (fun index _ -> index > 0)
    |> List.map (fun (row : Layout.row) ->
           String.sub row.text 2 (String.length row.text - 2))
    |> String.concat ""
  in
  check string "full layout loses no body bytes" body reconstructed;
  match Layout.visible_rows ~inner_width:20 ~height:3 [ newest ] with
  | metadata :: _ ->
      check bool "oversized newest entry keeps metadata" true
        (String.starts_with ~prefix:"[12:34:56]" metadata.text)
  | [] -> fail "oversized newest entry rendered no rows"

let test_terminal_cell_width_and_fit () =
  List.iter
    (fun (text, expected) ->
      check int (Printf.sprintf "display width of %S" text) expected
        (Layout.display_width text))
    [ "", 0
    ; "A", 1
    ; "é", 1
    ; "e\xCC\x81", 1
    ; "한", 2
    ; "🙂", 2
    ; "Aé한🙂", 6
    ; "\x1B[31m한\x1B[0m", 2
    ; "👍🏽", 4
    ; "🇰🇷", 2
    ; "❤️", 1
    ; "👩‍👩‍👧‍👦", 8
    ; "1️⃣", 1
    ; "한", 2
    ; "\x1B[31m❤️\x1B[0m", 1
    ];
  check string "exact-width text is unchanged" "12345"
    (Layout.fit_width "12345" 5);
  let fitted = Layout.fit_width "가나" 5 in
  check string "wide text is padded by cells" "가나 " fitted;
  check int "fitted UTF-8 fills the cell budget" 5
    (Layout.display_width fitted);
  check bool "fitted UTF-8 stays valid" true (String.is_valid_utf_8 fitted);
  check string "wide scalar is never split" "가~"
    (Layout.fit_width "가나" 3);
  check string "truncated ANSI style is reset before the marker"
    "\x1B[31m한\x1B[0m~"
    (Layout.fit_width "\x1B[31m한글\x1B[0m" 3);
  check string "emoji grapheme is never split by fit" " ~"
    (Layout.fit_width "👍🏽A" 2);
  (* The widest footer the chat pane assembles, built from the longest value
     of each part rather than quoted whole. The fixture used to be a short
     blocked hint and stopped being the widest when the queue hint arrived,
     without anything going red: this check passes on any string over the
     budget, so a stale fixture stays green while covering less than it says.

     The scrolling part is taken from the function the pane calls rather than
     quoted, so that one cannot go stale the same way. *)
  let longest_footer =
    String.concat "  "
      [ "\x1B[2m"
      ; "Enter:queue (99 waiting)  Ctrl-K:cancel last  Ctrl-P:edit last"
      ; "Ctrl-J:newline"
      ; Layout.scroll_hint ~scrolled_back:9999 ~older_exist:false
      ; "Ctrl-G:next Keeper"
      ; "Esc:interrupt turn"
      ; "Ctrl-U:clear\x1B[0m"
      ]
  in
  List.iter
    (fun terminal_cols ->
      let fitted = Layout.fit_width longest_footer (terminal_cols - 1) in
      check int
        (Printf.sprintf "%d-column footer avoids autowrap" terminal_cols)
        (terminal_cols - 1) (Layout.display_width fitted))
    [ 11; 20; 40 ]

(* The count the composer's status row used to carry. That row was drawn from
   the clamped scroll position and counted from the unclamped one, so an [up]
   press on a conversation that already fits left the pane a row short: the
   budget reserved a row the pane did not draw. The count lives in the footer
   now, which is drawn unconditionally, so nothing about the pane's height
   turns on it. *)
let test_scroll_hint_says_how_far_back () =
  let hint ?(older_exist = true) scrolled_back =
    Layout.scroll_hint ~scrolled_back ~older_exist
  in
  check string "an unscrolled pane names the key that scrolls" "PgUp:scroll back" (hint 0);
  check string "a clamped position is not scrolled" "PgUp:scroll back" (hint (-1));
  check string "a scrolled pane says how far back"
    "\xe2\x86\x91/\xe2\x86\x93:line  PgUp/PgDn:page  Ctrl-E:newest  (3 back)" (hint 3);
  check string "at the start, that is said instead of the distance"
    "\xe2\x86\x91/\xe2\x86\x93:line  PgUp/PgDn:page  Ctrl-E:newest  (start)"
    (hint ~older_exist:false 3);
  check bool "the count does not widen the start-of-history hint" true
    (Layout.display_width (hint ~older_exist:false 9999)
     <= Layout.display_width
          "\xe2\x86\x91/\xe2\x86\x93:line  PgUp/PgDn:page  Ctrl-E:newest  (start)")
;;

let test_utf8_scalar_input_contract () =
  List.iter
    (fun (lead, expected) ->
      check (option int) (Printf.sprintf "lead %02X" (Char.code lead)) expected
        (Layout.utf8_scalar_byte_length lead))
    [ 'A', Some 1
    ; '\xC2', Some 2
    ; '\xDF', Some 2
    ; '\xE0', Some 3
    ; '\xEF', Some 3
    ; '\xF0', Some 4
    ; '\xF4', Some 4
    ; '\x80', None
    ; '\xC0', None
    ; '\xC1', None
    ; '\xF5', None
    ; '\xFF', None
    ];
  List.iter
    (fun scalar ->
      check bool ("printable scalar " ^ scalar) true
        (Layout.is_printable_utf8_scalar scalar))
    [ "A"; "é"; "한"; "🙂"; "\xCC\x81" ];
  List.iter
    (fun value ->
      check bool "invalid or control scalar" false
        (Layout.is_printable_utf8_scalar value))
    [ ""; "AB"; "\x1B"; "\x7F"; "\xC2\x80"; "\x80"; "\xC0\xAF"
    ; "\xED\xA0\x80"; "\xF4\x90\x80\x80"
    ]

let test_backspace_removes_one_utf8_scalar () =
  let rec remove expected current =
    match expected with
    | [] -> ()
    | next :: rest ->
        let actual = Layout.drop_last_utf8_scalar current in
        check string "one scalar removed" next actual;
        check bool "remaining draft is valid UTF-8" true
          (String.is_valid_utf_8 actual);
        remove rest actual
  in
  remove [ "Aé한"; "Aé"; "A"; ""; "" ] "Aé한🙂";
  let invalid = "A\xE2" in
  check string "invalid buffer is preserved" invalid
    (Layout.drop_last_utf8_scalar invalid)

let test_input_viewport_keeps_latest_complete_scalars () =
  let viewport max_cells input = Layout.input_viewport ~max_cells input in
  check string "short input stays complete" "abc" (viewport 8 "abc");
  check string "exact boundary stays complete" "abcdefgh"
    (viewport 8 "abcdefgh");
  check string "ASCII overflow keeps the newest tail" "~cdefghi"
    (viewport 8 "abcdefghi");
  check string "mixed-width overflow keeps complete scalars" "~한🙂Z"
    (viewport 6 "Aé한🙂Z");
  check string "one-cell viewport keeps omission marker" "~"
    (viewport 1 "한");
  check string "detached combining mark is not rendered" "~"
    (viewport 2 "A한\xCC\x81");
  List.iter
    (fun (grapheme, cells) ->
      check string ("overflow keeps complete grapheme " ^ grapheme)
        ("~" ^ grapheme) (viewport (cells + 1) ("AB" ^ grapheme)))
    [ "👍🏽", 4
    ; "🇰🇷", 2
    ; "❤️", 1
    ; "👩‍👩‍👧‍👦", 8
    ; "1️⃣", 1
    ; "한", 2
    ];
  let repeated_hearts = String.concat "" (List.init 10 (fun _ -> "❤️")) in
  let heart_viewport = viewport 7 repeated_hearts in
  check int "repeated emoji viewport fills its cell budget" 7
    (Layout.display_width heart_viewport);
  check string "repeated emoji viewport keeps whole clusters" "~❤️❤️❤️❤️❤️❤️"
    heart_viewport;
  let before = "abcdefghi" in
  let after = Layout.drop_last_utf8_scalar before in
  check string "overflow before backspace" "~cdefghi" (viewport 8 before);
  check string "backspace immediately reveals the new boundary" "abcdefgh"
    (viewport 8 after);
  let mixed = "abcdef한🙂" in
  check string "mixed tail before backspace" "~f한🙂" (viewport 6 mixed);
  check string "mixed tail after scalar backspace" "~def한"
    (viewport 6 (Layout.drop_last_utf8_scalar mixed))

let test_input_cursor_uses_visible_terminal_cells () =
  let column terminal_cols input =
    Layout.input_cursor_column ~terminal_cols ~input
  in
  (* The caret is measured from the prefix the pane renders ("  > "), so what
     the operator typed and what the screen shows end at the same column. *)
  check int "empty input starts after the prompt" 7 (column 80 "");
  check int "prompt constant matches the pane prefix" 4
    Layout.chat_input_prompt_cells;
  check int "mixed UTF-8 input advances by cells" 13
    (column 80 "Aé한🙂");
  check int "emoji modifier follows xterm scalar cells" 12
    (column 80 "A👍🏽");
  check int "hangul syllables take two cells each" 11
    (column 80 "한글");
  check int "flag cluster advances by two cells" 9 (column 80 "🇰🇷");
  check int "VS16 cluster follows xterm's one cell" 8 (column 80 "❤️");
  check int "exact boundary reaches the pre-border spacer" 79
    (column 80 (String.make 75 'a'));
  check int "visible overflow remains in the pre-border spacer" 79
    (column 80 (Layout.input_viewport ~max_cells:75 (String.make 100 'a')));
  check int "tiny terminal cursor stays positive" 3 (column 4 "");
  (* Metadata rows align because every role label renders at one cell width. *)
  check int "short role label pads to the column"
    16 (Layout.display_width (Layout.align_role_label "you"));
  check int "wide-char role label pads by cells not bytes"
    16 (Layout.display_width (Layout.align_role_label "한글"));
  check string "long role label truncates with an ellipsis" "0123456789abcde…"
    (Layout.align_role_label "0123456789abcdefg");
  check string "column-width role label only pads"
    ("0123456789abcde" ^ String.make 1 ' ')
    (Layout.align_role_label "0123456789abcde");
  check string "short role label pads with spaces"
    ("you" ^ String.make 13 ' ')
    (Layout.align_role_label "you");
  let supported rows cols status_rows =
    Layout.message_viewport_supported ~terminal_rows:rows ~terminal_cols:cols
      ~status_rows
  in
  check bool "seven rows would scroll the final newline" false
    (supported 7 80 0);
  check bool "eight rows fit the zero-status frame" true
    (supported 8 80 0);
  check bool "status rows raise the minimum height" false
    (supported 10 80 3);
  check bool "status frame fits above its final newline" true
    (supported 11 80 3);
  check bool "narrow viewport uses the compact gate" false
    (supported 30 8 0);
  check bool "minimum width shows an omission marker and wide grapheme" true
    (supported 30 11 0)

let test_history_wraps_by_cells_without_losing_bytes () =
  let body = "A한🙂B" in
  let rows =
    Layout.visible_rows ~inner_width:6 ~height:10
      [ entry Layout.Keeper "k" "r" body ]
  in
  let body_rows =
    rows
    |> List.filteri (fun index _ -> index > 0)
    |> List.map (fun (row : Layout.row) -> row.text)
  in
  check (list string) "wide scalars wrap at the cell boundary"
    [ "  A한"; "  🙂B" ] body_rows;
  let reconstructed =
    body_rows
    |> List.map (fun text -> String.sub text 2 (String.length text - 2))
    |> String.concat ""
  in
  check string "cell wrapping preserves body bytes" body reconstructed;
  check (list string) "word wrapping uses cells"
    [ "A한"; "🙂B" ]
    (Layout.wrap_words ~max_cells:4 "A한 🙂B");
  let unbroken = "한한한" in
  let wrapped = Layout.wrap_words ~max_cells:4 unbroken in
  check (list string) "overlong word is split without an empty row"
    [ "한한"; "한" ] wrapped;
  check string "word splitting preserves bytes" unbroken
    (String.concat "" wrapped)

(* An escape that never got its final byte swallows whatever follows it,
   including a space. So a row is not the sum of its words: " word" measured
   on its own and measured as part of the row can disagree. Wrapping therefore
   segments the whole text once and reads the row widths off that, and this
   pins the input that rules the cheaper adding-up out. *)
let test_an_unterminated_escape_absorbs_the_space_after_it () =
  check int "an unterminated escape ends at the letter after the space" 4
    (Layout.display_width "\x1B[ words");
  check int "the same bytes measured apart keep the space" 7
    (Layout.display_width "\x1B[" + Layout.display_width " words");
  check int "a terminated escape leaves the space alone" 6
    (Layout.display_width "\x1B[0m words")

(* Rows carrying an escape are measured whole rather than word by word, so
   they get their own case. The two texts below differ only in whether the
   escape was finished, and that alone moves where the rows break -- which is
   what the whole-row measurement is there to get right. *)
let test_a_row_carrying_an_escape_wraps_by_its_real_width () =
  let unfinished = "\x1B[ ab cd ef" in
  let finished = "\x1B[0m ab cd ef" in
  check int "an unfinished escape eats the space and the letter after it" 7
    (Layout.display_width unfinished);
  check int "a finished escape leaves all nine cells" 9
    (Layout.display_width finished);
  check (list string) "seven cells hold the unfinished text whole"
    [ "\x1B[ ab cd ef" ]
    (Layout.wrap_words ~max_cells:7 unfinished);
  check (list string) "the same seven cells break the finished text"
    [ "\x1B[0m ab cd"; "ef" ]
    (Layout.wrap_words ~max_cells:7 finished);
  check (list string) "five cells break the unfinished text late"
    [ "\x1B[ ab cd"; "ef" ]
    (Layout.wrap_words ~max_cells:5 unfinished);
  check (list string) "and break the finished text one word earlier"
    [ "\x1B[0m ab"; "cd ef" ]
    (Layout.wrap_words ~max_cells:5 finished)

(* The two readers below stop as soon as further messages cannot change their
   answer. These pin that the stop lands in the same place the full walk would
   have: [max_scroll] still counts the whole transcript, so it is the oracle
   for the clamp, and a window wide enough to exhaust the transcript is the
   oracle for the scrolled window. *)
let transcript count =
  List.init count (fun index ->
      { Layout.style = Layout.Keeper;
        timestamp = Printf.sprintf "12:%02d:00" (index mod 60);
        role_label = "code-reviewer";
        request_label = Printf.sprintf "turn-%d" index;
        body =
          Printf.sprintf
            "turn %d closed and wrote a line long enough that it wraps more \
             than once at the widths this test uses"
            index;
        markdown_source = Layout.Markdown_streaming;
      })

let test_one_frame_renders_each_completed_entry_once_beyond_cache_capacity () =
  let rendered = ref [] in
  let equal_identity
      (left_keeper, left_request, left_at, left_index)
      (right_keeper, right_request, right_at, right_index) =
    String.equal left_keeper right_keeper
    && String.equal left_request right_request
    && Float.equal left_at right_at
    && left_index = right_index
  in
  let cache_capacity = 2 in
  let cache =
    Markdown_cache.create ~capacity:cache_capacity ~equal:equal_identity
  in
  let markdown ~(entry : Layout.entry) ~width =
    let source =
      match entry.markdown_source with
      | Layout.Markdown_stable
          { keeper_name; request_id; observed_at; entry_index } ->
          Markdown_cache.Stable_source
            { identity = keeper_name, request_id, observed_at, entry_index;
              text = entry.body;
            }
      | Layout.Markdown_growing _
      | Layout.Markdown_streaming ->
          Markdown_cache.Streaming_source entry.body
    in
    Markdown_cache.render cache ~theme_revision:1 ~palette_generation:0 ~width
      ~renderer:(fun ~width text ->
        rendered := entry.request_label :: !rendered;
        Layout.wrap_words ~max_cells:width text)
      ~source
  in
  let stable index =
    entry
      ~timestamp:(Printf.sprintf "12:34:%02d" index)
      ~markdown_source:
        (Layout.Markdown_stable
           { keeper_name = "keeper.one";
             request_id = Printf.sprintf "turn-%d" index;
             observed_at = float_of_int index;
             entry_index = index;
           })
      Layout.Keeper "keeper.one" (Printf.sprintf "turn-%d" index)
      (Printf.sprintf "completed markdown message %d wraps here" index)
  in
  let entries = List.init (cache_capacity + 1) stable in
  let inner_width = 24 in
  let height = 4 in
  let requested = 100 in
  let uncached_markdown ~(entry : Layout.entry) ~width =
    Layout.wrap_words ~max_cells:width entry.body
  in
  let expected_scroll =
    Layout.clamp_scroll ~markdown:uncached_markdown ~inner_width ~height requested
      entries
  in
  let expected_rows =
    Layout.scrolled_rows ~markdown:uncached_markdown ~inner_width ~height
      ~from_bottom:expected_scroll entries
  in
  let scroll, rows =
    Layout.clamped_scrolled_rows ~markdown ~inner_width ~height ~requested entries
  in
  check int "combined scroll matches the separate clamp" expected_scroll scroll;
  check (list string) "combined window matches the separate slice"
    (List.map (fun (row : Layout.row) -> row.text) expected_rows)
    (List.map (fun (row : Layout.row) -> row.text) rows);
  check (list string) "capacity + 1 entries were each rendered exactly once"
    [ "turn-0"; "turn-1"; "turn-2" ] !rendered;
  check int "persistent retention remains bounded" cache_capacity
    (Markdown_cache.For_testing.retained_entries cache)

let test_clamping_a_scroll_reads_only_as_far_as_it_must () =
  List.iter
    (fun count ->
       let entries = transcript count in
       List.iter
         (fun height ->
            List.iter
              (fun requested ->
                 let limit =
                   Layout.max_scroll ~inner_width:30 ~height entries
                 in
                 let expected = min requested limit in
                 check int
                   (Printf.sprintf "%d messages, height %d, scroll %d" count
                      height requested)
                   expected
                   (Layout.clamp_scroll ~inner_width:30 ~height requested
                      entries);
                 let expected_rows =
                   Layout.scrolled_rows ~inner_width:30 ~height
                     ~from_bottom:expected entries
                 in
                 let combined_scroll, combined_rows =
                   Layout.clamped_scrolled_rows ~inner_width:30 ~height
                     ~requested entries
                 in
                 check int "combined clamp matches" expected combined_scroll;
                 check (list string) "combined rows match"
                   (List.map (fun (row : Layout.row) -> row.text) expected_rows)
                   (List.map (fun (row : Layout.row) -> row.text) combined_rows))
              [ -3; 0; 1; 4; 17; 200 ])
         [ 0; 1; 5; 40 ])
    [ 0; 1; 3; 12 ]

let test_a_scrolled_window_matches_the_full_walk () =
  List.iter
    (fun count ->
       let entries = transcript count in
       let total = Layout.total_rows ~inner_width:30 entries in
       List.iter
         (fun height ->
            List.iter
              (fun from_bottom ->
                 (* Wide enough that the walk runs out of messages, which is
                    the path this replaced. *)
                 let exhaustive =
                   Layout.scrolled_rows ~inner_width:30
                     ~height:(total + from_bottom + 1) ~from_bottom entries
                 in
                 let expected =
                   let drop = max 0 (List.length exhaustive - height) in
                   List.filteri (fun index _ -> index >= drop) exhaustive
                 in
                 check (list string)
                   (Printf.sprintf "%d messages, height %d, back %d" count
                      height from_bottom)
                   (List.map (fun (row : Layout.row) -> row.text) expected)
                   (List.map
                      (fun (row : Layout.row) -> row.text)
                      (Layout.scrolled_rows ~inner_width:30 ~height ~from_bottom
                         entries)))
              [ 1; 2; 6; 19 ])
         [ 1; 3; 10 ])
    [ 1; 3; 12 ]

(* A board post arrived as one unbroken run with "\x0A" printed where every
   break belonged: the body went through a sanitiser that escapes control
   bytes, and a newline is one. The sanitiser below stands in for that one --
   what is under test is that it never sees a newline to escape. *)
let escape_control_bytes text =
  String.to_seq text
  |> Seq.map (fun c ->
         if Char.code c < 0x20 then Printf.sprintf "\\x%02X" (Char.code c)
         else String.make 1 c)
  |> List.of_seq
  |> String.concat ""

let test_a_body_keeps_the_breaks_its_author_wrote () =
  let body = "## heading\nfirst line\n\nlast line" in
  let rows =
    Layout.wrap_body ~max_cells:40 ~sanitize:escape_control_bytes body
  in
  check (list string) "one row per line, blank line kept"
    [ "## heading"; "first line"; ""; "last line" ] rows;
  check bool "no escaped newline reaches the screen" false
    (List.exists
       (fun row ->
         let needle = {|\x0A|} in
         let rec at i =
           i + String.length needle <= String.length row
           && (String.sub row i (String.length needle) = needle || at (i + 1))
         in
         at 0)
       rows)

let test_a_body_still_escapes_what_a_line_carries () =
  let rows =
    Layout.wrap_body
      ~max_cells:40
      ~sanitize:escape_control_bytes
      "before\n\x1b[31mred\nafter"
  in
  check (list string) "the escape on a line is still escaped"
    [ "before"; {|\x1B[31mred|}; "after" ] rows

(* With a renderer the escaping still happens first, and the renderer decides
   the rows. What must not happen is the renderer seeing a raw control byte, or
   the escaping eating the breaks it needs to find a heading. *)
let test_a_rendered_body_is_escaped_before_it_is_rendered () =
  let seen = ref "" in
  let renderer ~width text =
    ignore width;
    seen := text;
    String.split_on_char '\n' text
  in
  let rows =
    Layout.wrap_body
      ~markdown:renderer
      ~max_cells:40
      ~sanitize:escape_control_bytes
      "# title\n\x1b[31mred\nlast"
  in
  check string "the renderer is handed escaped text with its breaks intact"
    ({|# title|} ^ "\n" ^ {|\x1B[31mred|} ^ "\nlast")
    !seen;
  check (list string) "and it decides the rows"
    [ "# title"; {|\x1B[31mred|}; "last" ] rows

let test_a_body_of_one_line_is_one_row () =
  check (list string) "no newline, no change"
    [ "plain" ]
    (Layout.wrap_body ~max_cells:40 ~sanitize:escape_control_bytes "plain")

let test_history_never_splits_grapheme_clusters () =
  let body = "A👍🏽🇰🇷❤️B" in
  let rows =
    Layout.visible_rows ~inner_width:6 ~height:10
      [ entry Layout.Keeper "k" "r" body ]
  in
  let body_rows =
    rows
    |> List.filteri (fun index _ -> index > 0)
    |> List.map (fun (row : Layout.row) -> row.text)
  in
  check (list string) "grapheme clusters stay on one physical row"
    [ "  A"; "  👍🏽"; "  🇰🇷❤️B" ] body_rows;
  let reconstructed =
    body_rows
    |> List.map (fun text -> String.sub text 2 (String.length text - 2))
    |> String.concat ""
  in
  check string "grapheme wrapping preserves exact bytes" body reconstructed

let test_trailing_newlines_do_not_hide_reply () =
  let entries =
    [ entry Layout.User "you" "tui-..aaaaaaaa" (String.make 300 'u')
    ; entry Layout.Keeper "keeper.one" "tui-..bbbbbbbb"
        "reply\n\n\n\n\n\n"
    ]
  in
  let rows = Layout.visible_rows ~inner_width:16 ~height:3 entries in
  check bool "reply remains visible above trailing blank lines" true
    (List.exists
       (fun (row : Layout.row) -> String.equal row.text "  reply")
       rows)

let test_trailing_whitespace_lines_do_not_hide_reply () =
  let entries =
    [ entry Layout.Keeper "keeper.one" "tui-..bbbbbbbb"
        "reply\n \n\t\n  "
    ]
  in
  let rows = Layout.visible_rows ~inner_width:16 ~height:3 entries in
  check bool "reply remains visible above whitespace-only lines" true
    (List.exists
       (fun (row : Layout.row) -> String.equal row.text "  reply")
       rows)

(* The composer. Its row count has to be independent of the terminal width,
   because the pane's row budget is computed before the width is applied. *)
let test_composer_splits_on_newlines_only () =
  check (list string) "each newline is its own line"
    [ "first"; "second"; "third" ]
    (Layout.composer_lines ~max_rows:5 "first\nsecond\nthird");
  check (list string) "a long single line stays one line"
    [ String.make 400 'x' ]
    (Layout.composer_lines ~max_rows:5 (String.make 400 'x'))

let test_composer_keeps_the_newest_lines () =
  check (list string) "the oldest lines scroll off, not the newest"
    [ "3"; "4"; "5" ]
    (Layout.composer_lines ~max_rows:3 "1\n2\n3\n4\n5")

let test_an_empty_composer_is_one_empty_line () =
  (* One line, so the pane draws the prompt with nothing after it rather than
     drawing no prompt row at all. *)
  check (list string) "empty is a single empty line" [ "" ]
    (Layout.composer_lines ~max_rows:5 "")

let test_a_trailing_newline_opens_a_line () =
  check (list string) "the line the operator just started is shown"
    [ "typed"; "" ]
    (Layout.composer_lines ~max_rows:5 "typed\n")

(* One speaker talking twice is one heading. The pane used to write
   "[time] speaker request" above every message, so a keeper answering in four
   parts spent four rows saying who was talking. *)
let test_one_speaker_keeps_one_heading () =
  let rows entries =
    Layout.visible_rows ~inner_width:60 ~height:40 entries
    |> List.map (fun (row : Layout.row) -> row.text)
  in
  check (list string) "the same second is the same message"
    [ "[12:34:56] From [keeper.one] tui-..dddddddd"; "  first"; "  second" ]
    (rows
       [ entry Layout.Keeper "keeper.one" "tui-..dddddddd" "first"
       ; entry Layout.Keeper "keeper.one" "tui-..dddddddd" "second"
       ]);
  check (list string) "a later second keeps its own row, without the name"
    [ "[12:34:56] From [keeper.one] tui-..dddddddd"
    ; "  first"
    ; "[12:35:01]"
    ; "  second"
    ]
    (rows
       [ entry Layout.Keeper "keeper.one" "tui-..dddddddd" "first"
       ; entry ~timestamp:"12:35:01" Layout.Keeper "keeper.one"
           "tui-..dddddddd" "second"
       ]);
  check (list string) "a different speaker starts again"
    [ "[12:34:56] From [keeper.one] tui-..dddddddd"
    ; "  first"
    ; "[12:34:56] From [you] tui-..dddddddd"
    ; "  second"
    ]
    (rows
       [ entry Layout.Keeper "keeper.one" "tui-..dddddddd" "first"
       ; entry Layout.User "you" "tui-..dddddddd" "second"
       ]);
  check (list string) "a new turn starts again even from the same speaker"
    [ "[12:34:56] From [keeper.one] tui-..dddddddd"
    ; "  first"
    ; "[12:34:56] From [keeper.one] tui-..eeeeeeee"
    ; "  second"
    ]
    (rows
       [ entry Layout.Keeper "keeper.one" "tui-..dddddddd" "first"
       ; entry Layout.Keeper "keeper.one" "tui-..eeeeeeee" "second"
       ])
;;

let test_metadata_keeps_a_typed_origin () =
  let rows =
    Layout.visible_rows ~inner_width:80 ~height:10
      [ entry Layout.User "you" "tui-..aaaaaaaa" "hello"
      ; entry ~timestamp:"12:35:01" Layout.User "you" "tui-..aaaaaaaa"
          "again"
      ]
  in
  match rows with
  | { Layout.kind =
        Layout.Metadata
          (Layout.Origin { timestamp; role_label; request_label });
      _
    }
    :: { Layout.kind = Layout.Body; _ }
    :: { Layout.kind =
           Layout.Metadata (Layout.Continued_at { timestamp = continued_at });
         _
       }
    :: { Layout.kind = Layout.Body; _ }
    :: [] ->
      check string "origin timestamp" "12:34:56" timestamp;
      check string "origin label" "you" role_label;
      check string "origin request" "tui-..aaaaaaaa" request_label;
      check string "continuation timestamp" "12:35:01" continued_at
  | _ -> fail "message rows lost their typed origin/body structure"
;;

(* Scrollback. Ten one-line entries render to twenty rows -- a metadata row and
   a body row each -- so the arithmetic below is checkable by hand.

   Each carries its own second. Ten messages stamped the same second are one
   message as far as the pane is concerned and share a heading, which is the
   point of the grouping and would make this eleven rows rather than twenty. *)
let ten_entries =
  List.init 10 (fun index ->
      entry ~timestamp:(Printf.sprintf "12:34:%02d" index) Layout.Keeper
        "keeper.one" "tui-..dddddddd"
        (Printf.sprintf "line-%d" index))

let text_of rows = List.map (fun (row : Layout.row) -> row.text) rows

let test_total_rows_counts_metadata_and_body () =
  check int "two rows per single-line entry" 20
    (Layout.total_rows ~inner_width:40 ten_entries)

let test_unscrolled_is_the_existing_window () =
  check (list string) "from_bottom = 0 is visible_rows exactly"
    (text_of (Layout.visible_rows ~inner_width:40 ~height:6 ten_entries))
    (text_of
       (Layout.scrolled_rows ~inner_width:40 ~height:6 ~from_bottom:0
          ten_entries))

let test_scrolling_back_moves_the_window () =
  let window =
    Layout.scrolled_rows ~inner_width:40 ~height:4 ~from_bottom:4 ten_entries
    |> text_of
  in
  check int "the window is the height asked for" 4 (List.length window);
  check bool "it shows the entries above the hidden ones" true
    (List.exists (fun text -> String.equal text "  line-6") window
     && List.exists (fun text -> String.equal text "  line-7") window);
  check bool "and not the newest ones" false
    (List.exists (fun text -> String.equal text "  line-9") window)

let test_max_scroll_stops_at_the_oldest_row () =
  let height = 6 in
  let limit = Layout.max_scroll ~inner_width:40 ~height ten_entries in
  check int "twenty rows minus one screenful" 14 limit;
  let window =
    Layout.scrolled_rows ~inner_width:40 ~height ~from_bottom:limit ten_entries
    |> text_of
  in
  check bool "the oldest entry is on screen at the limit" true
    (List.exists (fun text -> String.equal text "  line-0") window)

let test_scrolling_past_the_top_yields_no_rows_rather_than_wrapping () =
  check (list string) "a position past the oldest row shows nothing" []
    (Layout.scrolled_rows ~inner_width:40 ~height:6 ~from_bottom:100 ten_entries
     |> text_of)

(* A scroll bound for rows that are not one per item. Bounding by
   [count - height] leaves the tail unreachable as soon as an item costs two
   rows, which is what a call that answered something costs. *)
let test_last_page_start_counts_rows_not_items () =
  check int "one row each is the plain bound" 4
    (Layout.last_page_start ~height:6 (List.init 10 (fun _ -> 1)));
  check int "two rows each halves what fits" 7
    (Layout.last_page_start ~height:6 (List.init 10 (fun _ -> 2)));
  check int "a mixed list stops where the height runs out" 2
    (Layout.last_page_start ~height:5 [ 1; 1; 2; 1; 2 ]);
  check int "everything fits" 0
    (Layout.last_page_start ~height:40 [ 1; 2; 1 ]);
  check int "nothing to place" 0 (Layout.last_page_start ~height:6 [])

(* The last item stays reachable even when it alone is taller than the pane:
   drawn as far as the height allows beats not drawn at all. *)
let test_last_page_start_keeps_the_last_item_reachable () =
  check int "an oversized last item" 2
    (Layout.last_page_start ~height:1 [ 1; 1; 9 ]);
  check int "a zero cost still spends a row" 1
    (Layout.last_page_start ~height:1 [ 0; 0 ])

(* An age reads as seconds until a minute, then as minutes and a zero-padded
   remainder so a column of them lines up. It is what tells an operator that a
   turn taking minutes is advancing rather than stuck, so the boundary and the
   padding are the parts worth pinning. *)
let test_age_reads_as_seconds_then_minutes () =
  List.iter
    (fun (since, expected) ->
      check (option string)
        (Printf.sprintf "age at %.1fs" (100. -. since))
        expected
        (Layout.age_text ~now:100. ~since))
    [ (100., Some "0s")
    ; (99.5, Some "0s")
    ; (99., Some "1s")
    ; (41., Some "59s")
    ; (40., Some "1m00s")
    ; (33., Some "1m07s")
    ; (-100., Some "3m20s")
    ]

(* A clock that moved backwards says nothing rather than a negative age: the
   row that shows this has no way to draw "-4s" that a reader could use. *)
let test_a_backwards_clock_says_nothing () =
  check (option string) "later start than now" None
    (Layout.age_text ~now:100. ~since:104.)

(* Bare-link dressing: styles the URL run only, restores the caller's row
   style after it, and never swallows an escape already in the row. *)
let test_bare_links_are_dressed_and_bounded () =
  let dress = Layout.dress_bare_links ~open_style:"<U>" ~close_style:"</U>" in
  check string "a bare url is dressed"
    "see <U>https://example.com/a?b=1</U> now"
    (dress "see https://example.com/a?b=1 now");
  check string "a bracketed url stops at the bracket"
    "(<U>https://example.com</U>)"
    (dress "(https://example.com)");
  check string "an escape ends the token"
    "<U>https://a.io</U>\x1b[0m tail"
    (dress "https://a.io\x1b[0m tail");
  check string "text with no url is untouched" "plain words"
    (dress "plain words");
  check string "http without slashes is not a link" "httpx and http:"
    (dress "httpx and http:")

(* The badge was 16 cells whatever the terminal was, so [codex-mcp-client]
   read as [codex-mcp-clien…] on a screen with room to spell it. These pin the
   three things the width has to be at once: wide enough for the names on the
   pane, never narrower than it used to be, and never so wide that one long
   name crowds out the messages. *)
let test_badge_fits_the_longest_name_present () =
  let width =
    Layout.chat_role_label_width ~pane_cells:200
      [ "you"; "codex-mcp-client"; "tools" ]
  in
  check int "the longest name fits whole" 16 width;
  check string "and is not truncated"
    "codex-mcp-client"
    (String.trim (Layout.align_role_label ~column:width "codex-mcp-client"))

let test_badge_grows_past_the_old_constant () =
  let long = "keeper-with-a-very-long-name" in
  let width = Layout.chat_role_label_width ~pane_cells:200 [ long ] in
  check bool "a 27-cell name gets more than the old 16" true (width > 16);
  check string "and reads whole" long
    (String.trim (Layout.align_role_label ~column:width long))

let test_badge_never_narrows_below_the_old_constant () =
  List.iter
    (fun labels ->
      check int "short labels keep the old badge" 16
        (Layout.chat_role_label_width ~pane_cells:200 labels))
    [ [ "you" ]; [ "tools"; "error" ]; [] ]

let test_one_long_name_cannot_crowd_the_messages () =
  let long = String.make 120 'k' in
  let pane = 80 in
  let width = Layout.chat_role_label_width ~pane_cells:pane [ long ] in
  check bool "the badge stays within a quarter of the pane" true
    (width <= pane / 4);
  check bool "so the body keeps most of the width" true
    (pane - width > pane / 2)

let test_a_narrow_pane_draws_what_it_always_did () =
  (* Under 64 cells a quarter is below 16, and the floor wins -- the same
     badge these panes have always had. *)
  check int "40-cell pane" 16
    (Layout.chat_role_label_width ~pane_cells:40 [ "codex-mcp-client" ]);
  check int "16-cell pane" 16
    (Layout.chat_role_label_width ~pane_cells:16 [ "codex-mcp-client" ])

let test_every_row_gets_the_same_badge () =
  (* Alignment is the reason the badge exists: one width for the pane, not
     one per row. *)
  let width = Layout.chat_role_label_width ~pane_cells:200 [ "you"; "analyst" ] in
  List.iter
    (fun label ->
      check int ("badge width for " ^ label) width
        (Layout.display_width (Layout.align_role_label ~column:width label)))
    [ "you"; "analyst"; "tools"; "thinking" ]

let () =
  run "tui_message_layout"
    [
      ( "bare links"
      , [ test_case "dressed and bounded" `Quick
            test_bare_links_are_dressed_and_bounded
        ] ); ( "message rows"
      , [ test_case "keeps latest reply at 20/40/80 columns" `Quick
            test_keeps_latest_reply
        ; test_case "keeps newest metadata and body bytes" `Quick
            test_keeps_newest_metadata_and_bytes
        ; test_case "terminal cell width and UTF-8 fit" `Quick
            test_terminal_cell_width_and_fit
        ; test_case "the scroll hint says how far back" `Quick
            test_scroll_hint_says_how_far_back
        ; test_case "UTF-8 scalar input contract" `Quick
            test_utf8_scalar_input_contract
        ; test_case "backspace removes one UTF-8 scalar" `Quick
            test_backspace_removes_one_utf8_scalar
        ; test_case "input viewport keeps latest scalars" `Quick
            test_input_viewport_keeps_latest_complete_scalars
        ; test_case "input cursor uses visible cells" `Quick
            test_input_cursor_uses_visible_terminal_cells
        ; test_case "last page start counts rows" `Quick
            test_last_page_start_counts_rows_not_items
        ; test_case "last page keeps the last item reachable" `Quick
            test_last_page_start_keeps_the_last_item_reachable
        ; test_case "age reads as seconds then minutes" `Quick
            test_age_reads_as_seconds_then_minutes
        ; test_case "a backwards clock says nothing" `Quick
            test_a_backwards_clock_says_nothing
        ; test_case "history wraps by cells without byte loss" `Quick
            test_history_wraps_by_cells_without_losing_bytes
        ; test_case "history never splits grapheme clusters" `Quick
            test_history_never_splits_grapheme_clusters
        ; test_case "an unterminated escape absorbs the space after it" `Quick
            test_an_unterminated_escape_absorbs_the_space_after_it
        ; test_case "a row carrying an escape wraps by its real width" `Quick
            test_a_row_carrying_an_escape_wraps_by_its_real_width
        ; test_case "a body keeps the breaks its author wrote" `Quick
            test_a_body_keeps_the_breaks_its_author_wrote
        ; test_case "a body still escapes what a line carries" `Quick
            test_a_body_still_escapes_what_a_line_carries
        ; test_case "a body of one line is one row" `Quick
            test_a_body_of_one_line_is_one_row
        ; test_case "a rendered body is escaped before it is rendered" `Quick
            test_a_rendered_body_is_escaped_before_it_is_rendered
        ; test_case "clamping a scroll reads only as far as it must" `Quick
            test_clamping_a_scroll_reads_only_as_far_as_it_must
        ; test_case "a scrolled window matches the full walk" `Quick
            test_a_scrolled_window_matches_the_full_walk
        ; test_case "one frame renders capacity + 1 markdown entries once" `Quick
            test_one_frame_renders_each_completed_entry_once_beyond_cache_capacity
        ; test_case "trailing newlines keep reply visible" `Quick
            test_trailing_newlines_do_not_hide_reply
        ; test_case "trailing whitespace lines keep reply visible" `Quick
            test_trailing_whitespace_lines_do_not_hide_reply
        ] )
    ; ( "composer"
      , [ test_case "splits on newlines only" `Quick
            test_composer_splits_on_newlines_only
        ; test_case "keeps the newest lines" `Quick
            test_composer_keeps_the_newest_lines
        ; test_case "empty is one empty line" `Quick
            test_an_empty_composer_is_one_empty_line
        ; test_case "a trailing newline opens a line" `Quick
            test_a_trailing_newline_opens_a_line
        ] )
    ; ( "scrollback"
      , [ test_case "one speaker keeps one heading" `Quick
            test_one_speaker_keeps_one_heading
        ; test_case "metadata keeps a typed origin" `Quick
            test_metadata_keeps_a_typed_origin
        ; test_case "total rows counts metadata and body" `Quick
            test_total_rows_counts_metadata_and_body
        ; test_case "unscrolled matches the existing window" `Quick
            test_unscrolled_is_the_existing_window
        ; test_case "scrolling back moves the window" `Quick
            test_scrolling_back_moves_the_window
        ; test_case "max scroll stops at the oldest row" `Quick
            test_max_scroll_stops_at_the_oldest_row
        ; test_case "badge fits the longest name present" `Quick
            test_badge_fits_the_longest_name_present
        ; test_case "badge grows past the old constant" `Quick
            test_badge_grows_past_the_old_constant
        ; test_case "badge never narrows below the old constant" `Quick
            test_badge_never_narrows_below_the_old_constant
        ; test_case "one long name cannot crowd the messages" `Quick
            test_one_long_name_cannot_crowd_the_messages
        ; test_case "a narrow pane draws what it always did" `Quick
            test_a_narrow_pane_draws_what_it_always_did
        ; test_case "every row gets the same badge" `Quick
            test_every_row_gets_the_same_badge
        ; test_case "scrolling past the top shows nothing" `Quick
            test_scrolling_past_the_top_yields_no_rows_rather_than_wrapping
        ] )
    ]
