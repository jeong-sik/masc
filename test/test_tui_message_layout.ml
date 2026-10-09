open Alcotest

module Layout = Masc_tui_message_layout
module Frame = Masc_tui_frame
module Markdown_cache = Masc_tui_markdown_render_cache

let entry ?(timestamp = "12:34:56") ?timeline_bucket ?speaker
    ?(markdown_source = Layout.Markdown_streaming) style role request_label body :
    Layout.entry =
  { style
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
      { Layout.style = Layout.Keeper;
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
    let scroll, rows =
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
      : int * Layout.row list);
  check bool "a new width measures again" true (!laid_out > second_cost)

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

let timeline_bucket ?(is_dst = false) hour : Layout.timeline_bucket =
  { tb_year = 2026
  ; tb_month = 9
  ; tb_day = 1
  ; tb_hour = hour
  ; tb_is_dst = is_dst
  }
;;

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
        ; test_case "a second walk pays for what it newly reaches" `Quick
            test_a_second_walk_pays_for_what_it_newly_reaches
        ; test_case "one frame renders capacity + 1 markdown entries once" `Quick
            test_one_frame_renders_each_completed_entry_once_beyond_cache_capacity
        ;] )
    ; ( "composer"
      , [] )
    ; ( "scrollback"
      , [] )
    ]
