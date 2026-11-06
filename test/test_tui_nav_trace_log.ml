(* The navigation trace file (RFC-0485). These cases hold what the loop hands it
   -- a key, a frame, the footer's hints -- to what lands in the file: the
   state it keeps between calls, the cap, the off switch. What a line holds of
   a key is decided in Masc_tui_nav_trace and tested there. *)

module Log = Masc_tui_nav_trace_log
module Presenter = Masc_tui_frame_presenter

let unchanged = Presenter.Unchanged
let presented = Presenter.Presented Presenter.Whole_screen

let with_path f =
  let path = Filename.temp_file "nav-trace" ".jsonl" in
  Fun.protect ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ()) (fun () -> f path)

(* The clock counts seconds from 1, so a line that skipped it shows. *)
let counting_clock () =
  let ticks = ref 0. in
  fun () ->
    ticks := !ticks +. 1.;
    !ticks

let with_trace ?(max_lines = 100) f =
  with_path (fun path -> f path (Log.create ~path ~max_lines ~clock:(counting_clock ())))

let lines path =
  In_channel.with_open_text path In_channel.input_all
  |> String.split_on_char '\n'
  |> List.filter (fun line -> not (String.equal line ""))
  |> List.map (fun line -> Yojson.Safe.from_string line)

let field name json = List.assoc name (Yojson.Safe.Util.to_assoc json)
let text name json = Yojson.Safe.Util.to_string (field name json)
let kinds path = List.map (text "kind") (lines path)

(* A footer that announces j, k, Enter and Esc, then one pressed key on a frame
   that stayed. *)
let press t key =
  Log.announce "j/k:move  Enter:open  Esc:back";
  Log.note_input t (Log.Key key);
  Log.note_frame t ~surface:"keepers" ~result:unchanged

let key_line path =
  match lines path with
  | [ _; key ] -> key
  | [] | [ _ ] | _ :: _ :: _ :: _ -> Alcotest.fail "expected the surface line and one key line"

let test_a_key_that_changed_nothing_is_written_with_the_footer_it_was_pressed_on () =
  with_trace (fun path t ->
    press t "j";
    Alcotest.(check (list string)) "kinds" [ "surface"; "key_unchanged" ] (kinds path);
    let key = key_line path in
    Alcotest.(check string) "surface" "keepers" (text "surface" key);
    Alcotest.(check string) "key" "j" (text "key" key);
    Alcotest.(check bool) "advertised" true
      (Yojson.Safe.Util.to_bool (field "advertised" key)))

let test_a_key_is_written_once () =
  with_trace (fun path t ->
    press t "j";
    Log.note_frame t ~surface:"keepers" ~result:unchanged;
    Log.note_frame t ~surface:"keepers" ~result:unchanged;
    Alcotest.(check (list string)) "kinds" [ "surface"; "key_unchanged" ] (kinds path))

let test_a_key_the_footer_did_not_announce_has_no_value () =
  with_trace (fun path t ->
    press t "x";
    let key = key_line path in
    Alcotest.(check string) "key" "char" (text "key" key);
    Alcotest.(check bool) "advertised" false
      (Yojson.Safe.Util.to_bool (field "advertised" key)))

let test_a_frame_that_drew_something_has_no_key_line () =
  with_trace (fun path t ->
    Log.announce "j/k:move";
    Log.note_input t (Log.Key "j");
    Log.note_frame t ~surface:"keepers" ~result:presented;
    Alcotest.(check (list string)) "kinds" [ "surface" ] (kinds path))

let test_a_paste_or_a_pointer_event_drops_the_key_before_it () =
  with_trace (fun path t ->
    Log.note_frame t ~surface:"keepers" ~result:presented;
    Log.announce "j/k:move";
    Log.note_input t (Log.Key "j");
    Log.note_input t Log.Other_input;
    Log.note_frame t ~surface:"keepers" ~result:unchanged;
    Alcotest.(check (list string)) "kinds" [ "surface" ] (kinds path))

