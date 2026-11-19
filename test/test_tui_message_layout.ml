open Alcotest

module Layout = Masc_tui_message_layout
module Frame = Masc_tui_frame
module Markdown_cache = Masc_tui_markdown_render_cache

let holds text needle =
  let n = String.length needle in
  let rec seek i =
    i + n <= String.length text
    && (String.sub text i n = needle || seek (i + 1))
  in
  n = 0 || seek 0

let entry ?(timestamp = "12:34:56") ?timeline_bucket ?speaker
    ?(heading_boundary = Layout.Inherit_heading)
    ?(markdown_source = Layout.Markdown_streaming) style role request_label body :
    Layout.entry =
  { delivery_state = None; style
  ; heading_boundary
  ; body_presentation = Layout.Source_body
  ; timestamp
  ; timeline_bucket
  ; diagnostics = []
  ; speaker = Option.value speaker ~default:role
  ; role_label = role
  ; role_label_mark_cells =
      Layout.role_label_mark_cells ~style ()
  ; request_label
  ; body
  ; journal = []
  ; markdown_source
  ; turn_rail = Layout.Rail_none
  ; action = Layout.Action_none
  }

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

let transcript count =
  List.init count (fun index ->
      { Layout.delivery_state = None; Layout.style = Layout.Keeper;
        heading_boundary = Layout.Inherit_heading;
        body_presentation = Layout.Source_body;
        timestamp = Printf.sprintf "12:%02d:00" (index mod 60);
        timeline_bucket = None;
        diagnostics = [];
        speaker = "code-reviewer";
        role_label = "code-reviewer";
        request_label = Printf.sprintf "turn-%d" index;
        body =
          Printf.sprintf
            "turn %d closed and wrote a line long enough that it wraps more \
             than once at the widths this test uses"
            index;
        role_label_mark_cells = 0;
        journal = [];
        markdown_source = Layout.Markdown_streaming;
        turn_rail = Layout.Rail_none;
        action = Layout.Action_none;
      })

let test_one_frame_renders_each_completed_entry_once_beyond_cache_capacity () =
  let rendered = ref [] in
  let cache_capacity = 2 in
  let cache = Markdown_cache.create ~capacity:cache_capacity in
  let markdown ~(entry : Layout.entry) ~width =
    let renderer ~width text =
      rendered := entry.request_label :: !rendered;
      Layout.wrap_words ~max_cells:width text
    in
    match entry.markdown_source with
    | Layout.Markdown_stable
        { keeper_name; request_id; observed_at; entry_index } ->
        Markdown_cache.render cache ~theme_revision:1 ~palette_generation:0
          ~width ~renderer
          ~identity:(keeper_name, request_id, observed_at, entry_index)
          ~text:entry.body
    | Layout.Markdown_growing _
    | Layout.Markdown_streaming ->
        renderer ~width entry.body
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
  let {Layout.scroll; rows; _} =
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

(* Reading further back does not lay out again what it already measured.

   A wheel notch moves the window three rows, and the frame has to know how
   far back the window now starts. That distance is what a deep scroll makes
   long. The row counts of the entries behind the window do not change while
   the entries and the width do not, so the second walk pays for what it
   newly reaches and for what it draws, not for the whole distance. *)
let test_a_second_walk_pays_for_what_it_newly_reaches () =
  let entries = transcript 60 in
  let inner_width = 30 in
  let height = 8 in
  let laid_out = ref 0 in
  let markdown ~(entry : Layout.entry) ~width =
    incr laid_out;
    Layout.wrap_words ~max_cells:width entry.body
  in
  let walk requested =
    laid_out := 0;
    let {Layout.scroll; rows; _} =
      Layout.clamped_scrolled_rows ~markdown ~inner_width ~height ~requested
        entries
    in
    (scroll, rows, !laid_out)
  in
  let _, first_rows, first_cost = walk 90 in
  let _, second_rows, second_cost = walk 93 in
  check bool "the first walk reaches far back" true (first_cost > 20);
  check bool
    (Printf.sprintf "the second walk costs %d against the first's %d"
       second_cost first_cost)
    true
    (second_cost * 3 < first_cost);
  check bool "and both drew a window" true
    (List.length first_rows > 0 && List.length second_rows > 0);
  (* A width the counts were not measured at is a different question. *)
  laid_out := 0;
  ignore
    (Layout.clamped_scrolled_rows ~markdown ~inner_width:(inner_width + 6)
       ~height ~requested:93 entries
      : Layout.scroll_window);
  check bool "a new width measures again" true (!laid_out > second_cost);
  (* Switching between plain-text and markdown on the same entries list must
     not reuse plain-text row counts for markdown or vice versa. *)
  let expanding_markdown ~(entry : Layout.entry) ~width =
    incr laid_out;
    List.concat_map (fun line -> [ line; line ]) (Layout.wrap_words ~max_cells:width entry.body)
  in
  let plain_scroll =
    Layout.scroll_for_body_row ~inner_width ~entry_index:0 ~body_row:0 entries
  in
  laid_out := 0;
  let markdown_scroll =
    Layout.scroll_for_body_row ~markdown:expanding_markdown ~inner_width
      ~entry_index:0 ~body_row:0 entries
  in
  check bool "markdown scroll query re-measures after plain-text memo" true
    (!laid_out > 0 && markdown_scroll <> plain_scroll)

