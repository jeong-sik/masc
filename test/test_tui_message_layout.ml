open Alcotest

module Layout = Masc_tui_message_layout
module Frame = Masc_tui_frame
module Markdown_cache = Masc_tui_markdown_render_cache

let entry ?(timestamp = "12:34:56") ?timeline_bucket
    ?(markdown_source = Layout.Markdown_streaming) style role request_label body :
    Layout.entry =
  { style
  ; timestamp
  ; timeline_bucket
  ; role_label = role
  ; role_label_mark_cells =
      Layout.role_label_mark_cells ~style ()
  ; request_label
  ; body
  ; markdown_source
  }

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
  | [ metadata; gap; latest ] ->
      check bool "oversized newest entry keeps metadata" true
        (String.starts_with ~prefix:"[12:34:56]" metadata.text);
      (match gap.kind with
       | Layout.Viewport_gap { hidden_rows } ->
           check int "the viewport reports every omitted physical row"
             (List.length all_rows - 2) hidden_rows;
           check bool "the marker fits without the generic truncation mark" true
             (Layout.display_width gap.text <= 20
              && not (String.ends_with ~suffix:"~" gap.text))
       | Layout.Metadata _ | Layout.Body ->
           fail "oversized newest entry hid rows without a typed gap");
      check string "the newest body tail remains visible"
        (List.hd (List.rev all_rows)).text latest.text
  | [] -> fail "oversized newest entry rendered no rows"
  | _ -> fail "oversized newest entry did not spend exactly the viewport"

let test_inline_oversized_entry_marks_the_missing_middle () =
  let body = String.init 160 (fun index -> Char.chr (97 + (index mod 26))) in
  let newest = entry Layout.Keeper "keeper.one" "tui-..cccccccc" body in
  let all_rows =
    Layout.visible_rows ~origin:Layout.Origin_inline ~inner_width:20 ~height:100
      [ newest ]
  in
  match
    Layout.visible_rows ~origin:Layout.Origin_inline ~inner_width:20 ~height:4
      [ newest ]
  with
  | [ first; gap; penultimate; latest ] ->
      check bool "inline mode keeps the start that names the speaker" true
        (String.starts_with ~prefix:"abc" (String.trim first.text));
      check bool "a partial inline clock has no generic truncation mark" true
        (not (String.contains first.gutter '~'));
      (match gap.kind with
       | Layout.Viewport_gap { hidden_rows } ->
           check int "inline marker reports only rows not drawn"
             (List.length all_rows - 3) hidden_rows
       | Layout.Metadata _ | Layout.Body ->
           fail "inline oversized entry hid its middle without a typed gap");
      check bool "the two newest rows remain in chronological order" true
        (not (String.equal penultimate.text latest.text));
      check string "inline mode keeps the latest body bytes"
        (List.hd (List.rev all_rows)).text latest.text
  | _ -> fail "inline oversized entry did not expose its viewport gap"

let test_row_mode_keeps_the_heading_opening_and_latest_output () =
  let newest =
    entry Layout.Keeper "keeper.one" "tui-..cccccccc" (String.make 160 'x')
  in
  match Layout.visible_rows ~inner_width:20 ~height:4 [ newest ] with
  | [ metadata; opening; gap; latest ] ->
      check bool "the first row remains the typed origin" true
        (match metadata.kind with Layout.Metadata _ -> true | _ -> false);
      check string "the opening body row remains visible" ("  " ^ String.make 18 'x')
        opening.text;
      check bool "the missing middle remains explicit" true
        (match gap.kind with Layout.Viewport_gap _ -> true | _ -> false);
      check bool "the latest output remains a body row" true
        (match latest.kind with Layout.Body -> true | _ -> false)
  | _ -> fail "row mode did not preserve heading, opening, gap, and latest row"

let test_live_edge_collapses_repeated_wrapped_tail_rows () =
  let repeated_line = String.concat "" (List.init 9 (fun _ -> "가")) in
  let newest =
    entry Layout.Keeper "keeper.one" "turn-degenerate"
      (String.concat "\n" (List.init 12 (fun _ -> repeated_line)))
  in
  let visible = Layout.visible_rows ~inner_width:20 ~height:10 [ newest ] in
  let repeated_gaps =
    List.filter
      (fun (row : Layout.row) ->
         match row.kind with
         | Layout.Viewport_gap { hidden_rows } ->
           hidden_rows > 0
           && String.starts_with ~prefix:"↻" (String.trim row.text)
         | Layout.Metadata _ | Layout.Body -> false)
      visible
  in
  check int "one visible repeated run is collapsed" 1 (List.length repeated_gaps);
  check bool "live edge no longer fills with identical rows" true
    (List.length visible < 10);
  let scrolled =
    Layout.scrolled_rows ~inner_width:20 ~height:10 ~from_bottom:1 [ newest ]
  in
  check bool "PgUp still reveals only original transcript rows" true
    (List.for_all
       (fun (row : Layout.row) ->
          match row.kind with
          | Layout.Metadata _ | Layout.Body -> true
          | Layout.Viewport_gap _ -> false)
       scrolled)
;;

let test_oversized_entry_small_height_policy () =
  let newest =
    entry Layout.Keeper "keeper.one" "tui-..cccccccc" (String.make 160 'x')
  in
  List.iter
    (fun origin ->
      let all =
        Layout.visible_rows ~origin ~inner_width:20 ~height:100 [ newest ]
      in
      let first = List.hd all and latest = List.hd (List.rev all) in
      let visible height =
        Layout.visible_rows ~origin ~inner_width:20 ~height [ newest ]
      in
      check int "zero height draws nothing" 0 (List.length (visible 0));
      check (list string) "one row preserves identity/opening" [ first.text ]
        (List.map (fun (row : Layout.row) -> row.text) (visible 1));
      check (list string) "two rows preserve first and latest without pretending"
        [ first.text; latest.text ]
        (List.map (fun (row : Layout.row) -> row.text) (visible 2));
      match visible 3 with
      | [ kept_first; gap; kept_latest ] ->
          check string "three rows preserve the first" first.text kept_first.text;
          check bool "three rows can state the omission" true
            (match gap.kind with Layout.Viewport_gap _ -> true | _ -> false);
          check string "three rows preserve the latest" latest.text kept_latest.text
      | _ -> fail "three-row viewport omitted its first/gap/latest contract")
    [ Layout.Origin_row; Layout.Origin_inline ]

