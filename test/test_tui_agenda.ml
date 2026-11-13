(** What the strip above the composer says, and whether it takes a row at all.

    The rows here are the ones the live workspace was carrying when this was
    written: an [edgar.a.poe] check on cron ["45 8-23 * * *"], the hourly
    board sweeps behind it, and the settled rows that outnumber them 37 to 13
    in the same store.

    Two properties matter more than any one rendering. The first is that
    [rows_taken] and [strip] answer the same question -- the frame draws the
    row that the keypress bound subtracts, or neither does. The second is
    that a status nobody recognised does not reach the strip: the wire is
    strings, and a string that means nothing to us must not mean "due". *)

open Alcotest

module Agenda = struct
  include Masc_tui_agenda

  (* Every case written before the question, goal and stuck sections states
     the same thing about them: the lists were read and they were empty.
     Shadowing [project] here says that once rather than at fifty call sites,
     and a case about those sections calls {!Masc_tui_agenda.project}
     directly. *)
  let project ~scheduled ~awaiting =
    Masc_tui_agenda.project ~scheduled ~scheduled_freshness:Last_read ~awaiting
      ~asking:(Masc_tui_agenda.Read [])
      ~confirming:(Masc_tui_agenda.Read [])
      ~stalled:(Masc_tui_agenda.Read [])
  ;;
end

(* Asia/Seoul, so 02:45Z reads as the 11:45 the operator sees. *)
let seoul t = Unix.gmtime (t +. (9.0 *. 3600.0))

let at_2026_08_26_0300z = 1787713200.0

let row ?(standing = Agenda.Coming) ?(recurrence = "every 3600s") at_iso who what
  : Agenda.scheduled
  =
  { at_iso; standing; who; what; recurrence }
;;

let edgar = row "2026-08-26T02:45:00Z" "edgar.a.poe" "진행 상황 체크"
let sweep = row "2026-08-26T03:14:04Z" "quill" "hourly board sweep"

let done_earlier =
  row ~standing:Agenda.Settled "2026-08-26T01:00:00Z" "orrery" "정기 보드 스윕"
;;

(* Registered a minute before [now]. The registry's timeout starts only after
   question publication, so these fields do not determine time remaining. *)
let asked_at_1155 = 1787713140.0

let ask ?(asked_at = asked_at_1155) ?(timeout_sec = 300.0)
    ?(tool_call_id = "call-1") asked_by question
  : Agenda.awaiting
  =
  { asked_by; tool_call_id; question; asked_at; timeout_sec }
;;

let strip_of ?(now = at_2026_08_26_0300z) ?(cols = 80) t =
  Agenda.strip ~ko:false ~now ~localtime:seoul ~cols t
;;

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i = i + n <= h && (String.sub haystack i n = needle || loop (i + 1)) in
  n = 0 || loop 0
;;