let escape_control_bytes text =
  String.to_seq text
  |> Seq.map (fun c ->
         if Char.code c < 0x20 then Printf.sprintf "\\x%02X" (Char.code c)
         else String.make 1 c)
  |> List.of_seq
  |> String.concat ""

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

(* A tab in output is a distance, not a character: it lands on the next stop
   whatever is before it, and the stops belong to the row, not to a run. *)
let test_a_tab_lands_on_the_next_stop () =
  let expanded ?(column = 0) text = Layout.expand_tabs ~column text in
  let check_expanded label (text, column) result =
    check (pair string int) label (text, column) result in
  check_expanded "no tab is no change" ("abc", 3) (expanded "abc");
  check_expanded "a tab after one cell" ("a       b", 9) (expanded "a\tb");
  check_expanded "a tab on a stop goes a whole stop" ("        x", 9) (expanded "\tx");
  check_expanded "the row's column carries into a run" ("     ", 8)
    (expanded ~column:3 "\t");
  check_expanded "two tabs" ("a       b       c", 17) (expanded "a\tb\tc");
  check_expanded "a trailing tab" ("ab      ", 8) (expanded "ab\t");
  check_expanded "a wide character fills two cells" ("\xea\xb0\x80      b", 9)
    (expanded "\xea\xb0\x80\tb");
  check int "the stops are eight cells apart" 8 Layout.tab_width

(* The escape writes a tab as the four characters of \x09, which reads as
   text inside a code fence. A renderer is handed the distance instead, and a
   body without one keeps the escape so a reader still sees the byte. *)
let test_a_rendered_body_draws_a_tab_as_spaces () =
  let seen = ref "" in
  let renderer ~width text =
    ignore width;
    seen := text;
    String.split_on_char '\n' text
  in
  let spaces count = String.make count ' ' in
  let _rows =
    Layout.wrap_body
      ~markdown:renderer
      ~max_cells:40
      ~sanitize:escape_control_bytes
      "```go\n\tif true {\n\t\tx()\n\t}\n```\nab\tc"
  in
  check string "each tab reaches the next stop of its own line"
    (String.concat "\n"
       [ "```go"
       ; spaces 8 ^ "if true {"
       ; spaces 16 ^ "x()"
       ; spaces 8 ^ "}"
       ; "```"
       ; "ab" ^ spaces 6 ^ "c"
       ])
    !seen

let test_a_plain_body_leaves_a_tab_to_the_escape () =
  let rows =
    Layout.wrap_body ~max_cells:40 ~sanitize:escape_control_bytes "a\tb"
  in
  check (list string) "a body without a renderer still shows the byte"
    [ {|a\x09b|} ] rows

(* #37666: the Keeper Calls screen escaped a tool's output whole, so each
   newline was printed as \x0A inside one run. The escape is the stand-in for
   [Terminal_text.single_line]: like it, it would print a newline it is handed
   as \x0A. *)
