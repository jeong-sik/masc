open Alcotest

module Lane_table = Masc_tui_lane_table

let width = Masc_tui_message_layout.display_width

(* The cut mark [fit_width] leaves behind. A column name carrying it is a
   column the reader cannot name. *)
let cut_mark = "\xe2\x80\xa6"

let contains needle text =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec walk index =
    if index + needle_length > text_length then false
    else if String.sub text index needle_length = needle then true
    else walk (index + 1)
  in
  walk 0

(* The five lanes a workspace runs, with the slot lists the fleet published on
   2026-09-22: the widest is two runtime ids and a comma. *)
let live_lanes =
  [ { Lane_table.label = "Board Attention"
    ; slots = "glm-coding.glm-5-turbo"
    }
  ; { Lane_table.label = "HITL Auto Judge"
    ; slots = "glm-coding.glm-5.3-flash,ollama.qwen3-coder"
    }
  ; { Lane_table.label = "Librarian"; slots = "glm-coding.glm-5-turbo" }
  ; { Lane_table.label = "Workspace Curator"; slots = "no admitted slot" }
  ; { Lane_table.label = "Verifier"; slots = "cli-only +cli:claude_code" }
  ]

(* Cells the fixed columns spend on these names. Below it the table's fixed
   columns do not fit either, which is a different question from how the two
   measured columns divide what is left, and not one this decides. *)
let fixed_floor =
  Lane_table.fixed_cells
    ~label_cells:(Lane_table.columns ~inner:220 live_lanes).label_cells

let total_cells (columns : Lane_table.columns) ~slots ~observed =
  Lane_table.fixed_cells ~label_cells:columns.label_cells
  + width (Lane_table.tail columns ~slots ~observed)

(* The row drew both lists whatever the frame was and let the line's own cut
   take what was past its end. Beside the roster pane the header itself read
   "OB\xe2\x80\xa6" and every row's last two columns were half a runtime id:
   the reader could not tell which runtime answered, which is the one thing
   the column is there for. A column the frame has no room for leaves. *)
let test_a_narrow_frame_drops_a_column_rather_than_cutting_it () =
  for inner = fixed_floor to 220 do
    let columns = Lane_table.columns ~inner live_lanes in
    let header = Lane_table.header columns inner in
    check bool
      (Printf.sprintf "header at %d cells carries no cut column name" inner)
      false (contains cut_mark header);
    check bool
      (Printf.sprintf "header at %d cells names SLOTS whole or not at all" inner)
      (columns.slots_cells > 0)
      (contains "SLOTS" header);
    check bool
      (Printf.sprintf "header at %d cells names OBSERVED whole or not at all"
         inner)
      (columns.observed_cells > 0)
      (contains "OBSERVED" header)
  done

(* The measured columns are sized against what the row has already spent, so
   the line's own cut has nothing left to take. This is the property the
   dropped column rests on: without it, "drop when there is no room" is a
   claim about a number nothing compares to the frame. *)
let test_a_row_never_asks_for_more_cells_than_the_frame_has () =
  for inner = fixed_floor to 220 do
    let columns = Lane_table.columns ~inner live_lanes in
    List.iter
      (fun (lane : Lane_table.reading) ->
        let total =
          total_cells columns ~slots:lane.slots
            ~observed:"glm-coding.glm-5.3-flash\xc3\x97133,ollama.qwen3-coder\xc3\x9712"
        in
        check bool
          (Printf.sprintf "%s at %d cells fits in %d" lane.label total inner)
          true (total <= inner))
      live_lanes
  done

(* The slot list is the cell to lose first: the block under the table prints
   the selected lane's slots in full, and the counts beside it are what a
   reader compares down the column. So the observed histogram never outlives
   the slot list. *)
let test_the_observed_column_never_outlives_the_slot_list () =
  for inner = fixed_floor to 220 do
    let columns = Lane_table.columns ~inner live_lanes in
    if columns.observed_cells > 0 then
      check bool
        (Printf.sprintf "at %d cells the slot list is still drawn" inner)
        true (columns.slots_cells > 0)
  done

(* Beside the roster pane the row has room for one of the two. The cap on the
   slot list is there to leave the histogram its cells; with the histogram gone
   the list takes what is left instead of stopping at the cap and leaving the
   row blank behind a reading it had cut -- eleven cells of it, on the live
   fleet's 114. *)
let test_the_slot_list_takes_the_row_the_histogram_left () =
  let columns = Lane_table.columns ~inner:114 live_lanes in
  check int "the histogram has no room" 0 columns.observed_cells;
  check bool
    (Printf.sprintf "the slot list took past its shared cap: %d"
       columns.slots_cells)
    true (columns.slots_cells > 28);
  check bool "and no further than the frame" true
    (total_cells columns ~slots:"" ~observed:"" <= 114)

(* A frame wide enough for both draws both whole: the widest slot list here is
   43 cells, past the column's cap, so it is the cap the column takes and the
   histogram gets the rest. *)
let test_a_wide_frame_draws_both_lists () =
  let columns = Lane_table.columns ~inner:220 live_lanes in
  check int "the slot column takes its cap" 28 columns.slots_cells;
  check bool "the histogram has room" true (columns.observed_cells > 0);
  let header = Lane_table.header columns 220 in
  check bool "the header names SLOTS" true (contains "SLOTS" header);
  check bool "the header names OBSERVED" true (contains "OBSERVED" header)

(* The name column is measured from the names, floored at its own header and
   capped, so one long name cannot take the row. *)
let test_the_name_column_is_measured_from_the_names () =
  let columns = Lane_table.columns ~inner:220 live_lanes in
  check int "the widest name sets the column" (String.length "Workspace Curator")
    columns.label_cells;
  let long =
    Lane_table.columns ~inner:220
      [ { Lane_table.label = String.make 80 'x'; slots = "s" } ]
  in
  check bool "a long name is capped" true (long.label_cells < 80)

let () =
  run "tui lane table"
    [ ( "columns"
      , [ test_case "a narrow frame drops a column rather than cutting it"
            `Quick test_a_narrow_frame_drops_a_column_rather_than_cutting_it
        ; test_case "a row never asks for more cells than the frame has" `Quick
            test_a_row_never_asks_for_more_cells_than_the_frame_has
        ; test_case "the observed column never outlives the slot list" `Quick
            test_the_observed_column_never_outlives_the_slot_list
        ; test_case "the slot list takes the row the histogram left" `Quick
            test_the_slot_list_takes_the_row_the_histogram_left
        ; test_case "a wide frame draws both lists" `Quick
            test_a_wide_frame_draws_both_lists
        ; test_case "the name column is measured from the names" `Quick
            test_the_name_column_is_measured_from_the_names
        ] )
    ]
