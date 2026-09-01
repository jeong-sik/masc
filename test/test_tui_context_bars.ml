let check = Alcotest.check
let int = Alcotest.int
let ints = Alcotest.(list int)
let string = Alcotest.string
let bool = Alcotest.bool

module Bars = Masc_tui_context_bars

(* The measurement the history bar actually draws, taken from the 2026-09-01
   reading: 61 atoms of a 3,337-atom conversation reached the provider. *)
let history_transmitted = 61
let history_total = 3337

(* One turn's composition, in bytes, from the same reading. *)
let composition = [ 99328; 74445; 46285; 42086; 12 ]

(* Terminal cells in a styled row: SGR sequences cost nothing, and every glyph
   the bars draw is one cell, so counting the bytes that open a UTF-8 character
   is counting cells. Without this the width assertions below would measure
   escape codes. *)
let cells text =
  let length = String.length text in
  let count = ref 0 in
  let index = ref 0 in
  while !index < length do
    if Char.equal text.[!index] '\027' then begin
      incr index;
      if !index < length && Char.equal text.[!index] '[' then begin
        incr index;
        while
          !index < length
          && not (text.[!index] >= '@' && text.[!index] <= '~')
        do
          incr index
        done;
        if !index < length then incr index
      end
    end
    else begin
      if Char.code text.[!index] land 0xc0 <> 0x80 then incr count;
      incr index
    end
  done;
  !count

let test_a_real_share_never_floors_away () =
  check int "history reach plots" 1
    (Bars.fill_cells ~width:60 ~numerator:history_transmitted
       ~denominator:history_total);
  (* Same rule at a share far below one cell. An empty bar would say nothing
     was sent, which is not what 1 of a million measures. *)
  check int "a millionth still plots" 1
    (Bars.fill_cells ~width:20 ~numerator:1 ~denominator:1_000_000)

let test_nothing_sent_plots_as_nothing () =
  check int "zero numerator" 0
    (Bars.fill_cells ~width:60 ~numerator:0 ~denominator:history_total);
  check int "negative numerator" 0
    (Bars.fill_cells ~width:60 ~numerator:(-5) ~denominator:history_total)

let test_fill_clamps_to_width () =
  check int "exactly full" 60
    (Bars.fill_cells ~width:60 ~numerator:history_total
       ~denominator:history_total);
  check int "over full" 60
    (Bars.fill_cells ~width:60 ~numerator:(history_total * 2)
       ~denominator:history_total)

let test_fill_needs_a_width_and_a_denominator () =
  check int "no width" 0 (Bars.fill_cells ~width:0 ~numerator:61 ~denominator:3337);
  check int "negative width" 0
    (Bars.fill_cells ~width:(-4) ~numerator:61 ~denominator:3337);
  check int "no denominator" 0
    (Bars.fill_cells ~width:60 ~numerator:61 ~denominator:0)

let test_fill_is_proportional_above_one_cell () =
  check int "half of forty" 20
    (Bars.fill_cells ~width:40 ~numerator:30 ~denominator:60)

let test_apportion_spends_every_cell () =
  (* The stacked bar shares one row, so a split that does not sum to the width
     either leaves a gap or overruns the frame. Checked across the widths the
     pane can hand it rather than at one convenient number. *)
  for width = 1 to 120 do
    let split = Bars.apportion ~width ~weights:composition in
    check int
      (Printf.sprintf "width %d sums" width)
      width
      (List.fold_left ( + ) 0 split);
    check int
      (Printf.sprintf "width %d keeps every segment" width)
      (List.length composition) (List.length split)
  done

let test_apportion_gives_ties_to_the_earlier_segment () =
  check ints "two cells over three equals" [ 1; 1; 0 ]
    (Bars.apportion ~width:2 ~weights:[ 1; 1; 1 ]);
  check ints "six cells over four equals" [ 2; 2; 1; 1 ]
    (Bars.apportion ~width:6 ~weights:[ 1; 1; 1; 1 ])

let test_apportion_leaves_an_unmeasured_bar_empty () =
  (* Handing the width to the first weight would draw a full bar for a turn
     whose composition measured nothing. *)
  check ints "all-zero weights" [ 0; 0; 0 ]
    (Bars.apportion ~width:30 ~weights:[ 0; 0; 0 ]);
  check ints "no width" [ 0; 0 ] (Bars.apportion ~width:0 ~weights:[ 5; 5 ]);
  check ints "empty weights" [] (Bars.apportion ~width:30 ~weights:[])

let test_apportion_reads_negative_weights_as_zero () =
  check ints "negative weight" [ 30; 0 ]
    (Bars.apportion ~width:30 ~weights:[ 100; -100 ])

let test_apportion_lets_a_tiny_segment_plot_as_nothing () =
  (* The counterpart of the [fill_cells] guarantee: here a minimum cell would
     have to come out of the neighbour and overstate the small share. The
     per-component percentages under the bar still name it. *)
  check ints "a millionth of the row" [ 10; 0 ]
    (Bars.apportion ~width:10 ~weights:[ 1_000_000; 1 ])

let sample_segments =
  List.map (fun bytes -> ("", bytes)) composition

let test_every_row_is_exactly_the_width () =
  (* A row wider than the frame's inner width is truncated by the frame, and a
     truncated bar reads as a smaller share. Checked over the widths the pane
     hands down at ordinary terminal sizes. *)
  for width = 1 to 120 do
    check int
      (Printf.sprintf "band at %d" width)
      width
      (cells
         (Bars.band ~width ~title:"HISTORY REACH"
            ~caption:"how far back this turn looked"));
    check int
      (Printf.sprintf "ratio bar at %d" width)
      width
      (cells (Bars.ratio_bar ~width ~numerator:68_200 ~denominator:200_000));
    check int
      (Printf.sprintf "reach bar at %d" width)
      width
      (cells
         (Bars.reach_bar ~width ~transmitted:history_transmitted
            ~total:history_total ~sent_style:""));
    check int
      (Printf.sprintf "stacked bar at %d" width)
      width
      (cells (Bars.stacked_bar ~width ~segments:sample_segments))
  done

let contains haystack needle =
  let rec scan index =
    index + String.length needle <= String.length haystack
    && (String.equal (String.sub haystack index (String.length needle)) needle
       || scan (index + 1))
  in
  scan 0

let test_a_narrow_band_sheds_its_caption_not_its_width () =
  (* Below the width both labels need, the caption goes and the title stays;
     below the width the title needs, the row is a plain rule. Either way the
     row is exactly the width, because a row the frame has to cut ends in a
     tilde and reads as broken. *)
  let title_only = Bars.band ~width:20 ~title:"COMPOSITION" ~caption:"by kind" in
  check int "title-only row width" 20 (cells title_only);
  check bool "title survives" true (contains title_only "COMPOSITION");
  check bool "caption is gone" false (contains title_only "by kind");
  let rule = Bars.band ~width:8 ~title:"COMPOSITION" ~caption:"by kind" in
  check int "plain rule width" 8 (cells rule);
  check bool "no title" false (contains rule "COMPOSITION");
  (* The full form appears as soon as both fit. *)
  let full = Bars.band ~width:30 ~title:"COMPOSITION" ~caption:"by kind" in
  check int "full row width" 30 (cells full);
  check bool "both labels" true
    (contains full "COMPOSITION" && contains full "by kind")

let test_wrap_folds_to_the_width () =
  let text =
    "3276 older atoms stayed behind. A cut falls between atoms, so a tool \
     result and the call it answers either both travel or neither does."
  in
  List.iter
    (fun width ->
      let lines = Bars.wrap ~width text in
      check bool
        (Printf.sprintf "every line fits %d" width)
        true
        (List.for_all (fun line -> String.length line <= width) lines);
      (* Folding must not drop or duplicate words. Compared on the words
         alone, since the fold decides where the spaces go. *)
      let words folded =
        List.filter
          (fun word -> not (String.equal word ""))
          (String.split_on_char ' ' folded)
      in
      check (Alcotest.list string)
        (Printf.sprintf "words survive %d" width)
        (words text)
        (List.concat_map words lines))
    [ 20; 34; 54; 74; 200 ]

let test_wrap_keeps_a_wide_separator () =
  (* The screen's unfolded rows separate figures with two spaces around a dot.
     A fold that collapsed them would make the folded row look like prose. *)
  let row = "67.3k / 128.0k tokens  \xc2\xb7  52.6% of the window  \xc2\xb7  60.7k left" in
  let folded = Bars.wrap ~width:50 row in
  check bool "more than one line" true (List.length folded > 1);
  check bool "the wide separator survives" true
    (List.exists (fun line -> contains line "  \xc2\xb7  ") folded)

let test_wrap_never_returns_nothing () =
  check int "empty text" 1 (List.length (Bars.wrap ~width:40 ""));
  check int "no width" 1 (List.length (Bars.wrap ~width:0 "anything at all"))

let test_the_pointer_ends_on_the_cut () =
  (* The corner has to land on the first sent cell, or the flag labels the
     omitted history instead. Its cell count is therefore one past the cut. *)
  let width = 60 in
  let sent =
    Bars.fill_cells ~width ~numerator:history_transmitted
      ~denominator:history_total
  in
  check int "flag ends on the first sent cell" (width - sent + 1)
    (cells
       (Bars.reach_pointer ~width ~transmitted:history_transmitted
          ~total:history_total));
  (* With the whole conversation sent there is no room on the left, so the
     label sits to the right of the cut and the row is longer than the cut. *)
  check bool "a full reach labels from the right" true
    (cells
       (Bars.reach_pointer ~width ~transmitted:history_total
          ~total:history_total)
    > 0)

let test_segment_shades_cycle () =
  check string "first segment is solid" (Bars.segment_glyph 0)
    (Bars.segment_glyph 4);
  check bool "the four shades differ" true
    (List.length
       (List.sort_uniq compare
          [ Bars.segment_glyph 0
          ; Bars.segment_glyph 1
          ; Bars.segment_glyph 2
          ; Bars.segment_glyph 3
          ])
    = 4)

(* Printed so the rows can be read rather than only counted; Alcotest keeps it
   under _build/_tests/. *)
let test_preview () =
  let width = 66 in
  print_newline ();
  print_endline
    (Bars.band ~width ~title:"ON THE WIRE" ~caption:"what the provider accepted");
  print_endline (Bars.ratio_bar ~width:60 ~numerator:68_200 ~denominator:200_000);
  print_endline
    (Bars.band ~width ~title:"HISTORY REACH"
       ~caption:"how far back this turn looked");
  print_endline
    (Bars.reach_bar ~width:60 ~transmitted:history_transmitted
       ~total:history_total ~sent_style:"");
  print_endline
    (Bars.reach_pointer ~width:60 ~transmitted:history_transmitted
       ~total:history_total);
  print_endline
    (Bars.band ~width ~title:"COMPOSITION"
       ~caption:"how this turn's content divides by kind");
  print_endline (Bars.stacked_bar ~width:60 ~segments:sample_segments);
  check bool "preview drew something" true
    (cells (Bars.stacked_bar ~width:60 ~segments:sample_segments) = 60)

let () =
  Alcotest.run "masc_tui_context_bars"
    [ ( "fill_cells"
      , [ Alcotest.test_case "a real share never floors away" `Quick
            test_a_real_share_never_floors_away
        ; Alcotest.test_case "nothing sent plots as nothing" `Quick
            test_nothing_sent_plots_as_nothing
        ; Alcotest.test_case "clamps to width" `Quick test_fill_clamps_to_width
        ; Alcotest.test_case "needs a width and a denominator" `Quick
            test_fill_needs_a_width_and_a_denominator
        ; Alcotest.test_case "is proportional above one cell" `Quick
            test_fill_is_proportional_above_one_cell
        ] )
    ; ( "apportion"
      , [ Alcotest.test_case "spends every cell" `Quick
            test_apportion_spends_every_cell
        ; Alcotest.test_case "gives ties to the earlier segment" `Quick
            test_apportion_gives_ties_to_the_earlier_segment
        ; Alcotest.test_case "leaves an unmeasured bar empty" `Quick
            test_apportion_leaves_an_unmeasured_bar_empty
        ; Alcotest.test_case "reads negative weights as zero" `Quick
            test_apportion_reads_negative_weights_as_zero
        ; Alcotest.test_case "lets a tiny segment plot as nothing" `Quick
            test_apportion_lets_a_tiny_segment_plot_as_nothing
        ] )
    ; ( "rows"
      , [ Alcotest.test_case "every row is exactly the width" `Quick
            test_every_row_is_exactly_the_width
        ; Alcotest.test_case "a narrow band sheds its caption, not its width"
            `Quick test_a_narrow_band_sheds_its_caption_not_its_width
        ; Alcotest.test_case "wrap folds to the width" `Quick
            test_wrap_folds_to_the_width
        ; Alcotest.test_case "wrap keeps a wide separator" `Quick
            test_wrap_keeps_a_wide_separator
        ; Alcotest.test_case "wrap never returns nothing" `Quick
            test_wrap_never_returns_nothing
        ; Alcotest.test_case "the pointer ends on the cut" `Quick
            test_the_pointer_ends_on_the_cut
        ; Alcotest.test_case "segment shades cycle" `Quick
            test_segment_shades_cycle
        ; Alcotest.test_case "preview" `Quick test_preview
        ] )
    ]