let test_an_output_keeps_its_lines_and_escapes_the_rest () =
  let wrap = Layout.wrap_indented_body ~max_cells:40 ~sanitize:escape_control_bytes in
  check (list string) "each stored line is its own row" [ "a"; "b" ] (wrap "a\nb");
  let rows = wrap "before\n\x1b[31mred\n\nafter\n" in
  check (list string) "an escape is still escaped and a blank line stays"
    [ "before"; {|\x1B[31mred|}; ""; "after"; "" ] rows;
  check bool "no newline is printed as \\x0A" false
    (List.exists (fun row -> holds row {|\x0A|}) rows);
  check bool "no raw ESC is left in a row" false
    (List.exists (fun row -> String.contains row '\x1b') rows)

(* The leading spaces of a line of code or of a served document are its
   structure. [wrap_words] drops them, so [wrap_body] cannot be used here. *)
let test_an_output_keeps_its_indentation () =
  let wrap max_cells =
    Layout.wrap_indented_body ~max_cells ~sanitize:escape_control_bytes
  in
  let document = "{\n  \"ok\": true,\n  \"items\": [\n    1\n  ]\n}" in
  check string "a value whose lines fit comes back byte for byte" document
    (String.concat "\n" (wrap 40 document));
  let rows = wrap 14 "    alpha beta gamma" in
  check (list string) "a wrapped line stays in its column"
    [ "    alpha beta"; "    gamma" ] rows;
  check bool "every row fits the width" true
    (List.for_all (fun row -> Layout.display_width row <= 14) rows);
  check (list string) "an indent as wide as the row is dropped for that line"
    [ "ab" ] (wrap 4 "    ab")

let test_live_edge_positions_belong_to_actual_selected_rows () =
  let entries=[entry Layout.Keeper "keeper" "live-edge"
    (String.concat "\n" (List.init 100 (fun n -> Printf.sprintf "ROW_%03d" n)))] in
  let window=Layout.clamped_scrolled_rows ~origin:Layout.Origin_row
    ~inner_width:60 ~height:6 ~requested:0 entries in
  check bool "actual producer exposes hidden middle" true
    (List.exists (fun (row : Layout.row) -> match row.kind with Layout.Viewport_gap _ -> true | _ -> false) window.rows);
  (match List.rev window.body_positions with
   | position::_ ->
       check int "last visible owner is original final body row" 99 position.body_row;
       check int "tail owner is at actual viewport bottom" 0 position.rows_below
   | [] -> fail "visible live-edge tail has no body owner");
  let heading_only=Layout.clamped_scrolled_rows ~origin:Layout.Origin_row
    ~inner_width:60 ~height:1 ~requested:0 entries in
  check int "a heading-only viewport has no invented source position" 0
    (List.length heading_only.body_positions)

let bare_sender_rows style =
  let entries = [ entry style "THINKING" "" "body text" ] in
  let rows =
    Layout.visible_rows ~origin:Layout.Origin_bare ~inner_width:60 ~height:20
      entries
  in
  List.exists
    (fun (row : Layout.row) -> row.kind = Layout.Metadata Layout.Sender)
    rows

let test_bare_sender_row_marks_arrived_reasoning_only () =
  check bool "arrived reasoning keeps its sender row" true
    (bare_sender_rows (Layout.Thinking Layout.Thinking_arrived));
  check bool "own reasoning stays unlabeled" false
    (bare_sender_rows (Layout.Thinking Layout.Thinking_own));
  check bool "inbound keeps its sender row" true
    (bare_sender_rows Layout.Inbound)

let test_a_text_laid_out_again_keeps_its_layout () =
  let texts =
    [ ("\xea\xb0\x80a", 3)
    ; ("a\xcc\x81b", 2)
    ; ("\xed\x95\x9c\xea\xb5\xad", 4)
    ; ("\xed\x95\x9c\xea\xb5\xad\xec\x96\xb4", 6)
    ; ("\027[31m\xed\x95\x9c\027[0m", 2)
    ; ("A1\xef\xb8\x8f\xe2\x83\xa3Z", 4)
    ]
  in
  let lay_out_all label =
    List.iter
      (fun (text, cells) ->
        check int (label ^ ": width of " ^ String.escaped text) cells
          (Layout.display_width text);
        check int (label ^ ": fitted width of " ^ String.escaped text) (cells + 1)
          (Layout.display_width (Layout.fit_width text (cells + 1))))
      texts
  in
  lay_out_all "first frame";
  lay_out_all "the same frame again";
  Layout.begin_frame ();
  lay_out_all "the next frame";
  Layout.begin_frame ();
  Layout.begin_frame ();
  lay_out_all "two frames without them"

(* Where a layout's pieces came from shows in what it allocates: splitting a
   text allocates its pieces, and taking them from a frame's table does not.
   On 2026-09-30 splitting this text allocated 93,776 bytes and taking its
   pieces 192. *)
let test_a_text_is_split_again_after_a_frame_without_it () =
  let text = String.concat "" (List.init 400 (fun _ -> "\xed\x95\x9c")) in
  let allocated () =
    let before = Gc.allocated_bytes () in
    ignore (Sys.opaque_identity (Layout.display_width (Sys.opaque_identity text)));
    Gc.allocated_bytes () -. before
  in
  Layout.begin_frame ();
  Layout.begin_frame ();
  let split = allocated () in
  let taken bytes = bytes *. 10. < split in
  let split_again bytes = bytes *. 2. > split in
  Layout.begin_frame ();
  let next_frame = allocated () in
  Layout.begin_frame ();
  let frame_after = allocated () in
  Layout.begin_frame ();
  Layout.begin_frame ();
  let after_a_frame_without_it = allocated () in
  check bool
    (Printf.sprintf "the next frame takes the pieces (%.0f of %.0f bytes)" next_frame split)
    true (taken next_frame);
  check bool
    (Printf.sprintf "so does the frame after it (%.0f of %.0f bytes)" frame_after split)
    true (taken frame_after);
  check bool
    (Printf.sprintf "a frame without the text lets it go (%.0f of %.0f bytes)"
       after_a_frame_without_it split)
    true (split_again after_a_frame_without_it)

(* An ASCII text is split each time and never kept, escapes included. *)
let test_an_ascii_text_is_not_kept () =
  let text = "\027[31m" ^ String.make 400 'a' ^ "\027[0m" in
  let allocated () =
    let before = Gc.allocated_bytes () in
    ignore (Sys.opaque_identity (Layout.take_cells (Sys.opaque_identity text) 200));
    Gc.allocated_bytes () -. before
  in
  Layout.begin_frame ();
  Layout.begin_frame ();
  let first = allocated () in
  let again = allocated () in
  check bool
    (Printf.sprintf "laying it out again allocates the same (%.0f then %.0f bytes)" first again)
    true (Float.equal first again)

let test_journal_source_spans () =
  let lines = [
    Layout.Journal_fact {sign=Journal_added;category="fact";tone=Tone_fact;claim="  foo bar foobar  longwordlongword"};
    Layout.Journal_drop {memory_id="memory-id";reason="same reason 한글 words"};
    Layout.Journal_fact {sign=Journal_removed;category="learning";tone=Tone_learning;claim=""}
  ] in
  let stable=ref [] in
  List.iter (fun width ->
    let mapped=Layout.journal_rows_with_spans ~width lines in
    check bool "journal mapping preserves exact existing rows" true
      (mapped.journal_rows=Layout.journal_rows ~width lines);
    let identities=List.map (fun (span : Layout.journal_source_span) -> span.line_index,span.field,span.value)
      mapped.journal_fields |> List.sort_uniq compare in
    if !stable=[] then stable:=identities else
      check bool "field identities survive hanging-column switch" true (!stable=identities);
    List.iter (fun (span : Layout.journal_source_span) ->
      let row=List.nth mapped.journal_rows span.row |> List.map fst |> String.concat "" in
      List.iter (fun (a,b) ->
        check bool "source range lies in original field" true (a>=0 && a<b && b<=String.length span.value);
        check bool "mapped source occurs on actual formatter row" true
          (holds row (String.sub span.value a (b-a)))) span.source_ranges) mapped.journal_fields
  ) [5;16;38;100]

let test_truncate_middle () =
  check string "non-positive column returns empty" ""
    (Layout.truncate_middle 0 "masc-worktree-branch");
  check string "negative column returns empty" ""
    (Layout.truncate_middle (-3) "masc-worktree-branch");
  check string "fitting label returns unpadded original" "short-id"
    (Layout.truncate_middle 16 "short-id");
  check int "fit_middle still pads fitting label to column" 16
    (Layout.display_width (Layout.fit_middle 16 "short-id"));
  let long_id = "feature/tui-work-narrow-summary-and-grouping-02" in
  let cut = Layout.truncate_middle 18 long_id in
  check bool "overflowing label contains middle ellipsis" true
    (holds cut "…");
  check bool "overflowing label keeps prefix and suffix" true
    (String.starts_with ~prefix:"featu" cut && String.ends_with ~suffix:"grouping-02" cut);
  check bool "overflowing label never exceeds column width" true
    (Layout.display_width cut <= 18);
  (* A plain ASCII label is cut without segmenting it. A zero-width style in
     front sends the same label down the segmenting path; with the style taken
     back out, the two cuts must be the same at every width. *)
  let name = "native-image-goal-verify-20261101-111334" in
  for col = Layout.cut_mark_cells to String.length name do
    check string (Printf.sprintf "plain and styled ASCII cut alike at col=%d" col)
      (Masc_tui_theme.strip_sgr (Layout.truncate_middle col ("\x1b[0m" ^ name)))
      (Layout.truncate_middle col name)
  done;
  let korean = "가나다라마바사아자차카타파하" in
  List.iter
    (fun col ->
      let s = Layout.truncate_middle col korean in
      check bool (Printf.sprintf "valid UTF-8 at col=%d" col) true
        (String.is_valid_utf_8 s);
      check bool (Printf.sprintf "display_width <= %d" col) true
        (Layout.display_width s <= col))
    [ 1; 2; 3; 4; 5; 6; 7; 8; 9; 10 ]

(* A count names its noun in the number the count asks for: the singular at
   one and only at one, the plural at zero and at every count above. The
   plural is the singular with an "s" unless the caller names another. *)
let test_count_noun_is_singular_only_at_one () =
  for count = 0 to 120 do
    let one = count = 1 in
    check string
      (Printf.sprintf "a regular noun at %d" count)
      (Printf.sprintf "%d %s" count (if one then "line" else "lines"))
      (Layout.count_noun count "line");
    check string
      (Printf.sprintf "an irregular noun at %d" count)
      (Printf.sprintf "%d %s" count (if one then "branch" else "branches"))
      (Layout.count_noun ~plural:"branches" count "branch")
  done

(* A duration or an age that is not a span reads as nothing. NaN and the
   infinities have no [int_of_float], so they must not reach the ladder. *)
let test_a_span_that_is_not_a_number_reads_as_nothing () =
  let nothing what = check bool what true in
  List.iter
    (fun (what, seconds) ->
      nothing (what ^ " is not an elapsed time") (Layout.elapsed_text seconds = None);
      nothing (what ^ " is not an age")
        (Layout.age_text ~now:seconds ~since:0. = None))
    [ "NaN", Float.nan
    ; "infinity", Float.infinity
    ; "negative infinity", Float.neg_infinity
    ; "a negative span", -1.
    ; "a span past what an integer holds", 1e19
    ; "the largest finite float", Float.max_float
    ];
  nothing "a NaN stamp is not an age" (Layout.age_text ~now:10. ~since:Float.nan = None);
  nothing "a stamp in the future is not an age" (Layout.age_text ~now:10. ~since:12. = None);
  List.iter
    (fun seconds ->
      nothing "a finite span is read" (Option.is_some (Layout.elapsed_text seconds)))
    [ 0.; -0.; 0.0004; 1.2; 59.96; 3600.; 9_000_000. ];
  nothing "equal clocks are a zero age" (Option.is_some (Layout.age_text ~now:5. ~since:5.))


let test_scroll_anchor_round_trip_after_revisiting_history () =
  let entries = transcript 600 in
  let walk entries ~origin ~inner_width requested =
    let window = Layout.clamped_scrolled_rows ~origin ~inner_width
        ~height:12 ~requested entries in
    check bool "the input anchor has a body owner" true
      (window.body_positions <> []);
    List.iter
      (fun (position : Layout.body_row_position) ->
        check (option int) "the same original body maps back to its scroll"
          (Some (window.scroll + position.rows_below))
          (Layout.scroll_for_body_row ~origin ~inner_width
             ~entry_index:position.entry_index ~body_row:position.body_row entries))
      window.body_positions
  in
  let revisit entries origin inner_width =
    walk entries ~origin ~inner_width 700;
    check bool "an older original body remains addressable" true
      (Option.is_some (Layout.scroll_for_body_row ~origin ~inner_width
         ~entry_index:0 ~body_row:0 entries));
    List.iter (walk entries ~origin ~inner_width) [3;2200;41;7000;700]
  in
  revisit entries Layout.Origin_row 27;
  revisit entries Layout.Origin_row 80;
  revisit entries Layout.Origin_bare 80;
  revisit entries Layout.Origin_bare 27;
  revisit entries Layout.Origin_row 27;
  let changed = List.mapi (fun index (entry : Layout.entry) ->
      if index = 0 then {entry with body = entry.body ^ "\nA new paragraph in the original body."}
      else entry) entries in
  revisit changed Layout.Origin_row 27

(* Whether a cut happened is the cutting function's answer, and a cut drawn
   at an edge carries the mark (RFC tui-one-screen-grammar §6.6). Checked as
   decisions: the branch, the mark the module itself defines, the width. *)
let test_a_cut_is_cut_and_a_fit_is_whole () =
  let sentence = "keeper-with-a-long-name \xc2\xb7 \xec\x97\x86\xec\x9d\x8c" in
  let width = Layout.display_width sentence in
  check bool "the whole sentence fits its own width" true
    (match Layout.take_cells sentence width with
     | Layout.Whole kept -> String.equal kept sentence
     | Layout.Cut _ -> false);
  check bool "one cell less is a cut" true
    (match Layout.take_cells sentence (width - 1) with
     | Layout.Cut kept -> Layout.display_width kept <= width - 1
     | Layout.Whole _ -> false)

let test_an_edge_cut_carries_the_mark () =
  let sentence = "keeper-with-a-long-name \xc2\xb7 \xec\x97\x86\xec\x9d\x8c" in
  let width = Layout.display_width sentence in
  check bool "a fitting text is drawn without a mark" false
    (String.ends_with ~suffix:Layout.cut_mark (Layout.truncate_end width sentence));
  List.iter
    (fun cells ->
      let drawn = Layout.truncate_end cells sentence in
      check bool (Printf.sprintf "cut to %d ends in the mark" cells) true
        (String.ends_with ~suffix:Layout.cut_mark drawn);
      check bool (Printf.sprintf "cut to %d stays within it" cells) true
        (Layout.display_width drawn <= cells))
    [ 1; 2; width - 2; width - 1 ];
  let styled = "\027[31m" ^ sentence ^ "\027[0m" in
  check bool "a styled cut resets before the mark" true
    (String.ends_with ~suffix:("\027[0m" ^ Layout.cut_mark) (Layout.truncate_end 5 styled))

(* A boundary inside a two-cell grapheme: the grapheme is not split, the
   head is still a cut, and the mark still fits. A styled text that fits is
   drawn as it came, its escapes included. *)
let test_a_wide_head_is_cut_whole_within_its_width () =
  let wide = "\xea\xb0\x80\xeb\x82\x98\xeb\x8b\xa4\xeb\x9d\xbc\xeb\xa7\x88" in
  let width = Layout.display_width wide in
  check bool "a boundary inside a grapheme is a cut" true
    (match Layout.take_cells wide 3 with
     | Layout.Cut kept -> String.starts_with ~prefix:kept wide && Layout.display_width kept <= 3
     | Layout.Whole _ -> false);
  List.iter
    (fun cells ->
      let drawn = Layout.truncate_end cells wide in
      let head =
        String.sub drawn 0 (String.length drawn - String.length Layout.cut_mark)
      in
      check bool (Printf.sprintf "cut to %d ends in the mark" cells) true
        (String.ends_with ~suffix:Layout.cut_mark drawn);
      check bool (Printf.sprintf "cut to %d stays within it" cells) true
        (Layout.display_width drawn <= cells);
      check bool (Printf.sprintf "cut to %d keeps whole graphemes" cells) true
        (String.starts_with ~prefix:head wide))
    (List.init (width - 1) (fun index -> index + 1));
  let styled = "\027[1m" ^ wide ^ "\027[0m" in
  check bool "a fitting styled text is drawn as it came" true
    (String.equal styled (Layout.truncate_end width styled))

let test_folded_thought_summary_includes_preview_when_width_permits () =
  let body = "\n  ## Checking the MASC board consensus\nSecond detail line\n" in
  let wide =
    Layout.folded_thought_summary ~mark:"\xe2\x97\x8b" ~width:90 ~line_count:12 ~body
  in
  check bool "wide summary fits within pane width" true
    (Layout.display_width wide <= 90);
  check bool "wide summary surfaces the first readable line" true
    (holds wide "Checking the MASC board consensus");
  let narrow =
    Layout.folded_thought_summary ~mark:"\xe2\x97\x8b" ~width:35 ~line_count:12 ~body
  in
  check bool "narrow summary drops preview rather than overflowing" false
    (holds narrow "Checking");
  let clipped =
    Layout.folded_thought_summary ~mark:"\xe2\x97\x8b" ~width:52 ~line_count:12 ~body
  in
  check bool "clipped summary stays within width and carries preview + cut mark" true
    (Layout.display_width clipped <= 52
     && holds clipped "Checking"
     && holds clipped Layout.cut_mark);
  let single =
    Layout.folded_thought_summary ~mark:"\xe2\x97\x8b" ~width:80 ~line_count:1
      ~body:"-42 keeps its sign and snake_case"
  in
  check bool "singular line count and non-bullet sign preserved" true
    (holds single "1 line" && holds single "-42 keeps its sign and snake_case");
  check string "fences and horizontal rules are skipped" "actual_step"
    (Layout.thought_preview ~max_cells:30 "```ocaml\n___\n---\nactual_step");
  check string "inline markdown links and bold are neutralized"
    "Checking board spec and bold text"
    (Layout.thought_preview ~max_cells:60
       "Checking [board spec](https://masc.internal/spec) and **bold** text");
  let korean =
    Layout.folded_thought_summary ~mark:"\xe2\x97\x8b" ~width:53 ~line_count:8
      ~body:"한글 추론 요약이 좁은 폭에서도 깨지지 않고 잘립니다"
  in
  check bool "Korean preview fits within odd width" true
    (Layout.display_width korean <= 53 && holds korean Layout.cut_mark)

let test_fit_width_puts_padding_after_ellipsis_on_wide_and_space_cuts () =
  let cut = Layout.cut_mark in
  (* 2-cell Korean cut at even width 6: room 5 fits 2 syllables (4 cells),
     so ellipsis sits tight against the text with trailing space after it. *)
  let korean = Layout.fit_width "가나다라마" 6 in
  check string "Korean fit_width has no space before ellipsis"
    ("가나" ^ cut ^ " ") korean;
  check int "Korean fit_width preserves exact display width" 6
    (Layout.display_width korean);
  let spaced = Layout.fit_width "hello world" 7 in
  check string "ASCII fit_width trims trailing space before ellipsis"
    ("hello" ^ cut ^ " ") spaced;
  check int "ASCII fit_width preserves exact display width" 7
    (Layout.display_width spaced);
  check int "fitted_source_bytes agrees with fit_width space trimming" 5
    (Layout.fitted_source_bytes "hello world" 7);
  let indented = Layout.fit_width "      abcdef" 5 in
  check string "leading-only spaces stay before ellipsis" ("    " ^ cut) indented

let test_wrap_words_avoids_orphan_separators_and_applies_kinsoku () =
  (* Multi-space separators must not leave trailing space before wrap. *)
  let double_spaced = Layout.wrap_words ~max_cells:6 "alpha  beta" in
  check (list string) "double-space wrap drops trailing space"
    [ "alpha"; "beta" ] double_spaced;
  let triple_spaced = Layout.wrap_words ~max_cells:6 "alpha   beta" in
  check (list string) "triple-space wrap drops trailing spaces"
    [ "alpha"; "beta" ] triple_spaced;
  (* Inline separator tokens are preserved losslessly (never silently dropped). *)
  let piped = Layout.wrap_words ~max_cells:8 "cmd1 | cmd2" in
  check bool "pipe token is preserved" true
    (List.exists (fun row -> holds row "|") piped);
  (* Kinsoku keeps closing parenthesis attached to its preceding syllable. *)
  let kinsoku = Layout.wrap_words ~max_cells:8 "가나다라)" in
  check bool "closing paren does not start continuation row" false
    (List.exists (String.starts_with ~prefix:")") kinsoku);
  check string "kinsoku concatenates losslessly" "가나다라)"
    (String.concat "" kinsoku);
  (* Separator at the very end of the cut does not bypass kinsoku pull-back. *)
  let sep_kinsoku = Layout.wrap_words ~max_cells:8 "foo/bar/)" in
  check bool "closing paren after trailing slash does not start continuation row" false
    (List.exists (String.starts_with ~prefix:")") sep_kinsoku);
  check string "separator+kinsoku concatenates losslessly" "foo/bar/)"
    (String.concat "" sep_kinsoku);
  (* Opening parenthesis does not dangle at the end of a row. *)
  let opening = Layout.wrap_words ~max_cells:9 "가나다라(값)" in
  check bool "opening paren does not end first row" false
    (String.ends_with ~suffix:"(" (List.hd opening));
  check string "opening kinsoku concatenates losslessly" "가나다라(값)"
    (String.concat "" opening)

let () =
  run "tui_message_layout"
    [
      ( "expanded diagnostics"
      , [] );
      ( "scrolled styles", [] );
      ( "layout across frames"
      , [ test_case "a text laid out again keeps its layout" `Quick
            test_a_text_laid_out_again_keeps_its_layout
        ; test_case "a text is split again after a frame without it" `Quick
            test_a_text_is_split_again_after_a_frame_without_it
        ; test_case "an ASCII text is not kept" `Quick test_an_ascii_text_is_not_kept
        ; test_case "truncate_middle preserves unpadded fit and wide scalar boundaries" `Quick
            test_truncate_middle
        ; test_case "count_noun is singular only at one" `Quick
            test_count_noun_is_singular_only_at_one
        ; test_case "a cut is Cut and a fit is Whole" `Quick
            test_a_cut_is_cut_and_a_fit_is_whole
        ; test_case "an edge cut carries the mark" `Quick test_an_edge_cut_carries_the_mark
        ; test_case "a wide head is cut whole within its width" `Quick
            test_a_wide_head_is_cut_whole_within_its_width
        ; test_case "fit_width places padding after ellipsis without floating space" `Quick
            test_fit_width_puts_padding_after_ellipsis_on_wide_and_space_cuts
        ; test_case "wrap_words avoids orphan separators and applies CJK kinsoku" `Quick
            test_wrap_words_avoids_orphan_separators_and_applies_kinsoku
        ] );
      ( "spans"
      , [ test_case "a span that is not a number reads as nothing" `Quick
            test_a_span_that_is_not_a_number_reads_as_nothing
        ] );
      ( "clause packing"
      , [] );
      ( "bare links"
      , [] ); ( "message rows"
      , [ test_case "UTF-8 scalar input contract" `Quick
            test_utf8_scalar_input_contract
        ; test_case "backspace removes one UTF-8 scalar" `Quick
            test_backspace_removes_one_utf8_scalar
        ; test_case "word delete removes blanks then word" `Quick
            test_word_delete_removes_blanks_then_word
        ; test_case "a body still escapes what a line carries" `Quick
            test_a_body_still_escapes_what_a_line_carries
        ; test_case "a rendered body is escaped before it is rendered" `Quick
            test_a_rendered_body_is_escaped_before_it_is_rendered
        ; test_case "a tab lands on the next stop" `Quick
            test_a_tab_lands_on_the_next_stop
        ; test_case "a rendered body draws a tab as spaces" `Quick
            test_a_rendered_body_draws_a_tab_as_spaces
        ; test_case "a plain body leaves a tab to the escape" `Quick
            test_a_plain_body_leaves_a_tab_to_the_escape
        ; test_case "an output keeps its lines and escapes the rest" `Quick
            test_an_output_keeps_its_lines_and_escapes_the_rest
        ; test_case "an output keeps its indentation" `Quick
            test_an_output_keeps_its_indentation
        ; test_case "a second walk pays for what it newly reaches" `Quick
            test_a_second_walk_pays_for_what_it_newly_reaches
        ; test_case "one frame renders capacity + 1 markdown entries once" `Quick
            test_one_frame_renders_each_completed_entry_once_beyond_cache_capacity
        ; test_case "bare sender row marks arrived reasoning only" `Quick
            test_bare_sender_row_marks_arrived_reasoning_only
        ; test_case "folded thought summary surfaces a 1-line preview when room permits"
            `Quick test_folded_thought_summary_includes_preview_when_width_permits
        ;] )
    ; ( "composer"
      , [] )
    ; ( "scrollback"
      , [ test_case "scroll anchors survive history revisit and input changes" `Quick
            test_scroll_anchor_round_trip_after_revisiting_history
        ; test_case "journal source spans" `Quick test_journal_source_spans
        ; test_case "live-edge positions own actual selected rows" `Quick
            test_live_edge_positions_belong_to_actual_selected_rows
        ] )
    ]