let test_scrolling_into_an_oversized_entry_shows_transcript_rows_only () =
  let newest =
    entry Layout.Keeper "keeper.one" "tui-..cccccccc" (String.make 160 'x')
  in
  let rows =
    Layout.scrolled_rows ~origin:Layout.Origin_inline ~inner_width:20 ~height:4
      ~from_bottom:1 [ newest ]
  in
  check bool "the gap is only a live-edge projection" true
    (List.for_all
       (fun (row : Layout.row) ->
         match row.kind with
         | Layout.Metadata _ | Layout.Body -> true
         | Layout.Viewport_gap _ -> false)
       rows)

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
  (* drop_cells is fit_width's left-edge counterpart: the Code pane's
     horizontal scroll. Styles crossed by the cut still open the remainder,
     and a wide scalar on the boundary pads rather than splits. *)
  check string "drop keeps the remainder" "cd" (Layout.drop_cells "abcd" 2);
  check string "zero drop is identity" "abcd" (Layout.drop_cells "abcd" 0);
  check string "over-length drop empties the row" ""
    (Layout.drop_cells "abcd" 9);
  check string "ANSI crossed by the cut still styles the remainder"
    "\x1B[31m\x1B[0m글" (Layout.drop_cells "\x1B[31m한\x1B[0m글" 2);
  check string "a wide scalar on the boundary pads its remaining cell"
    " 글" (Layout.drop_cells "한글" 1);
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

let test_word_delete_removes_blanks_then_word () =
  let word input = Layout.drop_last_utf8_word input in
  check string "last word goes, separator stays" "hello " (word "hello world");
  check string "trailing blanks go with the word" "hello  "
    (word "hello  world  ");
  check string "a second press walks the next word" "" (word "hello ");
  check string "a lone word empties the draft" "" (word "hello");
  check string "empty stays empty" "" (word "");
  check string "only blanks empty the draft" "" (word "   ");
  check string "tab is a separator" "hello\t" (word "hello\tworld");
  check string "newline is a separator" "one\n" (word "one\ntwo");
  check string "multi-byte words go whole" "한글 " (word "한글 단어");
  check string "multi-byte separator side survives" "한글 "
    (word "한글 세종🙂");
  let invalid = "word \xE2" in
  check string "invalid buffer is preserved" invalid (word invalid)

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
  let badge ?(style = Layout.Keeper) label =
    Layout.align_role_label ~style label
  in
  check int "short role label pads to the column"
    16 (Layout.display_width (badge "you"));
  check int "wide-char role label pads by cells not bytes"
    16 (Layout.display_width (badge "한글"));
  (* Right-aligned, so the cut is at the head: two canaries differ only in
     their tails and a head-preserving cut would draw them identically. *)
  check string "long role label loses its head, not its tail"
    ("\xe2\x97\x8f " ^ "…456789abcdefg")
    (badge "0123456789abcdefg");
  check string "column-width role label only pads"
    ("\xe2\x97\x8f " ^ "0123456789abcd")
    (badge "0123456789abcd");
  check string "short role label pads on the left"
    ("\xe2\x97\x8f " ^ String.make 11 ' ' ^ "you")
    (badge "you");
  (* The mark sits outside the truncation. Inside it, the labels that overrun
     would be the ones that lost their glyph -- and those are the names a
     reader most needs help telling apart. *)
  check bool "an overrunning label keeps its speaker mark" true
    (String.starts_with ~prefix:(Layout.speaker_mark Layout.User)
       (badge ~style:Layout.User "keeper-canary-10t-cdx-sol-xhigh-r2-agent"));
  (* Every style is distinguishable with no colour at all, which is what
     NO_COLOR leaves a reader. *)
  let marks =
    List.map Layout.speaker_mark
      [ Layout.User; Layout.Keeper; Layout.Status; Layout.Journal; Layout.Error;
        Layout.Tool; Layout.Thinking ]
  in
  check int "every speaker has its own mark" (List.length marks)
    (List.length (List.sort_uniq String.compare marks));
  (* The streaming turn says "live" where a settled row says "23:38". The
     gutter's width is what the body's width is taken from, so one cell of
     difference wrapped the live body differently from the rows it was about
     to become, and the text re-wrapped when the turn settled. *)
  let gutter_width timestamp =
    Layout.visible_rows ~origin:Layout.Origin_inline ~inner_width:80 ~height:200
      [ entry ~timestamp Layout.Keeper (badge "omega") "req" "body" ]
    |> List.filter_map (fun (row : Layout.row) ->
         let cells = Layout.display_width row.gutter in
         if cells = 0 then None else Some cells)
    |> function
    | width :: _ -> width
    | [] -> 0
  in
  (* Asserted non-zero first: rows without a margin measure zero on both
     sides, and a test that compares two zeroes passes whatever the clock
     does. *)
  check bool "the row has a margin to measure" true (gutter_width "23:38:42" > 0);
  check int "a streaming row's gutter matches a settled row's"
    (gutter_width "23:38:42") (gutter_width "live");
  (* Body width comes from what the badge leaves. Sizing the badge from the
     loaded labels meant one long speaker re-wrapped every body on the pane,
     the row count moved, and [msg_scroll] -- rows back from the newest --
     landed elsewhere in the conversation. Same body, same wrap, whatever
     the speaker is called. *)
  let body = String.concat " " (List.init 40 (fun i -> Printf.sprintf "w%02d" i)) in
  let wrapped label =
    Layout.visible_rows ~origin:Layout.Origin_inline ~inner_width:80
      ~height:200
      [ entry Layout.Keeper
          (Layout.align_role_label ~style:Layout.Keeper
             ~column:(Layout.chat_role_label_width ~pane_cells:80) label)
          "tui-..cccccccc" body
      ]
    |> List.length
  in
  check int "a long speaker name does not re-wrap the pane"
    (wrapped "omega")
    (wrapped "keeper-canary-10t-cdx-sol-xhigh-r2-20260820-agent · agent");
  let supported rows cols status_rows =
    Layout.message_viewport_supported ~terminal_rows:rows ~terminal_cols:cols
      ~status_rows
  in
  check bool "nine rows cannot show first, gap, and latest" false
    (supported 9 80 0);
  check bool "ten rows cannot fit two header rows and three history rows" false
    (supported 10 80 0);
  check bool "eleven rows fit three history rows" true (supported 11 80 0);
  check bool "status rows raise the minimum height" false
    (supported 13 80 3);
  check bool "status frame keeps three history rows" true
    (supported 14 80 3);
  check bool "twelve columns cannot preserve a source suffix" false
    (supported 30 12 0);
  check bool "thirteen columns preserve a source suffix" true
    (supported 30 13 0);
  check int "the minimum terminal leaves nine framed content cells" 9
    (Frame.inner_width ~cols:13)

let test_chat_history_height_uses_the_shared_chrome () =
  check int "46-row pane exposes 38 transcript rows" 38
    (Layout.message_history_height ~terminal_rows:46 ~status_rows:0);
  check int "three status rows reduce both viewport and page by three" 35
    (Layout.message_history_height ~terminal_rows:46 ~status_rows:3)