(* The property the Changes list lost its arrow keys to: a row the drawing
   adds while the bound counts rows without it. Here the two cannot disagree
   for any combination of the strip's two halves. *)
let test_rows_taken_agrees_with_what_is_drawn () =
  List.iter
    (fun (name, scheduled, awaiting) ->
       let t = Agenda.project ~scheduled:(Agenda.Read scheduled)
         ~awaiting:(Agenda.Read awaiting) in
       let drawn = strip_of t <> None in
       check
         bool
         (name ^ ": the row is counted exactly when it is drawn")
         drawn
         (Agenda.rows_taken t > 0))
    [ "nothing at all", [], []
    ; "a wake only", [ edgar ], []
    ; "a question only", [], [ ask "lane-smith" "Execute" ]
    ; "both", [ edgar; sweep ], [ ask "lane-smith" "Execute" ]
    ; "only settled rows", [ done_earlier ], []
    ]
;;

let test_an_empty_agenda_gives_the_row_back () =
  let t = Agenda.project ~scheduled:(Agenda.Read [ done_earlier ])
            ~awaiting:(Agenda.Read []) in
  check int "a store of finished rows takes no row" 0 (Agenda.rows_taken t);
  check bool "and draws nothing" true (strip_of t = None)
;;

(* [scheduled] and [due] are ahead of the operator; everything else has
   happened. A string outside the set is not a due row -- defaulting it onto
   the strip is how an unknown becomes a claim. *)
let test_wire_status_parsing () =
  let coming s = Agenda.standing_of_wire s = Agenda.Coming in
  List.iter
    (fun s -> check bool (s ^ " is still ahead") true (coming s))
    [ "scheduled"; "due" ];
  List.iter
    (fun s -> check bool (s ^ " has happened") false (coming s))
    [ "running"; "succeeded"; "failed"; "cancelled"; "expired" ];
  (match Agenda.standing_of_wire "quantum" with
   | Agenda.Unrecognised text -> check string "kept as itself" "quantum" text
   | Agenda.Coming -> fail "an unknown status reached the strip as due"
   | Agenda.Settled -> fail "an unknown status was folded into settled")
;;

let overlay_of ?(now = at_2026_08_26_0300z) ?(cols = 78) t =
  Agenda.overlay ~ko:false ~now ~localtime:seoul ~cols t
;;

let texts lines = List.map (fun (l : Agenda.line) -> l.Agenda.text) lines

let joined lines = String.concat "\n" (texts lines)

let tones_of lines tone =
  List.filter (fun (l : Agenda.line) -> l.Agenda.tone = tone) lines
;;

let test_stale_schedule_is_not_presented_as_current () =
  let project scheduled =
    Masc_tui_agenda.project ~scheduled
      ~scheduled_freshness:Agenda.Refresh_needed ~awaiting:(Agenda.Read [])
      ~asking:(Agenda.Read []) ~confirming:(Agenda.Read []) ~stalled:(Agenda.Read [])
  in
  let empty = project (Agenda.Read []) in
  check int "a stale empty read still takes a row" 1 (Agenda.rows_taken empty);
  let english = Option.get (strip_of empty) in
  check bool "the strip marks the empty reading as uncertain" true
    (contains ~needle:"Schedule may be out of date" english);
  let korean = Option.get (Agenda.strip ~ko:true ~now:at_2026_08_26_0300z
      ~localtime:seoul ~cols:80 empty) in
  check bool "Korean status is available" true
    (contains ~needle:"일정 정보가 오래됐을 수 있음" korean);
  let empty_panel = joined (overlay_of empty) in
  check bool "the panel marks the stale reading" true
    (contains ~needle:"Schedule may be out of date" empty_panel);
  check bool "the stale empty reading is not called empty" false
    (contains ~needle:"nothing is scheduled" empty_panel);
  let old_wake = project (Agenda.Read [ edgar ]) in
  let old_strip = Option.get (strip_of old_wake) in
  check bool "an old wake is not presented on the strip" false
    (contains ~needle:"edgar" old_strip);
  let old_panel = joined (overlay_of old_wake) in
  check bool "the panel labels retained rows" true
    (contains ~needle:"Schedule may be out of date" old_panel);
  check bool "the retained wake remains inspectable" true
    (contains ~needle:"edgar" old_panel);
  List.iter
    (fun cols ->
      let line = Option.get (Agenda.strip ~ko:true ~now:at_2026_08_26_0300z
          ~localtime:seoul ~cols empty) in
      check int "the row fits the available columns" cols
        (Masc_tui_message_layout.display_width line))
    [ 0; 1; 5; 20; 80 ]
;;

let test_an_unread_agenda_keeps_the_strip_down () =
  let t =
    Agenda.project ~scheduled:Agenda.Not_read
      ~awaiting:(Agenda.Read_failed "tool approvals load failed: HTTP 503")
  in
  check bool "no strip" true (strip_of t = None);
  check int "and no row taken" 0 (Agenda.rows_taken t)
;;

let test_failed_reads_are_safe_before_the_panel_fits_them () =
  let state =
    Masc_tui_types.create_state ~workspace:"test" ~port:8935 ()
  in
  let raw = "오류\027[31m\n\xFF\xE2\x80\x8B literal \\x1B" in
  let expected = "오류\\x1B[31m\\x0A\\xFF\\u200B literal \\x1B" in
  let body_rows = Masc_tui_types.surface_body_rows state ~terminal_rows:24 in
  state.schedules_agenda_error <- Some raw;
  state.keeper_tool_approvals_error <- Some raw;
  state.tasks_error <- Some raw;
  state.operator_stalled <- Agenda.Read_failed raw;
  check int "failed reads do not take a strip row" 0
    (Masc_tui_types.agenda_chrome_rows state);
  check int "failed reads preserve the body budget" body_rows
    (Masc_tui_types.surface_body_rows state ~terminal_rows:24);
  List.iter
    (fun cols ->
       let failures =
         overlay_of ~cols (Masc_tui_types.agenda state)
         |> fun lines -> tones_of lines Agenda.Failed
       in
       check int "all three failed reads have a row" 3 (List.length failures);
       List.iter
         (fun (line : Agenda.line) ->
            check bool "controls and invalid bytes cannot reach the terminal" false
              (String.exists
                 (fun c -> Char.code c < 0x20 || c = '\127' || c = '\xFF')
                 line.text);
            check bool "invisible codepoint is shown as text" false
              (contains ~needle:"\xE2\x80\x8B" line.text);
            check bool "escaped text is fitted to the row width" true
              (Masc_tui_message_layout.display_width line.text <= cols);
            if cols = 120 then
              check string "readable reason and literal escape are preserved"
                expected (String.trim line.text))
         failures)
    [ 16; 32; 120 ]
;;

let test_failed_schedule_snapshot_uses_the_same_display_boundary () =
  List.iter
    (fun (reason, expected) ->
       let state =
         Masc_tui_types.create_state ~workspace:"test" ~port:8935 ()
       in
       state.schedules_agenda <- Some
         { scs_status = "unknown"; scs_read_error = reason
         ; scs_request_count = None; scs_truncated = false
         ; scs_payload_target = None; scs_paging = Schedule_paging_unavailable
         ; scs_next_due_iso = None; scs_counts = None; scs_rows = []
         ; scs_observed_at_iso = "2026-10-26T08:59:00Z"
         ; scs_runner_status = Masc.Tui_decode.Runner_unrecognised "unknown"
         };
       state.schedules_agenda_error <- Some "older transport failure";
       let projection = Masc_tui_types.agenda state in
       check int "a failed store snapshot has no strip" 0 (Agenda.rows_taken projection);
       let failures = tones_of (overlay_of ~cols:120 projection) Agenda.Failed in
       check (list string) "the store reason wins and is safe to draw"
         [ expected ] (List.map (fun (line : Agenda.line) -> String.trim line.text) failures))
    [ Some "store\027[2Jfailed", "store\\x1B[2Jfailed"
    ; None, "schedule store unreadable"
    ]
;;

(* The title stands in for the row: these cases read where the row leads
   and what reaches the terminal, not the sentence around the title. *)
let stuck ?(since_iso = "2026-08-20T00:00:00Z") ?(task_id = "task-348")
    title : Agenda.stalled =
  Masc.Operator_task_attention.Held_without_keeper_route
    { task_id; title; assignee = "codex-mcp-client"; since = since_iso }
;;

let with_stuck rows =
  Masc_tui_agenda.project
    ~scheduled_freshness:Agenda.Last_read
    ~scheduled:(Agenda.Read [])
    ~awaiting:(Agenda.Read [])
    ~asking:(Agenda.Read [])
    ~confirming:(Agenda.Read [])
    ~stalled:(Agenda.Read rows)
;;

(* A missing route is not a request for the operator to answer. *)
let test_a_task_route_is_not_an_operator_request () =
  let t = with_stuck [ stuck "task-348: held by codex-mcp-client, which has no Keeper queue" ] in
  check int "the route does not count as a request" 0 (Agenda.waiting t);
  check int "and takes no row above the composer" 0 (Agenda.rows_taken t)
;;

let test_task_route_text_cannot_control_the_terminal () =
  let task_id = "task-control" in
  let raw = "title\rnext\nline\tend\027[31m\127\194\155" in
  let lines = overlay_of ~cols:160 (with_stuck [ stuck ~task_id raw ]) in
  match List.find_opt (fun (line : Agenda.line) ->
      line.goes_to = Agenda.Stuck_task task_id) lines with
  | None -> fail "the task remains reachable"
  | Some line ->
      check bool "external control bytes do not reach the terminal" false
        (String.exists (fun c -> Char.code c < 32 || Char.code c = 127) line.text);
      check bool "a UTF-8 C1 control does not reach the terminal" false
        (contains ~needle:"\194\155" line.text)
;;

let test_the_stuck_section_draws_every_row () =
  let rows =
    List.init 9 (fun index ->
      stuck
        ~task_id:(Printf.sprintf "task-%03d" index)
        ~since_iso:(Printf.sprintf "2026-08-%02dT00:00:00Z" (index + 10))
        (Printf.sprintf "task-%03d: held by a session that is gone" index))
  in
  let lines = overlay_of (with_stuck rows) in
  let reached =
    List.filter_map
      (fun index ->
        match List.nth_opt lines index with
        | Some { Agenda.goes_to = Agenda.Stuck_task task_id; _ } -> Some task_id
        | Some _ | None -> None)
      (Agenda.target_indexes lines)
  in
  check (list string) "every row, oldest first, takes the cursor"
    (List.map Masc.Operator_task_attention.task_id rows)
    reached
;;

let goal ?(since_iso = "2026-08-25T00:00:00Z") ?(goal_id = "goal-1") title
  : Agenda.goal_to_confirm =
  { goal_id; title; since_iso }
;;

let with_goals goals =
  Masc_tui_agenda.project
    ~scheduled_freshness:Agenda.Last_read
    ~scheduled:(Agenda.Read [])
    ~awaiting:(Agenda.Read [])
    ~asking:(Agenda.Read [])
    ~confirming:(Agenda.Read goals)
    ~stalled:(Agenda.Read [])
;;

(* A Goal whose stored phase awaits confirmation counts in the badge, and
   Enter leads to it without claiming that the proof was read. *)
let test_a_goal_to_confirm_is_waiting_on_the_operator () =
  let t = with_goals [ goal ~goal_id:"goal-9" "v0.38.0 release" ] in
  check int "a goal to confirm is counted" 1 (Agenda.waiting t);
  check bool "and the badge has something to say" true
    (Agenda.waiting_label ~ko:false ~cells:80 t <> "");
  let lines = overlay_of t in
  match Agenda.target_indexes lines with
  | [ index ] -> (
      match List.nth_opt lines index with
      | Some { Agenda.goes_to = Agenda.Goal_to_confirm goal_id; _ } ->
          check string "Enter leads to the goal" "goal-9" goal_id
      | Some _ | None -> fail "the goal row leads nowhere")
  | targets ->
      failf "expected one row to lead somewhere, got %d" (List.length targets)
;;

let test_only_rows_that_lead_somewhere_take_the_cursor () =
  let t = with_stuck [ stuck ~task_id:"task-348" "work nobody holds" ] in
  let lines = overlay_of t in
  match Agenda.target_indexes lines with
  | [ index ] -> (
      match List.nth_opt lines index with
      | Some { Agenda.goes_to = Agenda.Stuck_task task_id; _ } ->
          check string "the row names its task" "task-348" task_id
      | Some _ | None -> fail "the row the cursor stops on leads nowhere")
  | targets ->
      failf "expected one row to lead somewhere, got %d" (List.length targets)

(* Headings, spacers and the note an empty section draws are prose. A cursor
   that stopped on them would have Enter do nothing on most presses. *)
let test_prose_rows_take_no_cursor () =
  check (list int) "an empty agenda opens nothing" []
    (Agenda.target_indexes (overlay_of (with_stuck [])))

(* Refresh the same mutable workspace fields the loader replaces. Selection
   is the identity from the earlier displayed projection; renderer lookup and
   Enter lookup must agree even though that projection's row numbers moved. *)
let agenda_state () =
  Masc_tui_types.create_state ~workspace:"" ~port:0 ()

let lines_of_state state = overlay_of (Masc_tui_types.agenda state)

let selected_row state lines =
  match Agenda.selected_index lines ~selected:state.Masc_tui_types.agenda_selected with
  | Some row -> row
  | None -> fail "selected identity should still have a visible row"

let opened_target state lines =
  Option.map (fun line -> line.Agenda.goes_to)
    (Agenda.selected_line lines ~selected:state.Masc_tui_types.agenda_selected)

let test_task_goal_reading_preserves_source_truth () =
  let state = agenda_state () in
  let reading () = Masc_tui_types.task_goal_reading state ~task_id:"task-777" in
  check bool "an unread registry makes no absence claim" true
    (reading () = Agenda.Not_read);
  let index = Workspace_goal_index.build_task_goal_index
      ~goal_task_links:["goal-a", ["task-777"]; "goal-b", ["task-777"]] () in
  state.goal_task_links <- Masc_tui_types.Goal_links_read index;
  check bool "multiple Goal references come from the registry" true
    (reading () = Agenda.Read ["goal-a"; "goal-b"]);
  state.goal_task_links <- Masc_tui_types.Goal_links_read_failed "malformed primary";
  check bool "failed refresh does not reuse references or assert absence" true
    (reading () = Agenda.Read_failed "malformed primary");
  state.goal_task_links <- Masc_tui_types.Goal_links_read (Hashtbl.create 0);
  check bool "repaired empty registry proves absence" true
    (reading () = Agenda.Read []);
  state.goal_task_links <- Masc_tui_types.Goal_links_not_read;
  check bool "workspace reset discards the old index" true
    (reading () = Agenda.Not_read)

let test_distinct_calls_from_one_keeper_remain_reachable () =
  let state = agenda_state () in
  let held tool_call_id : Masc.Tui_decode.keeper_tool_approval =
    { kta_keeper = "keeper-a"
    ; kta_tool_call_id = tool_call_id
    ; kta_approval_id = "approval-" ^ tool_call_id
    ; kta_tool = "exec"
    ; kta_args = "{}"
    ; kta_question = "run?"
    ; kta_because = None
    ; kta_asked_at = asked_at_1155
    ; kta_timeout_sec = 300.
    }
  in
  let first = held "call-a" and second = held "call-b" in
  state.keeper_tool_approvals_observed <- true;
  state.keeper_tool_approvals <- [first; second];
  state.goals_to_confirm <- Agenda.Read [goal ~goal_id:"goal-a" "Proof"];
  let displayed = lines_of_state state in
  let advance lines =
    state.agenda_selected <- Agenda.step lines ~selected:state.agenda_selected Agenda.Next
  in
  let target tool_call_id =
    Agenda.Keeper_holding { keeper = "keeper-a"; tool_call_id }
  in
  advance displayed;
  check bool "first held call is selected" true
    (opened_target state displayed = Some (target "call-a"));
  advance displayed;
  check bool "j reaches the same Keeper's second call" true
    (opened_target state displayed = Some (target "call-b"));
  let old_row = selected_row state displayed in
  advance displayed;
  check bool "j passes both calls to reach the Goal" true
    (opened_target state displayed = Some (Agenda.Goal_to_confirm "goal-a"));
  state.agenda_selected <- Agenda.step displayed ~selected:state.agenda_selected Agenda.Previous;
  state.keeper_tool_approvals <- [second; first];
  let refreshed = lines_of_state state in
  check bool "the selected call moves after refresh" true
    (selected_row state refreshed <> old_row);
  check bool "refresh preserves the specific held call" true
    (opened_target state refreshed = Some (target "call-b"))

let test_goal_selection_survives_refresh_reordering () =
  let state = agenda_state () in
  let a = goal ~goal_id:"goal-a" "First proof" in
  let b = goal ~goal_id:"goal-b" "Second proof" in
  state.goals_to_confirm <- Agenda.Read [a; b];
  let displayed = lines_of_state state in
  state.agenda_selected <- Agenda.step displayed ~selected:Agenda.Nowhere Agenda.Next;
  let old_row = selected_row state displayed in
  (* A priority edit changes Goal_store's sorted read. *)
  state.goals_to_confirm <- Agenda.Read [b; a];
  let refreshed = lines_of_state state in
  check bool "the old index now names a different Goal" true
    (Option.map (fun line -> line.Agenda.goes_to) (List.nth_opt refreshed old_row)
       = Some (Agenda.Goal_to_confirm "goal-b"));
  check bool "highlight follows the chosen Goal's new row" true
    (selected_row state refreshed <> old_row);
  check bool "Enter still opens the Goal actually selected" true
    (opened_target state refreshed = Some (Agenda.Goal_to_confirm "goal-a"))

let test_task_route_is_not_a_home_decision () =
  List.iter (fun diagnostic ->
    let state = agenda_state () in
    let task_id = "task-primary" in
    state.tasks_error <- Some diagnostic;
    state.operator_stalled <- Agenda.Read [];
    let without_route = Masc_tui_home.home_decision_rows (Masc_tui_home.prepare state) in
    state.operator_stalled <- Agenda.Read [stuck ~task_id "Task to inspect"];
    check bool "an owner route does not add a Home decision" true
      (without_route = Masc_tui_home.home_decision_rows (Masc_tui_home.prepare state));
    check bool "the task remains reachable in Agenda" true
      (List.exists (fun line -> line.Agenda.goes_to = Agenda.Stuck_task task_id)
         (lines_of_state state)))
    ["task archive unavailable"; "goal links unavailable"]

let test_home_and_agenda_refuse_noncurrent_task_source () =
  let state = agenda_state () in
  state.operator_stalled <- Agenda.Read_failed "backlog recovered from backup";
  let agenda_lines = lines_of_state state in
  check bool "Agenda offers no task from a backup" false
    (List.exists (fun line -> match line.Agenda.goes_to with
       | Agenda.Stuck_task _ -> true | _ -> false) agenda_lines)

let test_inserted_goals_do_not_retarget_a_selected_task () =
  let state = agenda_state () in
  state.goals_to_confirm <- Agenda.Read [];
  state.operator_stalled <- Agenda.Read [stuck ~task_id:"shared-id" "Task to inspect"];
  let displayed = lines_of_state state in
  state.agenda_selected <- Agenda.step displayed ~selected:Agenda.Nowhere Agenda.Next;
  let old_row = selected_row state displayed in
  state.goals_to_confirm <- Agenda.Read
    [goal ~goal_id:"shared-id" "A Goal with the same opaque ID";
     goal ~goal_id:"goal-b" "New proof B";
     goal ~goal_id:"goal-c" "New proof C";
     goal ~goal_id:"goal-d" "New proof D"];
  let refreshed = lines_of_state state in
  check bool "the Task moved below the inserted Goals" true
    (selected_row state refreshed > old_row);
  check bool "the constructor and ID both remain authoritative" true
    (opened_target state refreshed = Some (Agenda.Stuck_task "shared-id"))

let test_removed_goal_does_not_select_its_replacement () =
  let state = agenda_state () in
  let a = goal ~goal_id:"goal-a" "Selected proof" in
  let b = goal ~goal_id:"goal-b" "Other proof" in
  state.goals_to_confirm <- Agenda.Read [a; b];
  let displayed = lines_of_state state in
  state.agenda_selected <- Agenda.step displayed ~selected:Agenda.Nowhere Agenda.Next;
  state.goals_to_confirm <- Agenda.Read [b];
  let refreshed = lines_of_state state in
  check (option int) "no replacement row is highlighted" None
    (Agenda.selected_index refreshed ~selected:state.agenda_selected);
  check bool "Enter does not open the Goal now at the old index" true
    (opened_target state refreshed = None);
  (* Only an explicit navigation key may choose a new target. *)
  state.agenda_selected <- Agenda.step refreshed ~selected:state.agenda_selected Agenda.Next;
  check bool "j deliberately selects the remaining Goal" true
    (opened_target state refreshed = Some (Agenda.Goal_to_confirm "goal-b"));
  state.goals_to_confirm <- Agenda.Read [];
  check bool "an empty reading moves to nowhere" true
    (Agenda.step (lines_of_state state) ~selected:state.agenda_selected Agenda.Previous
     = Agenda.Nowhere)

(* Questions a Keeper put to the operator with masc_ask. One ask can hold
   several questions; the operator answers it with one draft and one submit,
   so the ask is what waits. *)
let ask_row ?(questions = 1) ?(resolution = Masc.Tui_decode_asks.Ask_open)
    ask_id : Masc.Tui_decode_asks.ask_row =
  { ar_asker = Ask_keeper "edgar.a.poe"
  ; ar_id = ask_id
  ; ar_asked_at = asked_at_1155
  ; ar_source_turn_ref = None
  ; ar_context = None
  ; ar_questions =
      List.init questions (fun index ->
        { Masc.Tui_decode_asks.aq_id = Printf.sprintf "q%d" (index + 1)
        ; aq_header = "Release"
        ; aq_prompt = "Ship v0.38.0 tonight?"
        ; aq_mode = Masc.Tui_decode_asks.Ask_single
        ; aq_free_text = Masc.Tui_decode_asks.Ask_choices_only
        ; aq_choices = []
        })
  ; ar_resolution = resolution
  }

let answered = Masc.Tui_decode_asks.Ask_answered { aa_answered_at = 1.0; aa_question_ids = [ "q1" ] }

let withdrawn =
  Masc.Tui_decode_asks.Ask_withdrawn { aw_reason = "superseded"; aw_withdrawn_at = 1.0 }

let set_asks state rows =
  state.Masc_tui_types.asks_snapshot <-
    Some { asn_keeper = None; asn_open_count = List.length rows; asn_rows = rows }

let ask_targets lines =
  List.filter_map
    (fun index ->
      match List.nth_opt lines index with
      | Some { Agenda.goes_to = Agenda.Ask_to_answer ask; _ } -> Some ask.ak_id
      | Some _ | None -> None)
    (Agenda.target_indexes lines)

(* One count per ask, not per question: three questions in one ask are one
   thing to answer. Answered and withdrawn asks wait on nobody. *)
let test_an_ask_waits_once_however_many_questions_it_holds () =
  let state = agenda_state () in
  set_asks state
    [ ask_row ~questions:3 "ask-1"
    ; ask_row "ask-2"
    ; ask_row ~resolution:answered "ask-3"
    ; ask_row ~resolution:withdrawn "ask-4"
    ];
  let agenda = Masc_tui_types.agenda state in
  check int "two open asks wait" 2 (Agenda.waiting agenda)

let open_question ask_id : Agenda.open_question =
  { ask = { ak_asker = Ask_keeper "quill"; ak_id = ask_id }; asked_by = "quill"; first_question = Some "Merge?"
  ; asked_at = asked_at_1155 }

let with_questions rows =
  Masc_tui_agenda.project
    ~scheduled_freshness:Agenda.Last_read
    ~scheduled:(Agenda.Read [])
    ~awaiting:(Agenda.Read [])
    ~asking:(Agenda.Read rows)
    ~confirming:(Agenda.Read [])
    ~stalled:(Agenda.Read [])

let one_of_each =
  Masc_tui_agenda.project
    ~scheduled_freshness:Agenda.Last_read
    ~scheduled:(Agenda.Read [])
    ~awaiting:(Agenda.Read [ ask "lane-smith" "Execute" ])
    ~asking:(Agenda.Read [ open_question "ask-1" ])
    ~confirming:(Agenda.Read [ goal "v0.38.0 release" ])
    ~stalled:(Agenda.Read [ stuck "work nobody holds" ])

(* Route observations do not add to the request count. *)
let test_the_strip_count_adds_the_questions () =
  check int "one of each request plus a task route is three" 3 (Agenda.waiting one_of_each)

(* What the badge says is the badge's to change, so this does not read its
   words. It reads what the badge is for: nothing waiting says nothing, each
   kind reads differently from the others, and the count comes from the rows. *)
let test_the_badge_tells_the_kinds_apart () =
  let label = Agenda.waiting_label ~ko:false ~cells:80 in
  check string "nothing waiting says nothing" "" (label (with_stuck []));
  let one_question = label (with_questions [ open_question "ask-1" ]) in
  let one_stuck = label (with_stuck [ stuck "work nobody holds" ]) in
  let one_goal = label (with_goals [ goal "v0.38.0 release" ]) in
  check bool "a question and a stuck task read differently" true
    (one_question <> one_stuck);
  check bool "a question and a goal read differently" true
    (one_question <> one_goal);
  check bool "a goal and a stuck task read differently" true
    (one_goal <> one_stuck);
  check bool "two questions read differently from one" true
    (label (with_questions [ open_question "ask-1"; open_question "ask-2" ])
     <> one_question);
  check bool "every kind is in the label when all four wait" true
    (let all = label one_of_each in
     all <> one_question && all <> one_stuck && all <> one_goal)

(* The badge is the reminder that follows the operator: it is up while any ask
   is open and goes once the last one is answered. It is not the row above the
   composer, which holds the next wake. *)
let test_an_open_question_keeps_the_badge_up_until_answered () =
  let state = agenda_state () in
  set_asks state [ ask_row "ask-1" ];
  let label () = Agenda.waiting_label ~ko:false ~cells:80 (Masc_tui_types.agenda state) in
  check bool "an open question is on the badge" true (label () <> "");
  check int "and takes no row above the composer" 0
    (Masc_tui_types.agenda_chrome_rows state);
  set_asks state [ ask_row ~resolution:answered "ask-1" ];
  check string "the answered question leaves the badge" "" (label ())

(* Every open ask is a row Enter can open, and only open asks are. *)
let test_each_open_question_is_a_row_enter_opens () =
  let state = agenda_state () in
  set_asks state
    [ ask_row "ask-1"; ask_row ~resolution:answered "ask-2"; ask_row "ask-3" ];
  let lines = lines_of_state state in
  check (list string) "the open asks, and only those, lead somewhere"
    [ "ask-1"; "ask-3" ]
    (List.sort String.compare (ask_targets lines));
  let first = Agenda.step lines ~selected:Agenda.Nowhere Agenda.Next in
  let second = Agenda.step lines ~selected:first Agenda.Next in
  check bool "j reaches both" true
    (List.sort compare [ first; second ]
     = List.map (fun id -> Agenda.Ask_to_answer (Masc.Tui_decode_asks.ask_key (ask_row id))) [ "ask-1"; "ask-3" ])

(* An installation's ask id is the request id its package chose, so two
   installations can ask with one id. Home and the agenda keep them apart,
   and a package that changes its title keeps the row the operator chose. *)
let installation_ask ?(title = "Operator quiz") declaration_id : Masc.Tui_decode_asks.ask_row =
  { (ask_row "s-1-ask") with
    ar_asker = Ask_installation { ai_declaration_id = declaration_id; ai_title = title } }

let home_questions state =
  List.filter_map
    (fun (action, _) ->
       match action with
       | Masc_tui_types.Home_request (Masc_tui_types.Home_question ask) -> Some ask
       | Masc_tui_types.Home_request _ | Home_approvals | Home_agenda | Home_resume _
       | Home_read_last _ | Home_choose_keeper | Home_create_keeper | Home_operator_action _ -> None)
    (Masc_tui_home.home_decision_rows (Masc_tui_home.prepare state))

let asker_of (ask : Masc.Tui_decode_asks.ask_key) =
  match ask.ak_asker with
  | Ask_installation { ai_declaration_id; _ } -> ai_declaration_id
  | Ask_keeper name -> name

let test_two_installations_asking_with_one_id_are_two_targets () =
  let state = agenda_state () in
  state.workspace_identity <- Masc_tui_types.Workspace_identity_match;
  set_asks state [ installation_ask "quiz-a"; installation_ask "quiz-b" ];
  let asks = home_questions state in
  check (list string) "Home has a row for each installation" [ "quiz-a"; "quiz-b" ]
    (List.sort String.compare (List.map asker_of asks));
  List.iter
    (fun ask ->
       state.view <- Masc_tui_types.Approvals;
       state.home_opened_request <- Some (Masc_tui_types.Home_question ask);
       state.ask_cursor <- Masc_tui_ask_projection.Released 0;
       Masc_tui_home.reconcile_home_request_detail state;
       let rows = Option.value ~default:[] (Masc_tui_approvals_model.approvals_open_questions state) in
       check string "opening a row opens that installation's question" (asker_of ask)
         (match Masc_tui_ask_projection.selected_row rows state.ask_cursor with
          | Some row -> asker_of (Masc.Tui_decode_asks.ask_key row)
          | None -> "nothing"))
    asks;
  let lines = lines_of_state state in
  let first = Agenda.step lines ~selected:Agenda.Nowhere Agenda.Next in
  let second = Agenda.step lines ~selected:first Agenda.Next in
  check bool "j moves from one installation's question to the other's" false
    (Agenda.equal_destination first second);
  state.agenda_selected <- second;
  (match asks with
   | chosen :: _ -> state.home_selected <- Some (Masc_tui_types.Home_request (Home_question chosen))
   | [] -> fail "no Home question");
  set_asks state [ installation_ask ~title:"Quiz" "quiz-a"; installation_ask ~title:"Quiz" "quiz-b" ];
  check bool "the agenda keeps the chosen question under a new title" true
    (match opened_target state (lines_of_state state) with
     | Some target -> Agenda.equal_destination target second
     | None -> false);
  check bool "and so does Home" true
    (match Masc_tui_home.home_selected_action (Masc_tui_home.prepare state), asks with
     | Some (Masc_tui_types.Home_request (Home_question ask)), chosen :: _ ->
       Masc.Tui_decode_asks.equal_ask_key ask chosen
     | (Some _ | None), _ -> false)

(* A question list that never came back is not an empty one, and it is not
   a reason to raise the strip either. *)
let test_unread_questions_take_no_row_and_open_nothing () =
  let state = agenda_state () in
  state.asks_error <- Some "asks load failed: HTTP 503";
  check int "a failed read takes no row" 0 (Masc_tui_types.agenda_chrome_rows state);
  let lines = lines_of_state state in
  check (list string) "and offers no question to open" [] (ask_targets lines)

let test_home_approval_list_preserves_its_caller () =
  let open Masc_tui_types in
  let state = agenda_state () in
  state.view <- Overview;
  state.followed_from <- Some (Board, Some "older-reference");
  Masc_tui_message_input.insert state.msg_input "draft kept while reading requests";
  let navigate destination =
    state.view <- destination;
    state.followed_from <- None
  in
  Masc_tui_home.open_approvals state ~navigate;
  check bool "open the full request list" true (state.view = Approvals);
  check bool "back belongs to the current caller" true
    (state.followed_from = Some (Overview, None));
  check string "navigation retains the operator's draft" "draft kept while reading requests"
    (Masc_tui_message_input.contents state.msg_input)

let test_home_operator_target_keeps_original_request () =
  let module A = Masc.Operator_action_reason in
  let module P = Masc.Keeper_librarian_pending in
  let state = agenda_state () in
  let action request = A.memory_attention ~keeper:"keeper-a" ~durable:(Some (P.Worker
      {installation_id="original";request_id=request;wait=P.Missing_after_dispatch}))
      ~admission:None ~measured_at:(Some 123.) in
  let install item =
    match Masc.Tui_decode.decode_server_identity (`Assoc
      ["operator_action_required",`Bool true;
       "operator_action_reasons",`List [`String (A.diagnostic item)];
       "operator_actions",`List [A.to_json item]]) with
    | Ok identity -> state.server_identity <- Some identity
    | Error error -> Alcotest.fail error in
  let original = action "request-one" in
  install original;
  let target = match Masc_tui_home.home_operator_rows (Masc_tui_home.prepare state) with
    | [(target,_)] -> target
    | _ -> Alcotest.fail "one original observation is required" in
  state.home_selected <- Some target;
  check bool "the selected target retains the original request and scope" true
    (match target with
     | Masc_tui_types.Home_operator_action (authority,_,item) ->
         authority=state.workspace_authority && A.equal original item
     | Home_request _ | Home_approvals | Home_agenda | Home_resume _
     | Home_read_last _ | Home_choose_keeper | Home_create_keeper -> false);
  install (action "request-two");
  check bool "the same array index cannot retarget to another original" true
    (Option.is_none (Masc_tui_home.home_selected_action (Masc_tui_home.prepare state)))

let () =
  run
    "tui agenda"
    [ ( "the row"
      , [ test_case "rows_taken agrees with what is drawn" `Quick
            test_rows_taken_agrees_with_what_is_drawn
        ; test_case "an empty agenda gives the row back" `Quick
            test_an_empty_agenda_gives_the_row_back
        ; test_case "stale schedule is not presented as current" `Quick
            test_stale_schedule_is_not_presented_as_current
        ] )
    ; ( "what reaches it"
      , [ test_case "wire status parsing" `Quick test_wire_status_parsing
        ;] )
    ; ( "the frame and the bound"
      , [

        ] )
    ; ( "how it reads"
      , [] )
    ; ( "the panel"
      , [ test_case "an unread agenda keeps the strip down" `Quick
            test_an_unread_agenda_keeps_the_strip_down
        ; test_case "failed reads are safe before the panel fits them" `Quick
            test_failed_reads_are_safe_before_the_panel_fits_them
        ; test_case "failed schedule snapshots share the display boundary" `Quick
            test_failed_schedule_snapshot_uses_the_same_display_boundary
        ;] )
    ; ( "task owner routes"
      , [ test_case "a task route is not an operator request" `Quick
            test_a_task_route_is_not_an_operator_request
        ; test_case "task route text cannot control the terminal" `Quick
            test_task_route_text_cannot_control_the_terminal
        ; test_case "the section draws every row" `Quick
            test_the_stuck_section_draws_every_row
        ; test_case "only rows that lead somewhere take the cursor" `Quick
            test_only_rows_that_lead_somewhere_take_the_cursor
        ; test_case "prose rows take no cursor" `Quick
            test_prose_rows_take_no_cursor
        ] )
    ; ( "goals waiting for confirmation"
      , [ test_case "a goal to confirm is waiting on the operator" `Quick
            test_a_goal_to_confirm_is_waiting_on_the_operator
        ;] )
    ; ( "questions waiting on the operator"
      , [ test_case "operator target keeps the original request" `Quick
            test_home_operator_target_keeps_original_request
        ; test_case "an ask waits once however many questions it holds" `Quick
            test_an_ask_waits_once_however_many_questions_it_holds
        ; test_case "the total adds the questions" `Quick
            test_the_strip_count_adds_the_questions
        ; test_case "the badge tells the kinds apart" `Quick
            test_the_badge_tells_the_kinds_apart
        ; test_case "an open question keeps the badge up until answered" `Quick
            test_an_open_question_keeps_the_badge_up_until_answered
        ; test_case "each open question is a row Enter opens" `Quick
            test_each_open_question_is_a_row_enter_opens
        ; test_case "two installations asking with one id are two targets" `Quick
            test_two_installations_asking_with_one_id_are_two_targets
        ; test_case "unread questions take no row and open nothing" `Quick
            test_unread_questions_take_no_row_and_open_nothing
        ] )
    ; ( "selection across refreshed agenda projections"
      , [ test_case "Home approval list retains its caller" `Quick
            test_home_approval_list_preserves_its_caller
        ; test_case "Task Goal references preserve registry reading truth" `Quick
            test_task_goal_reading_preserves_source_truth
        ; test_case "task routes are not Home decisions" `Quick
            test_task_route_is_not_a_home_decision
        ; test_case "Home and Agenda refuse noncurrent task sources" `Quick
            test_home_and_agenda_refuse_noncurrent_task_source
        ; test_case "same Keeper calls retain distinct navigation identities" `Quick
            test_distinct_calls_from_one_keeper_remain_reachable
        ; test_case "Goal reorder preserves selected identity" `Quick
            test_goal_selection_survives_refresh_reordering
        ; test_case "inserted Goals preserve selected Task identity" `Quick
            test_inserted_goals_do_not_retarget_a_selected_task
        ; test_case "removed Goal opens no replacement" `Quick
            test_removed_goal_does_not_select_its_replacement
        ] )
    ]
;;
