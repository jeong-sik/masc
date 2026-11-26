(** Infra › Code › Review: which change is selected, which reads go out, and
    where hunk jumps and Enter land. The screen and the key handlers share
    [Code_review_layout] rows, so these checks are on those rows and on the
    requests the store emits. *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol
open Masc_tui_store

module L = Code_review_layout

let t0 = Clock.Mono.of_ns 1_000_000_000L

let char_key s : Keymap.Input.key_event =
  { key = Keymap.Input.Char s; mods = { ctrl = false; alt = false; shift = false } }

let enter_key : Keymap.Input.key_event =
  { key = Keymap.Input.Enter; mods = { ctrl = false; alt = false; shift = false } }

let line kind ?old_line ?new_line text : Wire_infra.git_diff_row =
  Wire_infra.Line { kind; old_line; new_line; text }

let hunk ~old_start ~new_start : Wire_infra.git_diff_row =
  Wire_infra.Hunk
    { old_start; old_count = 2; new_start; new_count = 2; section = None }

(* Two hunks: lines 1..2 and 40..41 of the new file. *)
let two_hunks =
  [ hunk ~old_start:1 ~new_start:1;
    line `Delete ~old_line:1 "old a";
    line `Delete ~old_line:2 "old b";
    line `Add ~new_line:1 "new a";
    line `Context ~old_line:3 ~new_line:2 "keep";
    hunk ~old_start:40 ~new_start:40;
    line `Context ~old_line:40 ~new_line:40 "tail";
    line `Add ~new_line:41 "more" ]

(* Long enough that the second hunk sits below the first screen. *)
let long_diff =
  (hunk ~old_start:1 ~new_start:1
   :: List.init 60 (fun i -> line `Context ~old_line:(i + 1) ~new_line:(i + 1) "same"))
  @ [ hunk ~old_start:100 ~new_start:100; line `Add ~new_line:100 "added" ]

let row_label = function
  | L.Hunk_header h -> Printf.sprintf "@%d" h.new_start
  | L.Single l -> "1:" ^ l.text
  | L.Pair { left; right } ->
      let side = function Some (l : Wire_infra.git_diff_line) -> l.text | None -> "_" in
      Printf.sprintf "%s|%s" (side left) (side right)

let test_side_by_side_pairs_each_change_block () =
  Alcotest.(check (list string)) "paired rows"
    [ "@1"; "old a|new a"; "old b|_"; "keep|keep"; "@40"; "tail|tail"; "_|more" ]
    (List.map row_label (L.rows ~side_by_side:true two_hunks));
  Alcotest.(check int) "unified keeps one row per diff row" (List.length two_hunks)
    (List.length (L.rows ~side_by_side:false two_hunks))

let test_hunk_steps_and_jump_lines () =
  let rows = L.rows ~side_by_side:false two_hunks in
  Alcotest.(check (option int)) "next hunk from the top" (Some 5)
    (L.step_hunk ~delta:1 ~scroll:0 rows);
  Alcotest.(check (option int)) "no hunk after the last" None
    (L.step_hunk ~delta:1 ~scroll:5 rows);
  Alcotest.(check (option int)) "previous hunk" (Some 0)
    (L.step_hunk ~delta:(-1) ~scroll:5 rows);
  Alcotest.(check (option int)) "a deletion row opens the next new line" (Some 1)
    (L.jump_line ~scroll:1 rows);
  Alcotest.(check (option int)) "second hunk header opens its start" (Some 40)
    (L.jump_line ~scroll:5 rows)

let status paths : Wire_infra.git_status_snapshot =
  { head = Some "main"; upstream = None; total = List.length paths;
    changes =
      List.map
        (fun path ->
          { Wire_infra.path; staged = false; unstaged = true; untracked = false;
            conflicted = false })
        paths }

let reply (m : Model.t) r = Update.step ~now:t0 m (Msg.Http_reply { epoch = m.epoch; reply = r })

let diff_reads cmds =
  List.filter_map
    (function
      | Cmd.Http_get { req = Cmd.Get_git_diff { path; _ }; _ } -> Some path
      | _ -> None)
    (Cmd.flatten cmds)

let file_reads cmds =
  List.filter_map
    (function
      | Cmd.Http_get { req = Cmd.Get_workspace_file { path; _ }; _ } -> Some path
      | _ -> None)
    (Cmd.flatten cmds)

let reviewing_model () =
  let m = Model.initial ~cols:120 ~rows:40 () in
  let infra =
    m.infra |> Infra_store.set_tab Nav.Infra_code
    |> Infra_store.set_code_right_mode Infra_store.Code_review
  in
  { m with nav = { m.nav with workspace = Nav.Infra; pane_index = 1 }; infra }

let test_status_selects_the_first_change_and_reads_its_diff () =
  let m, cmds =
    reply (reviewing_model ())
      (Msg.Reply_git_status
         { scope = Wire_infra.Ws_project; result = Ok (status [ "a.ml"; "b.ml" ]) })
  in
  Alcotest.(check (option string)) "first change selected" (Some "a.ml")
    m.infra.code.active_file_path;
  Alcotest.(check (list string)) "its diff is read" [ "a.ml" ] (diff_reads cmds)

let selected_with_diff () =
  let m, _ =
    reply (reviewing_model ())
      (Msg.Reply_git_status
         { scope = Wire_infra.Ws_project; result = Ok (status [ "a.ml"; "b.ml" ]) })
  in
  fst
    (reply m
       (Msg.Reply_git_diff
          { scope = Wire_infra.Ws_project; path = "a.ml";
            result = Ok { has_changes = true; rows = long_diff } }))

let test_next_change_reads_its_diff () =
  let m, cmds = Update.step ~now:t0 (selected_with_diff ()) (Msg.Key_event (char_key ">")) in
  Alcotest.(check (option string)) "second change selected" (Some "b.ml")
    m.infra.code.active_file_path;
  Alcotest.(check (list string)) "its diff is read" [ "b.ml" ] (diff_reads cmds)

let test_hunk_key_scrolls_to_the_next_header () =
  let m, _ = Update.step ~now:t0 (selected_with_diff ()) (Msg.Key_event (char_key "}")) in
  Alcotest.(check int) "scrolled to the second hunk" 61 m.infra.code.git_scroll_offset

let test_enter_opens_the_line_at_the_top_of_the_diff () =
  let m, _ = Update.step ~now:t0 (selected_with_diff ()) (Msg.Key_event (char_key "}")) in
  let m, cmds = Update.step ~now:t0 m (Msg.Key_event enter_key) in
  Alcotest.(check bool) "file view" true
    (Infra_store.equal_code_right_mode m.infra.code.right_mode Infra_store.Code_file);
  Alcotest.(check (option (pair string int))) "jump target" (Some ("a.ml", 100))
    m.infra.code.pending_jump_line;
  Alcotest.(check (list string)) "file read" [ "a.ml" ] (file_reads cmds)

let not_found = Msg.Http_error { status = 404; body = ""; api_error = None }

let a_diff_failed () =
  let m, _ =
    reply (reviewing_model ())
      (Msg.Reply_git_status
         { scope = Wire_infra.Ws_project; result = Ok (status [ "a.ml"; "b.ml" ]) })
  in
  fst
    (reply m
       (Msg.Reply_git_diff
          { scope = Wire_infra.Ws_project; path = "a.ml"; result = Error not_found }))

let is_failed (slot : _ Observed.t) =
  match slot with
  | Observed.Failed _ -> true
  | Observed.Value _ | Observed.Loading _ | Observed.Absent | Observed.Unreported -> false

let test_a_failed_diff_does_not_stop_the_next_file () =
  let failed = a_diff_failed () in
  Alcotest.(check bool) "a.ml failed" true (is_failed failed.infra.code.git_diff);
  let m, cmds = Update.step ~now:t0 failed (Msg.Key_event (char_key ">")) in
  Alcotest.(check (option string)) "second change selected" (Some "b.ml")
    m.infra.code.active_file_path;
  Alcotest.(check (list string)) "its diff is read" [ "b.ml" ] (diff_reads cmds)

let test_a_late_failure_does_not_land_on_another_file () =
  let m, _ =
    reply (reviewing_model ())
      (Msg.Reply_git_status
         { scope = Wire_infra.Ws_project; result = Ok (status [ "a.ml"; "b.ml" ]) })
  in
  let m, _ = Update.step ~now:t0 m (Msg.Key_event (char_key ">")) in
  let m, _ =
    reply m
      (Msg.Reply_git_diff
         { scope = Wire_infra.Ws_project; path = "a.ml"; result = Error not_found })
  in
  Alcotest.(check bool) "b.ml is not marked failed" false (is_failed m.infra.code.git_diff)

let () =
  Alcotest.run "code_review"
    [ ( "layout",
        [ Alcotest.test_case "side by side pairs" `Quick
            test_side_by_side_pairs_each_change_block;
          Alcotest.test_case "hunk steps and jump lines" `Quick
            test_hunk_steps_and_jump_lines ] );
      ( "store",
        [ Alcotest.test_case "status selects the first change" `Quick
            test_status_selects_the_first_change_and_reads_its_diff;
          Alcotest.test_case "next change reads its diff" `Quick
            test_next_change_reads_its_diff;
          Alcotest.test_case "hunk key scrolls" `Quick
            test_hunk_key_scrolls_to_the_next_header;
          Alcotest.test_case "enter opens the line" `Quick
            test_enter_opens_the_line_at_the_top_of_the_diff;
          Alcotest.test_case "a failed diff does not stop the next file" `Quick
            test_a_failed_diff_does_not_stop_the_next_file;
          Alcotest.test_case "a late failure stays on its file" `Quick
            test_a_late_failure_does_not_land_on_another_file ] ) ]