let test_chat_title_yields_before_projection_modes () =
  let modes = "  memory:off · reasoning:full · tools:full" in
  let row =
    Layout.chat_title_row ~inner_cells:52
      ~title:"Keepers ▸ a-very-long-keeper-identity ▸ chat"
      ~mode_suffix:modes
  in
  check int "title row keeps its exact budget" 52 (Layout.display_width row);
  check bool "projection modes survive title fitting" true
    (String.ends_with ~suffix:modes row)

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
        timeline_bucket = None;
        role_label = "code-reviewer";
        request_label = Printf.sprintf "turn-%d" index;
        body =
          Printf.sprintf
            "turn %d closed and wrote a line long enough that it wraps more \
             than once at the widths this test uses"
            index;
        role_label_mark_cells = 0;
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

let timeline_bucket ?(is_dst = false) hour : Layout.timeline_bucket =
  { tb_year = 2026
  ; tb_month = 9
  ; tb_day = 1
  ; tb_hour = hour
  ; tb_is_dst = is_dst
  }
;;

let test_timeline_breaks_follow_civil_hours () =
  let first =
    entry ~timeline_bucket:(timeline_bucket 18) Layout.Inbound "broadcast"
      "broadcast-18" "earlier lane"
  in
  let second =
    entry ~timeline_bucket:(timeline_bucket 18) Layout.Journal "JOURNAL"
      "journal-18" "same hour"
  in
  let third =
    entry ~timeline_bucket:(timeline_bucket 19) Layout.Keeper "keeper.one"
      "turn-19" "later hour"
  in
  let entries = [ first; second; third ] in
  let rows = Layout.visible_rows ~inner_width:60 ~height:30 entries in
  let breaks =
    List.filter_map
      (fun (row : Layout.row) ->
        match row.kind with
        | Layout.Metadata (Layout.Timeline_break bucket) ->
            Some (bucket.tb_hour, row.text)
        | Layout.Metadata (Layout.Origin _ | Layout.Continued_at _)
        | Layout.Body
        (* The fold marker is not a timeline rail. Named rather than matched
           by a wildcard, so the next row kind fails here instead of being
           silently counted as "not a rail". *)
        | Layout.Viewport_gap _ ->
            None)
      rows
  in
  check (list int) "one rail at the first row of each civil hour" [ 18; 19 ]
    (List.map fst breaks);
  check bool "the first rail names its local date and hour" true
    (String.starts_with
       ~prefix:"\xe2\x94\x80\xe2\x94\x80 2026-09-01 \xc2\xb7 18:00 "
       (List.assoc 18 breaks));
  check bool "the later rail names its local date and hour" true
    (String.starts_with
       ~prefix:"\xe2\x94\x80\xe2\x94\x80 2026-09-01 \xc2\xb7 19:00 "
       (List.assoc 19 breaks));
  check int "full transcript counts two rails" 8
    (Layout.total_rows ~inner_width:60 entries);
  check int "suffix count reuses the preceding hour rail" 5
    (Layout.total_rows ~previous:first ~inner_width:60 [ second; third ])
;;

let test_tiny_viewport_keeps_message_over_hour_rail () =
  let newest =
    entry ~timeline_bucket:(timeline_bucket 19) Layout.Keeper "keeper.one"
      "turn-19" "latest body"
  in
  match Layout.visible_rows ~inner_width:60 ~height:2 [ newest ] with
  | [ { Layout.kind = Layout.Metadata (Layout.Origin _); _ }
    ; { Layout.kind = Layout.Body; text; _ }
    ] ->
      check string "the newest body remains visible" "  latest body" text
  | _ -> fail "a cramped viewport let the hour rail hide the newest message"
;;

let test_oversized_hour_group_counts_its_deferred_rail () =
  let newest =
    entry ~timeline_bucket:(timeline_bucket 19) Layout.Keeper "keeper.one"
      "turn-19" (String.make 160 'x')
  in
  let all = Layout.visible_rows ~inner_width:20 ~height:100 [ newest ] in
  (match Layout.visible_rows ~inner_width:20 ~height:3 [ newest ] with
   | [ { Layout.kind = Layout.Metadata (Layout.Origin _); _ }
     ; { Layout.kind = Layout.Viewport_gap { hidden_rows }; _ }
     ; { Layout.kind = Layout.Body; _ }
     ] ->
       check int "the explicit gap counts the deferred rail and body middle"
         (List.length all - 2) hidden_rows
   | _ -> fail "an oversized hour group hid rows without its typed gap");
  match
    Layout.scrolled_rows ~inner_width:20 ~height:1
      ~from_bottom:(List.length all - 1) [ newest ]
  with
  | [ { Layout.kind = Layout.Metadata (Layout.Timeline_break _); _ } ] -> ()
  | _ -> fail "the deferred hour rail was not reachable in scrollback"
;;

let test_compact_origin_modes_keep_and_reach_the_hour_rail () =
  let newest =
    entry ~timeline_bucket:(timeline_bucket 19) Layout.Keeper "keeper.one"
      "turn-19" "latest body"
  in
  List.iter
    (fun (name, origin) ->
      (match
         Layout.visible_rows ~origin ~inner_width:60 ~height:2 [ newest ]
       with
       | [ { Layout.kind = Layout.Metadata (Layout.Timeline_break _); _ }
         ; { Layout.kind = Layout.Body; text; _ }
         ] ->
           check string (name ^ " body follows its fitting hour rail")
             "  latest body" text
       | _ -> fail (name ^ " dropped an hour rail that fit exactly"));
      match
        Layout.scrolled_rows ~origin ~inner_width:60 ~height:1 ~from_bottom:1
          [ newest ]
      with
      | [ { Layout.kind = Layout.Metadata (Layout.Timeline_break _); _ } ] -> ()
      | _ -> fail (name ^ " made a cramped hour rail unreachable by scrolling"))
    [ "inline", Layout.Origin_inline; "bare", Layout.Origin_bare ]
;;

