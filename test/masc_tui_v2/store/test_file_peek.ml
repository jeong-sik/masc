(** Keepers › Trace › Tool calls › [o]: the File inspector. These checks are on
    the inspector the store opens, the reads it sends, where the read lands,
    and where Enter goes. *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol
open Masc_tui_store

let t0 = Clock.Mono.of_ns 1_000_000_000L

let key k : Keymap.Input.key_event =
  { key = k; mods = { ctrl = false; alt = false; shift = false } }

let keeper : Wire_fleet.keeper_summary =
  {
    name = "alpha";
    group = Some "core";
    company = "core";
    health = Wire_fleet.Keeper_healthy;
    paused = false;
    keepalive_running = true;
    activation_mode = Wire_fleet.Activation_autonomous;
    runtime_id = "rt-1";
    model_id = Some "claude-opus";
    current_task_id = None;
    context =
      Observed.value ~observed_at:t0
        (Wire_fleet.Context_measured
           {
             ratio = Some 0.25;
             tokens = 50_000;
             window = Some 200_000;
             absolute_turn = Some 12;
             measured_at_unix = None;
           });
    total_turns = Observed.value ~observed_at:t0 12;
    last_turn_at_unix = Some 1_700_000_000.0;
    active_turn = None;
  }

let page entries_json =
  match
    Wire_keeper_context.decode_keeper_tool_calls
      (Yojson.Safe.from_string
         (Printf.sprintf {|{"keeper":"alpha","count":1,"coverage_gaps":[],"entries":[%s]}|}
            entries_json))
  with
  | Ok p -> p
  | Error e -> Alcotest.failf "tool-calls page: %s" e

let edit_row =
  {|{"ts":2.0,"tool":"edit_file","input":{},"output":"",
     "file_target":{"path":"lib/a.ml","lines":{"start_line":12,"end_line":40}}}|}

let shell_row = {|{"ts":1.0,"tool":"masc_shell","input":{"cmd":"ls"},"output":""}|}

let tool_calls_model entries_json =
  let base = Model.initial ~cols:140 ~rows:40 () in
  let fleet =
    base.fleet
    |> Fleet_store.apply_roster ~observed_at:t0 { keepers = [ keeper ]; unreadable = [] }
    |> Fleet_store.set_keeper_dive_tab Nav.Keeper_trace
  in
  let keeper_context =
    Keeper_context_store.apply_tool_calls ~observed_at:t0 ~keeper:"alpha"
      (page entries_json) base.keeper_context
    |> Keeper_context_store.set_trace_section ~keeper:"alpha"
         Keeper_context_store.Trace_tool_calls
  in
  { base with nav = { base.nav with workspace = Nav.Keepers; pane_index = 1 }; fleet; keeper_context }

let file_reads cmds =
  List.filter_map
    (function
      | Cmd.Http_get { req = Cmd.Get_workspace_file { scope; path }; _ } -> Some (scope, path)
      | _ -> None)
    (Cmd.flatten cmds)

let scope_label = function
  | Wire_infra.Ws_keeper k -> "keeper:" ^ k
  | Wire_infra.Ws_project -> "project"
  | Wire_infra.Ws_repo _ -> "repo"

let reads cmds = List.map (fun (scope, path) -> scope_label scope ^ " " ^ path) (file_reads cmds)

let press_o m = Update.step ~now:t0 m (Msg.Key_event (key (Keymap.Input.Char "o")))

let opened () = press_o (tool_calls_model (edit_row ^ "," ^ shell_row))

let peek_of (m : Model.t) =
  match Model.active_inspector m with
  | Some (Nav.File_inspector p) -> Some (p.keeper, p.path, p.line)
  | Some
      ( Nav.Verification_inspector _ | Nav.Tool_inspector _ | Nav.Skill_inspector _
      | Nav.Exact_run_inspector _ )
  | None ->
      None

let file_reply (m : Model.t) ~path result =
  Update.step ~now:t0 m
    (Msg.Http_reply
       {
         epoch = m.epoch;
         reply = Msg.Reply_workspace_file { scope = Wire_infra.Ws_keeper "alpha"; path; result };
       })

let content path : Wire_infra.workspace_file_content =
  { path; content = String.concat "\n" (List.init 60 string_of_int); revision = "r1" }

let test_o_opens_the_target_at_its_first_line () =
  let m, cmds = opened () in
  Alcotest.(check (option (triple string string int))) "File inspector"
    (Some ("alpha", "lib/a.ml", 12)) (peek_of m);
  Alcotest.(check (list string)) "reads the file from the Keeper workspace"
    [ "keeper:alpha lib/a.ml" ] (reads cmds);
  Alcotest.(check int) "opens a few lines above the target" 8 m.nav.inspector_scroll_offset

let test_o_without_a_target_sends_nothing () =
  let m, cmds = press_o (tool_calls_model shell_row) in
  Alcotest.(check bool) "no inspector" true (Option.is_none (Model.active_inspector m));
  Alcotest.(check (list string)) "no read" [] (reads cmds)

let test_reply_fills_only_the_shown_file () =
  let m, _ = opened () in
  let other, _ = file_reply m ~path:"lib/b.ml" (Ok (content "lib/b.ml")) in
  Alcotest.(check bool) "another file's reply is not shown" true
    (Option.is_none (Infra_store.file_peek_content ~keeper:"alpha" ~path:"lib/b.ml" other.infra));
  let shown, _ = file_reply m ~path:"lib/a.ml" (Ok (content "lib/a.ml")) in
  Alcotest.(check (option string)) "the shown file's reply is kept" (Some "r1")
    (Option.map
       (fun (c : Wire_infra.workspace_file_content) -> c.revision)
       (Infra_store.file_peek_content ~keeper:"alpha" ~path:"lib/a.ml" shown.infra))

let is_failed (slot : _ Observed.t) =
  match slot with
  | Observed.Failed _ -> true
  | Observed.Value _ | Observed.Loading _ | Observed.Absent | Observed.Unreported -> false

let not_found = Msg.Http_error { status = 404; body = ""; api_error = None }

let open_peek (m : Model.t) path =
  Update_nav.open_inspector m (Nav.File_inspector { keeper = "alpha"; path; line = 1 })

let test_read_failure_is_kept_as_failed () =
  let m, _ = opened () in
  let m, _ =
    file_reply m ~path:"lib/a.ml" (Error (Msg.Transport (Health.Other_io "connection closed")))
  in
  Alcotest.(check bool) "failed" true
    (is_failed (Infra_store.file_peek_state ~keeper:"alpha" ~path:"lib/a.ml" m.infra))

let test_esc_returns_to_the_row () =
  let before = tool_calls_model (edit_row ^ "," ^ shell_row) in
  let m, _ = press_o before in
  let m, _ = Update.step ~now:t0 m (Msg.Key_event (key Keymap.Input.Escape)) in
  Alcotest.(check bool) "inspector closed" true (Option.is_none (Model.active_inspector m));
  Alcotest.(check bool) "still in Keepers" true (Nav.equal_workspace m.nav.workspace Nav.Keepers);
  Alcotest.(check int) "same pane" before.nav.pane_index m.nav.pane_index;
  Alcotest.(check bool) "still on Tool calls" true
    (Keeper_context_store.equal_trace_section
       (Keeper_context_store.get_keeper ~keeper:"alpha" m.keeper_context).trace_section
       Keeper_context_store.Trace_tool_calls)

let test_enter_opens_the_file_in_code () =
  let m, _ = opened () in
  let m, cmds = Update.step ~now:t0 m (Msg.Key_event (key Keymap.Input.Enter)) in
  Alcotest.(check bool) "Infra workspace" true (Nav.equal_workspace m.nav.workspace Nav.Infra);
  Alcotest.(check bool) "inspector closed" true (Option.is_none (Model.active_inspector m));
  Alcotest.(check string) "Keeper workspace scope" "keeper:alpha" (scope_label m.infra.code.scope);
  Alcotest.(check (option (pair string int))) "jump target" (Some ("lib/a.ml", 12))
    m.infra.code.pending_jump_line;
  Alcotest.(check (list string)) "file read" [ "keeper:alpha lib/a.ml" ] (reads cmds)

let test_a_failed_file_does_not_stop_the_next () =
  let m, _ = opened () in
  let m, _ = file_reply m ~path:"lib/a.ml" (Error not_found) in
  let m, cmds = open_peek m "lib/b.ml" in
  Alcotest.(check (list string)) "b is read" [ "keeper:alpha lib/b.ml" ] (reads cmds);
  Alcotest.(check bool) "a's failure is not b's" false
    (is_failed (Infra_store.file_peek_state ~keeper:"alpha" ~path:"lib/b.ml" m.infra))

let test_a_failure_after_a_shown_file_is_a_failure () =
  let m, _ = opened () in
  let m, _ = file_reply m ~path:"lib/a.ml" (Ok (content "lib/a.ml")) in
  let m, _ = open_peek m "lib/b.ml" in
  let m, _ = file_reply m ~path:"lib/b.ml" (Error not_found) in
  Alcotest.(check bool) "b failed" true
    (is_failed (Infra_store.file_peek_state ~keeper:"alpha" ~path:"lib/b.ml" m.infra))

let test_reopening_reads_again () =
  let before = tool_calls_model (edit_row ^ "," ^ shell_row) in
  let m, _ = press_o before in
  let m, _ = file_reply m ~path:"lib/a.ml" (Ok (content "lib/a.ml")) in
  let m, _ = Update.step ~now:t0 m (Msg.Key_event (key Keymap.Input.Escape)) in
  let _, cmds = press_o m in
  Alcotest.(check (list string)) "read again" [ "keeper:alpha lib/a.ml" ] (reads cmds)

let shown_state (m : Model.t) =
  Infra_store.file_peek_state ~keeper:"alpha" ~path:"lib/a.ml" m.infra

let planned m = reads (View_fetches.fetches_for_current_view m)

(* The first read shows as loading and is not planned a second time. *)
let test_the_first_read_is_sent_once () =
  let m, _ = opened () in
  Alcotest.(check bool) "loading" true (Observed.is_loading (shown_state m));
  Alcotest.(check (list string)) "not planned again" [] (planned m)

let test_moving_before_the_body_keeps_the_target () =
  let down m = fst (Update.step ~now:t0 m (Msg.Key_event (key Keymap.Input.Down))) in
  let m, _ = opened () in
  let m = down m in
  Alcotest.(check int) "target kept without a body" 8 m.nav.inspector_scroll_offset;
  let m, _ = file_reply m ~path:"lib/a.ml" (Ok (content "lib/a.ml")) in
  Alcotest.(check int) "moves once the body is here" 9 (down m).nav.inspector_scroll_offset

let test_a_reconnect_reads_again () =
  let m, _ = opened () in
  let m, _ = file_reply m ~path:"lib/a.ml" (Ok (content "lib/a.ml")) in
  let m = Model.mark_all_domains_stale m in
  Alcotest.(check bool) "stale" true (Observed.is_stale (shown_state m));
  Alcotest.(check (list string)) "read again" [ "keeper:alpha lib/a.ml" ] (planned m)

(* The server comes back on another workspace, where the same Keeper and path
   can name another file. *)
let test_a_workspace_change_forgets_the_body () =
  let m, _ = opened () in
  let m, _ = file_reply m ~path:"lib/a.ml" (Ok (content "lib/a.ml")) in
  let mismatch =
    Msg.Workspace_mismatch
      {
        expected_instance = Some "inst-1";
        observed_instance = Some "inst-2";
        observed_workspace_sha256 = Some "sha-2";
        message = "server restarted on another workspace";
      }
  in
  let m, _ =
    Update.step ~now:t0 m
      (Msg.Http_reply { epoch = m.epoch; reply = Msg.Reply_dashboard_shell (Error mismatch) })
  in
  Alcotest.(check bool) "inspector still open" true (Option.is_some (peek_of m));
  Alcotest.(check bool) "old body forgotten" true
    (Option.is_none (Infra_store.file_peek_content ~keeper:"alpha" ~path:"lib/a.ml" m.infra));
  Alcotest.(check (list string)) "read again" [ "keeper:alpha lib/a.ml" ] (planned m)

let () =
  Alcotest.run "file_peek"
    [
      ( "store",
        [
          Alcotest.test_case "o opens the target" `Quick test_o_opens_the_target_at_its_first_line;
          Alcotest.test_case "o without a target" `Quick test_o_without_a_target_sends_nothing;
          Alcotest.test_case "reply fills only the shown file" `Quick
            test_reply_fills_only_the_shown_file;
          Alcotest.test_case "read failure" `Quick test_read_failure_is_kept_as_failed;
          Alcotest.test_case "esc returns to the row" `Quick test_esc_returns_to_the_row;
          Alcotest.test_case "enter opens Code" `Quick test_enter_opens_the_file_in_code;
          Alcotest.test_case "a failed file does not stop the next" `Quick
            test_a_failed_file_does_not_stop_the_next;
          Alcotest.test_case "a failure after a shown file" `Quick
            test_a_failure_after_a_shown_file_is_a_failure;
          Alcotest.test_case "reopening reads again" `Quick test_reopening_reads_again;
          Alcotest.test_case "the first read is sent once" `Quick
            test_the_first_read_is_sent_once;
          Alcotest.test_case "moving before the body keeps the target" `Quick
            test_moving_before_the_body_keeps_the_target;
          Alcotest.test_case "a reconnect reads again" `Quick test_a_reconnect_reads_again;
          Alcotest.test_case "a workspace change forgets the body" `Quick
            test_a_workspace_change_forgets_the_body;
        ] );
    ]
