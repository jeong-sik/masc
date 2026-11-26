open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_store
open Masc_tui_term

let t0 = Clock.Mono.of_ns 1_000_000_000L

let fresh () = Model.initial ~cols:80 ~rows:24 ()

let press m col row =
  fst (Update.step ~now:t0 m (Msg.Mouse_event (Keymap.Input.Left_press { col; row })))

let drag m col row =
  fst (Update.step ~now:t0 m (Msg.Mouse_event (Keymap.Input.Left_drag { col; row })))

let release m col row =
  fst (Update.step ~now:t0 m (Msg.Mouse_event (Keymap.Input.Left_release { col; row })))

let wheel m col row =
  fst
    (Update.step ~now:t0 m
       (Msg.Mouse_event (Keymap.Input.Wheel { dir = Keymap.Input.Wheel_down; col; row })))

let key m k =
  fst (Update.step ~now:t0 m (Msg.Key_event { key = k; mods = Keymap.Input.no_mods }))

let check = Alcotest.(check bool)

let test_state_machine () =
  let m = fresh () in
  check "initial no selection" true (Model.equal_mouse_selection_state m.mouse_selection Model.No_selection);
  let m1 = Model.begin_mouse_selection ~x:2 ~y:3 m in
  check "begin is dragging" true
    (Model.equal_mouse_selection_state m1.mouse_selection
       (Model.Dragging { anchor = { x = 2; y = 3 }; cursor = { x = 2; y = 3 } }));
  check "single cell has no rect" true (Model.mouse_selection_rect m1 = None);
  check "single cell not pending copy" false (Model.mouse_selection_is_pending_copy m1);
  let m2 = Model.extend_mouse_selection ~x:5 ~y:4 m1 in
  check "extend keeps anchor" true
    (Model.equal_mouse_selection_state m2.mouse_selection
       (Model.Dragging { anchor = { x = 2; y = 3 }; cursor = { x = 5; y = 4 } }));
  (match Model.mouse_selection_rect m2 with
  | Some r ->
      check "rect x" true (Int.equal r.x 2);
      check "rect y" true (Int.equal r.y 3);
      check "rect w" true (Int.equal r.w 4);
      check "rect h" true (Int.equal r.h 2)
  | None -> Alcotest.fail "expected selection rect");
  check "dragging not pending copy" false (Model.mouse_selection_is_pending_copy m2);
  let m3 = Model.settle_mouse_selection m2 in
  check "settle is pending copy" true (Model.mouse_selection_is_pending_copy m3);
  let m4 = Model.mark_mouse_selection_copied m3 in
  check "copied settles pending" false (Model.mouse_selection_is_pending_copy m4);
  check "copied keeps rect" true (Model.mouse_selection_rect m4 <> None);
  let m5 = Model.clear_mouse_selection m4 in
  check "clear idempotent" true
    (Model.equal_mouse_selection_state m5.mouse_selection Model.No_selection)

let test_reversed_drag () =
  let m = fresh () in
  let m1 = Model.begin_mouse_selection ~x:10 ~y:8 m in
  let m2 = Model.extend_mouse_selection ~x:4 ~y:5 m1 in
  (match Model.mouse_selection_rect m2 with
  | Some r ->
      check "reversed rect x" true (Int.equal r.x 4);
      check "reversed rect y" true (Int.equal r.y 5);
      check "reversed rect w" true (Int.equal r.w 7);
      check "reversed rect h" true (Int.equal r.h 4)
  | None -> Alcotest.fail "expected reversed rect");
  (* settle on a single cell collapses to no selection *)
  let ms = Model.begin_mouse_selection ~x:1 ~y:1 m in
  let ms = Model.settle_mouse_selection ms in
  check "settle single cell is empty" true
    (Model.equal_mouse_selection_state ms.mouse_selection Model.No_selection)

let test_update_drag_flow () =
  let m = fresh () in
  (* A single press on a non-navigating cell begins selection without
     duplicating the old click-only behavior check. *)
  let m1 = press m 5 4 in
  check "press begins dragging" true
    (match m1.mouse_selection with Model.Dragging { anchor; cursor } ->
         Model.equal_cell_pos anchor { x = 4; y = 3 }
         && Model.equal_cell_pos cursor { x = 4; y = 3}
     | _ -> false);
  let m2 = drag m1 8 6 in
  check "drag extends" true
    (match m2.mouse_selection with Model.Dragging { cursor; _ } ->
         Model.equal_cell_pos cursor { x = 7; y = 5 }
     | _ -> false);
  let m3 = release m2 8 6 in
  check "release settles" true
    (match m3.mouse_selection with Model.Settled { copied; _ } -> not copied | _ -> false);
  check "settled pending copy" true (Model.mouse_selection_is_pending_copy m3);
  (* A second click without movement collapses (navigation already on press). *)
  let m4 = press m 5 4 in
  let m5 = release m4 5 4 in
  check "click without drag clears" true
    (Model.equal_mouse_selection_state m5.mouse_selection Model.No_selection)