let test_repeated_dst_hour_has_distinct_rails () =
  let daylight =
    entry ~timeline_bucket:(timeline_bucket ~is_dst:true 1) Layout.Inbound
      "broadcast" "daylight" "first 01:00"
  in
  let standard =
    entry ~timeline_bucket:(timeline_bucket 1) Layout.Keeper "keeper.one"
      "standard" "second 01:00"
  in
  let labels =
    Layout.visible_rows ~inner_width:60 ~height:10 [ daylight; standard ]
    |> List.filter_map (fun (row : Layout.row) ->
         match row.kind with
         | Layout.Metadata (Layout.Timeline_break _) -> Some row.text
         | Layout.Metadata (Layout.Origin _ | Layout.Continued_at _)
         | Layout.Body
         | Layout.Viewport_gap _ ->
             None)
  in
  check int "the repeated civil hour keeps both rails" 2 (List.length labels);
  match labels with
  | daylight_label :: standard_label :: [] ->
      check bool "the daylight occurrence says DST" true
        (String.starts_with
           ~prefix:"\xe2\x94\x80\xe2\x94\x80 2026-09-01 \xc2\xb7 01:00 DST "
           daylight_label);
      check bool "the standard occurrence is visibly distinct" true
        (String.starts_with
           ~prefix:"\xe2\x94\x80\xe2\x94\x80 2026-09-01 \xc2\xb7 01:00 "
           standard_label);
      check bool "the standard occurrence does not claim daylight time" false
        (String.starts_with
           ~prefix:"\xe2\x94\x80\xe2\x94\x80 2026-09-01 \xc2\xb7 01:00 DST "
           standard_label)
  | _ -> fail "the repeated civil hour did not produce two labels"
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

(* [msg_scroll] counts rows back from the newest, and the field says what it
   is for:

     Held rather than derived: an operator reading back should stay where
     they are while the keeper keeps talking.

   Counting from the newest end does the opposite. A reply arriving adds rows
   at that end, so the same count lands that many rows further down and the
   window slides toward the new text the operator was not reading. *)
let test_a_new_message_does_not_move_a_scrolled_window () =
  let window requested entries =
    Layout.clamped_scrolled_rows ~inner_width:40 ~height:4 ~requested entries
    |> snd |> text_of
  in
  let before = window 4 ten_entries in
  let arrival =
    entry ~timestamp:"12:35:00" Layout.Keeper "keeper.one" "tui-..dddddddd"
      "a reply the operator has not scrolled to"
  in
  let after_arrival = ten_entries @ [ arrival ] in
  (* The defect: the count alone lands that many rows further down, so the
     window slides toward the reply. *)
  check bool "the count alone does not hold the position" false
    (window 4 after_arrival = before);
  (* The contract the pane relies on: give the count back the rows that
     arrived and the operator is looking at the same text. *)
  let grew = Layout.total_rows ~inner_width:40 [ arrival ] in
  check bool "and the reply is not free" true (grew > 0);
  check (list string) "the operator keeps reading the same rows" before
    (window (4 + grew) after_arrival)

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

(* The ladder did not go past minutes, and the Fusion table drew every one of
   its 28 rows through it: [12045m~], five figures cut by a seven-cell column,
   so a day-old run and a nine-day-old run were the same shape.

   The widest reading is what a column has to hold, so it is pinned: a span
   just under a year is seven cells, which is what the Fusion column already
   was. *)
let test_an_age_climbs_to_hours_and_days () =
  List.iter
    (fun (seconds, expected) ->
      check (option string)
        (Printf.sprintf "%.0f seconds" seconds)
        (Some expected)
        (Layout.age_text ~now:seconds ~since:0.))
    [ (3599., "59m59s")
    ; (3600., "1h00m")
    ; (41989., "11h39m")
    ; (86399., "23h59m")
    ; (86400., "1d00h")
    ; (722_730., "8d08h")
    ; (31_535_999., "364d23h")
    ];
  check bool "the widest reading fits the column it is drawn in" true
    (match Layout.age_text ~now:31_535_999. ~since:0. with
     | Some text -> String.length text <= 7
     | None -> false)

(* One ladder, two ways in. They differ in what a span from the future means
   -- an age says nothing, a duration clamps -- not in how a span reads. *)
let test_the_two_spellings_of_a_span_agree () =
  List.iter
    (fun seconds ->
      check (option string)
        (Printf.sprintf "%.0f seconds reads the same either way" seconds)
        (Some (Layout.span_text seconds))
        (Layout.age_text ~now:seconds ~since:0.))
    [ 42.; 134.; 41989.; 722_730. ]

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

(* The badge used to be measured from the labels on the pane, so that
   [codex-mcp-client] would not read as [codex-mcp-clien…] against the old
   16-cell constant. It fixed that and bought a worse problem: body width is
   taken from what the badge leaves, so the width of one speaker's name set
   how every message on the pane wrapped. Sampled from one live chat, the
   labels ran from 13 cells ("admin · agent") to 57
   ("keeper-canary-10t-cdx-sol-xhigh-r2-20260820-agent · agent"), and the
   quarter-of-the-pane ceiling meant a canary posting once took 51 of 205
   cells and gave them back on the next message. Every body re-wrapped both
   times, and [msg_scroll] counts rows back from the newest, so the operator's
   place in the conversation moved with it.

   The badge is a budget now. Built-in activity labels read whole; an opaque
   name past the budget loses its head rather than its tail, because these
   labels are [agent · surface] and share long prefixes. *)
let test_badge_is_a_budget_not_a_measurement () =
  let width = Layout.chat_role_label_width ~pane_cells:200 in
  check int "a wide pane spends the budget and no more" 14 width;
  List.iter
    (fun label ->
      let drawn =
        Layout.align_role_label ~column:width ~style:Layout.Keeper label
      in
      check bool (label ^ " reads whole") true
        (String.equal label (String.trim (Layout.drop_cells drawn 2))))
    [ "JOURNAL"; "THINKING" ]

let test_badge_keeps_the_tail_when_it_cannot_fit () =
  let width = Layout.chat_role_label_width ~pane_cells:200 in
  let long = "keeper-canary-10t-cdx-sol-xhigh-r2-20260820-agent \xc2\xb7 agent" in
  let drawn = Layout.align_role_label ~column:width ~style:Layout.Keeper long in
  check int "the badge still spends exactly its budget" width
    (Layout.display_width drawn);
  (* The mark leads and the ellipsis follows it: the cut is still at the head
     of the name, and the glyph is outside the cut so the longest labels are
     not the ones that lose it. *)
  let mark = Layout.speaker_mark Layout.Keeper ^ " " in
  check bool "the mark leads the badge" true
    (String.starts_with ~prefix:mark drawn);
  check bool "the head is what goes" true
    (String.starts_with ~prefix:(mark ^ "\xe2\x80\xa6") drawn);
  check bool "the surface survives the cut" true
    (let suffix = "agent" in
     let n = String.length drawn and m = String.length suffix in
     n >= m && String.sub drawn (n - m) m = suffix)

let test_badge_narrows_with_the_pane () =
  (* The fixed floor keeps every built-in activity label; wider panes add a
     small, bounded amount for speaker identities. *)
  check int "a wide pane spends the budget" 14
    (Layout.chat_role_label_width ~pane_cells:400);
  check int "40-cell pane keeps the compact badge" 10
    (Layout.chat_role_label_width ~pane_cells:40);
  check int "16-cell pane keeps the compact badge" 10
    (Layout.chat_role_label_width ~pane_cells:16)