let test_silence_and_terminal_replies_keep_the_key_waiting () =
  with_trace (fun path t ->
    Log.note_frame t ~surface:"keepers" ~result:presented;
    Log.announce "j/k:move";
    Log.note_input t (Log.Key "j");
    Log.note_input t Log.No_input;
    Log.note_frame t ~surface:"keepers" ~result:unchanged;
    Alcotest.(check (list string)) "kinds" [ "surface"; "key_unchanged" ] (kinds path))

let test_a_later_key_replaces_one_no_frame_was_presented_for () =
  with_trace (fun path t ->
    Log.note_frame t ~surface:"keepers" ~result:presented;
    Log.announce "j/k:move";
    Log.note_input t (Log.Key "j");
    Log.note_input t (Log.Key "k");
    Log.note_frame t ~surface:"keepers" ~result:unchanged;
    match lines path with
    | [ _; key ] -> Alcotest.(check string) "key" "k" (text "key" key)
    | [] | [ _ ] | _ :: _ :: _ :: _ -> Alcotest.fail "expected the surface line and one key line")

(* The footer announces for the frame it is drawn in; a frame that draws no
   footer must not borrow the last one's keys. *)
let test_hints_announced_for_one_frame_do_not_reach_the_next () =
  with_trace (fun path t ->
    Log.announce "j/k:move";
    Log.note_frame t ~surface:"keepers" ~result:presented;
    Log.note_input t (Log.Key "j");
    Log.note_frame t ~surface:"keepers" ~result:unchanged;
    let key = key_line path in
    Alcotest.(check string) "key" "char" (text "key" key);
    Alcotest.(check bool) "advertised" false
      (Yojson.Safe.Util.to_bool (field "advertised" key)))

(* The header clock moves once a second, so a key pressed after the second turned
   gets a differential repaint of the header row even when the key drew
   nothing. [note_screen] lets the log see the rows and the cursor, and it
   decides on those. *)
let frame ?(cursor = Presenter.Hidden) rows =
  { Presenter.surface_key = "keepers"
  ; compact_frame = false
  ; terminal_rows = List.length rows
  ; terminal_cols = 80
  ; cursor
  ; lines = rows
  }

let header clock = Printf.sprintf "  MASC Workspace / Keepers  %s  HTTP [connected]" clock
let rows_idle = [ "  imp    idle"; "  relay  idle" ]

(* A frame, then a key pressed on it with the footer announcing j, then the
   frame the key led to, which the presenter reported as [result]. *)
let press_between t ~before ~after ~result =
  Log.note_screen t before;
  Log.note_frame t ~surface:"keepers" ~result:presented;
  Log.announce "j/k:move";
  Log.note_input t (Log.Key "j");
  Log.note_screen t after;
  Log.note_frame t ~surface:"keepers" ~result

let repainted rows = Presenter.Presented (Presenter.Rows rows)

let test_a_key_after_which_only_the_clock_moved_is_written () =
  with_trace (fun path t ->
    press_between t
      ~before:(frame (header "23:51:57" :: rows_idle))
      ~after:(frame (header "23:51:58" :: rows_idle))
      ~result:(repainted [ 0 ]);
    Alcotest.(check (list string)) "kinds" [ "surface"; "key_unchanged" ] (kinds path);
    Alcotest.(check string) "key" "j" (text "key" (key_line path)))

let test_a_key_after_which_a_row_changed_is_not_written () =
  with_trace (fun path t ->
    press_between t
      ~before:(frame (header "23:51:57" :: rows_idle))
      ~after:(frame (header "23:51:58" :: [ "  imp    busy"; "  relay  idle" ]))
      ~result:(repainted [ 0; 1 ]);
    Alcotest.(check (list string)) "kinds" [ "surface" ] (kinds path))

let test_a_key_that_moved_only_the_cursor_is_not_written () =
  with_trace (fun path t ->
    press_between t
      ~before:(frame (header "23:51:57" :: rows_idle))
      ~after:(frame ~cursor:(Presenter.Visible_at { row = 3; column = 4 }) (header "23:51:57" :: rows_idle))
      ~result:(repainted []);
    Alcotest.(check (list string)) "kinds" [ "surface" ] (kinds path))

let test_a_moved_cursor_is_not_hidden_by_a_clock_that_moved_with_it () =
  with_trace (fun path t ->
    press_between t
      ~before:(frame (header "23:51:57" :: rows_idle))
      ~after:(frame ~cursor:(Presenter.Visible_at { row = 3; column = 4 }) (header "23:51:58" :: rows_idle))
      ~result:(repainted [ 0 ]);
    Alcotest.(check (list string)) "kinds" [ "surface" ] (kinds path))

let test_a_whole_screen_repaint_keeps_its_result () =
  with_trace (fun path t ->
    press_between t
      ~before:(frame (header "23:51:57" :: rows_idle))
      ~after:(frame (header "23:51:58" :: rows_idle))
      ~result:presented;
    Alcotest.(check (list string)) "kinds" [ "surface" ] (kinds path))

let test_a_frame_the_presenter_called_unchanged_stays_unchanged () =
  with_trace (fun path t ->
    press_between t
      ~before:(frame (header "23:51:57" :: rows_idle))
      ~after:(frame (header "23:51:57" :: [ "  imp    busy"; "  relay  idle" ]))
      ~result:unchanged;
    Alcotest.(check (list string)) "kinds" [ "surface"; "key_unchanged" ] (kinds path))

let test_a_surface_event_names_where_the_screen_came_from () =
  with_trace (fun path t ->
    Log.note_frame t ~surface:"keepers" ~result:presented;
    Log.note_frame t ~surface:"changes" ~result:presented;
    Log.note_frame t ~surface:"changes" ~result:unchanged;
    match lines path with
    | [ first; second ] ->
      Alcotest.(check bool) "the first frame has no origin" true (field "from" first = `Null);
      Alcotest.(check string) "then keepers" "keepers" (text "from" second);
      Alcotest.(check string) "to changes" "changes" (text "to" second)
    | [] | [ _ ] | _ :: _ :: _ :: _ -> Alcotest.fail "expected two surface lines")

(* One line per call to the clock, in order. *)
let test_each_line_reads_the_clock_once () =
  with_trace (fun path t ->
    press t "j";
    let stamps = List.map (fun json -> Yojson.Safe.Util.to_float (field "t" json)) (lines path) in
    Alcotest.(check (list (float 0.))) "stamps" [ 1.; 2. ] stamps)

let test_the_cap_ends_the_file_with_one_capped_line () =
  with_trace ~max_lines:3 (fun path t ->
    for surface = 0 to 9 do
      Log.note_frame t ~surface:(string_of_int surface) ~result:presented
    done;
    Alcotest.(check (list string)) "kinds" [ "surface"; "surface"; "surface"; "capped" ] (kinds path);
    let capped = List.nth (lines path) 3 in
    Alcotest.(check int) "limit" 3 (Yojson.Safe.Util.to_int (field "limit" capped));
    Log.note_frame t ~surface:"later" ~result:presented;
    Alcotest.(check int) "nothing after the cap" 4 (List.length (lines path)))

let test_a_path_that_cannot_be_opened_ends_the_trace_without_raising () =
  let path = Filename.concat (Filename.concat (Filename.get_temp_dir_name ()) "nav-trace-no-such-directory") "trace.jsonl" in
  let t = Log.create ~path ~max_lines:10 ~clock:(counting_clock ()) in
  press t "j";
  press t "k";
  Alcotest.(check bool) "no file" false (Sys.file_exists path)

(* Every byte as the key: whatever the file holds of it is the word "char", a
   key the footer announced, or a word the decoder spells. *)
let test_no_typed_text_reaches_the_file () =
  with_trace ~max_lines:1000 (fun path t ->
    let raws =
      List.init 256 (fun byte -> String.make 1 (Char.chr byte))
      @ [ "hello world"; "pa$$word"; "\xed\x95\x9c\xea\xb8\x80"; "\xff\xfe" ]
    in
    List.iter (press t) raws;
    let is_word_shape word =
      String.length word >= 2
      && String.for_all (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false) word
    in
    List.iter
      (fun json ->
        match text "kind" json with
        | "key_unchanged" ->
          let word = text "key" json in
          Alcotest.(check bool) word true
            (List.mem word [ "char"; "j"; "k" ] || is_word_shape word)
        | _ -> ())
      (lines path))

let test_the_environment_variable_names_the_file () =
  with_path (fun path ->
    Unix.putenv "MASC_TUI_NAV_TRACE" path;
    let on = Log.from_environment ~clock:(counting_clock ()) in
    Log.note_frame on ~surface:"keepers" ~result:presented;
    Alcotest.(check (list string)) "a line" [ "surface" ] (kinds path);
    (* A blank value is off: no line, and the clock is never read. *)
    Unix.putenv "MASC_TUI_NAV_TRACE" "   ";
    let off =
      Log.from_environment ~clock:(fun () -> Alcotest.fail "the clock was read while off")
    in
    Log.note_input off (Log.Key "j");
    Log.note_screen off (frame [ header "23:51:57" ]);
    Log.note_frame off ~surface:"changes" ~result:presented;
    Log.note_frame off ~surface:"changes" ~result:unchanged;
    Alcotest.(check (list string)) "still one line" [ "surface" ] (kinds path))

let () =
  Alcotest.run "tui_nav_trace_log"
    [ ( "keys"
      , [ Alcotest.test_case "a key that changed nothing is written with the footer it was pressed on"
            `Quick test_a_key_that_changed_nothing_is_written_with_the_footer_it_was_pressed_on
        ; Alcotest.test_case "a key is written once" `Quick test_a_key_is_written_once
        ; Alcotest.test_case "a key the footer did not announce has no value" `Quick
            test_a_key_the_footer_did_not_announce_has_no_value
        ; Alcotest.test_case "a frame that drew something has no key line" `Quick
            test_a_frame_that_drew_something_has_no_key_line
        ; Alcotest.test_case "a paste or a pointer event drops the key before it" `Quick
            test_a_paste_or_a_pointer_event_drops_the_key_before_it
        ; Alcotest.test_case "silence and terminal replies keep the key waiting" `Quick
            test_silence_and_terminal_replies_keep_the_key_waiting
        ; Alcotest.test_case "a later key replaces one no frame was presented for" `Quick
            test_a_later_key_replaces_one_no_frame_was_presented_for
        ; Alcotest.test_case "hints announced for one frame do not reach the next" `Quick
            test_hints_announced_for_one_frame_do_not_reach_the_next
        ; Alcotest.test_case "no typed text reaches the file" `Quick
            test_no_typed_text_reaches_the_file
        ] )
    ; ( "clock"
      , [ Alcotest.test_case "a key after which only the clock moved is written" `Quick
            test_a_key_after_which_only_the_clock_moved_is_written
        ; Alcotest.test_case "a key after which a row changed is not written" `Quick
            test_a_key_after_which_a_row_changed_is_not_written
        ; Alcotest.test_case "a key that moved only the cursor is not written" `Quick
            test_a_key_that_moved_only_the_cursor_is_not_written
        ; Alcotest.test_case "a moved cursor is not hidden by a clock that moved with it" `Quick
            test_a_moved_cursor_is_not_hidden_by_a_clock_that_moved_with_it
        ; Alcotest.test_case "a whole-screen repaint keeps its result" `Quick
            test_a_whole_screen_repaint_keeps_its_result
        ; Alcotest.test_case "a frame the presenter called unchanged stays unchanged" `Quick
            test_a_frame_the_presenter_called_unchanged_stays_unchanged
        ] )
    ; ( "file"
      , [ Alcotest.test_case "a surface event names where the screen came from" `Quick
            test_a_surface_event_names_where_the_screen_came_from
        ; Alcotest.test_case "each line reads the clock once" `Quick
            test_each_line_reads_the_clock_once
        ; Alcotest.test_case "the cap ends the file with one capped line" `Quick
            test_the_cap_ends_the_file_with_one_capped_line
        ; Alcotest.test_case "a path that cannot be opened ends the trace without raising" `Quick
            test_a_path_that_cannot_be_opened_ends_the_trace_without_raising
        ; Alcotest.test_case "the environment variable names the file" `Quick
            test_the_environment_variable_names_the_file
        ] )
    ]