let test_key_wheel_clear () =
  let m = fresh () in
  let m1 = press m 5 4 in
  let m2 = drag m1 8 6 in
  let m3 = release m2 8 6 in
  check "settled before key" true (Model.mouse_selection_is_pending_copy m3);
  let m4 = key m3 Keymap.Input.Up in
  check "key clears selection" true
    (Model.equal_mouse_selection_state m4.mouse_selection Model.No_selection);
  let n1 = press m 5 4 in
  let n2 = drag n1 8 6 in
  let n3 = wheel n2 8 6 in
  check "wheel clears selection" true
    (Model.equal_mouse_selection_state n3.mouse_selection Model.No_selection)

let sample_grid () =
  let grid = Cell_grid.create ~cols:10 ~rows:4 in
  let st = Style.default in
  ignore (Cell_grid.put_text grid ~x:0 ~y:0 ~style:st "Hello");
  ignore (Cell_grid.put_text grid ~x:0 ~y:1 ~style:st "가나다");
  grid

let test_extract () =
  let grid = sample_grid () in
  let r1 = Rect.make ~x:0 ~y:0 ~w:5 ~h:1 in
  Alcotest.(check string) "extract ascii" "Hello" (Selection.extract_text grid ~rect:r1);
  let r2 = Rect.make ~x:0 ~y:0 ~w:10 ~h:2 in
  Alcotest.(check string) "extract two lines" "Hello\n가나다"
    (Selection.extract_text grid ~rect:r2);
  let r3 = Rect.make ~x:2 ~y:0 ~w:4 ~h:1 in
  Alcotest.(check string) "extract partial" "llo"
    (Selection.extract_text grid ~rect:r3);
  let r4 = Rect.make ~x:8 ~y:2 ~w:2 ~h:2 in
  Alcotest.(check string) "extract blank" "" (Selection.extract_text grid ~rect:r4);
  let r5 = Rect.make ~x:0 ~y:0 ~w:0 ~h:2 in
  Alcotest.(check string) "extract empty rect" "" (Selection.extract_text grid ~rect:r5)

let test_paint_trims_to_text () =
  let grid = sample_grid () in
  let fg = Color.of_rgb 0xFFFFFF in
  let bg = Color.of_rgb 0x1D2C42 in
  let rect = Rect.make ~x:0 ~y:0 ~w:10 ~h:1 in
  Selection.paint grid ~rect ~fg ~bg;
  let c0 = Cell_grid.get grid ~x:0 ~y:0 in
  let c4 = Cell_grid.get grid ~x:4 ~y:0 in
  let c5 = Cell_grid.get grid ~x:5 ~y:0 in
  check "painted fg" true (Color.equal c0.style.fg fg);
  check "painted bg" true (Color.equal c4.style.bg bg);
  check "margin untouched" true (Color.equal c5.style.bg Color.Default)

let test_paint_keeps_wide_glyphs () =
  let grid = sample_grid () in
  let fg = Color.of_rgb 0xFFFFFF in
  let bg = Color.of_rgb 0x1D2C42 in
  let rect = Rect.make ~x:0 ~y:1 ~w:6 ~h:1 in
  Selection.paint grid ~rect ~fg ~bg;
  let lead = Cell_grid.get grid ~x:0 ~y:1 in
  let cont = Cell_grid.get grid ~x:1 ~y:1 in
  check "lead style painted" true (Color.equal lead.style.bg bg);
  check "continuation shares painted style" true
    (Color.equal cont.style.bg bg);
  check "continuation glyph kept" true
    (Cell_grid.glyph_equal cont.glyph Cell_grid.Continuation);
  let whole = Rect.make ~x:0 ~y:1 ~w:6 ~h:1 in
  Alcotest.(check string) "wide text intact after paint" "가나다"
    (Selection.extract_text grid ~rect:whole)

let () =
  Alcotest.run "drag-select"
    [
      ( "selection",
        [
          Alcotest.test_case "state machine" `Quick test_state_machine;
          Alcotest.test_case "reversed drag rect" `Quick test_reversed_drag;
          Alcotest.test_case "update press-drag-release flow"
            `Quick test_update_drag_flow;
          Alcotest.test_case "key and wheel clear selection"
            `Quick test_key_wheel_clear;
          Alcotest.test_case "extract text from grid" `Quick test_extract;
          Alcotest.test_case "paint trims to text" `Quick
            test_paint_trims_to_text;
          Alcotest.test_case "paint keeps wide glyphs" `Quick
            test_paint_keeps_wide_glyphs;
        ] );
    ]