let test_one_long_name_cannot_crowd_the_messages () =
  let pane = 80 in
  let width = Layout.chat_role_label_width ~pane_cells:pane in
  check bool "the badge stays within a quarter of the pane" true
    (width <= pane / 4);
  check bool "so the body keeps most of the width" true
    (pane - width > pane / 2)

let test_a_narrow_pane_keeps_the_builtin_labels () =
  check int "40-cell pane" 10 (Layout.chat_role_label_width ~pane_cells:40);
  check int "16-cell pane" 10 (Layout.chat_role_label_width ~pane_cells:16)

let test_every_row_gets_the_same_badge () =
  (* Alignment is the reason the badge exists: one width for the pane, not
     one per row. *)
  let width = Layout.chat_role_label_width ~pane_cells:200 in
  List.iter
    (fun label ->
      check int ("badge width for " ^ label) width
        (Layout.display_width (Layout.align_role_label ~column:width ~style:Layout.Keeper label)))
    [ "you"; "analyst"; "tools"; "thinking" ]

(* The origin heading costs a row per message. Folding it into the margin is
   what buys those rows back, so the count is the claim worth pinning. *)
let origin_entries () =
  [ entry Layout.User "you" "tui-..aaaaaaaa" "first"
  ; entry ~timestamp:"12:35:00" Layout.Keeper "keeper.one" "tui-..bbbbbbbb"
      "second"
  ]

let test_row_mode_draws_what_it_always_did () =
  let rows =
    Layout.visible_rows ~inner_width:40 ~height:20 (origin_entries ())
  in
  check bool "every gutter empty" true
    (List.for_all (fun (row : Layout.row) -> String.equal row.gutter "") rows);
  check bool "headings still have their own rows" true
    (List.exists
       (fun (row : Layout.row) ->
         match row.kind with
         | Layout.Metadata _ -> true
         | Layout.Body | Layout.Viewport_gap _ -> false)
       rows)

let test_folding_returns_one_row_per_message () =
  let entries = origin_entries () in
  let full = Layout.total_rows ~inner_width:40 entries in
  let inline =
    Layout.total_rows ~origin:Layout.Origin_inline ~inner_width:40 entries
  in
  let bare =
    Layout.total_rows ~origin:Layout.Origin_bare ~inner_width:40 entries
  in
  check int "inline drops a row per message" (full - 2) inline;
  check int "bare drops the same" (full - 2) bare;
  check bool "no metadata rows survive" true
    (List.for_all
       (fun (row : Layout.row) ->
         match row.kind with
         | Layout.Metadata _ | Layout.Viewport_gap _ -> false
         | Layout.Body -> true)
       (Layout.visible_rows ~origin:Layout.Origin_inline ~inner_width:40
          ~height:20 entries))

let first_gutter ~origin entries =
  match Layout.visible_rows ~origin ~inner_width:40 ~height:20 entries with
  | row :: _ -> row.Layout.gutter
  | [] -> failwith "no rows"

let test_inline_margin_carries_clock_and_speaker () =
  let entries = [ entry Layout.User "you" "tui-..aaaaaaaa" "hello" ] in
  check string "clock cut to the minute, speaker kept" "12:34 you"
    (first_gutter ~origin:Layout.Origin_inline entries);
  check string "bare keeps the speaker only" "you"
    (first_gutter ~origin:Layout.Origin_bare entries)

let inline_rows ~terminal_cols source =
  let inner_width = Frame.inner_width ~cols:terminal_cols in
  let role =
    (* The column is [align_role_label]'s own default, so it is left to it:
       spelling it here needed the constant exported, and it is not. *)
    Layout.align_role_label ~style:Layout.Keeper source
  in
  let rows =
    Layout.visible_rows ~origin:Layout.Origin_inline ~inner_width ~height:20
      [ entry Layout.Keeper role "tui-..bbbbbbbb" "hello" ]
  in
  match rows with
  | row :: _ -> row, rows
  | [] -> failwith "no rows"

(* The clock used to take the narrow gutter from the left and cut the source
   away before its first cell. These widths exercise the smallest supported
   pane and two wider ceilings. The two source names share their head and
   differ at the tail, so distinct suffixes prove that the identity -- not
   just a generic speaker mark -- survived. *)
let test_a_narrow_inline_margin_keeps_the_source () =
  List.iter
    (fun terminal_cols ->
      let inner_width = Frame.inner_width ~cols:terminal_cols in
      let one, one_rows = inline_rows ~terminal_cols "keeper.aa" in
      let two, two_rows = inline_rows ~terminal_cols "keeper.zz" in
      check bool
        (Printf.sprintf "%d terminal cells keep source aa" terminal_cols)
        true (String.ends_with ~suffix:"aa" one.Layout.gutter);
      check bool
        (Printf.sprintf "%d terminal cells keep source zz" terminal_cols)
        true (String.ends_with ~suffix:"zz" two.Layout.gutter);
      check bool
        (Printf.sprintf "%d terminal cells keep sources distinct" terminal_cols)
        true (not (String.equal one.Layout.gutter two.Layout.gutter));
      check int
        (Printf.sprintf "%d terminal cells omit the truncated mark" terminal_cols)
        0 one.Layout.gutter_label_at;
      check int
        (Printf.sprintf "%d terminal cells omit the other truncated mark"
           terminal_cols)
        0 two.Layout.gutter_label_at;
      check bool
        (Printf.sprintf "%d terminal cells remove the mark bytes" terminal_cols)
        false
        (String.starts_with ~prefix:(Layout.speaker_mark Layout.Keeper)
           one.Layout.gutter);
      List.iter
        (fun (row : Layout.row) ->
          check bool
            (Printf.sprintf "%d-terminal-cell row stays inside %d content cells"
               terminal_cols inner_width)
            true
            (Layout.display_width row.Layout.gutter
             + Layout.display_width row.Layout.text
            <= inner_width))
        (one_rows @ two_rows))
    [ 13; 16; 24 ]

(* A normal pane has room for both pieces. Pin the exact bytes, including the
   aligned badge, and the continuation rule: keep the clock, drop the repeated
   source, keep the speaker's own mark, and retain the first gutter's width. *)
let test_normal_inline_margin_bytes_stay_stable () =
  let role =
    (* The column is [align_role_label]'s own default, so it is left to it:
       spelling it here needed the constant exported, and it is not. *)
    Layout.align_role_label ~style:Layout.Keeper "keeper.one"
  in
  let entries =
    [ entry ~timestamp:"12:34:56" Layout.Keeper role "tui-..bbbbbbbb" "first"
    ; entry ~timestamp:"12:35:56" Layout.Keeper role "tui-..bbbbbbbb" "second"
    ]
  in
  let inner_width = Frame.inner_width ~cols:40 in
  match
    Layout.visible_rows ~origin:Layout.Origin_inline ~inner_width ~height:20
      entries
  with
  | [ first; second ] ->
      check string "normal first gutter bytes"
        ("12:34 " ^ Layout.speaker_mark Layout.Keeper ^ "     keeper.one")
        first.Layout.gutter;
      check string "normal continuation bytes"
        ("12:35 " ^ Layout.speaker_mark Layout.Keeper ^ String.make 15 ' ')
        second.Layout.gutter;
      check int "normal gutter keeps clock plus mark boundary" 8
        first.Layout.gutter_label_at;
      check int "continuation has no source boundary" 0
        second.Layout.gutter_label_at;
      check int "continuation keeps the first gutter width"
        (Layout.display_width first.Layout.gutter)
        (Layout.display_width second.Layout.gutter)
  | _ -> failwith "expected two rows"

(* A timestamp that is not [HH:MM:SS] is left alone rather than cut blind:
   the shortener is a normaliser, and the case where it does nothing is the
   one that would otherwise lose bytes silently. *)
let test_a_timestamp_of_another_shape_survives () =
  let entries = [ entry ~timestamp:"just now" Layout.User "you" "r" "hello" ] in
  check string "unshortened" "just now you"
    (first_gutter ~origin:Layout.Origin_inline entries)

let test_wrapped_rows_indent_under_the_first () =
  let entries =
    [ entry Layout.Keeper "keeper.one" "tui-..bbbbbbbb" (String.make 300 'w') ]
  in
  match
    Layout.visible_rows ~origin:Layout.Origin_inline ~inner_width:40 ~height:20
      entries
  with
  | [] | [ _ ] -> failwith "expected a wrapped body"
  | first :: rest ->
      let width = Layout.display_width first.Layout.gutter in
      check bool "first row names the origin" true
        (String.trim first.Layout.gutter <> "");
      check bool "continuations indent to the same column" true
        (List.for_all
           (fun (row : Layout.row) ->
             String.trim row.Layout.gutter = ""
             && Layout.display_width row.Layout.gutter = width)
           rest)

let test_a_second_message_from_one_speaker_stays_blank () =
  let entries =
    [ entry Layout.Keeper "keeper.one" "tui-..bbbbbbbb" "first"
    ; entry Layout.Keeper "keeper.one" "tui-..bbbbbbbb" "second"
    ]
  in
  let rows =
    Layout.visible_rows ~origin:Layout.Origin_inline ~inner_width:40 ~height:20
      entries
  in
  check int "one row apiece" 2 (List.length rows);
  match rows with
  | [ first; second ] ->
      check bool "the first names the speaker" true
        (String.trim first.Layout.gutter <> "");
      (* A continuation drops the name and keeps the clock. The name is what
         repeats and says nothing; the gap between two things one speaker said
         is what a reader checks in this column, and blanking the whole margin
         took that away too. The mark stays the speaker's own -- the renderer
         draws the whole continuation gutter quiet, and that is what says the
         row is lower than the one that started it. *)
      check int "the second keeps the column's width" 
        (Layout.display_width first.Layout.gutter)
        (Layout.display_width second.Layout.gutter);
      check bool "the second keeps its clock" true
        (String.length (String.trim second.Layout.gutter) > 0);
      check bool "the second does not repeat the name" true
        (not (String.equal first.Layout.gutter second.Layout.gutter))
  | _ -> failwith "expected two rows"

(* The layout hands the renderer a margin and the offset to cut it at, and the
   renderer draws the two halves back to back so the mark can keep the status
   colour while the kind label recedes. A continuation carries no name, so it
   asks to be cut at zero -- and a cut that still hands back a piece at zero
   cells drew the clock's first digit twice. On the Keepers pane a row sent at
   22:32 read "222:32": the layout was right and the drawing was not, which is
   why the test above could not see it. *)
(* A continuation used to borrow [Thinking]'s dot on the argument that reusing
   a glyph keeps the alphabet closed. It closed nothing: the dot then meant
   both "reasoning" and "the same speaker is still talking", and a second
   autonomous message read as a block of reasoning -- same glyph, same grey,
   and no name, because a continuation drops the name too. *)
let test_a_continuation_does_not_borrow_the_reasoning_glyph () =
  let continued style =
    match
      Layout.visible_rows ~origin:Layout.Origin_inline ~inner_width:40
        ~height:20
        [ entry style "auto" "tui-..cccccccc" "first"
        ; entry style "auto" "tui-..cccccccc" "second"
        ]
    with
    | [ _; second ] ->
        (* The gutter is "<clock> <mark>" once the padding is trimmed; the mark
           is what this is about. *)
        let trimmed = String.trim second.Layout.gutter in
        (match String.rindex_opt trimmed ' ' with
         | Some index ->
             String.sub trimmed (index + 1) (String.length trimmed - index - 1)
         | None -> trimmed)
    | _ -> failwith "expected two rows"
  in
  check string "a keeper's continuation keeps the keeper's mark"
    (Layout.speaker_mark Layout.Keeper)
    (continued Layout.Keeper);
  check string "a tool block's continuation keeps the tool mark"
    (Layout.speaker_mark Layout.Tool)
    (continued Layout.Tool);
  check bool "and so is not the reasoning mark" true
    (not
       (String.equal
          (Layout.speaker_mark Layout.Thinking)
          (continued Layout.Keeper)));
  (* Reasoning's own continuation still draws a dot, because that is what it
     is. The glyph is ambiguous only when it is borrowed. *)
  check string "reasoning continues as reasoning"
    (Layout.speaker_mark Layout.Thinking)
    (continued Layout.Thinking)

(* Every speaker draws a different mark. A shared glyph is how the pane came to
   say two things with one shape. *)
let test_every_speaker_mark_is_distinct () =
  let marks =
    List.map Layout.speaker_mark
      [ Layout.User; Layout.Inbound; Layout.Keeper; Layout.Status
      ; Layout.Journal; Layout.Error; Layout.Tool; Layout.Thinking
      ]
  in
  check int "no two speakers share a mark" (List.length marks)
    (List.length (List.sort_uniq String.compare marks))

let test_skill_marks_keep_state_without_colour () =
  check (list string) "live used warning and failure keep distinct shapes"
    [ "\xe2\x97\x87"; "\xe2\x97\x86"; "\xe2\x96\xb3"; "\xe2\x9c\x97" ]
    (List.map Layout.speaker_mark
       [ Layout.Skill Layout.Skill_live
       ; Layout.Skill Layout.Skill_used
       ; Layout.Skill Layout.Skill_attention
       ; Layout.Skill Layout.Skill_failure
       ]);
  List.iter
    (fun tone ->
      let rows =
        Layout.visible_rows ~inner_width:40 ~height:10
          [ entry (Layout.Skill tone) "SKILL" "trace-1#54" "evidence" ]
      in
      (* [Body] only. The evidence is the machine output; the rows around it
         are chrome -- the metadata header naming the trace, and the fold
         marker a short viewport inserts. Neither is quoted, and neither
         should be: a [for_all] over every row read their shade as the
         evidence losing its own.

         This assertion could not have held since [visible_rows] began
         emitting the header row. It went unseen because the suite did not
         compile, so nothing ran it. *)
      let evidence =
        List.filter
          (fun (row : Layout.row) ->
            match row.kind with
            | Layout.Body -> true
            | Layout.Metadata _ | Layout.Viewport_gap _ -> false)
          rows
      in
      check bool "the sample holds evidence rows" true (evidence <> []);
      check bool "Skill evidence is a quoted machine-produced block" true
        (List.for_all
           (fun (row : Layout.row) -> row.shade = Layout.Shade_quoted)
           evidence))
    [ Layout.Skill_live; Layout.Skill_used; Layout.Skill_attention
    ; Layout.Skill_failure
    ]

(* The badge is drawn in reverse video, while its fixed-column padding is
   layout rather than content. *)
let test_alignment_padding_is_kept_apart_from_the_name () =
  let aligned = Layout.align_role_label ~column:16 ~style:Layout.Keeper "AUTO" in
  let mark, name, alignment =
    Layout.split_aligned_role_label ~style:Layout.Keeper aligned
  in
  check bool "the mark leads" true
    (String.starts_with ~prefix:(Layout.speaker_mark Layout.Keeper) mark);
  check bool "the alignment is only spaces" true
    (String.length alignment > 0
     && String.for_all (fun c -> Char.equal c ' ') alignment);
  check string "the name is the label alone" "AUTO" name;
  check string "the three pieces rebuild the label" aligned
    (mark ^ name ^ alignment);
  (* A column too narrow for both drops the mark, and the split says so rather
     than colouring the first byte of a name as though it were one. *)
  let narrow = Layout.align_role_label ~column:2 ~style:Layout.Keeper "AUTO" in
  let mark, name, alignment =
    Layout.split_aligned_role_label ~style:Layout.Keeper narrow
  in
  check string "a markless label reports no mark" "" mark;
  check string "the three pieces still rebuild it" narrow
    (mark ^ name ^ alignment)

let test_a_continuation_survives_the_renderer_cut () =
  let entries =
    [ entry ~timestamp:"22:32:07" Layout.Keeper "keeper.one" "tui-..bbbbbbbb"
        "first"
    ; entry ~timestamp:"22:32:41" Layout.Keeper "keeper.one" "tui-..bbbbbbbb"
        "second"
    ]
  in
  let rows =
    Layout.visible_rows ~origin:Layout.Origin_inline ~inner_width:40 ~height:20
      entries
  in
  match rows with
  | [ _; second ] ->
      let gutter = second.Layout.gutter in
      let at = second.Layout.gutter_label_at in
      (* Asserted rather than assumed: this row is the whole reason a zero cut
         happens here, and a continuation that started reporting a boundary
         would leave the checks below passing on a row that was never it. *)
      check int "a continuation asks to be cut at zero" 0 at;
      check string "the renderer redraws the margin it was given" gutter
        (Layout.take_cells gutter at ^ Layout.drop_cells gutter at);
      check string "the clock reads once" "22:32"
        (Layout.take_cells gutter at ^ Layout.drop_cells gutter at
        |> fun redrawn -> Layout.take_cells redrawn 5)
  | _ -> failwith "expected two rows"
;;

(* Two readers, one rule. The pane underlines a bare URL and something else
   names what it points at, and a URL that ended in one place for the
   underline and another for the name would underline text the name had not
   read -- or name a link the reader never saw as one. Asserted by dressing
   the text and taking back exactly what was dressed. *)
let substrings_between ~opening ~closing text =
  let length = String.length text in
  let find needle from =
    let needle_length = String.length needle in
    let rec go index =
      if index + needle_length > length then None
      else if String.equal (String.sub text index needle_length) needle then
        Some index
      else go (index + 1)
    in
    go from
  in
  let opening_length = String.length opening in
  let rec go from found =
    match find opening from with
    | None -> List.rev found
    | Some start -> (
        match find closing (start + opening_length) with
        | None -> List.rev found
        | Some stop ->
            go
              (stop + String.length closing)
              (String.sub text (start + opening_length)
                 (stop - start - opening_length)
              :: found))
  in
  go 0 []

let test_the_two_link_readers_agree () =
  List.iter
    (fun (name, text) ->
      let dressed =
        Layout.dress_bare_links ~open_style:"<a>" ~close_style:"</a>" text
      in
      check (list string)
        (name ^ ": dressed exactly what bare_urls names")
        (Layout.bare_urls text)
        (substrings_between ~opening:"<a>" ~closing:"</a>" dressed))
    [ ("prose around them",
       "see https://github.com/o/r/pull/1, and (http://x.test/y) then done")
    ; ("none at all", "nothing to follow here")
    ; ("two in a row", "https://a.test/one https://a.test/two")
    ; ("closed by punctuation", "the evidence (https://a.test/x).")
    ; ("at the very end", "read https://a.test/z")
    ]

(* The margin is paid for out of the body, not out of the frame. A row that
   drew its own width plus a margin would spill past the border it sits in. *)
let test_the_margin_comes_out_of_the_body () =
  let entries =
    [ entry Layout.User "a-rather-long-speaker" "tui-..aaaaaaaa"
        (String.make 400 'x')
    ]
  in
  List.iter
    (fun origin ->
      List.iter
        (fun inner ->
          List.iter
            (fun (row : Layout.row) ->
              check bool
                (Printf.sprintf "row fits %d cells" inner)
                true
                (Layout.display_width row.Layout.gutter
                 + Layout.display_width row.Layout.text
                <= inner))
            (Layout.visible_rows ~origin ~inner_width:inner ~height:20 entries))
        [ 16; 24; 40; 80 ])
    [ Layout.Origin_row; Layout.Origin_inline; Layout.Origin_bare ]

(* Every scroll function has to measure the mode the pane draws. Given one
   mode for the clamp and another for the slice, the pane comes out a row
   short of where it says it is. *)
let test_scrolling_measures_the_mode_it_draws () =
  let entries =
    List.init 12 (fun index ->
      entry
        ~timestamp:(Printf.sprintf "12:%02d:00" index)
        Layout.Keeper
        (Printf.sprintf "keeper.%d" index)
        "tui-..bbbbbbbb"
        (String.make 90 'b'))
  in
  List.iter
    (fun origin ->
      let height = 6 in
      let total = Layout.total_rows ~origin ~inner_width:40 entries in
      let bound = Layout.max_scroll ~origin ~inner_width:40 ~height entries in
      check int "max scroll agrees with the total" (max 0 (total - height))
        bound;
      List.iter
        (fun requested ->
          let clamped, rows =
            Layout.clamped_scrolled_rows ~origin ~inner_width:40 ~height
              ~requested entries
          in
          check int "clamped agrees with clamp_scroll"
            (Layout.clamp_scroll ~origin ~inner_width:40 ~height requested
               entries)
            clamped;
          check bool "the window never exceeds the height" true
            (List.length rows <= height))
        [ 0; 1; 5; bound; bound + 4 ])
    [ Layout.Origin_row; Layout.Origin_inline; Layout.Origin_bare ]

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
        ; test_case "inline oversized entry marks the missing middle" `Quick
            test_inline_oversized_entry_marks_the_missing_middle
        ; test_case "row mode keeps heading, opening, and latest output" `Quick
            test_row_mode_keeps_the_heading_opening_and_latest_output
        ; test_case "live edge collapses repeated wrapped tail rows" `Quick
            test_live_edge_collapses_repeated_wrapped_tail_rows
        ; test_case "oversized entry has an explicit small-height policy" `Quick
            test_oversized_entry_small_height_policy
        ; test_case "scrolling shows transcript rows without synthetic gaps" `Quick
            test_scrolling_into_an_oversized_entry_shows_transcript_rows_only
        ; test_case "civil-hour rails are structural and deduplicated" `Quick
            test_timeline_breaks_follow_civil_hours
        ; test_case "a tiny viewport keeps the message before its hour rail"
            `Quick test_tiny_viewport_keeps_message_over_hour_rail
        ; test_case "oversized hour groups count their deferred rail" `Quick
            test_oversized_hour_group_counts_its_deferred_rail
        ; test_case "compact origin modes keep and reach the hour rail" `Quick
            test_compact_origin_modes_keep_and_reach_the_hour_rail
        ; test_case "DST fallback hours remain visibly distinct" `Quick
            test_repeated_dst_hour_has_distinct_rails
        ; test_case "terminal cell width and UTF-8 fit" `Quick
            test_terminal_cell_width_and_fit
        ; test_case "the scroll hint says how far back" `Quick
            test_scroll_hint_says_how_far_back
        ; test_case "UTF-8 scalar input contract" `Quick
            test_utf8_scalar_input_contract
        ; test_case "backspace removes one UTF-8 scalar" `Quick
            test_backspace_removes_one_utf8_scalar
        ; test_case "word delete removes blanks then word" `Quick
            test_word_delete_removes_blanks_then_word
        ; test_case "input viewport keeps latest scalars" `Quick
            test_input_viewport_keeps_latest_complete_scalars
        ; test_case "input cursor uses visible cells" `Quick
            test_input_cursor_uses_visible_terminal_cells
        ; test_case "history height uses the shared chrome" `Quick
            test_chat_history_height_uses_the_shared_chrome
        ; test_case "chat title yields before projection modes" `Quick
            test_chat_title_yields_before_projection_modes
        ; test_case "last page start counts rows" `Quick
            test_last_page_start_counts_rows_not_items
        ; test_case "last page keeps the last item reachable" `Quick
            test_last_page_start_keeps_the_last_item_reachable
        ; test_case "age reads as seconds then minutes" `Quick
            test_age_reads_as_seconds_then_minutes
        ; test_case "an age climbs to hours and days" `Quick
            test_an_age_climbs_to_hours_and_days
        ; test_case "the two spellings of a span agree" `Quick
            test_the_two_spellings_of_a_span_agree
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
        ; test_case "a new message does not move a scrolled window" `Quick
            test_a_new_message_does_not_move_a_scrolled_window
        ; test_case "max scroll stops at the oldest row" `Quick
            test_max_scroll_stops_at_the_oldest_row
        ; test_case "badge is a budget, not a measurement" `Quick
            test_badge_is_a_budget_not_a_measurement
        ; test_case "badge keeps the tail when it cannot fit" `Quick
            test_badge_keeps_the_tail_when_it_cannot_fit
        ; test_case "badge narrows with the pane" `Quick
            test_badge_narrows_with_the_pane
        ; test_case "one long name cannot crowd the messages" `Quick
            test_one_long_name_cannot_crowd_the_messages
        ; test_case "a narrow pane keeps built-in labels" `Quick
            test_a_narrow_pane_keeps_the_builtin_labels
        ; test_case "every row gets the same badge" `Quick
            test_every_row_gets_the_same_badge
        ; test_case "origin rows draw what they always did" `Quick
            test_row_mode_draws_what_it_always_did
        ; test_case "folding returns one row per message" `Quick
            test_folding_returns_one_row_per_message
        ; test_case "inline margin carries clock and speaker" `Quick
            test_inline_margin_carries_clock_and_speaker
        ; test_case "a narrow inline margin keeps the source" `Quick
            test_a_narrow_inline_margin_keeps_the_source
        ; test_case "normal inline margin bytes stay stable" `Quick
            test_normal_inline_margin_bytes_stay_stable
        ; test_case "a timestamp of another shape survives" `Quick
            test_a_timestamp_of_another_shape_survives
        ; test_case "wrapped rows indent under the first" `Quick
            test_wrapped_rows_indent_under_the_first
        ; test_case "a second message from one speaker stays blank" `Quick
            test_a_second_message_from_one_speaker_stays_blank
        ; test_case "a continuation does not borrow the reasoning glyph" `Quick
            test_a_continuation_does_not_borrow_the_reasoning_glyph
        ; test_case "every speaker mark is distinct" `Quick
            test_every_speaker_mark_is_distinct
        ; test_case "Skill states keep shapes without colour" `Quick
            test_skill_marks_keep_state_without_colour
        ; test_case "alignment padding is kept apart from the name" `Quick
            test_alignment_padding_is_kept_apart_from_the_name
        ; test_case "a continuation survives the renderer cut" `Quick
            test_a_continuation_survives_the_renderer_cut
        ; test_case "the two link readers agree" `Quick
            test_the_two_link_readers_agree
        ; test_case "the margin comes out of the body" `Quick
            test_the_margin_comes_out_of_the_body
        ; test_case "scrolling measures the mode it draws" `Quick
            test_scrolling_measures_the_mode_it_draws
        ; test_case "scrolling past the top shows nothing" `Quick
            test_scrolling_past_the_top_yields_no_rows_rather_than_wrapping
        ] )
    ]
